#!/usr/bin/env bash
# 11 - Configura Kiwix (puerto 10002), el script CLI de búsqueda limpia y un
# servidor MCP puente (puerto 10003) con Streamable HTTP y CORS para Page Assist.
#
# DEPENDENCIA: el MCP de Wikipedia no funciona sin Kiwix (el CLI le consulta por HTTP).
# El servicio MCP arranca después de Kiwix (After/Wants) y recibe KIWIX_URL por entorno,
# así que el puerto de Kiwix se define en UN solo sitio (KIWIX_PORT) y el MCP lo sigue.
#
# Uso:
#   ./11_wikipedia_server.sh                    # inglés, solo escucha en 127.0.0.1
#   WIKI_LANG=es ./11_wikipedia_server.sh       # español
#   BIND_ADDR=0.0.0.0 ./11_wikipedia_server.sh  # exponer el MCP en la red local (con cuidado)
#   KIWIX_BIND=0.0.0.0 ./11_wikipedia_server.sh # exponer también Kiwix (por defecto solo 127.0.0.1)
#
# Ejecútalo como usuario normal (usa sudo internamente cuando hace falta).
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/maple}"
WIKI_DIR="$INSTALL_DIR/wikipedia"
WIKI_LANG="${WIKI_LANG:-en}"
# Mapa de puertos: 10000 Maple · 10001 calculadora · 10002 Kiwix · 10003 MCP Wikipedia · 10004 MCP man
KIWIX_PORT="${KIWIX_PORT:-10002}"
MCP_PORT="${MCP_PORT:-10003}"
BIND_ADDR="${BIND_ADDR:-127.0.0.1}"     # dónde escucha el MCP
KIWIX_BIND="${KIWIX_BIND:-127.0.0.1}"   # dónde escucha Kiwix (solo lo consulta el MCP, en esta máquina)
SERVICE_KIWIX="kiwix-wiki.service"
SERVICE_MCP="wikipedia-mcp.service"
RUN_USER="${USER:-$(id -un)}"
VENV_DIR="$INSTALL_DIR/venv"
CLIENT_SCRIPT="$INSTALL_DIR/buscar_wiki_${WIKI_LANG}.sh"
MCP_SERVER_FILE="$INSTALL_DIR/wikipedia_mcp_server.py"

# Dirección con la que este script y el CLI alcanzan a los servicios (0.0.0.0 no es una dirección de destino)
case "$KIWIX_BIND" in 0.0.0.0|::) KIWIX_HOST=127.0.0.1 ;; *) KIWIX_HOST="$KIWIX_BIND" ;; esac
case "$BIND_ADDR"  in 0.0.0.0|::) MCP_HOST_CHECK=127.0.0.1 ;; *) MCP_HOST_CHECK="$BIND_ADDR" ;; esac
KIWIX_URL="http://$KIWIX_HOST:$KIWIX_PORT"

die() { echo "❌ $*" >&2; exit 1; }

echo "======================================================"
echo " 11 - Configurando Kiwix y Servidor MCP para Wikipedia ($WIKI_LANG)"
echo "======================================================"

[ "$(id -u)" -ne 0 ] || die "No ejecutes este script como root; hazlo como tu usuario (usa sudo internamente)."
command -v apt-get >/dev/null 2>&1 || die "Este script necesita apt-get (Debian/Ubuntu)."

mkdir -p "$INSTALL_DIR"

# Puertos: paramos NUESTROS servicios y, si algo sigue ocupando el puerto, es de otro proceso
[ "$KIWIX_PORT" != "$MCP_PORT" ] || die "KIWIX_PORT y MCP_PORT no pueden ser el mismo ($KIWIX_PORT)."
sudo systemctl stop "$SERVICE_MCP" "$SERVICE_KIWIX" 2>/dev/null || true
for p in "$KIWIX_PORT" "$MCP_PORT"; do
  if command -v ss >/dev/null 2>&1 && ss -ltnH "sport = :$p" | grep -q .; then
    echo "❌ El puerto $p ya está en uso:" >&2
    ss -ltnp "sport = :$p" >&2 || true
    die "Libéralo (¿un servicio antiguo?) o elige otro con KIWIX_PORT / MCP_PORT."
  fi
done

# 1. Dependencias del sistema
echo "==> Verificando dependencias del sistema..."
PKGS=()
command -v kiwix-serve >/dev/null 2>&1 || PKGS+=(kiwix-tools)   # 'kiwix' es la app de escritorio, no el servidor
command -v python3     >/dev/null 2>&1 || PKGS+=(python3)
command -v curl        >/dev/null 2>&1 || PKGS+=(curl)
python3 -c 'import venv, ensurepip' >/dev/null 2>&1 || PKGS+=(python3-venv)

if [ ${#PKGS[@]} -gt 0 ]; then
  echo "⚠️ Instalando paquetes: ${PKGS[*]}"
  sudo apt-get update
  sudo apt-get install -y "${PKGS[@]}"
else
  echo "✅ Todas las herramientas del sistema están presentes."
fi

KIWIX_BIN="$(command -v kiwix-serve)" || die "kiwix-serve no quedó instalado."

# 2. Entorno virtual de Python (evita --break-system-packages y paquetes globales)
echo "==> Preparando entorno virtual en $VENV_DIR..."
[ -x "$VENV_DIR/bin/python" ] || python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/pip" install --quiet --upgrade pip
"$VENV_DIR/bin/pip" install --quiet fastapi uvicorn beautifulsoup4
PYTHON_BIN="$VENV_DIR/bin/python"

# 3. Localizar el ZIM más reciente (por versión, no por orden arbitrario)
pick_zim() {
  find "$WIKI_DIR" -maxdepth 1 -type f -name "$1" 2>/dev/null | sort -V | tail -n 1 || true
}
ZIM_FILE=$(pick_zim "wikipedia_${WIKI_LANG}_top_nopic_*.zim")
if [ -z "$ZIM_FILE" ]; then
  ZIM_FILE=$(pick_zim "wikipedia_${WIKI_LANG}_*.zim")
fi
[ -n "$ZIM_FILE" ] || die "No hay ningún ZIM 'wikipedia_${WIKI_LANG}_*' en $WIKI_DIR. Ejecuta antes el script 10 (WIKI_LANG=$WIKI_LANG)."
echo "✅ ZIM seleccionado: $ZIM_FILE"

# 4. Servicio systemd para Kiwix
echo "==> Configurando servicio $SERVICE_KIWIX ($KIWIX_BIND:$KIWIX_PORT)..."
sudo tee "/etc/systemd/system/$SERVICE_KIWIX" > /dev/null <<EOF
[Unit]
Description=Servidor Kiwix Wikipedia ($WIKI_LANG) (Maple)
After=network.target

[Service]
Type=simple
User=$RUN_USER
ExecStart=$KIWIX_BIN --address=$KIWIX_BIND --port=$KIWIX_PORT "$ZIM_FILE"
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

# 5. Script CLI de búsqueda limpia
echo "==> Generando script CLI en: $CLIENT_SCRIPT"
cat > "$CLIENT_SCRIPT" <<'EOF'
#!/usr/bin/env bash
# Busca en la Wikipedia local (Kiwix) y devuelve el primer artículo en Markdown limpio.
set -euo pipefail

if [ $# -eq 0 ]; then
  echo "❌ Error: Debes proporcionar un término de búsqueda." >&2
  exit 1
fi

QUERY="$*"
KIWIX_URL="${KIWIX_URL:-__KIWIX_URL__}"
PYTHON="${WIKI_PYTHON:-__PYTHON__}"
MAX_WORDS="${MAX_WORDS:-2000}"
CURL=(curl -fsS --max-time 15)

# Dependencia: sin Kiwix no hay búsqueda. Mensaje claro en vez de un error críptico de curl.
if ! curl -fs -o /dev/null --max-time 3 "$KIWIX_URL/"; then
  echo "❌ Kiwix no responde en $KIWIX_URL (revisa: systemctl status kiwix-wiki.service)" >&2
  exit 1
fi

# Primer resultado de la búsqueda (URL absoluta); vacío si no hay resultados
ARTICLE_URL=$("${CURL[@]}" -G "$KIWIX_URL/search" \
    --data-urlencode "pattern=$QUERY" --data-urlencode "pageLength=5" |
  "$PYTHON" -c '
import sys
from urllib.parse import urljoin
from bs4 import BeautifulSoup
soup = BeautifulSoup(sys.stdin.read(), "html.parser")
box = soup.find("div", class_="results")
link = box.find("a", href=True) if box else None
if link:
    print(urljoin(sys.argv[1] + "/", link["href"]))
' "$KIWIX_URL")

if [ -z "$ARTICLE_URL" ]; then
  echo "⚠️ No articles found for: '$QUERY'"
  exit 0
fi

# Artículo -> HTML -> texto limpio (títulos, párrafos y listas) con recorte por palabras.
# Sin pandoc: así no hay escapes tipo \[ ... \] (que Page Assist interpreta como fórmula LaTeX)
# ni cortes de párrafo en mitad de una frase.
"${CURL[@]}" -L "$ARTICLE_URL" |
"$PYTHON" -c '
import re
import sys
from bs4 import BeautifulSoup

max_words = int(sys.argv[1])
soup = BeautifulSoup(sys.stdin.read(), "html.parser")

for el in soup(["script", "style", "link", "meta", "noscript", "nav", "footer", "header",
                "aside", "table", "sup", "img", "figure", "audio", "button"]):
    el.decompose()
NOISY = ["kiwixNav", "kiwixfooter", "mw-jump-link", "infobox", "navbox", "thumb", "reference",
         "mw-ref", "ext-phonos", "mw-editsection", "noprint"]
for el in soup.find_all(class_=NOISY):
    el.decompose()
content = soup.find("div", id="mw-content-text") or soup.find("body") or soup

# Secciones finales sin valor para el modelo (se corta al llegar a la primera)
STOP = {"references", "notes", "footnotes", "external links", "see also", "further reading",
        "bibliography", "sources", "referencias", "notas", "enlaces externos", "véase también",
        "bibliografía"}

def clean(t):
    t = t.replace("\u2009", " ").replace("\xa0", " ")
    t = re.sub(r"\s+", " ", t).strip()
    t = re.sub(r"\s+([,.;:!?)\]])", r"\1", t)     # espacio antes de puntuación
    t = re.sub(r"([(\[])\s+", r"\1", t)           # espacio tras ( o [
    t = re.sub(r"\(\s*[;,:]?\s*\)", "", t)        # paréntesis vacíos
    t = re.sub(r" {2,}", " ", t)
    return t.replace("$", "\\$")                  # un $ suelto activaría el modo fórmula

def own_text(li):
    # texto del <li> sin el de sus sublistas (esas tienen sus propios <li>)
    return "".join(s for s in li.find_all(string=True) if s.find_parent(["ul", "ol"]) is li.parent)

out, count, trimmed, prev_li = [], 0, False, False
for el in content.find_all(["h1", "h2", "h3", "h4", "h5", "h6", "p", "li"]):
    name = el.name
    if name == "p" and el.find_parent(["li", "p"]):
        continue                                   # ya incluido en su <li> / <p> contenedor
    text = clean(own_text(el) if name == "li" else el.get_text())
    if not text:
        continue
    if name[0] == "h":
        if text.lower() in STOP:
            break
        text = "#" * min(int(name[1]), 4) + " " + text
    elif name == "li":
        text = "- " + text

    words = text.split()
    if count + len(words) > max_words:
        remaining = max_words - count
        if remaining > 0:
            out.append(" ".join(words[:remaining]))
        trimmed = True
        break
    if name == "li" and prev_li:
        out[-1] += "\n" + text                     # elementos de lista consecutivos juntos
    else:
        out.append(text)
    prev_li = name == "li"
    count += len(words)

if trimmed:
    out.append("[... Content trimmed to %d words ...]" % max_words)
print("\n\n".join(out) if out else "")
' "$MAX_WORDS"
EOF
sed -i "s|__KIWIX_URL__|$KIWIX_URL|g; s|__PYTHON__|$PYTHON_BIN|g" "$CLIENT_SCRIPT"
chmod +x "$CLIENT_SCRIPT"

# 6. Servidor MCP puente (Streamable HTTP)
echo "==> Generando servidor MCP puente en: $MCP_SERVER_FILE"
cat > "$MCP_SERVER_FILE" <<'EOF'
import asyncio
import os
import signal

import uvicorn
from fastapi import FastAPI, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

HERE = os.path.dirname(os.path.abspath(__file__))
CLI_SCRIPT = os.environ.get("WIKI_CLI_SCRIPT") or os.path.join(HERE, "buscar_wiki_en.sh")
HOST = os.environ.get("MCP_HOST", "127.0.0.1")
PORT = int(os.environ.get("MCP_PORT", "10003"))
TIMEOUT = float(os.environ.get("MCP_TIMEOUT", "30"))
ORIGINS = [o.strip() for o in os.environ.get("MCP_CORS_ORIGINS", "*").split(",") if o.strip()]

SUPPORTED_VERSIONS = ["2025-06-18", "2025-03-26", "2024-11-05"]

TOOLS = [
    {
        "name": "search_wikipedia",
        "description": "Search for a topic in the local Wikipedia ZIM database and return clean markdown content.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "The search term or topic to look up in Wikipedia."}
            },
            "required": ["query"],
        },
    }
]

app = FastAPI(title="Wikipedia Streamable HTTP MCP Server")
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


async def run_search(query: str):
    """Devuelve (texto, es_error). No bloquea el event loop."""
    query = query.strip()
    if not query:
        return "Empty query.", True
    try:
        proc = await asyncio.create_subprocess_exec(
            CLI_SCRIPT, query,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            start_new_session=True,  # permite matar todo el grupo (curl, pandoc...) si hay timeout
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
        return f"Search timed out after {TIMEOUT:g}s.", True

    if proc.returncode != 0:
        return f"Error: {err.decode(errors='replace').strip()}", True
    text = out.decode(errors="replace").strip()
    return (text or "No relevant article found."), False


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
            "serverInfo": {"name": "wikipedia_mini", "version": "1.1.0"},
        })

    if method == "ping":
        return rpc_result(req_id, {})

    if method == "tools/list":
        return rpc_result(req_id, {"tools": TOOLS})

    if method == "tools/call":
        if params.get("name") != "search_wikipedia":
            return rpc_error(req_id, -32602, f"Unknown tool: {params.get('name')}")
        arguments = params.get("arguments") or {}
        query = arguments.get("query")
        if not isinstance(query, str):
            return rpc_error(req_id, -32602, "Argument 'query' (string) is required")
        text, is_error = await run_search(query)
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

# 7. Servicio systemd para el MCP puente
echo "==> Configurando servicio $SERVICE_MCP ($BIND_ADDR:$MCP_PORT)..."
sudo tee "/etc/systemd/system/$SERVICE_MCP" > /dev/null <<EOF
[Unit]
Description=Servidor Puente MCP Wikipedia (Page Assist)
After=network.target $SERVICE_KIWIX
Wants=$SERVICE_KIWIX

[Service]
Type=simple
User=$RUN_USER
Environment=MCP_HOST=$BIND_ADDR
Environment=MCP_PORT=$MCP_PORT
Environment=WIKI_CLI_SCRIPT=$CLIENT_SCRIPT
Environment=KIWIX_URL=$KIWIX_URL
ExecStart=$PYTHON_BIN $MCP_SERVER_FILE
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

# 8. Arrancar servicios
sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_KIWIX" "$SERVICE_MCP" >/dev/null
sudo systemctl restart "$SERVICE_KIWIX"
sudo systemctl restart "$SERVICE_MCP"

# 9. Comprobación rápida
wait_http() {
  local url="$1" i
  for i in $(seq 1 20); do
    curl -fs -o /dev/null --max-time 2 "$url" && return 0
    sleep 1
  done
  return 1
}

echo "==> Comprobando servicios..."
if wait_http "$KIWIX_URL/"; then
  echo "✅ Kiwix responde en el puerto $KIWIX_PORT"
else
  echo "⚠️ Kiwix no responde. Revisa: journalctl -u $SERVICE_KIWIX -n 30" >&2
fi
if wait_http "http://$MCP_HOST_CHECK:$MCP_PORT/health"; then
  echo "✅ MCP responde en el puerto $MCP_PORT"
else
  echo "⚠️ MCP no responde. Revisa: journalctl -u $SERVICE_MCP -n 30" >&2
fi

TEST_OUT=$("$CLIENT_SCRIPT" "Albert Einstein" 2>&1 | head -c 200 || true)
echo "==> Prueba de búsqueda CLI: ${TEST_OUT:-<sin salida>}"

echo ""
echo "======================================================"
echo " 🎉 ¡Despliegue completado!"
echo "======================================================"
echo "1️⃣ Kiwix:            $KIWIX_URL"
echo "2️⃣ MCP (Page Assist): http://$BIND_ADDR:$MCP_PORT/  (también /mcp)"
echo "3️⃣ CLI de búsqueda:   $CLIENT_SCRIPT \"término\""
echo "======================================================"

