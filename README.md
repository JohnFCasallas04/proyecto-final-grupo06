# Experimento Asincrono con SQS (Productor/Consumidor)

Este repositorio simula el patron de resiliencia ante picos de trafico:

- `api_productor`: recibe peticiones y responde `HTTP 202` de inmediato.
- `worker_consumidor`: procesa en background desde la cola.
- `sqs-local` (ElasticMQ): emula Amazon SQS localmente.

## Estructura

- `docker-compose.yml`
- `api_productor/`
  - `app.py`
  - `Dockerfile`
  - `requirements.txt`
- `worker_consumidor/`
  - `worker.py`
  - `Dockerfile`
  - `requirements.txt`

## Levantar el entorno

```bash
docker compose up --build -d
```

Ver estado:

```bash
docker compose ps
docker compose logs -f api-producer
docker compose logs -f worker-consumer
```

## Probar el API

Salud:

```bash
curl http://localhost:8000/health
```

Pago (se encola y responde rapido):

```bash
curl -X POST http://localhost:8000/api/v1/pagos \
  -H "Content-Type: application/json" \
  -d '{"cantidad":150.0,"moneda":"USD","tiempo_estres":1.2}'
```

## Simular autoescalado local

Incrementar workers:

```bash
docker compose up -d --scale worker-consumidor=4
```

Reducir workers:

```bash
docker compose up -d --scale worker-consumidor=1
```

## Variables importantes

- `SQS_ENDPOINT_URL`: endpoint de SQS (local o AWS).
- `SQS_QUEUE_NAME`: nombre de la cola.
- `AWS_DEFAULT_REGION`: region AWS.

En AWS, solo cambia variables de entorno para apuntar al SQS real.