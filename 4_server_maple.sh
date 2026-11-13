#!/usr/bin/env bash
# 4/5 - Servidor OpenAI-compatible con Maple-Preview 20B-A1B (para Page Assist u otros clientes).
# Endpoint:  http://127.0.0.1:8083/v1     Modelo: maple-preview
#
# Maple SIEMPRE razona: su plantilla trae el prefijo de "thinking" y no hay interruptor para
# apagarlo, así que este script no pasa ningún flag para eso.
#
# Parámetros de muestreo: temperatura 1.0 y top-p 0.95, los que recomienda DeepGrove en el README
# de su fork. (En las primeras pruebas de este proyecto se usó 0.6/0.95/20, que NO es la
# recomendación del autor; puedes comparar con TEMP=0.6.)
#
# Dónde se ejecuta (CPU o GPU): lo decide INSTALL_DIR/engine.env (lo escribe el script 1 y lo
# actualiza 6_bench_maple.sh tras medir). Se puede forzar con DEVICE=cpu|gpu.
#
# Variables opcionales:
#   PORT=8083  THREADS=4  CTX=16384  MAXTOK=8192  VARIANT=tq2|tq2_f16|tq1|tq1_f16
#   TEMP=1.0  TOP_P=0.95  TOP_K=<n>  MIN_P=<x>       (TOP_K y MIN_P solo se pasan si los defines)
#   DEVICE=cpu|gpu     NGL=99     N_CPU_MOE=<n>      (con GPU pequeña: deja n capas de expertos en CPU)
#   REASONING_FORMAT=none|auto|deepseek   (por defecto el del servidor)
#       Por defecto llama-server manda el razonamiento en un campo aparte (reasoning_content).
#       Con REASONING_FORMAT=none queda dentro del texto como <think>...</think>.
# Argumentos extra se pasan tal cual a llama-server (p. ej. --no-reasoning-preserve).
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/maple}"
BIN="$INSTALL_DIR/llama.cpp/build/bin/llama-server"
PORT="${PORT:-8083}"
THREADS="${THREADS:-4}"        # medido en un i5-8350U: 6 hilos casi no mejora a 4
CTX="${CTX:-16384}"            # la caché KV es pequeña (atención de ventana deslizante)
MAXTOK="${MAXTOK:-8192}"       # tope por respuesta si el cliente no envía max_tokens (corta bucles)
VARIANT="${VARIANT:-tq2}"
TEMP="${TEMP:-1.0}"
TOP_P="${TOP_P:-0.95}"

case "$VARIANT" in
  tq2)     FILE="maple-preview-TQ2_0-head-Q4_K.gguf" ;;
  tq2_f16) FILE="maple-preview-TQ2_0-head-F16.gguf" ;;
  tq1)     FILE="maple-preview-TQ1_0-head-Q4_K.gguf" ;;
  tq1_f16) FILE="maple-preview-TQ1_0-head-F16.gguf" ;;
  *) echo "VARIANT debe ser tq2, tq2_f16, tq1 o tq1_f16" >&2; exit 1 ;;
esac
MODEL="$INSTALL_DIR/models/$FILE"

[[ -x "$BIN" ]]   || { echo "No encuentro $BIN (ejecuta 1_install_maple_engine.sh)" >&2; exit 1; }
[[ -s "$MODEL" ]] || { echo "No encuentro $MODEL (ejecuta 2_download_maple.sh)" >&2; exit 1; }

# Qué se compiló y dónde ejecutar (engine.env lo escribe el script 1)
BACKEND="cpu"; PLACEMENT="cpu"
if [[ -f "$INSTALL_DIR/engine.env" ]]; then
  # shellcheck disable=SC1091
  source "$INSTALL_DIR/engine.env"
fi
DEVICE="${DEVICE:-$PLACEMENT}"
case "$DEVICE" in cpu|gpu) ;; *) echo "DEVICE debe ser cpu o gpu" >&2; exit 1 ;; esac
if [[ "$DEVICE" == "gpu" && "$BACKEND" != "vulkan" ]]; then
  echo "AVISO: este motor se compiló sin soporte de GPU; se usa la CPU." >&2
  DEVICE="cpu"
fi

HELP="$("$BIN" --help 2>&1 || true)"
has_flag() { grep -qF -- "$1" <<<"$HELP"; }

ARGS=(-m "$MODEL" -t "$THREADS" -c "$CTX" --host 127.0.0.1 --port "$PORT"
      --alias maple-preview
      -np 1
      -n "$MAXTOK"
      --temp "$TEMP" --top-p "$TOP_P")
[[ -z "${TOP_K:-}" ]] || ARGS+=(--top-k "$TOP_K")
[[ -z "${MIN_P:-}" ]] || ARGS+=(--min-p "$MIN_P")

# Necesario para la plantilla de chat y las llamadas a herramientas (MCP)
has_flag "--jinja" && ARGS+=(--jinja)

# Reparto CPU/GPU
if [[ "$DEVICE" == "gpu" ]]; then
  ARGS+=(-ngl "${NGL:-99}")
  if [[ -n "${N_CPU_MOE:-}" ]]; then
    if has_flag "--n-cpu-moe"; then ARGS+=(--n-cpu-moe "$N_CPU_MOE")
    else echo "AVISO: este llama-server no admite --n-cpu-moe; se ignora N_CPU_MOE." >&2; fi
  fi
elif [[ "$BACKEND" == "vulkan" ]]; then
  # Motor con Vulkan pero ejecución en CPU: hay que impedir que reparta capas a la GPU
  ARGS+=(-dev none -ngl 0)
fi

# Nota: NO se pasa --cache-reuse. Maple usa atención de ventana deslizante (SWA) y el servidor
# lo desactiva con un aviso. La caché del prompt se reutiliza igualmente por similitud de prefijo.
# Aviso habitual al arrancar: "chat template supports preserving reasoning ... may use more tokens".
# Si las conversaciones largas llenan el contexto, añade al final:  --no-reasoning-preserve

if [[ -n "${REASONING_FORMAT:-}" ]]; then
  has_flag "--reasoning-format" && ARGS+=(--reasoning-format "$REASONING_FORMAT")
fi

# Comprobar que el puerto está libre
if command -v ss >/dev/null && ss -ltnH "sport = :$PORT" | grep -q .; then
  echo "El puerto $PORT ya está en uso:" >&2
  ss -ltnp "sport = :$PORT" >&2 || true
  echo "Usa otro puerto:  PORT=8085 $0" >&2
  exit 1
fi

echo "Servidor en http://127.0.0.1:$PORT/v1  (modelo: maple-preview)"
echo "Motor: $BACKEND | ejecución: $DEVICE | temp=$TEMP top-p=$TOP_P | hilos=$THREADS | contexto=$CTX"
echo "También tiene web propia en http://127.0.0.1:$PORT"
exec "$BIN" "${ARGS[@]}" "$@"
