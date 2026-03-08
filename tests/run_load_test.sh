#!/usr/bin/env bash
set -euo pipefail

#
# Prueba de carga con Newman (Postman CLI) para el experimento de escalabilidad.
#
# MODOS disponibles (variable MODE):
#
#   demo   → ~8 min total. Ideal para validar el patrón localmente a escala.
#            Mismas 4 fases y proporciones de carga, duraciones reducidas.
#
#            Fase 1 - Base:       150 TPM  durante 1 min  (150 requests)
#            Fase 2 - Rampa:      400 TPM  durante 1 min  (400 requests)
#            Fase 3 - Pico:       800 TPM  durante 5 min  (4000 requests)
#            Fase 4 - Reducción:  150 TPM  durante 1 min  (150 requests)
#
#   full   → Experimento completo según diseño del NotebookLM.
#            Fase 1 - Base:       150 TPM  durante  5 min
#            Fase 2 - Rampa:      400 TPM  durante  5 min
#            Fase 3 - Pico:       800 TPM  durante  2 horas
#            Fase 4 - Reducción:  150 TPM  durante  5 min
#
# Uso:
#   ./run_load_test.sh                         # modo demo por defecto
#   MODE=full ./run_load_test.sh               # experimento completo (2 horas)
#   BASE_URL=http://mi-alb.amazonaws.com ./run_load_test.sh
#

BASE_URL="${BASE_URL:-http://localhost:8000}"
MODE="${MODE:-demo}"
COLLECTION="$(dirname "$0")/postman_collection.json"
DATA_FILE="$(dirname "$0")/data.csv"
RESULTS_DIR="$(dirname "$0")/results"

mkdir -p "${RESULTS_DIR}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

check_newman() {
  if ! command -v newman &>/dev/null; then
    echo "Newman no está instalado. Instálalo con:"
    echo "  npm install -g newman"
    echo "  npm install -g newman-reporter-htmlextra  (opcional, para reportes HTML)"
    exit 1
  fi
}

# run_phase <nombre> <TPM> <duración_en_minutos>
run_phase() {
  local PHASE_NAME="$1"
  local TPM="$2"
  local DURATION_MIN="$3"

  local TOTAL_REQUESTS=$((TPM * DURATION_MIN))
  local DELAY_MS=$(( (60 * 1000) / TPM ))

  echo ""
  echo "=============================================="
  echo " FASE: ${PHASE_NAME}"
  echo " TPM objetivo:    ${TPM}"
  echo " Duración:        ${DURATION_MIN} min"
  echo " Total requests:  ${TOTAL_REQUESTS}"
  echo " Delay entre req: ${DELAY_MS} ms"
  echo "=============================================="
  echo ""

  local REPORT_FILE="${RESULTS_DIR}/${TIMESTAMP}_${PHASE_NAME}"

  local REPORTERS="cli,json"
  local EXTRA_ARGS=""
  if newman run --help 2>&1 | grep -q "htmlextra"; then
    REPORTERS="${REPORTERS},htmlextra"
    EXTRA_ARGS="--reporter-htmlextra-export ${REPORT_FILE}.html"
  fi

  newman run "${COLLECTION}" \
    --env-var "base_url=${BASE_URL}" \
    --iteration-data "${DATA_FILE}" \
    --iteration-count "${TOTAL_REQUESTS}" \
    --delay-request "${DELAY_MS}" \
    --reporters "${REPORTERS}" \
    --reporter-json-export "${REPORT_FILE}.json" \
    --folder "Enviar Pago" \
    --timeout-request 10000 \
    --bail \
    ${EXTRA_ARGS} \
    || true

  echo ""
  echo "Resultados guardados en: ${REPORT_FILE}.json"
}

main() {
  check_newman

  if [[ "${MODE}" == "full" ]]; then
    local BASE_DUR=5
    local RAMP_DUR=5
    local PEAK_DUR=120
    local DOWN_DUR=5
    local MODE_LABEL="COMPLETO (2 horas de pico)"
  else
    local BASE_DUR=1
    local RAMP_DUR=1
    local PEAK_DUR=5
    local DOWN_DUR=1
    local MODE_LABEL="DEMO (~8 min total)"
  fi

  echo "=============================================="
  echo " EXPERIMENTO DE ESCALABILIDAD"
  echo " Modo:   ${MODE_LABEL}"
  echo " Target: ${BASE_URL}"
  echo " Inicio: $(date)"
  echo "=============================================="

  echo ""
  echo "Verificando que la API esté disponible..."
  newman run "${COLLECTION}" \
    --env-var "base_url=${BASE_URL}" \
    --folder "Health Check" \
    --reporters cli \
    --bail

  run_phase "01_base"      150 "${BASE_DUR}"
  run_phase "02_rampa"     400 "${RAMP_DUR}"
  run_phase "03_pico"      800 "${PEAK_DUR}"
  run_phase "04_reduccion" 150 "${DOWN_DUR}"

  echo ""
  echo "=============================================="
  echo " EXPERIMENTO FINALIZADO"
  echo " Fin: $(date)"
  echo " Resultados en: ${RESULTS_DIR}/"
  echo "=============================================="
}

main "$@"
