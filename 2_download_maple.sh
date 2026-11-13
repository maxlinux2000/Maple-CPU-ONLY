#!/usr/bin/env bash
# 2/5 - Descarga Maple-Preview 20B-A1B (DeepGrove, licencia MIT) en formato GGUF ternario.
# Descarga con curl (reanudable). Si el fichero ya existe y es válido, no hace nada.
#
# Uso:   ./2_download_maple.sh                 (variante por defecto: tq2)
#        VARIANT=tq2_f16 ./2_download_maple.sh
#
# Variantes (VARIANT). Los nombres y tamaños salen del README de DeepGrove:
#   tq2       maple-preview-TQ2_0-head-Q4_K.gguf   5,50 GiB   <- por defecto; la probada en este proyecto
#   tq2_f16   maple-preview-TQ2_0-head-F16.gguf    5,91 GiB   cabeza de salida en FP16
#   tq1       maple-preview-TQ1_0-head-Q4_K.gguf   4,64 GiB   empaquetado ternario más compacto
#   tq1_f16   maple-preview-TQ1_0-head-F16.gguf    5,06 GiB
# Según DeepGrove, TQ2_0 es en general más rápido que TQ1_0 (algo más de memoria), y la cabeza Q4_K
# más rápida que la FP16. Esas medidas son suyas, en un Apple M5 Pro: en tu CPU pueden variar.
#
# Variables opcionales: INSTALL_DIR=~/maple   VARIANT=tq2|tq2_f16|tq1|tq1_f16
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/maple}"
MODEL_DIR="$INSTALL_DIR/models"
REPO="deepgrove/maple-preview-GGUF"
VARIANT="${VARIANT:-tq2}"

case "$VARIANT" in
  tq2)     FILE="maple-preview-TQ2_0-head-Q4_K.gguf"; MIN_BYTES=5300000000 ;;
  tq2_f16) FILE="maple-preview-TQ2_0-head-F16.gguf";  MIN_BYTES=6000000000 ;;
  tq1)     FILE="maple-preview-TQ1_0-head-Q4_K.gguf"; MIN_BYTES=4700000000 ;;
  tq1_f16) FILE="maple-preview-TQ1_0-head-F16.gguf";  MIN_BYTES=5100000000 ;;
  *) echo "VARIANT debe ser tq2, tq2_f16, tq1 o tq1_f16" >&2; exit 1 ;;
esac

mkdir -p "$MODEL_DIR"
DEST="$MODEL_DIR/$FILE"
URL="https://huggingface.co/$REPO/resolve/main/$FILE"

valid() {  # tamaño mínimo y cabecera GGUF
  [[ -s "$1" ]] && (( $(stat -c %s "$1") >= MIN_BYTES )) && [[ "$(head -c 4 "$1")" == "GGUF" ]]
}

if valid "$DEST"; then
  echo "Ya está descargado y parece válido: $DEST ($(du -h "$DEST" | cut -f1))"
  exit 0
fi

echo "==> Descargando $FILE (reanudable si se corta)..."
curl -L --fail -C - --progress-bar -o "$DEST" "$URL" || {
  echo >&2
  echo "Falló la descarga. Comprueba el nombre del fichero en:" >&2
  echo "  https://huggingface.co/$REPO/tree/main" >&2
  exit 1
}

valid "$DEST" || { echo "El fichero descargado no es válido (tamaño o cabecera GGUF). Bórralo y reintenta." >&2; exit 1; }
echo "==> Listo: $DEST ($(du -h "$DEST" | cut -f1))"
echo "Siguiente paso: ./4_server_maple.sh   (o ./6_bench_maple.sh para medir velocidades)"
