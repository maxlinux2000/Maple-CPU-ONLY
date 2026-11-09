#!/usr/bin/env bash
# install.sh - Instalador de la pila Maple local: Maple + MCP calculadora + Wikipedia (Kiwix) + man.
#
# Pon este fichero en la MISMA carpeta que el resto de scripts (1_..., 2_..., 3_..., 5_..., 10_..., 11_...,
# 12_... y mcp_calculator.py). Los copia a $INSTALL_DIR/scripts, los ejecuta en orden y deja todo como
# servicios systemd.
#
# Uso:
#   ./install.sh                       # instala todo (pide confirmación)
#   ./install.sh -y                    # sin preguntar
#   ./install.sh --only wiki,man       # solo algunos componentes: maple, calc, wiki, man
#   ./install.sh --lang es             # Wikipedia en español (por defecto: en)
#   ./install.sh --no-services         # Maple y calculadora NO como servicio (se lanzan a mano: scripts 3 y 5)
#   ./install.sh --no-downloads        # no descargar el modelo ni el ZIM (ya los tienes)
#   ./install.sh --dry-run             # solo muestra el plan
#   ./install.sh --status              # estado de servicios y puertos
#   ./install.sh --uninstall           # para y elimina los servicios (conserva datos)
#   ./install.sh --uninstall --purge   # además borra INSTALL_DIR (¡modelo, ZIM, compilación!)
#
# Variables opcionales:
#   INSTALL_DIR=~/maple
#   MAPLE_PORT=10000  CALC_PORT=10001  KIWIX_PORT=10002  WIKI_MCP_PORT=10003  MAN_MCP_PORT=10004
#   BIND_ADDR=127.0.0.1   (dónde escuchan los MCP de Wikipedia y man)    ALLOW_HELP_EXEC=0|1
#   ENGINE, LLAMA_REF, VARIANT, THREADS, CTX, MAXTOK, REASONING_FORMAT, WIKI_LANG  (se pasan a los scripts)
# OJO: los scripts 11 y 12 usan ambos "MCP_PORT"; aquí se fija cada uno por separado (WIKI_MCP_PORT / MAN_MCP_PORT).
#
# Ejecútalo como usuario normal; pide sudo cuando hace falta.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { echo "❌ $*" >&2; exit 1; }

# Mapa de puertos (en orden de script)
MAPLE_PORT="${MAPLE_PORT:-10000}"
CALC_PORT="${CALC_PORT:-10001}"
KIWIX_PORT="${KIWIX_PORT:-10002}"
WIKI_MCP_PORT="${WIKI_MCP_PORT:-10003}"
MAN_MCP_PORT="${MAN_MCP_PORT:-10004}"
unset MCP_PORT PORT   # nombres ambiguos: se fijan por componente más abajo

INSTALL_DIR="${INSTALL_DIR:-$HOME/maple}"
WIKI_LANG="${WIKI_LANG:-en}"
RUN_USER="${USER:-$(id -un)}"

MODE=install; ASSUME_YES=0; SERVICES=1; DOWNLOADS=1; DRY=0; PURGE=0
ONLY="maple,calc,wiki,man"

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)         ONLY="${2:?Falta la lista de componentes}"; shift 2 ;;
    --lang)         WIKI_LANG="${2:?Falta el idioma}"; shift 2 ;;
    --install-dir)  INSTALL_DIR="${2:?Falta la carpeta}"; shift 2 ;;
    --no-services)  SERVICES=0; shift ;;
    --no-downloads) DOWNLOADS=0; shift ;;
    -y|--yes)       ASSUME_YES=1; shift ;;
    -n|--dry-run)   DRY=1; shift ;;
    --uninstall)    MODE=uninstall; shift ;;
    --purge)        PURGE=1; shift ;;
    --status)       MODE=status; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) die "Opción desconocida: $1 (usa --help)" ;;
  esac
done

INSTALL_DIR="$(realpath -m "$INSTALL_DIR")"
SCRIPTS_DIR="$INSTALL_DIR/scripts"
VENV_CALC="$INSTALL_DIR/mcp-venv"
export INSTALL_DIR WIKI_LANG

declare -A WANT=([maple]=0 [calc]=0 [wiki]=0 [man]=0)
IFS=',' read -ra _items <<<"$ONLY"
for i in "${_items[@]}"; do
  [[ -v WANT[$i] ]] || die "Componente desconocido: '$i' (válidos: maple, calc, wiki, man)"
  WANT[$i]=1
done
want() { [[ "${WANT[$1]}" == 1 ]]; }

UNITS=(maple-server.service maple-calc-mcp.service kiwix-wiki.service wikipedia-mcp.service man-mcp.service)

# ---------------------------------------------------------------- utilidades
confirm() {
  [[ $ASSUME_YES == 1 ]] && return 0
  [[ -t 0 ]] || die "No hay terminal para preguntar; usa --yes."
  local a; read -r -p "$1 [s/N] " a
  [[ "$a" =~ ^[sSyY] ]]
}
port_in_use() { command -v ss >/dev/null 2>&1 && ss -ltnH "sport = :$1" | grep -q .; }
check_port_free() {   # puerto nombre
  if port_in_use "$1"; then
    echo "❌ El puerto $1 ($2) ya está en uso:" >&2
    ss -ltnp "sport = :$1" >&2 || true
    return 1
  fi
}
wait_up() {           # url modo(strict|any) segundos
  local i code
  for ((i = 0; i < $3; i++)); do
    if [[ "$2" == any ]]; then
      code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$1" || true)
      [[ "$code" != 000 ]] && return 0
    else
      curl -fs -o /dev/null --max-time 2 "$1" && return 0
    fi
    sleep 1
  done
  return 1
}

# ---------------------------------------------------------------- estado / desinstalación
do_status() {
  printf '%-22s %-10s %s\n' SERVICIO ESTADO PUERTO
  local rows=("maple-server.service:$MAPLE_PORT" "maple-calc-mcp.service:$CALC_PORT"
              "kiwix-wiki.service:$KIWIX_PORT" "wikipedia-mcp.service:$WIKI_MCP_PORT" "man-mcp.service:$MAN_MCP_PORT")
  local r u p st
  for r in "${rows[@]}"; do
    u="${r%%:*}"; p="${r##*:}"
    st=$(systemctl is-active "$u" 2>/dev/null || true)
    printf '%-22s %-10s %s\n' "$u" "${st:-desconocido}" "$p"
  done
}

do_uninstall() {
  command -v systemctl >/dev/null 2>&1 || die "Sin systemd no hay servicios que quitar."
  echo "Se pararán, deshabilitarán y eliminarán: ${UNITS[*]}"
  confirm "¿Continuar?" || exit 0
  sudo -v
  local u
  for u in "${UNITS[@]}"; do
    sudo systemctl disable --now "$u" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/$u"
  done
  sudo systemctl daemon-reload
  echo "✅ Servicios eliminados."
  if [[ $PURGE == 1 ]]; then
    [[ -n "$INSTALL_DIR" && "$INSTALL_DIR" != "/" && "$INSTALL_DIR" != "$HOME" ]] || die "INSTALL_DIR no es seguro para borrar: '$INSTALL_DIR'"
    [[ -e "$INSTALL_DIR/.installed-by-install.sh" || -d "$INSTALL_DIR/llama.cpp" ]] || die "$INSTALL_DIR no parece una instalación de esta pila; no lo borro."
    echo "Se borrará $INSTALL_DIR ($(du -sh "$INSTALL_DIR" 2>/dev/null | cut -f1)): modelo, ZIM, compilación, venvs."
    confirm "¿Borrar de verdad?" && { rm -rf "$INSTALL_DIR"; echo "✅ Borrado $INSTALL_DIR"; }
  else
    echo "Los datos siguen en $INSTALL_DIR (usa --purge para borrarlos)."
  fi
}

[[ $MODE == status ]]    && { do_status; exit 0; }
[[ $MODE == uninstall ]] && { do_uninstall; exit 0; }

# ---------------------------------------------------------------- validaciones
for v in MAPLE_PORT CALC_PORT KIWIX_PORT WIKI_MCP_PORT MAN_MCP_PORT; do
  [[ "${!v}" =~ ^[0-9]+$ ]] && (( ${!v} >= 1024 && ${!v} <= 65535 )) || die "$v='${!v}' no es un puerto válido (1024-65535)."
done
[[ $(printf '%s\n' "$MAPLE_PORT" "$CALC_PORT" "$KIWIX_PORT" "$WIKI_MCP_PORT" "$MAN_MCP_PORT" | sort -u | wc -l) -eq 5 ]] \
  || die "Los cinco puertos deben ser distintos."
[[ "$WIKI_LANG" =~ ^[a-z]{2,3}$ ]] || die "WIKI_LANG='$WIKI_LANG' no es un código de idioma válido."

missing=()
need() { [[ -f "$HERE/$1" ]] || missing+=("$1"); }
want maple && { need 1_install_maple_engine.sh; need 2_download_maple.sh; need 3_server_maple.sh; }
want calc  && need mcp_calculator.py
want wiki  && { need 10_wikipedia.sh; need 11_wikipedia_server.sh; }
want man   && need 12_man_server.sh
[[ ${#missing[@]} -eq 0 ]] || die "Faltan junto a install.sh: ${missing[*]}"

HAS_SYSTEMD=0; [[ -d /run/systemd/system ]] && HAS_SYSTEMD=1
if [[ $HAS_SYSTEMD == 0 ]]; then
  { want wiki || want man; } && die "Wikipedia y man necesitan systemd (no detectado)."
  SERVICES=0
  echo "AVISO: sin systemd; Maple y la calculadora se instalarán sin servicio."
fi

# ---------------------------------------------------------------- plan
yn() { [[ "$1" == 1 ]] && echo sí || echo no; }
echo "======================================================"
echo " Instalador de la pila Maple local"
echo "======================================================"
echo " Carpeta:           $INSTALL_DIR"
echo " Componentes:       $(for c in maple calc wiki man; do want $c && printf '%s ' "$c"; done)"
want maple && echo " Maple (llama.cpp): puerto $MAPLE_PORT      (compila ~5-15 min, modelo ~5,5 GiB)"
want calc  && echo " MCP calculadora:   puerto $CALC_PORT"
want wiki  && echo " Kiwix ($WIKI_LANG):       puerto $KIWIX_PORT  ·  MCP Wikipedia: puerto $WIKI_MCP_PORT"
want man   && echo " MCP man:           puerto $MAN_MCP_PORT"
echo " Servicios systemd (Maple/calculadora): $(yn $SERVICES)    Descargas: $(yn $DOWNLOADS)"
echo "======================================================"
[[ $DRY == 1 ]] && { echo "(--dry-run: no se ha hecho ningún cambio)"; exit 0; }

[[ $EUID -ne 0 ]] || die "No ejecutes el instalador como root; hazlo como usuario normal (usa sudo internamente)."

mkdir -p "$INSTALL_DIR"
need_gb=0; want maple && need_gb=$((need_gb + 8)); want wiki && [[ $DOWNLOADS == 1 ]] && need_gb=$((need_gb + 6))
avail_gb=$(( $(df -Pk "$INSTALL_DIR" | awk 'NR==2 {print $4}') / 1024 / 1024 ))
if (( avail_gb < need_gb )); then
  echo "AVISO: hay ~${avail_gb} GiB libres en $INSTALL_DIR y se estiman ~${need_gb} GiB necesarios."
fi
confirm "¿Instalar?" || { echo "Cancelado."; exit 0; }

command -v apt-get >/dev/null 2>&1 || die "Este instalador necesita apt-get (Debian/Ubuntu)."
command -v sudo    >/dev/null 2>&1 || die "Falta sudo."
sudo -v
# Mantiene viva la sesión de sudo durante compilaciones y descargas largas
( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null; sleep 50; done ) &
KEEPALIVE_PID=$!
trap 'kill "$KEEPALIVE_PID" 2>/dev/null || true' EXIT

# ---------------------------------------------------------------- pasos
step_base() {
  local pk=(curl ca-certificates iproute2)
  want calc && { command -v python3 >/dev/null 2>&1 || pk+=(python3); python3 -c 'import venv, ensurepip' >/dev/null 2>&1 || pk+=(python3-venv); }
  want wiki && [[ $DOWNLOADS == 1 ]] && pk+=(wget)     # el script 10 descarga con wget y nadie más lo instala
  sudo apt-get update
  sudo apt-get install -y "${pk[@]}"
}

step_scripts() {
  mkdir -p "$SCRIPTS_DIR"
  touch "$INSTALL_DIR/.installed-by-install.sh"
  [[ "$HERE" -ef "$SCRIPTS_DIR" ]] && return 0
  local f
  for f in 1_install_maple_engine.sh 2_download_maple.sh 3_server_maple.sh 4_run_maple_cli.sh \
           5_run_mcp_calculator.sh 10_wikipedia.sh 11_wikipedia_server.sh 12_man_server.sh mcp_calculator.py; do
    if [[ -f "$HERE/$f" ]]; then install -m 755 "$HERE/$f" "$SCRIPTS_DIR/$f"; fi
  done
  echo "Scripts copiados a $SCRIPTS_DIR"
}

# Los scripts 6 y 7 (kiwix.service / kiwix-mcp.service) están obsoletos y chocan con los puertos nuevos
step_migrar() {
  [[ $HAS_SYSTEMD == 1 ]] || return 0
  local old=() u
  for u in kiwix.service kiwix-mcp.service; do
    systemctl cat "$u" >/dev/null 2>&1 && old+=("$u")
  done
  [[ ${#old[@]} -gt 0 ]] || return 0
  echo "Servicios de la versión antigua (scripts 6 y 7): ${old[*]}"
  if confirm "¿Pararlos y deshabilitarlos (los ficheros .service no se borran)?"; then
    sudo systemctl disable --now "${old[@]}" 2>/dev/null || true
  fi
}

step_maple() {
  "$SCRIPTS_DIR/1_install_maple_engine.sh"
  [[ $DOWNLOADS == 1 ]] && "$SCRIPTS_DIR/2_download_maple.sh"
  [[ $SERVICES == 1 ]] || { echo "Sin servicio: lánzalo con PORT=$MAPLE_PORT $SCRIPTS_DIR/3_server_maple.sh"; return 0; }

  local envs="" v
  for v in VARIANT THREADS CTX MAXTOK REASONING_FORMAT; do
    [[ -n "${!v:-}" ]] && envs+="Environment=$v=${!v}"$'\n'
  done
  sudo systemctl stop maple-server.service 2>/dev/null || true
  check_port_free "$MAPLE_PORT" "Maple"
  sudo tee /etc/systemd/system/maple-server.service >/dev/null <<UNIT
[Unit]
Description=Maple-Preview (llama-server, puerto $MAPLE_PORT)
After=network.target

[Service]
Type=simple
User=$RUN_USER
Environment=INSTALL_DIR=$INSTALL_DIR
Environment=PORT=$MAPLE_PORT
${envs}ExecStart=$SCRIPTS_DIR/3_server_maple.sh
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT
  sudo systemctl daemon-reload
  sudo systemctl enable --now maple-server.service
}

step_calc() {
  [[ -x "$VENV_CALC/bin/python" ]] || python3 -m venv "$VENV_CALC"
  "$VENV_CALC/bin/pip" install --quiet --upgrade pip
  "$VENV_CALC/bin/pip" install --quiet "mcp<2"      # la v2 cambió la API
  [[ $SERVICES == 1 ]] || { echo "Sin servicio: lánzalo con MCP_PORT=$CALC_PORT $SCRIPTS_DIR/5_run_mcp_calculator.sh"; return 0; }

  sudo systemctl stop maple-calc-mcp.service 2>/dev/null || true
  check_port_free "$CALC_PORT" "calculadora MCP"
  # Solo 127.0.0.1: el SDK de MCP rechaza cabeceras Host que no sean locales
  sudo tee /etc/systemd/system/maple-calc-mcp.service >/dev/null <<UNIT
[Unit]
Description=Servidor MCP calculadora (puerto $CALC_PORT)
After=network.target

[Service]
Type=simple
User=$RUN_USER
Environment=MCP_HOST=127.0.0.1
Environment=MCP_PORT=$CALC_PORT
ExecStart=$VENV_CALC/bin/python $SCRIPTS_DIR/mcp_calculator.py
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only

[Install]
WantedBy=multi-user.target
UNIT
  sudo systemctl daemon-reload
  sudo systemctl enable --now maple-calc-mcp.service
}

step_man()  { MCP_PORT="$MAN_MCP_PORT" "$SCRIPTS_DIR/12_man_server.sh"; }
step_wiki() {
  [[ $DOWNLOADS == 1 ]] && "$SCRIPTS_DIR/10_wikipedia.sh"
  KIWIX_PORT="$KIWIX_PORT" MCP_PORT="$WIKI_MCP_PORT" "$SCRIPTS_DIR/11_wikipedia_server.sh"
}

# Cada paso en un subshell con errexit activo: si falla, se anota y se sigue con los demás
OK=(); FAILED=()
run_step() {   # clave descripción función
  local key="$1" desc="$2" fn="$3" rc=0
  echo; echo "==> $desc"
  set +e; ( set -e; "$fn" ); rc=$?; set -e
  if [[ $rc -eq 0 ]]; then OK+=("$key"); else FAILED+=("$key"); echo "❌ Falló: $desc (código $rc)" >&2; fi
}
failed() { [[ " ${FAILED[*]-} " == *" $1 "* ]]; }

run_step base    "Dependencias del sistema"        step_base
run_step scripts "Copiando scripts"                step_scripts
failed base || run_step migrar "Buscando servicios antiguos" step_migrar
# Orden: man antes que wiki, así un man-mcp antiguo (que ocupaba el 10003) se libera antes de arrancar el MCP de Wikipedia
want maple && run_step maple "Maple: motor, modelo y servidor (puerto $MAPLE_PORT)" step_maple
want calc  && run_step calc  "MCP calculadora (puerto $CALC_PORT)"                   step_calc
want man   && run_step man   "MCP man (puerto $MAN_MCP_PORT)"                         step_man
want wiki  && run_step wiki  "Wikipedia: Kiwix ($KIWIX_PORT) + MCP ($WIKI_MCP_PORT)"  step_wiki

# ---------------------------------------------------------------- verificación
echo; echo "==> Verificando servicios..."
declare -A RESULT=()
check() {   # clave nombre url modo segundos
  failed "$1" && { RESULT[$2]="FALLÓ la instalación"; return; }
  if wait_up "$3" "$4" "$5"; then RESULT[$2]="OK"; else RESULT[$2]="no responde aún"; fi
}
want maple && [[ $SERVICES == 1 ]] && check maple "Maple        :$MAPLE_PORT" "http://127.0.0.1:$MAPLE_PORT/health" strict 180
want calc  && [[ $SERVICES == 1 ]] && check calc  "Calculadora  :$CALC_PORT"  "http://127.0.0.1:$CALC_PORT/mcp" any 15
want wiki  && check wiki "Kiwix        :$KIWIX_PORT"    "http://127.0.0.1:$KIWIX_PORT/" strict 15
want wiki  && check wiki "MCP Wikipedia:$WIKI_MCP_PORT" "http://127.0.0.1:$WIKI_MCP_PORT/health" strict 15
want man   && check man  "MCP man      :$MAN_MCP_PORT"  "http://127.0.0.1:$MAN_MCP_PORT/health" strict 15

echo
echo "======================================================"
echo " Resumen"
echo "======================================================"
for k in "${!RESULT[@]}"; do printf ' %-26s %s\n' "$k" "${RESULT[$k]}"; done | sort
echo
echo " Page Assist:"
want maple && echo "   Maple (OpenAI API):  http://127.0.0.1:$MAPLE_PORT/v1      modelo: maple-preview"
want calc  && echo "   MCP calculadora:     http://127.0.0.1:$CALC_PORT/mcp"
want wiki  && echo "   MCP Wikipedia:       http://127.0.0.1:$WIKI_MCP_PORT/mcp"
want man   && echo "   MCP man:             http://127.0.0.1:$MAN_MCP_PORT/mcp"
echo
echo " Scripts en: $SCRIPTS_DIR     Estado: $0 --status     Quitar: $0 --uninstall"
echo " Chat en terminal: $SCRIPTS_DIR/4_run_maple_cli.sh"
echo "======================================================"
if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "❌ Pasos con errores: ${FAILED[*]}  (puedes repetir solo esos con --only)" >&2
  exit 1
fi
