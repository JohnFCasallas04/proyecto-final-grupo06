## Guía: Experimento de escalabilidad en entorno local

Esta guía te permite replicar el experimento completo en tu máquina usando
Docker Compose (con ElasticMQ como SQS local) y Newman para las pruebas de carga.
Así puedes validar todo antes de ir a AWS.

---

### Requisitos del experimento (resumen del NotebookLM)

| Concepto | Valor |
|---|---|
| Carga base | 150 TPM (Transacciones Por Minuto) |
| Pico máximo | 800 TPM |
| Duración del pico (AWS) | 2 horas continuas |
| Duración del pico (local) | 10 min (configurable) |
| Umbral de CPU para scale-out | 70% |
| Tasa de éxito requerida | 100% (HTTP 202, 0% caídas) |
| Métricas clave | CPU, RequestCount, códigos HTTP, cold start, tiempos de respuesta |

---

### Prerrequisitos de software

| Herramienta | Instalación |
|---|---|
| Docker + Docker Compose | Ya instalados |
| Node.js (v18+) | Para instalar Newman |
| Newman | `npm install -g newman` |
| newman-reporter-htmlextra (opcional) | `npm install -g newman-reporter-htmlextra` |

Verificación rápida:

```bash
docker compose version
node --version
newman --version
```

---

### Paso 1: Levantar el entorno local

Desde la raíz del proyecto:

```bash
docker compose up --build -d
```

Esto levanta:

| Servicio | Puerto | Descripción |
|---|---|---|
| `sqs-local` (ElasticMQ) | 9324, 9325 | Emula Amazon SQS en local |
| `api-producer` (FastAPI) | 8000 | Recibe peticiones HTTP, encola en SQS |
| `worker-consumer` | - | Lee de SQS, procesa con carga de CPU simulada |

Verifica que todo esté corriendo:

```bash
docker compose ps
```

Deberías ver los 3 servicios en estado `running`.

---

### Paso 2: Verificar que la API responde

```bash
curl http://localhost:8000/health
```

Respuesta esperada:

```json
{"status": "healthy"}
```

Prueba manual de un pago:

```bash
curl -X POST http://localhost:8000/api/v1/payments \
  -H "Content-Type: application/json" \
  -d '{"amount": 150.0, "currency": "USD", "stress_time": 1.0}'
```

Respuesta esperada (HTTP 202):

```json
{
  "status": "processing",
  "transaction_id": "uuid-aquí",
  "message": "Payment received and queued. Asynchronous processing started."
}
```

Verifica que el worker lo procesó:

```bash
docker compose logs -f worker-consumer
```

Deberías ver algo como:

```
Processing transaction <uuid> with CPU load of 1.0s
Transaction <uuid> completed and deleted from SQS.
```

---

### Paso 3: Entender la estructura de pruebas

```
tests/
├── postman_collection.json   # Colección Postman con 2 requests
├── data.csv                  # Datos de prueba (amount, currency, stress_time)
├── run_load_test.sh          # Script que orquesta las 4 fases con Newman
└── results/                  # Se crea automáticamente con los reportes
```

**`postman_collection.json`** contiene:

- **Health Check**: `GET /health` con test de status 200.
- **Enviar Pago**: `POST /api/v1/payments` con:
  - Pre-request script que genera datos aleatorios si no vienen del CSV.
  - Tests que validan: HTTP 202, presencia de `transaction_id`, y tiempo de respuesta < 2s.

**`data.csv`** tiene 15 filas de datos de ejemplo que Newman rota cíclicamente en cada iteración.

**`run_load_test.sh`** ejecuta 4 fases secuenciales en dos modos:

**Modo `demo` (por defecto, ~8 min total)**

| Fase | Nombre | TPM | Duración | Requests |
|---|---|---|---|---|
| 1 | `01_base` | 150 | 1 min | 150 |
| 2 | `02_rampa` | 400 | 1 min | 400 |
| 3 | `03_pico` | 800 | 5 min | 4 000 |
| 4 | `04_reduccion` | 150 | 1 min | 150 |

**Modo `full` (experimento completo según diseño)**

| Fase | Nombre | TPM | Duración | Requests |
|---|---|---|---|---|
| 1 | `01_base` | 150 | 5 min | 750 |
| 2 | `02_rampa` | 400 | 5 min | 2 000 |
| 3 | `03_pico` | 800 | 120 min | 96 000 |
| 4 | `04_reduccion` | 150 | 5 min | 750 |

Las proporciones de carga son idénticas en ambos modos; solo cambia la duración del pico.

El delay entre requests se calcula como: `(60000 ms) / TPM`. Ejemplo para 800 TPM: ~75 ms entre requests.

---

### Paso 4: Ejecutar las pruebas de carga

#### 4.1. Modo demo (~8 min, por defecto)

Demuestra el patrón completo de escalabilidad a escala reducida. Mismas 4 fases y proporciones, sin esperar 2 horas.

```bash
cd tests
./run_load_test.sh
```

#### 4.2. Modo completo (2 horas de pico, para el informe final)

```bash
cd tests
MODE=full ./run_load_test.sh
```

#### 4.3. Ejecutar solo una fase manualmente

Si quieres aislar y observar un nivel de carga específico:

```bash
# 800 TPM durante 2 minutos (1600 requests, 75ms de delay)
newman run postman_collection.json \
  --env-var "base_url=http://localhost:8000" \
  --iteration-data data.csv \
  --iteration-count 1600 \
  --delay-request 75 \
  --folder "Enviar Pago" \
  --reporters cli,json \
  --reporter-json-export results/solo_pico.json
```

#### 4.4. Apuntar a otra URL (por ejemplo AWS)

```bash
BASE_URL=http://mi-alb.amazonaws.com ./run_load_test.sh
# o en modo completo:
MODE=full BASE_URL=http://mi-alb.amazonaws.com ./run_load_test.sh
```

---

### Paso 5: Simular autoescalado local de workers

Mientras las pruebas de carga corren, abre otra terminal y varía el número de workers:

```bash
# Empezar con 1 worker (observar backlog creciendo)
docker compose up -d --scale worker-consumer=1

# Escalar a 4 workers (observar cómo drena más rápido)
docker compose up -d --scale worker-consumer=4

# Escalar a 8 workers (máximo throughput local)
docker compose up -d --scale worker-consumer=8

# Volver a 1 worker (simular scale-in)
docker compose up -d --scale worker-consumer=1
```

---

### Paso 6: Monitorear durante las pruebas

#### 6.1. Logs de los workers

```bash
docker compose logs -f worker-consumer
```

Verás la cadencia de procesamiento. Con más workers, más mensajes procesados en paralelo.

#### 6.2. Estado de la cola SQS (ElasticMQ)

ElasticMQ expone una UI en el puerto 9325:

```
http://localhost:9325
```

También puedes consultar las métricas de la cola con AWS CLI apuntando al endpoint local:

```bash
aws sqs get-queue-attributes \
  --queue-url http://localhost:9324/000000000000/ReservasQueue \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
  --endpoint-url http://localhost:9324 \
  --region us-east-1
```

Esto te da:

- `ApproximateNumberOfMessages`: backlog (mensajes esperando procesamiento).
- `ApproximateNumberOfMessagesNotVisible`: mensajes "en vuelo" (siendo procesados).

#### 6.3. Uso de CPU de los contenedores

```bash
docker stats --no-stream
```

O en tiempo real:

```bash
docker stats
```

Observa la columna `CPU %` de los workers. Cuando supere ~70% es la señal de que (en AWS) se dispararía el autoescalado.

---

### Paso 7: Interpretar los resultados

Después de ejecutar `run_load_test.sh`, revisa los archivos en `tests/results/`:

#### Reporte JSON

Cada fase genera un archivo `<timestamp>_<fase>.json` con la estructura de Newman:

```bash
# Ver resumen rápido de una fase
cat tests/results/*_03_pico.json | python3 -c "
import json, sys
data = json.load(sys.stdin)
run = data['run']
stats = run['stats']
timings = run['timings']
print(f\"Total requests:  {stats['requests']['total']}\")
print(f\"Fallidos:        {stats['requests']['failed']}\")
print(f\"Tasa de éxito:   {(1 - stats['requests']['failed']/stats['requests']['total'])*100:.1f}%\")
print(f\"Tiempo promedio: {timings['responseAverage']:.0f} ms\")
print(f\"Tiempo máximo:   {timings['responseMax']:.0f} ms\")
print(f\"Duración total:  {timings['completed'] - timings['started']:.0f} ms\")
"
```

#### Métricas clave a verificar

| Métrica | Criterio de éxito |
|---|---|
| Tasa de éxito HTTP 202 | 100% (0 fallos) |
| Tiempo de respuesta del API | < 2000 ms |
| Backlog SQS durante pico | Crece (esperado); el API no rechaza nada |
| Backlog SQS después del pico | Vuelve a 0 al drenar |
| CPU de workers durante pico | > 70% (justifica el autoescalado) |

---

### Paso 8: Resumen de lo que demuestra el entorno local

| Aspecto | Qué se valida localmente |
|---|---|
| Desacoplamiento productor/consumidor | El API responde 202 rápido sin importar cuántos workers hay |
| Absorción de picos por SQS | El backlog crece durante el pico pero no se pierden mensajes |
| Efecto del escalado horizontal | Más workers = backlog baja más rápido |
| Tasa de éxito | 100% de las peticiones aceptadas |
| Tiempos de respuesta estables | El API mantiene latencia baja incluso bajo estrés |

Una vez validado todo en local, puedes pasar al entorno AWS con Fargate
ejecutando `setup_aws_experiment.sh` con la opción de Fargate.

---

### Troubleshooting

| Problema | Solución |
|---|---|
| `newman: command not found` | `npm install -g newman` |
| `Error connecting to localhost:8000` | Verifica que los containers estén corriendo: `docker compose ps` |
| El worker no procesa mensajes | Revisa logs: `docker compose logs worker-consumer` y que SQS esté corriendo |
| Muchos errores 500 | Revisa logs del API: `docker compose logs api-producer` |
| Puerto 8000 ocupado | `lsof -i :8000` y mata el proceso, o cambia el puerto en `docker-compose.yml` |
| ElasticMQ no inicia | Verifica que los puertos 9324/9325 estén libres |
