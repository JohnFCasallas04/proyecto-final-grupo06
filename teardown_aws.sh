#!/usr/bin/env bash
set -euo pipefail

# =============================================================
# Destruye todos los recursos AWS creados por setup_aws_experiment.sh
# =============================================================

REGION="${AWS_DEFAULT_REGION:-us-east-1}"
QUEUE_NAME="${SQS_QUEUE_NAME:-ReservasQueue}"
DLQ_NAME="${SQS_DLQ_NAME:-${QUEUE_NAME}Dlq}"
CLUSTER_NAME="${ECS_CLUSTER_NAME:-sqs-experiment-cluster}"
API_SERVICE_NAME="api-producer-service"
WORKER_SERVICE_NAME="worker-consumer-service"
ALB_NAME="sqs-experiment-alb"
TG_NAME="sqs-experiment-api-tg"
ECR_API_REPO="api-producer"
ECR_WORKER_REPO="worker-consumer"
LOG_GROUP_API="/ecs/${CLUSTER_NAME}/api-producer"
LOG_GROUP_WORKER="/ecs/${CLUSTER_NAME}/worker-consumer"

ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)

echo "══════════════════════════════════════════"
echo "  TEARDOWN — Eliminando recursos AWS"
echo "  Cuenta: ${ACCOUNT_ID} | Región: ${REGION}"
echo "══════════════════════════════════════════"
echo ""
read -r -p "  ¿Eliminar TODOS los recursos del experimento? [y/N] " CONFIRM
[[ "${CONFIRM}" =~ ^[yY]$ ]] || { echo "Cancelado."; exit 0; }

log()  { echo "[$(date '+%H:%M:%S')] $*"; }

# 1. Autoscaling
log "Eliminando políticas de autoscaling..."
aws application-autoscaling delete-scaling-policy \
  --policy-name "${WORKER_SERVICE_NAME}-cpu-scaling" \
  --service-namespace ecs \
  --resource-id "service/${CLUSTER_NAME}/${WORKER_SERVICE_NAME}" \
  --scalable-dimension ecs:service:DesiredCount \
  --region "${REGION}" 2>/dev/null && log "  Scaling policy eliminada" || true

aws application-autoscaling deregister-scalable-target \
  --service-namespace ecs \
  --resource-id "service/${CLUSTER_NAME}/${WORKER_SERVICE_NAME}" \
  --scalable-dimension ecs:service:DesiredCount \
  --region "${REGION}" 2>/dev/null && log "  Scalable target eliminado" || true

# 2. Servicios ECS (bajar a 0 y luego eliminar)
for SVC in "${API_SERVICE_NAME}" "${WORKER_SERVICE_NAME}"; do
  log "Bajando y eliminando servicio ECS: ${SVC}..."
  aws ecs update-service --cluster "${CLUSTER_NAME}" --service "${SVC}" \
    --desired-count 0 --region "${REGION}" >/dev/null 2>/dev/null || true
  aws ecs delete-service --cluster "${CLUSTER_NAME}" --service "${SVC}" \
    --force --region "${REGION}" >/dev/null 2>/dev/null && log "  ${SVC} eliminado" || true
done

# 3. ALB y Target Group
log "Eliminando ALB (${ALB_NAME})..."
ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names "${ALB_NAME}" --region "${REGION}" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || echo "None")
if [[ "${ALB_ARN}" != "None" && -n "${ALB_ARN}" ]]; then
  # Eliminar listeners primero
  LISTENERS=$(aws elbv2 describe-listeners \
    --load-balancer-arn "${ALB_ARN}" --region "${REGION}" \
    --query 'Listeners[*].ListenerArn' --output text 2>/dev/null || true)
  for L in $LISTENERS; do
    aws elbv2 delete-listener --listener-arn "${L}" --region "${REGION}" >/dev/null 2>/dev/null || true
  done
  aws elbv2 delete-load-balancer --load-balancer-arn "${ALB_ARN}" --region "${REGION}" >/dev/null
  log "  ALB eliminado (esperando..."
  aws elbv2 wait load-balancers-deleted --load-balancer-arns "${ALB_ARN}" --region "${REGION}" 2>/dev/null || true
fi

TG_ARN=$(aws elbv2 describe-target-groups \
  --names "${TG_NAME}" --region "${REGION}" \
  --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || echo "None")
[[ "${TG_ARN}" != "None" && -n "${TG_ARN}" ]] && \
  aws elbv2 delete-target-group --target-group-arn "${TG_ARN}" --region "${REGION}" >/dev/null 2>/dev/null \
  && log "  Target group eliminado" || true

# 4. Cluster ECS
log "Eliminando cluster ECS (${CLUSTER_NAME})..."
aws ecs delete-cluster --cluster "${CLUSTER_NAME}" --region "${REGION}" >/dev/null 2>/dev/null \
  && log "  Cluster eliminado" || true

# 5. Security Groups
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" \
  --region "${REGION}" --query 'Vpcs[0].VpcId' --output text)
for SG_NAME in "sqs-experiment-api-sg" "sqs-experiment-worker-sg" "sqs-experiment-alb-sg"; do
  SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
    --region "${REGION}" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")
  [[ "${SG_ID}" != "None" && -n "${SG_ID}" ]] && \
    aws ec2 delete-security-group --group-id "${SG_ID}" --region "${REGION}" >/dev/null 2>/dev/null \
    && log "  SG ${SG_NAME} eliminado" || true
done

# 6. Roles IAM
for ROLE in "ecsTaskExecutionRole-sqs-experiment" "ecsApiTaskRole-sqs-experiment" "ecsWorkerTaskRole-sqs-experiment"; do
  log "Eliminando rol IAM: ${ROLE}..."
  # Quitar políticas inline
  INLINE=$(aws iam list-role-policies --role-name "${ROLE}" \
    --query 'PolicyNames' --output text 2>/dev/null || true)
  for P in $INLINE; do
    aws iam delete-role-policy --role-name "${ROLE}" --policy-name "${P}" 2>/dev/null || true
  done
  # Desadjuntar políticas managed
  MANAGED=$(aws iam list-attached-role-policies --role-name "${ROLE}" \
    --query 'AttachedPolicies[*].PolicyArn' --output text 2>/dev/null || true)
  for P in $MANAGED; do
    aws iam detach-role-policy --role-name "${ROLE}" --policy-arn "${P}" 2>/dev/null || true
  done
  aws iam delete-role --role-name "${ROLE}" 2>/dev/null \
    && log "  Rol ${ROLE} eliminado" || true
done

# 7. ECR
for REPO in "${ECR_API_REPO}" "${ECR_WORKER_REPO}"; do
  log "Eliminando repositorio ECR: ${REPO}..."
  aws ecr delete-repository --repository-name "${REPO}" --force \
    --region "${REGION}" >/dev/null 2>/dev/null \
    && log "  ECR ${REPO} eliminado" || true
done

# 8. SQS
for URL in "$(aws sqs get-queue-url --queue-name "${QUEUE_NAME}" --region "${REGION}" --query 'QueueUrl' --output text 2>/dev/null || echo '')" \
           "$(aws sqs get-queue-url --queue-name "${DLQ_NAME}"   --region "${REGION}" --query 'QueueUrl' --output text 2>/dev/null || echo '')"; do
  [[ -n "${URL}" ]] && \
    aws sqs delete-queue --queue-url "${URL}" --region "${REGION}" >/dev/null 2>/dev/null \
    && log "  Cola SQS eliminada: ${URL}" || true
done

# 9. CloudWatch alarma y log groups
aws cloudwatch delete-alarms --alarm-names "${QUEUE_NAME}-BacklogHigh" \
  --region "${REGION}" 2>/dev/null || true
for LG in "${LOG_GROUP_API}" "${LOG_GROUP_WORKER}"; do
  aws logs delete-log-group --log-group-name "${LG}" \
    --region "${REGION}" 2>/dev/null \
    && log "  Log group ${LG} eliminado" || true
done

echo ""
echo "══════════════════════════════════════════"
echo "  Teardown completado ✓"
echo "══════════════════════════════════════════"
