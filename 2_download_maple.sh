#!/usr/bin/env bash
# 2b - Descarga Maple-Preview 20B-A1B (DeepGrove, MIT) en formato GGUF ternario.
# Descarga con curl (reanudable). Si el fichero ya existe y es válido, no hace nada.
#
# Variantes (VARIANT):
#   tq2      (por defecto)  maple-preview-TQ2_0-head-Q4_K.gguf   ~5,5 GiB  <- probado en este proyecto
#   tq1                     maple-preview-TQ1_0-head-Q4_K.gguf   ~5,0 GB   (sin verificar)
#   tq2_f16                 maple-preview-TQ2_0-head-F16.gguf    ~6,4 GB   (sin verificar)
# Los nombres de "tq1" y "tq2_f16" salen de una guía de terceros; si el servidor responde 404,
# mira la lista de ficheros en https://huggingface.co/deepgrove/maple-preview-GGUF
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/maple}"
MODEL_DIR="$INSTALL_DIR/models"
REPO="deepgrove/maple-preview-GGUF"
VARIANT="${VARIANT:-tq2}"

case "$VARIANT" in
  tq2)     FILE="maple-preview-TQ2_0-head-Q4_K.gguf";  MIN_BYTES=5000000000 ;;
  tq1)     FILE="maple-preview-TQ1_0-head-Q4_K.gguf";  MIN_BYTES=4500000000 ;;
  tq2_f16) FILE="maple-preview-TQ2_0-head-F16.gguf";   MIN_BYTES=5800000000 ;;
  *) echo "VARIANT debe ser tq2, tq1 o tq2_f16" >&2; exit 1 ;;
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
