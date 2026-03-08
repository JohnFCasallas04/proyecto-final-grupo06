# Experimento de Escalabilidad — TravelHub
## Escalabilidad dinámica de microservicios transaccionales en entorno Cloud

Implementación del experimento de escalabilidad del proyecto final, basado en el patrón
**productor/consumidor** con Amazon SQS y autoescalado automático en AWS ECS Fargate.

---

## Arquitectura

```
Internet
   │
[ALB]  ──► [api-producer  (Fargate)]  ──► [SQS ReservasQueue]
                                                    │
                                         [worker-consumer (Fargate)]
                                         [worker-consumer (Fargate)]  ← autoescala 1..10
                                         [worker-consumer (Fargate)]
```

| Servicio | Descripción | Tecnología |
|---|---|---|
| `api-producer` | Gestor de Reservas — recibe pagos, encola en SQS, responde `202` | FastAPI + boto3 |
| `worker-consumer` | Servicio de Pagos — consume mensajes de SQS en background | Python + boto3 |
| SQS `ReservasQueue` | Buffer asíncrono — absorbe picos sin rechazar peticiones | Amazon SQS |
| ALB | Punto de entrada único con health checks automáticos | AWS ALB |
| ECS Fargate | Orquestación sin servidor + autoescalado por CPU (umbral 70%) | AWS Fargate |

---

## Estructura del repositorio

```
.
├── api_producer/               # Gestor de Reservas (FastAPI)
│   ├── app.py
│   ├── Dockerfile
│   └── requirements.txt
├── worker_consumer/            # Servicio de Pagos (consumidor SQS)
│   ├── worker.py
│   ├── Dockerfile
│   └── requirements.txt
├── tests/
│   ├── postman_collection.json # Coleccion Newman con Health Check + Enviar Pago
│   ├── data.csv                # Datos de prueba para las iteraciones
│   ├── run_load_test.sh        # Orquesta las 4 fases de carga (demo / full)
│   └── results/                # Reportes JSON por fase + resumen CSV/JSON
├── docker-compose.yml          # Entorno local con ElasticMQ
├── elasticmq.conf              # Configuracion de ElasticMQ
├── setup_aws_experiment.sh     # Despliega toda la infraestructura en AWS
├── teardown_aws.sh             # Elimina todos los recursos de AWS
├── docs_experimento_escalabilidad_aws.md  # Guia completa del experimento en AWS
└── docs_guia_local.md          # Guia para replicar el experimento en local
```

---

## Inicio rapido — AWS

### 1. Prerrequisitos

```bash
# AWS CLI configurado
aws configure

# Docker corriendo
docker info

# Newman instalado
npm install -g newman
```

### 2. Desplegar infraestructura

```bash
./setup_aws_experiment.sh
```

Crea automaticamente: SQS, ECR (build + push de imagenes), IAM roles, Security Groups,
ECS Cluster, ALB, Target Group, Fargate services y politica de autoescalado.

Al finalizar imprime la URL del ALB:
```
http://sqs-experiment-alb-XXXXXXXXXX.us-east-1.elb.amazonaws.com
```

### 3. Ejecutar pruebas de carga

```bash
# Modo demo (~8 min, 4700 requests)
BASE_URL=http://tu-alb.amazonaws.com ./tests/run_load_test.sh

# Modo completo (2 horas de pico)
MODE=full BASE_URL=http://tu-alb.amazonaws.com ./tests/run_load_test.sh
```

### 4. Monitorear autoescalado

```bash
# Estado del servicio worker en tiempo real
watch -n 10 "aws ecs describe-services \
  --cluster sqs-experiment-cluster \
  --services worker-consumer-service \
  --region us-east-1 \
  --query 'services[0].{desired:desiredCount,running:runningCount}'"

# Logs del worker
aws logs tail /ecs/sqs-experiment-cluster/worker-consumer --follow --region us-east-1
```

### 5. Limpiar recursos

```bash
./teardown_aws.sh
```

---

## Inicio rapido — Local

```bash
# Levantar entorno con ElasticMQ (emulador SQS local)
docker compose up --build -d

# Verificar
curl http://localhost:8000/health

# Prueba de carga demo
cd tests && ./run_load_test.sh
```

Ver la guia completa en [`docs_guia_local.md`](docs_guia_local.md).

---

## Fases del experimento

| Fase | TPM | Demo | Full | Requests (demo) |
|---|---|---|---|---|
| 1. Base | 150 | 1 min | 5 min | 150 |
| 2. Rampa | 400 | 1 min | 5 min | 400 |
| 3. Pico | 800 | 5 min | 2 horas | 4 000 |
| 4. Reduccion | 150 | 1 min | 5 min | 150 |

---

## Resultados del experimento (AWS — 2026-03-08)

| Fase | Requests | Tasa exito | Lat avg | Lat p99 |
|---|---|---|---|---|
| Base (150 TPM) | 150 | **100%** | 108 ms | 242 ms |
| Rampa (400 TPM) | 400 | **100%** | 100 ms | 143 ms |
| Pico (800 TPM) | 4 000 | **100%** | 99 ms | 154 ms |
| Reduccion (150 TPM) | 150 | **100%** | 100 ms | 137 ms |

**Autoescalado:** el servicio worker escalo de **1 a 10 tareas** automaticamente en ~9 min.  
**Backlog:** absorbio hasta 1 067 mensajes y lo dreno a **0** al llegar a 10 tareas.

---

## Documentacion

| Documento | Descripcion |
|---|---|
| [`docs_experimento_escalabilidad_aws.md`](docs_experimento_escalabilidad_aws.md) | Guia completa del experimento en AWS (objetivo, arquitectura, pasos, monitoreo) |
| [`docs_guia_local.md`](docs_guia_local.md) | Guia para replicar el experimento en local con Docker Compose |
