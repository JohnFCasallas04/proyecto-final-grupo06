#!/usr/bin/env bash
set -euo pipefail

# =============================================================
# Despliegue completo del experimento de escalabilidad en AWS
#
# Recursos que crea/actualiza (idempotente):
#   - SQS:  cola principal + DLQ + alarma CloudWatch
#   - ECR:  repos para api-producer y worker-consumer
#   - IAM:  execution role + task roles con permisos mínimos
#   - Networking: security groups (ALB, API, Worker)
#   - ECS Cluster Fargate
#   - ALB + Target Group + Listener (expone el API al exterior)
#   - Fargate service: api-producer (detrás del ALB)
#   - Fargate service: worker-consumer (autoscaling por CPU ≥70%)
#   - CloudWatch log groups para ambos servicios
#
# Prerrequisitos:
#   - AWS CLI v2 configurado (aws configure)
#   - Docker instalado y corriendo
#   - Ejecutar desde la raíz del proyecto
# =============================================================

# ── Variables configurables ───────────────────────────────────
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
QUEUE_NAME="${SQS_QUEUE_NAME:-ReservasQueue}"
DLQ_NAME="${SQS_DLQ_NAME:-${QUEUE_NAME}Dlq}"
CLUSTER_NAME="${ECS_CLUSTER_NAME:-sqs-experiment-cluster}"

ECR_API_REPO="${ECR_API_REPO:-api-producer}"
ECR_WORKER_REPO="${ECR_WORKER_REPO:-worker-consumer}"

API_SERVICE_NAME="api-producer-service"
WORKER_SERVICE_NAME="worker-consumer-service"
API_TASK_FAMILY="api-producer-fargate"
WORKER_TASK_FAMILY="worker-consumer-fargate"

EXEC_ROLE_NAME="ecsTaskExecutionRole-sqs-experiment"
API_TASK_ROLE_NAME="ecsApiTaskRole-sqs-experiment"
WORKER_TASK_ROLE_NAME="ecsWorkerTaskRole-sqs-experiment"

ALB_NAME="sqs-experiment-alb"
TG_NAME="sqs-experiment-api-tg"

LOG_GROUP_API="/ecs/${CLUSTER_NAME}/api-producer"
LOG_GROUP_WORKER="/ecs/${CLUSTER_NAME}/worker-consumer"

ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# ── Helpers ──────────────────────────────────────────────────
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
ok()   { echo "[$(date '+%H:%M:%S')] ✓ $*"; }
info() { echo ""; echo "══════════════════════════════════════════"; echo "  $*"; echo "══════════════════════════════════════════"; }

# ── Resumen y confirmación ────────────────────────────────────
info "DESPLIEGUE EXPERIMENTO ESCALABILIDAD — AWS"
echo "  Cuenta:   ${ACCOUNT_ID}"
echo "  Región:   ${REGION}"
echo "  Cluster:  ${CLUSTER_NAME}"
echo "  Cola SQS: ${QUEUE_NAME}"
echo ""
read -r -p "  ¿Continuar? [y/N] " CONFIRM
[[ "${CONFIRM}" =~ ^[yY]$ ]] || { echo "Cancelado."; exit 0; }

# ════════════════════════════════════════════════════════════
# 1. SQS — Cola principal + DLQ + alarma CloudWatch
# ════════════════════════════════════════════════════════════
info "1/9  SQS"

log "Creando/obteniendo DLQ (${DLQ_NAME})..."
DLQ_URL=$(aws sqs create-queue \
  --queue-name "${DLQ_NAME}" \
  --attributes VisibilityTimeout=30 \
  --region "${REGION}" \
  --query 'QueueUrl' --output text)

DLQ_ARN=$(aws sqs get-queue-attributes \
  --queue-url "${DLQ_URL}" --attribute-names QueueArn \
  --region "${REGION}" \
  --query 'Attributes.QueueArn' --output text)

log "Creando/obteniendo cola principal (${QUEUE_NAME})..."
# Usamos --cli-input-json para evitar problemas de escaping con el JSON del RedrivePolicy
_TMP_SQS=$(mktemp --suffix=.json)
python3 -c "
import json, sys
print(json.dumps({
  'QueueName': '${QUEUE_NAME}',
  'Attributes': {
    'VisibilityTimeout': '30',
    'ReceiveMessageWaitTimeSeconds': '10',
    'RedrivePolicy': json.dumps({'deadLetterTargetArn': '${DLQ_ARN}', 'maxReceiveCount': '5'})
  }
}))" > "${_TMP_SQS}"

QUEUE_URL=$(aws sqs create-queue \
  --cli-input-json "file://${_TMP_SQS}" \
  --region "${REGION}" \
  --query 'QueueUrl' --output text 2>/dev/null \
  || aws sqs get-queue-url --queue-name "${QUEUE_NAME}" \
       --region "${REGION}" --query 'QueueUrl' --output text)
rm -f "${_TMP_SQS}"

QUEUE_ARN=$(aws sqs get-queue-attributes \
  --queue-url "${QUEUE_URL}" --attribute-names QueueArn \
  --region "${REGION}" \
  --query 'Attributes.QueueArn' --output text)

aws cloudwatch put-metric-alarm \
  --alarm-name "${QUEUE_NAME}-BacklogHigh" \
  --metric-name ApproximateNumberOfMessagesVisible \
  --namespace AWS/SQS --statistic Average \
  --period 60 --evaluation-periods 1 \
  --threshold 50 --comparison-operator GreaterThanOrEqualToThreshold \
  --dimensions "Name=QueueName,Value=${QUEUE_NAME}" \
  --treat-missing-data notBreaching \
  --region "${REGION}" >/dev/null

ok "SQS listo: ${QUEUE_URL}"

# ════════════════════════════════════════════════════════════
# 2. CloudWatch Log Groups
# ════════════════════════════════════════════════════════════
info "2/9  CloudWatch Log Groups"

for LG in "${LOG_GROUP_API}" "${LOG_GROUP_WORKER}"; do
  aws logs create-log-group --log-group-name "${LG}" --region "${REGION}" 2>/dev/null || true
  ok "Log group: ${LG}"
done

# ════════════════════════════════════════════════════════════
# 3. IAM Roles
# ════════════════════════════════════════════════════════════
info "3/9  IAM Roles"

ASSUME_ECS='{
  "Version":"2012-10-17",
  "Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]
}'

# Execution role (pull ECR + push logs CloudWatch)
if ! aws iam get-role --role-name "${EXEC_ROLE_NAME}" >/dev/null 2>&1; then
  aws iam create-role --role-name "${EXEC_ROLE_NAME}" \
    --assume-role-policy-document "${ASSUME_ECS}" >/dev/null
  aws iam attach-role-policy --role-name "${EXEC_ROLE_NAME}" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy" >/dev/null
fi
EXEC_ROLE_ARN=$(aws iam get-role --role-name "${EXEC_ROLE_NAME}" --query 'Role.Arn' --output text)
ok "Execution role: ${EXEC_ROLE_ARN}"

# Task role — API Producer (SendMessage a SQS)
if ! aws iam get-role --role-name "${API_TASK_ROLE_NAME}" >/dev/null 2>&1; then
  aws iam create-role --role-name "${API_TASK_ROLE_NAME}" \
    --assume-role-policy-document "${ASSUME_ECS}" >/dev/null
fi
aws iam put-role-policy \
  --role-name "${API_TASK_ROLE_NAME}" \
  --policy-name "SqsProducerAccess" \
  --policy-document "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[{\"Effect\":\"Allow\",
      \"Action\":[\"sqs:SendMessage\",\"sqs:GetQueueUrl\",\"sqs:GetQueueAttributes\",\"sqs:CreateQueue\"],
      \"Resource\":\"${QUEUE_ARN}\"}]}" >/dev/null
API_TASK_ROLE_ARN=$(aws iam get-role --role-name "${API_TASK_ROLE_NAME}" --query 'Role.Arn' --output text)
ok "API task role: ${API_TASK_ROLE_ARN}"

# Task role — Worker Consumer (ReceiveMessage + DeleteMessage de SQS)
if ! aws iam get-role --role-name "${WORKER_TASK_ROLE_NAME}" >/dev/null 2>&1; then
  aws iam create-role --role-name "${WORKER_TASK_ROLE_NAME}" \
    --assume-role-policy-document "${ASSUME_ECS}" >/dev/null
fi
aws iam put-role-policy \
  --role-name "${WORKER_TASK_ROLE_NAME}" \
  --policy-name "SqsWorkerAccess" \
  --policy-document "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[{\"Effect\":\"Allow\",
      \"Action\":[\"sqs:ReceiveMessage\",\"sqs:DeleteMessage\",\"sqs:ChangeMessageVisibility\",\"sqs:GetQueueUrl\",\"sqs:GetQueueAttributes\",\"sqs:CreateQueue\"],
      \"Resource\":\"${QUEUE_ARN}\"}]}" >/dev/null
WORKER_TASK_ROLE_ARN=$(aws iam get-role --role-name "${WORKER_TASK_ROLE_NAME}" --query 'Role.Arn' --output text)
ok "Worker task role: ${WORKER_TASK_ROLE_ARN}"

# ════════════════════════════════════════════════════════════
# 4. ECR — Build + Push imágenes
# ════════════════════════════════════════════════════════════
info "4/9  ECR — Build & Push"

log "Login en ECR..."
aws ecr get-login-password --region "${REGION}" \
  | docker login --username AWS --password-stdin "${ECR_URI}"

for REPO in "${ECR_API_REPO}" "${ECR_WORKER_REPO}"; do
  aws ecr describe-repositories --repository-names "${REPO}" --region "${REGION}" >/dev/null 2>&1 \
    || aws ecr create-repository --repository-name "${REPO}" --region "${REGION}" >/dev/null
done

log "Construyendo y subiendo api-producer..."
docker build --platform linux/amd64 -t "${ECR_API_REPO}:latest" ./api_producer
docker tag "${ECR_API_REPO}:latest" "${ECR_URI}/${ECR_API_REPO}:latest"
docker push "${ECR_URI}/${ECR_API_REPO}:latest"
API_IMAGE="${ECR_URI}/${ECR_API_REPO}:latest"
ok "API image: ${API_IMAGE}"

log "Construyendo y subiendo worker-consumer..."
docker build --platform linux/amd64 -t "${ECR_WORKER_REPO}:latest" ./worker_consumer
docker tag "${ECR_WORKER_REPO}:latest" "${ECR_URI}/${ECR_WORKER_REPO}:latest"
docker push "${ECR_URI}/${ECR_WORKER_REPO}:latest"
WORKER_IMAGE="${ECR_URI}/${ECR_WORKER_REPO}:latest"
ok "Worker image: ${WORKER_IMAGE}"

# ════════════════════════════════════════════════════════════
# 5. Networking — VPC, subnets, security groups
# ════════════════════════════════════════════════════════════
info "5/9  Networking"

VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=isDefault,Values=true" \
  --region "${REGION}" --query 'Vpcs[0].VpcId' --output text)

# Obtener al menos 2 subnets públicas en distintas AZs (requerido por el ALB)
SUBNET_IDS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=defaultForAz,Values=true" \
  --region "${REGION}" --query 'Subnets[*].SubnetId' --output text | tr '\t' ' ')
SUBNET_ARR=( $SUBNET_IDS )
SUBNET_A="${SUBNET_ARR[0]}"
SUBNET_B="${SUBNET_ARR[1]:-${SUBNET_ARR[0]}}"

ok "VPC: ${VPC_ID}"
ok "Subnets: ${SUBNET_A}, ${SUBNET_B}"

# Security Group — ALB (inbound 80 desde internet)
ALB_SG_NAME="sqs-experiment-alb-sg"
ALB_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${ALB_SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --region "${REGION}" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")
if [[ "${ALB_SG_ID}" == "None" || -z "${ALB_SG_ID}" ]]; then
  ALB_SG_ID=$(aws ec2 create-security-group \
    --group-name "${ALB_SG_NAME}" \
    --description "ALB SG - sqs experiment" \
    --vpc-id "${VPC_ID}" --region "${REGION}" \
    --query 'GroupId' --output text)
  aws ec2 authorize-security-group-ingress \
    --group-id "${ALB_SG_ID}" \
    --protocol tcp --port 80 --cidr 0.0.0.0/0 \
    --region "${REGION}" >/dev/null
fi
ok "ALB SG: ${ALB_SG_ID}"

# Security Group — API (inbound 8000 desde ALB SG, todo outbound)
API_SG_NAME="sqs-experiment-api-sg"
API_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${API_SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --region "${REGION}" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")
if [[ "${API_SG_ID}" == "None" || -z "${API_SG_ID}" ]]; then
  API_SG_ID=$(aws ec2 create-security-group \
    --group-name "${API_SG_NAME}" \
    --description "API Fargate SG - sqs experiment" \
    --vpc-id "${VPC_ID}" --region "${REGION}" \
    --query 'GroupId' --output text)
  aws ec2 authorize-security-group-ingress \
    --group-id "${API_SG_ID}" \
    --protocol tcp --port 8000 \
    --source-group "${ALB_SG_ID}" \
    --region "${REGION}" >/dev/null
fi
ok "API SG: ${API_SG_ID}"

# Security Group — Worker (solo outbound a SQS/internet, sin inbound)
WORKER_SG_NAME="sqs-experiment-worker-sg"
WORKER_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${WORKER_SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --region "${REGION}" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")
if [[ "${WORKER_SG_ID}" == "None" || -z "${WORKER_SG_ID}" ]]; then
  WORKER_SG_ID=$(aws ec2 create-security-group \
    --group-name "${WORKER_SG_NAME}" \
    --description "Worker Fargate SG - sqs experiment" \
    --vpc-id "${VPC_ID}" --region "${REGION}" \
    --query 'GroupId' --output text)
fi
ok "Worker SG: ${WORKER_SG_ID}"

# ════════════════════════════════════════════════════════════
# 6. ECS Cluster
# ════════════════════════════════════════════════════════════
info "6/9  ECS Cluster"

aws ecs create-cluster --cluster-name "${CLUSTER_NAME}" \
  --region "${REGION}" >/dev/null 2>&1 || true
CLUSTER_ARN=$(aws ecs describe-clusters --clusters "${CLUSTER_NAME}" \
  --region "${REGION}" --query 'clusters[0].clusterArn' --output text)
ok "Cluster: ${CLUSTER_ARN}"

# ════════════════════════════════════════════════════════════
# 7. Task Definitions (API + Worker)
# ════════════════════════════════════════════════════════════
info "7/9  Task Definitions"

log "Registrando task definition — api-producer..."
API_TASK_DEF_ARN=$(aws ecs register-task-definition \
  --region "${REGION}" \
  --cli-input-json "{
    \"family\": \"${API_TASK_FAMILY}\",
    \"networkMode\": \"awsvpc\",
    \"requiresCompatibilities\": [\"FARGATE\"],
    \"cpu\": \"256\",
    \"memory\": \"512\",
    \"executionRoleArn\": \"${EXEC_ROLE_ARN}\",
    \"taskRoleArn\": \"${API_TASK_ROLE_ARN}\",
    \"containerDefinitions\": [{
      \"name\": \"api-producer\",
      \"image\": \"${API_IMAGE}\",
      \"essential\": true,
      \"portMappings\": [{\"containerPort\": 8000, \"protocol\": \"tcp\"}],
      \"environment\": [
        {\"name\": \"AWS_DEFAULT_REGION\", \"value\": \"${REGION}\"},
        {\"name\": \"SQS_QUEUE_NAME\",     \"value\": \"${QUEUE_NAME}\"}
      ],
      \"logConfiguration\": {
        \"logDriver\": \"awslogs\",
        \"options\": {
          \"awslogs-group\":         \"${LOG_GROUP_API}\",
          \"awslogs-region\":        \"${REGION}\",
          \"awslogs-stream-prefix\": \"api\"
        }
      }
    }]
  }" \
  --query 'taskDefinition.taskDefinitionArn' --output text)
ok "API task def: ${API_TASK_DEF_ARN}"

log "Registrando task definition — worker-consumer..."
WORKER_TASK_DEF_ARN=$(aws ecs register-task-definition \
  --region "${REGION}" \
  --cli-input-json "{
    \"family\": \"${WORKER_TASK_FAMILY}\",
    \"networkMode\": \"awsvpc\",
    \"requiresCompatibilities\": [\"FARGATE\"],
    \"cpu\": \"256\",
    \"memory\": \"512\",
    \"executionRoleArn\": \"${EXEC_ROLE_ARN}\",
    \"taskRoleArn\": \"${WORKER_TASK_ROLE_ARN}\",
    \"containerDefinitions\": [{
      \"name\": \"worker-consumer\",
      \"image\": \"${WORKER_IMAGE}\",
      \"essential\": true,
      \"environment\": [
        {\"name\": \"AWS_DEFAULT_REGION\", \"value\": \"${REGION}\"},
        {\"name\": \"SQS_QUEUE_NAME\",     \"value\": \"${QUEUE_NAME}\"}
      ],
      \"logConfiguration\": {
        \"logDriver\": \"awslogs\",
        \"options\": {
          \"awslogs-group\":         \"${LOG_GROUP_WORKER}\",
          \"awslogs-region\":        \"${REGION}\",
          \"awslogs-stream-prefix\": \"worker\"
        }
      }
    }]
  }" \
  --query 'taskDefinition.taskDefinitionArn' --output text)
ok "Worker task def: ${WORKER_TASK_DEF_ARN}"

# ════════════════════════════════════════════════════════════
# 8. ALB + Target Group + Listener
# ════════════════════════════════════════════════════════════
info "8/9  ALB + Target Group"

# ALB
ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names "${ALB_NAME}" --region "${REGION}" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || echo "None")
if [[ "${ALB_ARN}" == "None" || -z "${ALB_ARN}" ]]; then
  log "Creando ALB (puede tardar ~1-2 min)..."
  ALB_ARN=$(aws elbv2 create-load-balancer \
    --name "${ALB_NAME}" \
    --type application \
    --scheme internet-facing \
    --subnets "${SUBNET_A}" "${SUBNET_B}" \
    --security-groups "${ALB_SG_ID}" \
    --region "${REGION}" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text)
  aws elbv2 wait load-balancer-available \
    --load-balancer-arns "${ALB_ARN}" --region "${REGION}"
fi
ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "${ALB_ARN}" --region "${REGION}" \
  --query 'LoadBalancers[0].DNSName' --output text)
ok "ALB: ${ALB_DNS}"

# Target Group
TG_ARN=$(aws elbv2 describe-target-groups \
  --names "${TG_NAME}" --region "${REGION}" \
  --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || echo "None")
if [[ "${TG_ARN}" == "None" || -z "${TG_ARN}" ]]; then
  TG_ARN=$(aws elbv2 create-target-group \
    --name "${TG_NAME}" \
    --protocol HTTP --port 8000 \
    --vpc-id "${VPC_ID}" \
    --target-type ip \
    --health-check-path "/health" \
    --health-check-interval-seconds 15 \
    --healthy-threshold-count 2 \
    --region "${REGION}" \
    --query 'TargetGroups[0].TargetGroupArn' --output text)
fi
ok "Target Group: ${TG_ARN}"

# Listener puerto 80
LISTENER_ARN=$(aws elbv2 describe-listeners \
  --load-balancer-arn "${ALB_ARN}" --region "${REGION}" \
  --query 'Listeners[?Port==`80`].ListenerArn | [0]' --output text 2>/dev/null || echo "None")
if [[ "${LISTENER_ARN}" == "None" || -z "${LISTENER_ARN}" ]]; then
  aws elbv2 create-listener \
    --load-balancer-arn "${ALB_ARN}" \
    --protocol HTTP --port 80 \
    --default-actions "Type=forward,TargetGroupArn=${TG_ARN}" \
    --region "${REGION}" >/dev/null
fi
ok "Listener HTTP:80 configurado"

# ════════════════════════════════════════════════════════════
# 9. Fargate Services + Autoscaling
# ════════════════════════════════════════════════════════════
info "9/9  Fargate Services"

NETWORK_API="awsvpcConfiguration={subnets=[\"${SUBNET_A}\",\"${SUBNET_B}\"],securityGroups=[\"${API_SG_ID}\"],assignPublicIp=\"ENABLED\"}"
NETWORK_WORKER="awsvpcConfiguration={subnets=[\"${SUBNET_A}\",\"${SUBNET_B}\"],securityGroups=[\"${WORKER_SG_ID}\"],assignPublicIp=\"ENABLED\"}"

# ── Servicio API Producer ─────────────────────────────────
log "Desplegando servicio api-producer..."
API_SVC_STATUS=$(aws ecs describe-services \
  --cluster "${CLUSTER_NAME}" --services "${API_SERVICE_NAME}" \
  --region "${REGION}" \
  --query 'services[0].status' --output text 2>/dev/null || echo "NOTFOUND")

if [[ "${API_SVC_STATUS}" == "ACTIVE" ]]; then
  aws ecs update-service \
    --cluster "${CLUSTER_NAME}" --service "${API_SERVICE_NAME}" \
    --task-definition "${API_TASK_DEF_ARN}" \
    --region "${REGION}" >/dev/null
else
  aws ecs create-service \
    --cluster "${CLUSTER_NAME}" \
    --service-name "${API_SERVICE_NAME}" \
    --task-definition "${API_TASK_DEF_ARN}" \
    --desired-count 1 \
    --launch-type FARGATE \
    --network-configuration "${NETWORK_API}" \
    --load-balancers "targetGroupArn=${TG_ARN},containerName=api-producer,containerPort=8000" \
    --health-check-grace-period-seconds 30 \
    --region "${REGION}" >/dev/null
fi
ok "Servicio API creado/actualizado"

# ── Servicio Worker Consumer ──────────────────────────────
log "Desplegando servicio worker-consumer..."
WORKER_SVC_STATUS=$(aws ecs describe-services \
  --cluster "${CLUSTER_NAME}" --services "${WORKER_SERVICE_NAME}" \
  --region "${REGION}" \
  --query 'services[0].status' --output text 2>/dev/null || echo "NOTFOUND")

if [[ "${WORKER_SVC_STATUS}" == "ACTIVE" ]]; then
  aws ecs update-service \
    --cluster "${CLUSTER_NAME}" --service "${WORKER_SERVICE_NAME}" \
    --task-definition "${WORKER_TASK_DEF_ARN}" \
    --region "${REGION}" >/dev/null
else
  aws ecs create-service \
    --cluster "${CLUSTER_NAME}" \
    --service-name "${WORKER_SERVICE_NAME}" \
    --task-definition "${WORKER_TASK_DEF_ARN}" \
    --desired-count 1 \
    --launch-type FARGATE \
    --network-configuration "${NETWORK_WORKER}" \
    --region "${REGION}" >/dev/null
fi
ok "Servicio Worker creado/actualizado"

# ── Autoscaling del Worker (Target Tracking CPU ≥ 70%) ───
log "Configurando autoscaling del worker (CPU target 70%)..."
aws application-autoscaling register-scalable-target \
  --service-namespace ecs \
  --resource-id "service/${CLUSTER_NAME}/${WORKER_SERVICE_NAME}" \
  --scalable-dimension ecs:service:DesiredCount \
  --min-capacity 1 --max-capacity 10 \
  --region "${REGION}" >/dev/null

aws application-autoscaling put-scaling-policy \
  --policy-name "${WORKER_SERVICE_NAME}-cpu-scaling" \
  --service-namespace ecs \
  --resource-id "service/${CLUSTER_NAME}/${WORKER_SERVICE_NAME}" \
  --scalable-dimension ecs:service:DesiredCount \
  --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration '{
    "TargetValue": 70.0,
    "PredefinedMetricSpecification": {"PredefinedMetricType": "ECSServiceAverageCPUUtilization"},
    "ScaleOutCooldown": 60,
    "ScaleInCooldown": 120
  }' \
  --region "${REGION}" >/dev/null
ok "Autoscaling configurado (CPU 70%, min 1, max 10 tasks)"

# ════════════════════════════════════════════════════════════
# Esperar que los servicios estén estables
# ════════════════════════════════════════════════════════════
echo ""
log "Esperando que los servicios estén estables (puede tardar 2-3 min)..."
aws ecs wait services-stable \
  --cluster "${CLUSTER_NAME}" \
  --services "${API_SERVICE_NAME}" "${WORKER_SERVICE_NAME}" \
  --region "${REGION}"

# ════════════════════════════════════════════════════════════
# Resumen final
# ════════════════════════════════════════════════════════════
cat <<SUMMARY

══════════════════════════════════════════════════════════════
  DESPLIEGUE COMPLETADO ✓
══════════════════════════════════════════════════════════════

  URL del API (ALB):
    http://${ALB_DNS}

  Health check:
    curl http://${ALB_DNS}/health

  Prueba de pago:
    curl -X POST http://${ALB_DNS}/api/v1/payments \\
      -H "Content-Type: application/json" \\
      -d '{"amount":100,"currency":"USD","stress_time":1.0}'

  Prueba de carga con Newman (modo demo ~8 min):
    BASE_URL=http://${ALB_DNS} ./tests/run_load_test.sh

  Prueba de carga con Newman (modo completo 2h):
    MODE=full BASE_URL=http://${ALB_DNS} ./tests/run_load_test.sh

  Logs en tiempo real:
    aws logs tail ${LOG_GROUP_API}    --follow --region ${REGION}
    aws logs tail ${LOG_GROUP_WORKER} --follow --region ${REGION}

  Monitorear autoscaling:
    watch -n 10 "aws ecs describe-services \\
      --cluster ${CLUSTER_NAME} \\
      --services ${WORKER_SERVICE_NAME} \\
      --region ${REGION} \\
      --query 'services[0].{desired:desiredCount,running:runningCount,pending:pendingCount}'"

══════════════════════════════════════════════════════════════
  Para destruir todos los recursos al terminar:
    ./teardown_aws.sh
══════════════════════════════════════════════════════════════
SUMMARY
