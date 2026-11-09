#!/usr/bin/env bash
# 3 - Servidor OpenAI-compatible con Maple-Preview 20B-A1B (para Page Assist u otros clientes).
# Endpoint:  http://127.0.0.1:10000/v1    Modelo: maple-preview
#
# NOTA: Maple SIEMPRE razona (su plantilla no tiene interruptor de "thinking"), así que
# este script no pasa ningún flag para apagarlo.
#
# Variables opcionales:
#   PORT=10000  THREADS=4  CTX=16384  MAXTOK=8192  VARIANT=tq2|tq1|tq2_f16
#   REASONING_FORMAT=none|auto|deepseek   (por defecto: el del servidor)
#       Por defecto llama-server manda el razonamiento en un campo aparte (reasoning_content).
#       Con REASONING_FORMAT=none queda dentro del texto como <think>...</think>.
#       Si las herramientas MCP fallan con "none", vuelve al valor por defecto.
# Argumentos extra se pasan tal cual a llama-server.
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/maple}"
BIN="$INSTALL_DIR/llama.cpp/build/bin/llama-server"
# Mapa de puertos: 10000 Maple · 10001 calculadora · 10002 Kiwix · 10003 MCP Wikipedia · 10004 MCP man
PORT="${PORT:-10000}"
THREADS="${THREADS:-4}"        # medido en un i5-8350U: 6 hilos casi no mejora a 4
CTX="${CTX:-32768}"            # la caché KV es pequeña (atención de ventana); medido ~5,8 GiB de RAM en total
MAXTOK="${MAXTOK:-8192}"       # tope por respuesta si el cliente no envía max_tokens (corta bucles de razonamiento)
VARIANT="${VARIANT:-tq2}"

case "$VARIANT" in
  tq2)     FILE="maple-preview-TQ2_0-head-Q4_K.gguf" ;;
  tq1)     FILE="maple-preview-TQ1_0-head-Q4_K.gguf" ;;
  tq2_f16) FILE="maple-preview-TQ2_0-head-F16.gguf" ;;
  *) echo "VARIANT debe ser tq2, tq1 o tq2_f16" >&2; exit 1 ;;
esac
MODEL="$INSTALL_DIR/models/$FILE"

[[ -x "$BIN" ]]   || { echo "No encuentro $BIN" >&2; exit 1; }
[[ -s "$MODEL" ]] || { echo "No encuentro $MODEL (ejecuta 2_download_maple.sh)" >&2; exit 1; }

HELP="$("$BIN" --help 2>&1 || true)"
has_flag() { grep -qF -- "$1" <<<"$HELP"; }

# Muestreo: 0.6 / 0.95 / 20 son los valores por defecto de un envoltorio de la comunidad;
# la ficha del modelo no publica una configuración oficial.
ARGS=(-m "$MODEL" -t "$THREADS" -c "$CTX" --host 127.0.0.1 --port "$PORT"
      --alias maple-preview
      -np 1
      -n "$MAXTOK"
      --temp 0.6 --top-p 0.95 --top-k 20)

# Necesario para la plantilla de chat y las llamadas a herramientas (MCP)
has_flag "--jinja" && ARGS+=(--jinja)

# Reutiliza la caché del prompt entre turnos
has_flag "--cache-reuse" && ARGS+=(--cache-reuse 256)

if [[ -n "${REASONING_FORMAT:-}" ]]; then
  has_flag "--reasoning-format" && ARGS+=(--reasoning-format "$REASONING_FORMAT")
fi

# Comprobar que el puerto está libre
if command -v ss >/dev/null && ss -ltnH "sport = :$PORT" | grep -q .; then
  echo "El puerto $PORT ya está en uso:" >&2
  ss -ltnp "sport = :$PORT" >&2 || true
  echo "¿Sigue en marcha el servidor de maple u otro parecido? Páralo, o usa otro puerto:  PORT=10010 $0" >&2
  exit 1
fi

echo "Servidor en http://127.0.0.1:$PORT/v1  (modelo: maple-preview)"
echo "También tiene web propia en http://127.0.0.1:$PORT"
exec "$BIN" "${ARGS[@]}" "$@"
