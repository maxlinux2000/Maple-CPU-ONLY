#!/usr/bin/env bash
# 1/5 - Instala dependencias y compila llama.cpp (solo CPU) para ejecutar Maple-Preview.
# Probado en: Debian 12, x86_64 con AVX2 (Intel i5-8350U). No hace falta clang: basta gcc.
#
# Todo queda dentro de INSTALL_DIR (por defecto ~/maple); no se toca nada fuera de ahí,
# salvo los paquetes del sistema que instala apt.
# Al volver a ejecutarlo se actualiza llama.cpp a la última versión (o a LLAMA_REF); cualquier
# cambio manual dentro de INSTALL_DIR/llama.cpp se descarta. LLAMA_REF exige el SHA COMPLETO.
#
# Uso:   ./1_install_maple_engine.sh
#
# Variables opcionales:
#   INSTALL_DIR=~/maple    carpeta de instalación
#   ENGINE=upstream        llama.cpp oficial (por defecto). La arquitectura "maple" ya está integrada.
#   ENGINE=deepgrove       fork de DeepGrove (rama main). Solo si tu llama.cpp oficial no soporta maple.
#   LLAMA_REF=<ref>        fijar una versión: SHA completo, etiqueta o rama (por defecto, la última)
#   LLAMA_REPO=<url>       usar otro repositorio o mirror (anula ENGINE)
#   JOBS=4                 procesos de compilación en paralelo (por defecto, todos los núcleos)
#   ALLOW_ROOT=1           permitir ejecutarlo como root (contenedores); entonces no se usa sudo
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/maple}"
ENGINE="${ENGINE:-upstream}"
LLAMA_REF="${LLAMA_REF:-}"
JOBS="${JOBS:-$(nproc)}"
SRC_DIR="$INSTALL_DIR/llama.cpp"

case "$ENGINE" in
  upstream)  REPO="https://github.com/ggml-org/llama.cpp.git" ;;
  deepgrove) REPO="https://github.com/deepgrove-ai/llama.cpp.git" ;;
  *) echo "ENGINE debe ser 'upstream' o 'deepgrove'" >&2; exit 1 ;;
esac
CUSTOM_REPO=""
if [[ -n "${LLAMA_REPO:-}" ]]; then REPO="$LLAMA_REPO"; CUSTOM_REPO=1; fi

# ---------------------------------------------------------------- comprobaciones previas
SUDO="sudo"
if [[ $EUID -eq 0 ]]; then
  if [[ -z "${ALLOW_ROOT:-}" ]]; then
    echo "No ejecutes este script como root (usa un usuario normal; sudo se pide solo para apt)." >&2
    echo "En un contenedor puedes forzarlo con ALLOW_ROOT=1." >&2
    exit 1
  fi
  SUDO=""
fi

if grep -q avx2 /proc/cpuinfo 2>/dev/null; then
  echo "CPU: AVX2 OK"
else
  echo "AVISO: no se detecta AVX2; Maple irá bastante más lento."
fi

MEM_KB="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
if (( MEM_KB > 0 && MEM_KB < 8 * 1024 * 1024 )); then
  echo "AVISO: tienes menos de 8 GB de RAM; el modelo ocupa ~6 GB solo cargado."
fi

# ---------------------------------------------------------------- dependencias
if command -v apt-get >/dev/null 2>&1; then
  echo "==> Instalando dependencias con apt..."
  $SUDO apt-get update
  $SUDO apt-get install -y git cmake make build-essential ca-certificates curl iproute2
else
  echo "AVISO: no hay apt-get. Instala a mano: git, cmake, make, gcc/g++, curl e iproute2 (comando ss)."
fi
for c in git cmake make g++ curl; do
  command -v "$c" >/dev/null 2>&1 || { echo "Falta '$c' en el PATH." >&2; exit 1; }
done

# ---------------------------------------------------------------- código fuente
mkdir -p "$INSTALL_DIR"
if [[ -d "$SRC_DIR/.git" ]]; then
  CURRENT="$(git -C "$SRC_DIR" remote get-url origin)"
  if [[ "$CURRENT" != "$REPO" ]]; then
    echo "Ya existe $SRC_DIR con otro origen:" >&2
    echo "  actual : $CURRENT" >&2
    echo "  pedido : $REPO" >&2
    echo "Bórralo o usa otro INSTALL_DIR para cambiar de motor." >&2
    exit 1
  fi
  echo "==> Actualizando el código en $SRC_DIR ..."
else
  echo "==> Descargando $REPO ..."
  git init -q "$SRC_DIR"
  git -C "$SRC_DIR" remote add origin "$REPO"
fi
# fetch superficial + checkout: funciona igual en la primera instalación y al actualizar,
# incluso si el origen reescribe su historial (git pull --ff-only fallaría ahí).
git -C "$SRC_DIR" fetch --depth 1 origin "${LLAMA_REF:-HEAD}"
git -C "$SRC_DIR" checkout -q -f --detach FETCH_HEAD
COMMIT="$(git -C "$SRC_DIR" rev-parse HEAD)"
echo "Commit: $COMMIT"

# ¿Esta versión del código conoce la arquitectura maple?
if ! grep -qi "maple" "$SRC_DIR/src/llama-arch.cpp" 2>/dev/null; then
  echo >&2
  echo "ERROR: este código de llama.cpp no incluye la arquitectura 'maple'." >&2
  echo "  - Con ENGINE=upstream: usa una versión más reciente (no fijes LLAMA_REF a un commit antiguo)." >&2
  echo "  - O prueba el fork de DeepGrove:  ENGINE=deepgrove ./$(basename "$0")" >&2
  exit 1
fi
echo "Arquitectura maple: soportada"

# ---------------------------------------------------------------- compilación
CMAKE_OPTS=(
  -DCMAKE_BUILD_TYPE=Release
  -DGGML_NATIVE=ON            # optimiza para ESTA CPU (el binario no es portable a otras)
  -DLLAMA_OPENSSL=OFF         # sin HTTPS integrado: las descargas se hacen con curl
  -DLLAMA_BUILD_TESTS=OFF
  -DLLAMA_BUILD_EXAMPLES=OFF
)
# Versiones antiguas (p. ej. el fork) usan libcurl para descargar; así no hace falta instalarla.
if [[ "$ENGINE" != "upstream" || -n "$CUSTOM_REPO" ]]; then
  CMAKE_OPTS+=(-DLLAMA_CURL=OFF)
fi

echo "==> Configurando (Release, optimizado para esta CPU)..."
cmake -S "$SRC_DIR" -B "$SRC_DIR/build" "${CMAKE_OPTS[@]}"

echo "==> Compilando con $JOBS procesos (puede tardar 5-15 min)..."
cmake --build "$SRC_DIR/build" --config Release -j"$JOBS"

# ---------------------------------------------------------------- resultado
MISSING=0
for b in llama-cli llama-server llama-bench; do
  if [[ ! -x "$SRC_DIR/build/bin/$b" ]]; then
    echo "AVISO: no se ha generado $SRC_DIR/build/bin/$b" >&2
    MISSING=1
  fi
done
echo "$COMMIT" > "$INSTALL_DIR/engine-commit.txt"

echo
echo "Motor listo en: $SRC_DIR/build/bin/"
echo "Commit compilado: $COMMIT   (guardado en $INSTALL_DIR/engine-commit.txt)"
echo "(Nota: el número de 'build' que imprime llama.cpp sale como b1 en clones superficiales;"
echo " el hash de arriba es la referencia fiable para reproducir esta versión con LLAMA_REF.)"
(( MISSING == 0 )) || echo "Revisa los avisos de arriba antes de continuar."
echo "Siguiente paso: ./2_download_maple.sh"
