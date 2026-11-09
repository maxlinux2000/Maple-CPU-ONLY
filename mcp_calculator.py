#!/usr/bin/env python3
"""
Servidor MCP con una calculadora exacta, pensado para modelos pequeños.

- Una sola herramienta: `calcular(expresion, decimales=10)`.
- Aritmética decimal de 60 dígitos (sqrt, exp, ln, log10 y potencias exactas a esa precisión).
  La trigonometría usa coma flotante (~15 dígitos).
- Seguro: NO usa eval ni shell. Evalúa el árbol sintáctico con una lista blanca de operaciones.
- Transporte: HTTP streamable en http://127.0.0.1:10001/mcp (cambia con MCP_HOST / MCP_PORT).

Requisitos:  pip install "mcp<2"
"""
import ast
import math
import os
import re
from decimal import (ROUND_CEILING, ROUND_FLOOR, ROUND_HALF_UP, Decimal,
                     DecimalException, localcontext)
from typing import Annotated

from pydantic import Field

PRECISION = 60
MAX_LEN = 400          # caracteres de la expresión
MAX_NODES = 300        # nodos del árbol
MAX_EXP = 100_000      # |exponente| máximo en potencias
MAX_FACTORIAL = 1000
PI = Decimal("3.14159265358979323846264338327950288419716939937510582097494459")


class CalcError(Exception):
    pass


# ---------------------------------------------------------------- funciones
def _f(fn):
    """Aplica una función de math (float) y devuelve Decimal."""
    def wrapper(x):
        try:
            return Decimal(repr(fn(float(x))))
        except (ValueError, OverflowError) as e:
            raise CalcError(f"valor fuera del dominio ({e})")
    return wrapper


def _sqrt(x):
    if x < 0:
        raise CalcError("raíz cuadrada de un número negativo")
    return x.sqrt()


def _cbrt(x):
    if x == 0:
        return Decimal(0)
    r = abs(x) ** (Decimal(1) / Decimal(3))
    return r if x > 0 else -r


def _ln(x):
    if x <= 0:
        raise CalcError("el logaritmo exige un número positivo")
    return x.ln()


def _log10(x):
    if x <= 0:
        raise CalcError("el logaritmo exige un número positivo")
    return x.log10()


def _log2(x):
    return _ln(x) / _ln(Decimal(2))


def _log(x, base=None):
    if base is None:
        return _ln(x)
    if base <= 0 or base == 1:
        raise CalcError("base de logaritmo no válida")
    return _ln(x) / _ln(base)


def _round(x, n=Decimal(0)):
    return x.quantize(Decimal(1).scaleb(-int(n)), rounding=ROUND_HALF_UP)


def _factorial(x):
    if x != x.to_integral_value() or x < 0:
        raise CalcError("el factorial exige un entero no negativo")
    if x > MAX_FACTORIAL:
        raise CalcError(f"factorial limitado a {MAX_FACTORIAL}")
    return Decimal(math.factorial(int(x)))


def _pow(x, y):
    if abs(y) > MAX_EXP:
        raise CalcError("exponente demasiado grande")
    try:
        return x ** y
    except DecimalException:
        raise CalcError("potencia no válida (¿base negativa con exponente no entero?)")


FUNCS = {
    "sqrt": _sqrt, "cbrt": _cbrt,
    "exp": lambda x: x.exp(), "ln": _ln, "log10": _log10, "log2": _log2, "log": _log,
    "abs": abs,
    "floor": lambda x: x.to_integral_value(rounding=ROUND_FLOOR),
    "ceil": lambda x: x.to_integral_value(rounding=ROUND_CEILING),
    "round": _round, "factorial": _factorial,
    "sin": _f(math.sin), "cos": _f(math.cos), "tan": _f(math.tan),
    "asin": _f(math.asin), "acos": _f(math.acos), "atan": _f(math.atan),
    "sinh": _f(math.sinh), "cosh": _f(math.cosh), "tanh": _f(math.tanh),
    "radians": lambda x: x * PI / 180, "degrees": lambda x: x * 180 / PI,
    "min": min, "max": max, "pow": _pow,
}


# ---------------------------------------------------------------- evaluador
class _Eval:
    def __init__(self, source: str):
        self.src = source
        self.nodes = 0

    def visit(self, node):
        self.nodes += 1
        if self.nodes > MAX_NODES:
            raise CalcError("expresión demasiado compleja")

        if isinstance(node, ast.Expression):
            return self.visit(node.body)

        if isinstance(node, ast.Constant):
            if isinstance(node.value, bool) or not isinstance(node.value, (int, float)):
                raise CalcError("solo se admiten números")
            text = ast.get_source_segment(self.src, node) or str(node.value)
            try:
                return Decimal(text.replace("_", ""))
            except DecimalException:
                return Decimal(str(node.value))

        if isinstance(node, ast.Name):
            if node.id == "pi":
                return PI
            if node.id == "e":
                return Decimal(1).exp()
            raise CalcError(f"nombre desconocido: {node.id}")

        if isinstance(node, ast.UnaryOp):
            v = self.visit(node.operand)
            if isinstance(node.op, ast.USub):
                return -v
            if isinstance(node.op, ast.UAdd):
                return +v
            raise CalcError("operador no admitido")

        if isinstance(node, ast.BinOp):
            a, b = self.visit(node.left), self.visit(node.right)
            op = node.op
            if isinstance(op, ast.Add):
                return a + b
            if isinstance(op, ast.Sub):
                return a - b
            if isinstance(op, ast.Mult):
                return a * b
            if isinstance(op, (ast.Div, ast.FloorDiv, ast.Mod)) and b == 0:
                raise CalcError("división por cero")
            if isinstance(op, ast.Div):
                return a / b
            if isinstance(op, ast.FloorDiv):
                return (a / b).to_integral_value(rounding=ROUND_FLOOR)
            if isinstance(op, ast.Mod):
                return a % b
            if isinstance(op, ast.Pow):
                return _pow(a, b)
            raise CalcError("operador no admitido")

        if isinstance(node, ast.Call):
            if not isinstance(node.func, ast.Name) or node.keywords:
                raise CalcError("llamada no admitida")
            fn = FUNCS.get(node.func.id)
            if fn is None:
                raise CalcError(f"función desconocida: {node.func.id}")
            args = [self.visit(a) for a in node.args]
            try:
                return fn(*args)
            except TypeError:
                raise CalcError(f"número de argumentos incorrecto en {node.func.id}()")

        raise CalcError("expresión no admitida")


def _normalize(expr: str) -> str:
    expr = expr.strip().rstrip("=? ").strip()   # tolera "sqrt(2) =" o "sqrt(2)?"
    expr = (expr.replace("×", "*").replace("÷", "/").replace("−", "-")
                .replace("π", "pi").replace("^", "**"))
    expr = re.sub(r"√\s*\(", "sqrt(", expr)
    expr = re.sub(r"√\s*([0-9.]+)", r"sqrt(\1)", expr)
    return expr


def _format(x: Decimal, decimals: int) -> str:
    if x.is_nan() or x.is_infinite():
        raise CalcError("resultado no finito")
    if x == x.to_integral_value() and abs(x) < Decimal(10) ** 59:
        return str(int(x))          # enteros exactos (hasta 59 dígitos)
    ax = abs(x)
    if ax >= Decimal("1e15") or ax < Decimal("1e-6"):
        mant, exp = format(x, ".15E").split("E")
        mant = mant.rstrip("0").rstrip(".") if "." in mant else mant
        return f"{mant}e{int(exp):+d}"
    q = x.quantize(Decimal(1).scaleb(-decimals), rounding=ROUND_HALF_UP)
    s = format(q, "f")
    if "." in s:
        s = s.rstrip("0").rstrip(".")
    return s


def evaluar(expresion: str, decimales: int = 10) -> str:
    """Núcleo testeable: devuelve 'expresión = resultado' o 'Error: ...'."""
    try:
        if not isinstance(expresion, str) or not expresion.strip():
            raise CalcError("expresión vacía")
        if len(expresion) > MAX_LEN:
            raise CalcError("expresión demasiado larga")
        decimales = max(0, min(30, int(decimales)))
        src = _normalize(expresion)
        try:
            tree = ast.parse(src, mode="eval")
        except SyntaxError:
            raise CalcError("expresión mal formada (usa punto decimal y paréntesis)")
        with localcontext() as ctx:
            ctx.prec = PRECISION
            ctx.Emax = 1_000_000
            ctx.Emin = -1_000_000
            result = _Eval(src).visit(tree)
            if not isinstance(result, Decimal):
                result = Decimal(result)
            shown = expresion.strip().rstrip("=? ").strip()
            # Page Assist interpreta los asteriscos como cursiva (Markdown) y los "come":
            # 48*25*0.96 se ve como "48250.96". Se muestra con × y ^ (la herramienta los acepta).
            shown = shown.replace("**", "^").replace("*", "×")
            return f"{shown} = {_format(result, decimales)}"   # dentro del contexto de precisión
    except CalcError as e:
        return f"Error: {e}"
    except DecimalException:
        return "Error: operación no válida o resultado fuera de rango"
    except (ValueError, ArithmeticError) as e:
        return f"Error: {e}"


# ---------------------------------------------------------------- Origin de extensiones
# El SDK de MCP rechaza (403) cualquier cabecera Origin que no sea localhost/127.0.0.1.
# Las extensiones de navegador (p. ej. Page Assist) envían moz-extension://<uuid> o
# chrome-extension://<id>, que además cambian por perfil y no admiten comodines.
# Esta capa quita la cabecera Origin SOLO en esos casos; cualquier otra web sigue bloqueada
# y la comprobación del Host se mantiene.
EXTENSION_ORIGINS = ("moz-extension://", "chrome-extension://",
                     "safari-web-extension://", "ms-browser-extension://")


class AllowExtensionOrigin:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http":
            origin = next((v for k, v in scope["headers"] if k == b"origin"), b"").decode("latin-1")
            if origin.startswith(EXTENSION_ORIGINS):
                scope = dict(scope)
                scope["headers"] = [(k, v) for k, v in scope["headers"] if k != b"origin"]
        await self.app(scope, receive, send)


# ---------------------------------------------------------------- servidor MCP
def calcular(
    expresion: Annotated[str, Field(description="Expresión matemática, p. ej. sqrt(123) o 2^10/3")],
    decimales: Annotated[int, Field(description="Decimales del resultado (0-30)")] = 10,
) -> str:
    """Calculadora exacta. Úsala SIEMPRE para cualquier cuenta (sumas, raíces, potencias, logaritmos…) en lugar de calcular de cabeza.
    Operadores: + - * / ** ^ % //. Funciones: sqrt cbrt exp ln log10 log2 log(x,base) abs floor ceil round factorial
    sin cos tan asin acos atan (radianes) radians degrees min max pow. Constantes: pi, e. Punto decimal."""
    return evaluar(expresion, decimales)


def main():
    import uvicorn
    from mcp.server.fastmcp import FastMCP
    from starlette.middleware.cors import CORSMiddleware

    host = os.environ.get("MCP_HOST", "127.0.0.1")
    port = int(os.environ.get("MCP_PORT", "10001"))

    mcp = FastMCP("calculadora", host=host, port=port,
                  stateless_http=True, json_response=True)
    mcp.tool(structured_output=False)(calcular)   # solo texto: evita el duplicado {"result": ...}

    app = mcp.streamable_http_app()
    app.add_middleware(AllowExtensionOrigin)   # interna: el SDK no verá el Origin de extensiones
    app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"],
                       allow_headers=["*"], expose_headers=["Mcp-Session-Id"])

    print(f"Calculadora MCP en http://{host}:{port}/mcp  (Ctrl+C para parar)")
    uvicorn.run(app, host=host, port=port, log_level="warning")


if __name__ == "__main__":
    main()
