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
