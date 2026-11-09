#!/usr/bin/env bash
# 12 - Configura el servidor MCP de manuales de Linux y ayuda CLI (puerto 10004)
#
# No depende de ningún otro servicio: solo de man-db y de los comandos instalados en el sistema.
#
# Uso:
#   ./12_man_server.sh                       # solo escucha en 127.0.0.1
#   ALLOW_HELP_EXEC=0 ./12_man_server.sh     # NO ejecutar nunca 'comando --help' (solo man/help/apropos)
#   BIND_ADDR=0.0.0.0 ./12_man_server.sh     # exponer en la red local (con cuidado)
#
# Ejecútalo como usuario normal (usa sudo internamente cuando hace falta).
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/maple}"
# Mapa de puertos: 10000 Maple · 10001 calculadora · 10002 Kiwix · 10003 MCP Wikipedia · 10004 MCP man
MCP_PORT="${MCP_PORT:-10004}"
BIND_ADDR="${BIND_ADDR:-127.0.0.1}"
ALLOW_HELP_EXEC="${ALLOW_HELP_EXEC:-1}"
SERVICE_NAME="man-mcp.service"
RUN_USER="${USER:-$(id -un)}"
VENV_DIR="$INSTALL_DIR/venv"
CLI_SCRIPT="$INSTALL_DIR/buscar_man.sh"
MCP_SERVER_FILE="$INSTALL_DIR/man_mcp_server.py"

case "$BIND_ADDR" in 0.0.0.0|::) MCP_HOST_CHECK=127.0.0.1 ;; *) MCP_HOST_CHECK="$BIND_ADDR" ;; esac

die() { echo "❌ $*" >&2; exit 1; }

echo "======================================================"
echo " 12 - Configurando Servidor MCP de Man Pages & Help"
echo "======================================================"

[ "$(id -u)" -ne 0 ] || die "No ejecutes este script como root; hazlo como tu usuario (usa sudo internamente)."
command -v apt-get >/dev/null 2>&1 || die "Este script necesita apt-get (Debian/Ubuntu)."

mkdir -p "$INSTALL_DIR"

# Puerto: paramos NUESTRO servicio y, si algo sigue ocupándolo, es de otro proceso
sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
if command -v ss >/dev/null 2>&1 && ss -ltnH "sport = :$MCP_PORT" | grep -q .; then
  echo "❌ El puerto $MCP_PORT ya está en uso:" >&2
  ss -ltnp "sport = :$MCP_PORT" >&2 || true
  die "Libéralo (¿un servicio antiguo?) o elige otro con MCP_PORT."
fi

# 1. Dependencias del sistema
echo "==> Verificando dependencias del sistema..."
PKGS=()
command -v man     >/dev/null 2>&1 || PKGS+=(man-db)
command -v python3 >/dev/null 2>&1 || PKGS+=(python3)
command -v curl    >/dev/null 2>&1 || PKGS+=(curl)
python3 -c 'import venv, ensurepip' >/dev/null 2>&1 || PKGS+=(python3-venv)

if [ ${#PKGS[@]} -gt 0 ]; then
  echo "⚠️ Instalando paquetes: ${PKGS[*]}"
  sudo apt-get update
  sudo apt-get install -y "${PKGS[@]}"
else
  echo "✅ Todas las herramientas del sistema están presentes."
fi

# 2. Entorno virtual (compartido con el script 11; no depende de que se haya ejecutado antes)
echo "==> Preparando entorno virtual en $VENV_DIR..."
[ -x "$VENV_DIR/bin/python" ] || python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/pip" install --quiet --upgrade pip
"$VENV_DIR/bin/pip" install --quiet fastapi uvicorn
PYTHON_BIN="$VENV_DIR/bin/python"

# 3. Script CLI de consulta
echo "==> Generando CLI de manuales en: $CLI_SCRIPT"
cat > "$CLI_SCRIPT" <<'EOF'
#!/usr/bin/env bash
# Obtiene el man o la ayuda de un comando del sistema, limpio y recortado para un LLM.
# Uso: buscar_man.sh [seccion] comando
set -euo pipefail

if [ $# -eq 0 ] || [ $# -gt 2 ]; then
  echo "❌ Uso: $0 [seccion] comando" >&2
  exit 1
fi

SECTION=""
if [ $# -eq 2 ]; then
  SECTION="$1"
  CMD="$2"
else
  CMD="$1"
fi

# Validación estricta: evita inyección de opciones (-P, --html=...) y rutas arbitrarias
if [ ${#CMD} -gt 64 ] || ! [[ "$CMD" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; then
  echo "❌ Nombre de comando no válido: '$CMD'" >&2
  exit 1
fi
if [ -n "$SECTION" ] && ! [[ "$SECTION" =~ ^([0-9][a-z]*|[nl])$ ]]; then
  echo "❌ Sección de manual no válida: '$SECTION'" >&2
  exit 1
fi

MAX_WORDS="${MAX_WORDS:-2500}"
ALLOW_HELP_EXEC="${ALLOW_HELP_EXEC:-1}"
# Comandos que nunca se ejecutan, ni siquiera con --help
DENY_EXEC=" shutdown reboot poweroff halt init telinit "
OUTPUT=""

strip_overstrike() {
  if command -v col >/dev/null 2>&1; then col -bx; else sed -E 's/.\x08//g'; fi
}

MAN_ARGS=()
if [ -n "$SECTION" ]; then
  MAN_ARGS+=("$SECTION")
fi

# 1) Página de manual
if MANWIDTH=100 man -w ${MAN_ARGS[@]+"${MAN_ARGS[@]}"} "$CMD" >/dev/null 2>&1; then
  OUTPUT=$(MANWIDTH=100 man -P cat ${MAN_ARGS[@]+"${MAN_ARGS[@]}"} "$CMD" 2>/dev/null | strip_overstrike || true)
fi

# Imágenes mínimas de Ubuntu/Debian: 'man' devuelve un aviso con código 0 en vez de la página
if [[ "$OUTPUT" == *"has been minimized"* ]]; then
  OUTPUT=""
fi

# 2) Comandos internos de bash (cd, export, ...)
if [ -z "$OUTPUT" ] && [ "$(type -t "$CMD" 2>/dev/null || true)" = "builtin" ]; then
  OUTPUT=$(help "$CMD" 2>&1 || true)
fi

# 3) '<comando> --help' (una sola ejecución, con timeout y sin stdin)
if [ -z "$OUTPUT" ] && [ "$ALLOW_HELP_EXEC" = "1" ]; then
  BIN=$(type -P "$CMD" 2>/dev/null || true)
  if [ -n "$BIN" ] && [[ "$DENY_EXEC" != *" $CMD "* ]]; then
    OUTPUT=$(timeout 5 "$BIN" --help </dev/null 2>&1 | head -c 200000 || true)
  fi
fi

# 4) Entradas relacionadas
if [ -z "$OUTPUT" ] && command -v apropos >/dev/null 2>&1; then
  RELATED=$(apropos -- "$CMD" 2>/dev/null | grep -v 'nothing appropriate' | head -n 30 || true)
  if [ -n "$RELATED" ]; then
    OUTPUT="No manual found for '$CMD'. Related entries:"$'\n'"$RELATED"
  fi
fi

if [ -z "$OUTPUT" ]; then
  echo "No manual or help found for: $CMD"
  exit 0
fi

printf '%s\n' "$OUTPUT" | python3 -c '
import re
import sys

text = sys.stdin.read()
text = re.sub(r"\x1B\[[0-9;]*[A-Za-z]", "", text)
text = text.replace("\r", "")
text = re.sub(r"[ \t]+\n", "\n", text)
text = re.sub(r"\n{3,}", "\n\n", text).strip()

max_words = int(sys.argv[1])
out, count, trimmed = [], 0, False
for line in text.split("\n"):
    n = len(line.split())
    if count + n > max_words:
        trimmed = True
        break
    out.append(line)
    count += n
if trimmed:
    out.append("")
    out.append("[... Manual trimmed to %d words for LLM context optimization ...]" % max_words)
print("\n".join(out))
' "$MAX_WORDS"
EOF
chmod +x "$CLI_SCRIPT"

# 4. Servidor MCP (Streamable HTTP)
echo "==> Generando servidor MCP de manuales en: $MCP_SERVER_FILE"
cat > "$MCP_SERVER_FILE" <<'EOF'
import asyncio
import os
import signal

import uvicorn
from fastapi import FastAPI, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

HERE = os.path.dirname(os.path.abspath(__file__))
CLI_SCRIPT = os.environ.get("MAN_CLI_SCRIPT") or os.path.join(HERE, "buscar_man.sh")
HOST = os.environ.get("MCP_HOST", "127.0.0.1")
PORT = int(os.environ.get("MCP_PORT", "10004"))
TIMEOUT = float(os.environ.get("MCP_TIMEOUT", "20"))
ORIGINS = [o.strip() for o in os.environ.get("MCP_CORS_ORIGINS", "*").split(",") if o.strip()]

SUPPORTED_VERSIONS = ["2025-06-18", "2025-03-26", "2024-11-05"]

TOOLS = [
    {
        "name": "get_linux_manual",
        "description": "Retrieve the man page or CLI help documentation for any Linux command (e.g. grep, cut, yt-dlp, tar).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "command": {"type": "string", "description": "The name of the command to look up (e.g., 'grep', 'find', 'yt-dlp')."},
                "section": {"type": "string", "description": "Optional man section (e.g., '1', '3', '5') when a name exists in several sections."},
            },
            "required": ["command"],
        },
    }
]

app = FastAPI(title="Linux Manuals Streamable HTTP MCP Server")
app.add_middleware(
    CORSMiddleware,
    allow_origins=ORIGINS,
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
    expose_headers=["Mcp-Session-Id"],
)


def rpc_result(req_id, result):
    return {"jsonrpc": "2.0", "result": result, "id": req_id}


def rpc_error(req_id, code, message):
    return {"jsonrpc": "2.0", "error": {"code": code, "message": message}, "id": req_id}


async def run_manual(command: str, section: str):
    """Devuelve (texto, es_error). No bloquea el event loop."""
    command = command.strip()
    section = section.strip()
    if not command:
        return "Empty command.", True
    args = [CLI_SCRIPT] + ([section] if section else []) + [command]
    try:
        proc = await asyncio.create_subprocess_exec(
            *args,
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            start_new_session=True,  # permite matar todo el grupo de procesos si hay timeout
        )
    except Exception as e:
        return f"Execution error: {e}", True

    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout=TIMEOUT)
    except asyncio.TimeoutError:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        await proc.wait()
        return f"Lookup timed out after {TIMEOUT:g}s.", True

    if proc.returncode != 0:
        return f"Error: {err.decode(errors='replace').strip()}", True
    text = out.decode(errors="replace").strip()
    return (text or f"No manual found for command: {command}"), False


async def handle(msg):
    """Procesa un mensaje JSON-RPC. Devuelve dict de respuesta o None (notificaciones)."""
    if not isinstance(msg, dict):
        return rpc_error(None, -32600, "Invalid Request")
    # Notificaciones (sin id) y respuestas del cliente: no se contestan
    if "id" not in msg or "method" not in msg:
        return None

    method = msg["method"]
    req_id = msg["id"]
    params = msg.get("params") or {}

    if method == "initialize":
        requested = params.get("protocolVersion")
        version = requested if requested in SUPPORTED_VERSIONS else SUPPORTED_VERSIONS[0]
        return rpc_result(req_id, {
            "protocolVersion": version,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "linux_manuals", "version": "1.1.0"},
        })

    if method == "ping":
        return rpc_result(req_id, {})

    if method == "tools/list":
        return rpc_result(req_id, {"tools": TOOLS})

    if method == "tools/call":
        if params.get("name") != "get_linux_manual":
            return rpc_error(req_id, -32602, f"Unknown tool: {params.get('name')}")
        arguments = params.get("arguments") or {}
        command = arguments.get("command")
        section = arguments.get("section") or ""
        if not isinstance(command, str):
            return rpc_error(req_id, -32602, "Argument 'command' (string) is required")
        if not isinstance(section, str):
            return rpc_error(req_id, -32602, "Argument 'section' must be a string")
        text, is_error = await run_manual(command, section)
        return rpc_result(req_id, {"content": [{"type": "text", "text": text}], "isError": is_error})

    return rpc_error(req_id, -32601, f"Method not found: {method}")


@app.post("/")
@app.post("/mcp")
async def mcp_endpoint(request: Request):
    try:
        body = await request.json()
    except Exception:
        return JSONResponse(rpc_error(None, -32700, "Parse error"), status_code=400)

    if isinstance(body, list):  # batch JSON-RPC
        responses = [r for r in [await handle(m) for m in body] if r is not None]
        return JSONResponse(responses) if responses else Response(status_code=202)

    response = await handle(body)
    return JSONResponse(response) if response is not None else Response(status_code=202)


@app.get("/health")
async def health():
    return {"status": "ok"}


if __name__ == "__main__":
    uvicorn.run(app, host=HOST, port=PORT)
EOF

# 5. Servicio systemd
echo "==> Configurando servicio $SERVICE_NAME ($BIND_ADDR:$MCP_PORT)..."
sudo tee "/etc/systemd/system/$SERVICE_NAME" > /dev/null <<EOF
[Unit]
Description=Servidor Puente MCP Linux Manuals (Page Assist)
After=network.target

[Service]
Type=simple
User=$RUN_USER
Environment=MCP_HOST=$BIND_ADDR
Environment=MCP_PORT=$MCP_PORT
Environment=MAN_CLI_SCRIPT=$CLI_SCRIPT
Environment=ALLOW_HELP_EXEC=$ALLOW_HELP_EXEC
# PATH ampliado para que --help encuentre herramientas de usuario (pipx, snap...)
Environment=PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin:/snap/bin
ExecStart=$PYTHON_BIN $MCP_SERVER_FILE
Restart=always
RestartSec=5
# Endurecimiento: el servicio puede ejecutar 'comando --help', así que se limita lo que puede tocar
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME" >/dev/null
sudo systemctl restart "$SERVICE_NAME"

# 6. Comprobación rápida
echo "==> Comprobando servicio..."
OK=0
for _ in $(seq 1 20); do
  if curl -fs -o /dev/null --max-time 2 "http://$MCP_HOST_CHECK:$MCP_PORT/health"; then OK=1; break; fi
  sleep 1
done
if [ "$OK" -eq 1 ]; then
  echo "✅ MCP responde en el puerto $MCP_PORT"
else
  echo "⚠️ El MCP no responde. Revisa: journalctl -u $SERVICE_NAME -n 30" >&2
fi

TEST_OUT=$("$CLI_SCRIPT" grep 2>&1 | head -c 200 || true)
echo "==> Prueba CLI (grep): ${TEST_OUT:-<sin salida>}"

echo ""
echo "======================================================"
echo " 🎉 ¡Servidor MCP de Manuales creado con éxito!"
echo "======================================================"
echo "🌐 Configuración para Page Assist:"
echo "   -> Transport: Streamable HTTP"
echo "   -> Server URL: http://$BIND_ADDR:$MCP_PORT/  (también /mcp)"
echo ""
echo "🛠️ CLI de prueba manual:"
echo "   -> $CLI_SCRIPT grep"
echo "   -> $CLI_SCRIPT 5 passwd    # con sección"
echo "======================================================"

