# Experimento: Escalabilidad dinámica de microservicios transaccionales en entorno Cloud

## Objetivo

Validar que el sistema TravelHub, basado en el patrón productor/consumidor con SQS,
escala automáticamente ante picos de tráfico transaccional y mantiene el **100% de tasa de éxito
(0% de caídas)** durante todo el ciclo de carga.

## Parámetros del experimento

| Parámetro | Valor |
|---|---|
| Carga base | **150 TPM** (Transacciones Por Minuto) |
| Pico máximo | **800 TPM** |
| Duración del pico sostenido | **2 horas** continuas |
| Umbral CPU para scale-out | **70%** |
| Política de escalado | Target Tracking (`ECSServiceAverageCPUUtilization`) |
| Tasa de éxito requerida | **100%** (HTTP 202, 0 rechazos) |

## Fases de la prueba de carga

| Fase | TPM | Duración (demo) | Duración (full) | Propósito |
|---|---|---|---|---|
| 1. Base | 150 | 1 min | 5 min | Comportamiento normal |
| 2. Rampa | 400 | 1 min | 5 min | Incremento progresivo |
| 3. Pico | 800 | 5 min | **2 horas** | Estrés máximo sostenido |
| 4. Reducción | 150 | 1 min | 5 min | Validar scale-in |

## Criterios de éxito

1. El autoescalado **se activa automáticamente** al superar CPU > 70%, sin intervención manual.
2. **100% de tasa de éxito** (HTTP 202) durante toda la rampa y el pico.
3. **0% de peticiones rechazadas** en ningún momento.
4. El sistema **escala hacia abajo** (scale-in) al cesar la carga.

## Métricas a recopilar

| Métrica | Fuente |
|---|---|
| CPU del servicio worker | CloudWatch `ECSServiceAverageCPUUtilization` |
| Códigos HTTP (202 vs 5xx) | Newman / CloudWatch ALB |
| Cold start de nuevas tareas | CloudWatch eventos ECS |
| Tiempos de respuesta (avg, p99) | Newman |
| Backlog SQS | CloudWatch `ApproximateNumberOfMessagesVisible` |

## Arquitectura

```
Internet
   │
[ALB]  ──► [api-producer  (Fargate)]  ──► [SQS ReservasQueue]
                                                    │
                                         [worker-consumer (Fargate)]
                                         [worker-consumer (Fargate)]  ← autoescala
                                         [worker-consumer (Fargate)]
```

| Componente | Rol | Tecnología |
|---|---|---|
| `api-producer` | Gestor de Reservas — recibe HTTP POST, encola en SQS y responde 202 | FastAPI + boto3 |
| `worker-consumer` | Servicio de Pagos — extrae mensajes de SQS y procesa en background | Python + boto3 |
| SQS `ReservasQueue` | Buffer asíncrono entre productor y consumidor | Amazon SQS Standard |
| ALB | Punto de entrada único con health checks automáticos | Application Load Balancer |
| ECS Fargate | Orquestación sin servidor de los contenedores | AWS Fargate |
| CloudWatch | Monitoreo + disparo de alarmas de autoescalado | Amazon CloudWatch |

---

## Prerrequisitos

- **AWS CLI v2** instalado y en el `PATH`.
- **Docker** instalado y corriendo.
- **Newman** (Postman CLI): `npm install -g newman`
- **Credenciales AWS** configuradas:

```bash
aws configure
# Introduce: Access Key ID, Secret Access Key, región (us-east-1), formato (json)
```

O mediante variables de entorno:

```bash
export AWS_ACCESS_KEY_ID=TU_ACCESS_KEY
export AWS_SECRET_ACCESS_KEY=TU_SECRET_KEY
export AWS_DEFAULT_REGION=us-east-1
```

---

## Paso 1: Desplegar toda la infraestructura en AWS

El script `setup_aws_experiment.sh` crea todos los recursos de forma **idempotente**:

```bash
./setup_aws_experiment.sh
```

**Recursos que crea:**

| Recurso | Detalle |
|---|---|
| SQS `ReservasQueue` | Cola principal con `VisibilityTimeout=30s`, long polling, redrive a DLQ |
| SQS `ReservasQueueDlq` | Dead Letter Queue — absorbe mensajes con más de 5 reintentos fallidos |
| CloudWatch alarm | Alerta cuando el backlog supera 50 mensajes |
| ECR repos | `api-producer` y `worker-consumer` — build + push automático desde el script |
| IAM roles | Execution role (pull ECR + logs) + task roles con permisos mínimos por servicio |
| Security groups | ALB-SG (80 público), API-SG (8000 desde ALB), Worker-SG (salida a SQS) |
| ECS Cluster | `sqs-experiment-cluster` |
| ALB | `sqs-experiment-alb` — internet-facing, HTTP:80 |
| Target Group | `sqs-experiment-api-tg` — health check en `/health` cada 15s |
| Fargate service — API | `api-producer-service`, 1 tarea, detrás del ALB |
| Fargate service — Worker | `worker-consumer-service`, 1–10 tareas, autoescalado CPU 70% |
| CloudWatch Log Groups | `/ecs/sqs-experiment-cluster/api-producer` y `.../worker-consumer` |

Al finalizar, el script imprime la URL del ALB:

```
http://sqs-experiment-alb-XXXXXXXXXX.us-east-1.elb.amazonaws.com
```

---

## Paso 2: Verificar que los servicios están saludables

```bash
# Reemplaza con tu URL del ALB
ALB=http://sqs-experiment-alb-XXXXXXXXXX.us-east-1.elb.amazonaws.com

# Health check
curl $ALB/health

# Pago de prueba
curl -X POST $ALB/api/v1/payments \
  -H "Content-Type: application/json" \
  -d '{"amount": 100, "currency": "USD", "stress_time": 1.0}'
```

Respuesta esperada del health check: `{"status": "healthy"}`  
Respuesta esperada del pago: `HTTP 202` con `transaction_id`

---

## Paso 3: Ejecutar las pruebas de carga

Desde la carpeta `tests/`:

```bash
# Modo demo (~8 min total — 4 fases a escala reducida)
BASE_URL=http://tu-alb.amazonaws.com ./run_load_test.sh

# Modo completo (2 horas de pico)
MODE=full BASE_URL=http://tu-alb.amazonaws.com ./run_load_test.sh
```

El script genera un archivo JSON por fase en `tests/results/` con métricas completas de Newman.

---

## Paso 4: Monitorear el autoescalado

### Estado del servicio worker en tiempo real

```bash
watch -n 10 "aws ecs describe-services \
  --cluster sqs-experiment-cluster \
  --services worker-consumer-service \
  --region us-east-1 \
  --query 'services[0].{desired:desiredCount,running:runningCount,pending:pendingCount}'"
```

### Historial de eventos de escalado

```bash
aws application-autoscaling describe-scaling-activities \
  --service-namespace ecs \
  --resource-id "service/sqs-experiment-cluster/worker-consumer-service" \
  --region us-east-1 \
  --query 'ScalingActivities[*].{Accion:Description,Hora:StartTime,Estado:StatusCode}' \
  --output table
```

### Backlog de la cola SQS

```bash
aws sqs get-queue-attributes \
  --queue-url https://sqs.us-east-1.amazonaws.com/TU_CUENTA/ReservasQueue \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
  --region us-east-1
```

### Logs de los contenedores en tiempo real

```bash
aws logs tail /ecs/sqs-experiment-cluster/api-producer    --follow --region us-east-1
aws logs tail /ecs/sqs-experiment-cluster/worker-consumer --follow --region us-east-1
```

---

## Paso 5: Verificar criterios de éxito

| # | Criterio | Cómo verificar | Esperado |
|---|---|---|---|
| 1 | Autoescalado automático | `describe-scaling-activities` / Consola ECS | Scale-out sin intervención al superar 70% CPU |
| 2 | Tasa de éxito 100% | Reportes Newman (`stats.requests.failed`) | 0 fallos en las 4 fases |
| 3 | 0% peticiones rechazadas | Newman — sin HTTP 5xx | Todos los requests HTTP 202 |
| 4 | Scale-in automático | `describe-services` — desiredCount baja tras el pico | Tareas se reducen gradualmente |
| 5 | Cold start medido | CloudWatch eventos ECS | Documentar tiempo entre alarma y tarea `RUNNING` |
| 6 | Tiempos de respuesta estables | Newman response times | < 2 000 ms promedio |
| 7 | Backlog SQS se drena | CloudWatch `ApproximateNumberOfMessagesVisible` | Vuelve a ~0 después del pico |

---

## Paso 6: Limpiar recursos al finalizar

```bash
./teardown_aws.sh
```

Elimina todos los recursos creados: servicios ECS, ALB, Target Group, ECR, SQS, roles IAM,
security groups y log groups.

---

## Variables configurables

Todas las variables tienen valores por defecto pero pueden sobreescribirse antes de ejecutar el script:

| Variable | Valor por defecto | Descripción |
|---|---|---|
| `AWS_DEFAULT_REGION` | `us-east-1` | Región de AWS |
| `SQS_QUEUE_NAME` | `ReservasQueue` | Nombre de la cola principal |
| `ECS_CLUSTER_NAME` | `sqs-experiment-cluster` | Nombre del cluster ECS |
| `ECR_API_REPO` | `api-producer` | Nombre del repositorio ECR del API |
| `ECR_WORKER_REPO` | `worker-consumer` | Nombre del repositorio ECR del worker |
