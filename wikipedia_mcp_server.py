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
