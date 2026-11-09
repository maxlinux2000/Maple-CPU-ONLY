#!/usr/bin/env bash
# 3 - Ejecuta Maple-Preview en modo chat interactivo desde la terminal usando llama-cli.
#
# Variables opcionales:
#   THREADS=4  CTX=16384  MAXTOK=8192  VARIANT=tq2|tq1|tq2_f16
# Argumentos extra se pasan tal cual a llama-cli.
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/maple}"
BIN="$INSTALL_DIR/llama.cpp/build/bin/llama-cli"
THREADS="${THREADS:-4}"        
CTX="${CTX:-32768}"            
MAXTOK="${MAXTOK:-8192}"       
VARIANT="${VARIANT:-tq2}"

case "$VARIANT" in
  tq2)     FILE="maple-preview-TQ2_0-head-Q4_K.gguf" ;;
  tq1)     FILE="maple-preview-TQ1_0-head-Q4_K.gguf" ;;
  tq2_f16) FILE="maple-preview-TQ2_0-head-F16.gguf" ;;
  *) echo "VARIANT debe ser tq2, tq1 o tq2_f16" >&2; exit 1 ;;
esac
MODEL="$INSTALL_DIR/models/$FILE"

[[ -x "$BIN" ]]   || { echo "No encuentro $BIN (ejecuta 1_install_maple_engine.sh primero)" >&2; exit 1; }
[[ -s "$MODEL" ]] || { echo "No encuentro $MODEL (ejecuta el script de descarga del modelo primero)" >&2; exit 1; }

HELP="$("$BIN" --help 2>&1 || true)"
has_flag() { grep -qF -- "$1" <<<"$HELP"; }

# Parámetros de muestreo y ejecución interactiva (sin la bandera -i obsoleta)
ARGS=(-m "$MODEL" -t "$THREADS" -c "$CTX"
      -n "$MAXTOK"
      --temp 0.6 --top-p 0.95 --top-k 20)

# Necesario para interpretar correctamente la plantilla de chat del modelo
has_flag "--jinja" && ARGS+=(--jinja)

# Activa el modo chat conversacional por defecto si está disponible
has_flag "-cnv" && ARGS+=(-cnv)

echo "==> Iniciando Maple-Preview en la terminal (modo interactivo)..."
echo "Escribe tu mensaje, presiona Enter y espera a que razone y responda."
echo "Para salir de la sesión, escribe 'exit' o presiona Ctrl+C."
echo "------------------------------------------------------------------"

exec "$BIN" "${ARGS[@]}" "$@"
