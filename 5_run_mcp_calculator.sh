#!/usr/bin/env bash
# 5 - Lanza el servidor MCP de calculadora (mcp_calculator.py).
# Crea un entorno virtual aparte la primera vez (no toca el Python del sistema).
#
# Endpoint MCP:  http://127.0.0.1:10001/mcp
# Variables opcionales:  MCP_PORT=10001  MCP_HOST=127.0.0.1  INSTALL_DIR=~/maple
#
# En Page Assist: Ajustes -> MCP -> añadir servidor -> URL http://127.0.0.1:10001/mcp (sin auth)
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/maple}"
VENV="$INSTALL_DIR/mcp-venv"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export MCP_HOST="${MCP_HOST:-127.0.0.1}"
export MCP_PORT="${MCP_PORT:-10001}"

command -v python3 >/dev/null || { echo "Falta python3 (sudo apt install python3)" >&2; exit 1; }
[[ -f "$HERE/mcp_calculator.py" ]] || { echo "No encuentro mcp_calculator.py junto a este script" >&2; exit 1; }

# Puerto libre
if command -v ss >/dev/null && ss -ltnH "sport = :$MCP_PORT" | grep -q .; then
  echo "El puerto $MCP_PORT ya está en uso:" >&2
  ss -ltnp "sport = :$MCP_PORT" >&2 || true
  echo "Usa otro:  MCP_PORT=10011 $0" >&2
  exit 1
fi

# Entorno virtual
if [[ ! -x "$VENV/bin/python" ]]; then
  echo "==> Creando entorno virtual en $VENV ..."
  python3 -m venv "$VENV" || {
    echo "No se pudo crear el entorno virtual. En Debian/Ubuntu:  sudo apt install python3-venv" >&2
    rm -rf "$VENV"; exit 1
  }
fi

# Dependencias. Se fija mcp<2: la v2 cambió la API (FastMCP pasó a llamarse MCPServer).
if ! "$VENV/bin/python" -c "import mcp, uvicorn, starlette" 2>/dev/null; then
  echo "==> Instalando dependencias (mcp<2)..."
  "$VENV/bin/pip" install --quiet --upgrade pip
  "$VENV/bin/pip" install --quiet "mcp<2"
fi

exec "$VENV/bin/python" "$HERE/mcp_calculator.py"
