#!/usr/bin/env bash
# 10 - Descarga la versión más reciente de Wikipedia sin imágenes (nopic)
# para Kiwix / Maple local usando wget.
#
# Uso:
#   ./10_wikipedia.sh                  # inglés (por defecto)
#   WIKI_LANG=es ./10_wikipedia.sh     # español
#   RATE_LIMIT=5M ./10_wikipedia.sh    # limitar velocidad (vacío = máximo)
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/maple}"
WIKI_DIR="$INSTALL_DIR/wikipedia"
WIKI_LANG="${WIKI_LANG:-en}"
RATE_LIMIT="${RATE_LIMIT:-}"
BASE_URL="https://dumps.wikimedia.org/other/kiwix/zim/wikipedia/"

for cmd in curl wget; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "❌ Falta el comando '$cmd'." >&2; exit 1; }
done

echo "==> Preparando el directorio en $WIKI_DIR..."
mkdir -p "$WIKI_DIR"

echo "==> Obteniendo el listado de $BASE_URL ..."
LISTING=$(curl -fsSL "$BASE_URL") || {
  echo "❌ Error: no se pudo descargar el listado de $BASE_URL." >&2
  exit 1
}

# Busca en el listado (ya descargado una sola vez) el archivo más reciente
find_latest() {
  printf '%s\n' "$LISTING" | grep -oE "$1" | sort -uV | tail -n 1 || true
}

echo "==> Buscando el ZIM 'wikipedia_${WIKI_LANG}' más reciente..."
LATEST_ZIM=$(find_latest "wikipedia_${WIKI_LANG}_top_nopic_[0-9]{4}-[0-9]{2}\.zim")

if [ -z "$LATEST_ZIM" ]; then
  # Fallback: solo variantes ligeras (nopic/mini) para no bajar 100+ GB por error
  LATEST_ZIM=$(find_latest "wikipedia_${WIKI_LANG}_[a-z0-9]+_(nopic|mini)_[0-9]{4}-[0-9]{2}\.zim")
fi

if [ -z "$LATEST_ZIM" ]; then
  echo "❌ Error: no se pudo localizar un ZIM para '${WIKI_LANG}' en $BASE_URL." >&2
  exit 1
fi

echo "✅ Archivo ZIM detectado: $LATEST_ZIM"

DEST_FILE="$WIKI_DIR/$LATEST_ZIM"
PART_FILE="$DEST_FILE.part"
DOWNLOAD_URL="$BASE_URL$LATEST_ZIM"

if [ -f "$DEST_FILE" ]; then
  echo "✅ El archivo ya existe en: $DEST_FILE"
  exit 0
fi

# Tamaño informativo (si el servidor lo da)
SIZE=$(curl -fsIL "$DOWNLOAD_URL" | awk 'tolower($1)=="content-length:"{s=$2} END{print s+0}' || true)
if [ "${SIZE:-0}" -gt 0 ]; then
  echo "    Tamaño: $(( SIZE / 1024 / 1024 )) MiB"
fi

echo "==> Descargando $LATEST_ZIM con wget..."
echo "    URL: $DOWNLOAD_URL"

WGET_ARGS=(-c --progress=bar:force -O "$PART_FILE")
if [ -n "$RATE_LIMIT" ]; then
  echo "==> Aplicando límite de velocidad: $RATE_LIMIT"
  WGET_ARGS+=(--limit-rate="$RATE_LIMIT")
else
  echo "==> Descargando a máxima velocidad..."
fi

wget "${WGET_ARGS[@]}" "$DOWNLOAD_URL"

# Solo renombramos al terminar bien: así un corte no deja un ZIM "falso" completo
mv "$PART_FILE" "$DEST_FILE"

echo ""
echo "🎉 ¡Descarga completada!"
echo "📁 Guardado en: $DEST_FILE"

