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
