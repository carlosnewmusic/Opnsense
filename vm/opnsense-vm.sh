#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: michelroegl-brunner
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
#
# OPNsense VM - FreeBSD 14.x + bootstrap
# ---------------------------------------------------------------------------
# Estrategia: durante la instalación solo se añade la interfaz WAN (vmbr1)
# para evitar el cuelgue de dhclient en la LAN. La LAN (vmbr0) se añade
# después del bootstrap y se configura con IP estática.
# ---------------------------------------------------------------------------

LOG_FILE="${LOG_FILE:-/var/log/opnsense-vm-install.log}"
DEBUG_SERIAL="${DEBUG_SERIAL:-0}"
KEEP_ON_ERROR="${KEEP_ON_ERROR:-0}"
OPNSENSE_VERSION="${OPNSENSE_VERSION:-26.7}"
FREEBSD_MAJOR="14"
LAN_STATIC_IP="${LAN_STATIC_IP:-192.168.2.1}"
LAN_STATIC_PREFIX="${LAN_STATIC_PREFIX:-24}"

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

log()  { local l="$1"; shift; echo -e "[$(date '+%F %T')] [$l] $*" | tee -a "$LOG_FILE"; }
log_info() { log "INFO " "$@"; }
log_warn() { log "WARN " "$@"; }
log_err()  { log "ERROR" "$@"; }
log_dbg()  { [ "$DEBUG_SERIAL" = "1" ] && log "DEBUG" "$@" || echo -e "[DEBUG] $*" >>"$LOG_FILE"; }
log_step() { log "STEP " "$@"; }
log_ok()   { log "OK   " "$@"; }

exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)

log_info "==============================================================="
log_info "OPNsense VM install (FreeBSD ${FREEBSD_MAJOR}.x + bootstrap)"
log_info "OPNsense target: $OPNSENSE_VERSION"
log_info "LAN estática: $LAN_STATIC_IP/$LAN_STATIC_PREFIX"
log_info "DEBUG_SERIAL=$DEBUG_SERIAL  KEEP_ON_ERROR=$KEEP_ON_ERROR"
log_info "==============================================================="

source /dev/stdin <<<$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/api.func)

function header_info {
  clear
  cat <<"EOF"
   ____  ____  _   __
  / __ \/ __ \/ | / /_______  ____  ________
 / / / / /_/ /  |/ / ___/ _ \/ __ \/ ___/ _ \
/ /_/ / ____/ /|  (__  )  __/ / / (__  )  __/
\____/_/   /_/ |_/____/\___/_/ /_/____/\___/

EOF
}
header_info
echo -e "Loading..."

NSAPP="opnsense-vm"; var_os="opnsense"; var_version="${OPNSENSE_VERSION}"
GEN_MAC=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')
GEN_MAC_LAN=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')

YW=$'\033[33m'; BL=$'\033[36m'; RD=$'\033[01;31m'; BGN=$'\033[4;92m'
GN=$'\033[1;92m'; DGN=$'\033[32m'; CL=$'\033[m'; BFR="\\r\\033[K"
HOLD="-"; CM="${GN}✓${CL}"; CROSS="${RD}✗${CL}"

set -Eeo pipefail
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT
trap 'post_update_to_api "failed" "130"' SIGINT
trap 'post_update_to_api "failed" "143"' SIGTERM
trap 'post_update_to_api "failed" "129"; exit 129' SIGHUP

function error_handler() {
  local ec="$?" line="$1" cmd="$2"
  log_err "ERROR line $line exit $ec: $cmd"
  dump_serial_tail 40 2>/dev/null || true
  post_update_to_api "failed" "$ec" 2>/dev/null || true
  [ "$KEEP_ON_ERROR" = "1" ] && log_warn "KEEP_ON_ERROR=1 -> VM $VMID NO destruida" \
    || { log_warn "Destruyendo VM $VMID"; cleanup_vmid; }
}

function get_valid_nextid() {
  local t; t=$(pvesh get /cluster/nextid)
  while true; do
    [ -f "/etc/pve/qemu-server/${t}.conf" ] && { t=$((t+1)); continue; }
    [ -f "/etc/pve/lxc/${t}.conf" ] && { t=$((t+1)); continue; }
    lvs --noheadings -o lv_name 2>/dev/null | grep -qE "(^|[-_])${t}($|[-_])" && { t=$((t+1)); continue; }
    break
  done
  echo "$t"
}

function cleanup_vmid() {
  if qm status $VMID &>/dev/null; then
    qm stop $VMID &>/dev/null || true
    qm destroy $VMID &>/dev/null || true
  fi
}

function cleanup() {
  local ec=$?
  log_info "cleanup() exit=$ec"
  serial_reader_stop 2>/dev/null || true
  popd >/dev/null 2>&1 || true
  [[ "${POST_TO_API_DONE:-}" == "true" && "${POST_UPDATE_DONE:-}" != "true" ]] && {
    [ "$ec" -eq 0 ] && post_update_to_api "done" "none" 2>/dev/null || true
    [ "$ec" -ne 0 ] && post_update_to_api "failed" "$ec" 2>/dev/null || true
  }
  [ "$ec" -eq 0 ] && rm -rf "$TEMP_DIR" || log_warn "TEMP_DIR: $TEMP_DIR"
}

function check_disk_space() {
  local kb=$(df -k "$1" | awk 'NR==2 {print $4}')
  [ $((kb/1024/1024)) -ge "$2" ]
}

if [ -d "/var/tmp" ] && check_disk_space "/var/tmp" 20; then
  TEMP_DIR=$(mktemp -d /var/tmp/opnsense-vm.XXXXXX)
else
  TEMP_DIR=$(mktemp -d)
fi
log_info "TEMP_DIR=$TEMP_DIR"
pushd "$TEMP_DIR" >/dev/null

SERIAL_LOG=""; SERIAL_READER_PID=""

function serial_reader_start() {
  serial_reader_stop
  SERIAL_LOG="${TEMP_DIR}/serial-${VMID}.log"; : > "$SERIAL_LOG"
  command -v socat >/dev/null 2>&1 || { log_err "socat no instalado (apt install socat)"; return 1; }
  local sock="/var/run/qemu-server/${VMID}.serial0"
  for _ in $(seq 1 30); do [ -S "$sock" ] && break; sleep 1; done
  [ -S "$sock" ] || { log_err "Socket $sock no aparece"; return 1; }
  socat -u UNIX-CONNECT:"$sock" - >>"$SERIAL_LOG" 2>/dev/null &
  SERIAL_READER_PID=$!; sleep 1
  log_info "Serial reader PID=$SERIAL_READER_PID"
}

function serial_reader_stop() {
  if [ -n "${SERIAL_READER_PID:-}" ] && kill -0 "$SERIAL_READER_PID" 2>/dev/null; then
    kill "$SERIAL_READER_PID" 2>/dev/null || true
    wait "$SERIAL_READER_PID" 2>/dev/null || true
  fi
  SERIAL_READER_PID=""
}

function wait_for_serial_pattern() {
  local pat="$1" to="${2:-600}" label="${3:-$pat}" el=0
  [ -f "$SERIAL_LOG" ] || return 1
  log_info "Esperando hasta ${to}s a: '$label'"
  while [ $el -lt "$to" ]; do
    grep -qE "$pat" "$SERIAL_LOG" 2>/dev/null && { log_info "Match tras ${el}s"; return 0; }
    sleep 3; el=$((el+3))
    (( el % 60 == 0 )) && log_info "  ... ${el}s / ${to}s"
  done
  log_warn "TIMEOUT '$label'"
  return 1
}

function dump_serial_tail() {
  local n="${1:-30}"
  [ -f "$SERIAL_LOG" ] && { log_info "--- últimas $n líneas ---"; tail -n "$n" "$SERIAL_LOG" | sed 's/^/  | /'; log_info "--- fin ---"; }
}

function send_line_to_vm() {
  log_dbg "TX -> $1"
  local i c
  for ((i=0; i<${#1}; i++)); do
    c=${1:i:1}
    case $c in
      " ") c="spc";; "-") c="minus";; "=") c="equal";; ",") c="comma";; ".") c="dot";;
      "/") c="slash";; "'") c="apostrophe";; ";") c="semicolon";; '\') c="backslash";;
      '`') c="grave_accent";; "[") c="bracket_left";; "]") c="bracket_right";;
      "_") c="shift-minus";; "+") c="shift-equal";; "?") c="shift-slash";;
      "<") c="shift-comma";; ">") c="shift-dot";; '"') c="shift-apostrophe";;
      ":") c="shift-semicolon";; "|") c="shift-backslash";; "~") c="shift-grave_accent";;
      "{") c="shift-bracket_left";; "}") c="shift-bracket_right";;
      A) c="shift-a";; B) c="shift-b";; C) c="shift-c";; D) c="shift-d";;
      E) c="shift-e";; F) c="shift-f";; G) c="shift-g";; H) c="shift-h";;
      I) c="shift-i";; J) c="shift-j";; K) c="shift-k";; L) c="shift-l";;
      M) c="shift-m";; N) c="shift-n";; O) c="shift-o";; P) c="shift-p";;
      Q) c="shift-q";; R) c="shift-r";; S) c="shift-s";; T) c="shift-t";;
      U) c="shift-u";; V) c="shift-v";; W) c="shift-w";; X) c="shift-x";;
      Y) c="shift-y";; Z) c="shift-z";;
      "!") c="shift-1";; "@") c="shift-2";; "#") c="shift-3";; '$') c="shift-4";;
      "%") c="shift-5";; "^") c="shift-6";; "&") c="shift-7";; "*") c="shift-8";;
      "(") c="shift-9";; ")") c="shift-0";;
    esac
    qm sendkey $VMID "$c"
  done
  qm sendkey $VMID ret
}

# --- PROMPT ---
if ! whiptail --backtitle "Proxmox VE Helper Scripts" --title "OPNsense VM" \
     --yesno "Crear VM OPNsense (FreeBSD ${FREEBSD_MAJOR}.x + bootstrap)?" 10 58; then
  header_info && echo -e "⚠ Cancelado\n" && exit
fi

function msg_info() { echo -ne " ${HOLD} ${YW}$1..."; }
function msg_ok()   { echo -e "${BFR} ${CM} ${GN}$1${CL}"; log_ok "$1"; }
function msg_error(){ echo -e "${BFR} ${CROSS} ${RD}$1${CL}"; log_err "$1"; }

function pve_check() {
  local v; v=$(pveversion | awk -F'/' '{print $2}' | awk -F'-' '{print $1}')
  [[ "$v" =~ ^8\.([0-9]+) ]] && { [ ${BASH_REMATCH[1]} -gt 9 ] && { msg_error "PVE 8.x no soportado"; exit 105; }; return 0; }
  [[ "$v" =~ ^9\.([0-9]+) ]] && { [ ${BASH_REMATCH[1]} -gt 2 ] && { msg_error "PVE 9.x no soportado"; exit 105; }; return 0; }
  msg_error "PVE $v no soportado"; exit 105
}
function arch_check() { [ "$(dpkg --print-architecture)" = "amd64" ] || { echo "Solo amd64"; exit; }; }
function ssh_check() {
  command -v pveversion >/dev/null 2>&1 || return 0
  [ -n "${SSH_CLIENT:+x}" ] || return 0
  whiptail --backtitle "Proxmox VE Helper Scripts" --defaultno --title "SSH" \
    --yesno "Usar shell de Proxmox es mejor. ¿Continuar por SSH?" 10 62 || { clear; exit; }
}
function exit-script() { clear; echo "⚠ User exited"; exit; }
function get_available_bridges() { ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | sort; }

function default_settings() {
  VMID=$(get_valid_nextid)
  FORMAT=",efitype=4m"; MACHINE=""; DISK_CACHE=""; HN="opnsense"; CPU_TYPE=""
  CORE_COUNT="4"; RAM_SIZE="8192"; BRG="vmbr0"
  IP_ADDR="$LAN_STATIC_IP"; NETMASK="$LAN_STATIC_PREFIX"; LAN_GW=""
  WAN_IP_ADDR=""; WAN_GW=""; WAN_NETMASK=""
  VLAN=""; MAC=$GEN_MAC; WAN_MAC=$GEN_MAC_LAN; WAN_BRG=""; MTU=""

  local AVAIL=$(get_available_bridges)
  local COUNT=$(echo "$AVAIL" | wc -l)
  log_info "Bridges: $(echo $AVAIL | tr '\n' ' ')"

  echo -e "${DGN}VM ID: ${BGN}${VMID}${CL}"
  echo -e "${DGN}Hostname: ${BGN}${HN}${CL}"
  echo -e "${DGN}Cores: ${BGN}${CORE_COUNT}${CL}"
  echo -e "${DGN}RAM: ${BGN}${RAM_SIZE}${CL}"
  ip link show "$BRG" &>/dev/null || { msg_error "Bridge $BRG no existe"; exit; }
  echo -e "${DGN}LAN Bridge: ${BGN}${BRG}${CL}"
  echo -e "${DGN}LAN estática: ${BGN}${IP_ADDR}/${NETMASK}${CL}"
  echo -e "${DGN}LAN MAC: ${BGN}${MAC}${CL}"

  local DW=$(echo "$AVAIL" | grep -v "^${BRG}$" | head -n1 || true)
  if [ "$COUNT" -ge 2 ]; then
    if NETWORK_MODE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "NETWORK" --radiolist --cancel-button Exit-Script \
      "Modo de red:\n" 14 70 2 \
      "dual" "Dual Interface (Firewall) - WAN en ${DW}" ON \
      "single" "Single Interface (Proxy/VPN)" OFF 3>&1 1>&2 2>&3); then
      if [ "$NETWORK_MODE" = "dual" ]; then
        WAN_BRG="$DW"
        echo -e "${DGN}WAN Bridge: ${BGN}${WAN_BRG}${CL}"
        echo -e "${DGN}WAN MAC: ${BGN}${WAN_MAC}${CL}"
      else WAN_BRG=""; fi
    else exit-script; fi
  else WAN_BRG=""; fi
  echo -e "${BL}Creando VM con la configuración por defecto${CL}"
}

function advanced_settings() { default_settings; }

function start_script() {
  if whiptail --backtitle "Proxmox VE Helper Scripts" --title "SETTINGS" --yesno "¿Usar ajustes por defecto?" --no-button Advanced 10 58; then
    header_info; echo -e "${BL}Default settings${CL}"; default_settings
  else
    header_info; echo -e "${RD}Advanced settings${CL}"; advanced_settings
  fi
}

log_step "[01] arch_check"; arch_check
log_step "[02] pve_check";  pve_check
log_step "[03] ssh_check";  ssh_check
log_step "[04] start_script"; start_script
log_step "[05] post_to_api_vm"; post_to_api_vm || true

# --- STORAGE ---
msg_info "Validando storage"
while read -r line; do
  TAG=$(echo $line | awk '{print $1}')
  TYPE=$(echo $line | awk '{printf "%-10s", $2}')
  FREE=$(echo $line | numfmt --field 4-6 --from-unit=K --to=iec --format %.2f | awk '{printf( "%9sB", $6)}')
  ITEM="  Type: $TYPE Free: $FREE "
  OFFSET=2
  [[ $((${#ITEM} + $OFFSET)) -gt ${MSG_MAX_LENGTH:-} ]] && MSG_MAX_LENGTH=$((${#ITEM} + $OFFSET))
  STORAGE_MENU+=("$TAG" "$ITEM" "OFF")
done < <(pvesm status -content images | awk 'NR>1')
VALID=$(pvesm status -content images | awk 'NR>1')
[ -z "$VALID" ] && { msg_error "Sin storage válido"; exit; }
if [ $((${#STORAGE_MENU[@]} / 3)) -eq 1 ]; then STORAGE=${STORAGE_MENU[0]}
else
  while [ -z "${STORAGE:+x}" ]; do
    STORAGE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Storage" --radiolist \
      "Storage para ${HN}?" 16 $(($MSG_MAX_LENGTH + 23)) 6 "${STORAGE_MENU[@]}" 3>&1 1>&2 2>&3)
  done
fi
msg_ok "Storage: $STORAGE"
msg_ok "VM ID: $VMID"

# --- RESOLVER URL ---
log_step "[06] Resolviendo FreeBSD ${FREEBSD_MAJOR}.x"
RELEASE_LIST="$(curl -s https://download.freebsd.org/releases/VM-IMAGES/ | grep -Eo "${FREEBSD_MAJOR}\.[0-9]+-RELEASE" | sort -Vr | uniq)"
log_info "Releases: $(echo $RELEASE_LIST | tr '\n' ' ')"
URL=""; FREEBSD_VER=""
for ver in $RELEASE_LIST; do
  for variant in "" "-ufs" "-zfs"; do
    c="https://download.freebsd.org/releases/VM-IMAGES/${ver}/amd64/Latest/FreeBSD-${ver}-amd64${variant}.qcow2.xz"
    if curl -fsI "$c" >/dev/null 2>&1; then FREEBSD_VER="$ver"; URL="$c"; break 2; fi
  done
done
[ -z "$URL" ] && { msg_error "No hay imagen FreeBSD ${FREEBSD_MAJOR}.x"; exit 115; }
msg_ok "URL: $URL"

# --- DESCARGA ---
log_step "[07] Espacio"; check_disk_space "$TEMP_DIR" 20 || { msg_error "Espacio insuficiente"; exit 214; }
log_step "[08] Descargando"; msg_info "Descargando $(basename $URL)"
curl -f#SL -o "$(basename "$URL")" "$URL"; echo -en "\e[1A\e[0K"; msg_ok "Descargado"

log_step "[09] Descomprimiendo"
check_disk_space "$TEMP_DIR" 15 || { msg_error "Espacio insuficiente"; exit 214; }
FILE=FreeBSD.qcow2
unxz -cv "$(basename "$URL")" > "$FILE" || { msg_error "Fallo al descomprimir"; exit 115; }
rm -f "$(basename "$URL")"; msg_ok "Descomprimido: $FILE"

# --- MAPEO STORAGE ---
log_step "[10] Mapeando storage"
STORAGE_TYPE=$(pvesm status -storage $STORAGE | awk 'NR>1 {print $2}')
case $STORAGE_TYPE in
nfs|dir)  DISK_EXT=".qcow2"; DISK_REF="$VMID/"; DISK_IMPORT="-format qcow2"; THIN="" ;;
btrfs)    DISK_EXT=".raw";   DISK_REF="$VMID/"; DISK_IMPORT="-format raw";  FORMAT=",efitype=4m"; THIN="" ;;
*)        DISK_EXT="";       DISK_REF="";        DISK_IMPORT="-format raw" ;;
esac
DISK0="vm-${VMID}-disk-0${DISK_EXT}"
DISK1="vm-${VMID}-disk-1${DISK_EXT}"
DISK0_REF="${STORAGE}:${DISK_REF}${DISK0}"
DISK1_REF="${STORAGE}:${DISK_REF}${DISK1}"
log_info "DISK0_REF=$DISK0_REF  DISK1_REF=$DISK1_REF"

# =============================================================================
# FASE 1: Crear VM con SOLO la interfaz WAN (net0 en vmbr1)
# Motivo: la imagen de FreeBSD trae ifconfig_DEFAULT="DHCP" y dhclient se
# cuelga infinitamente si una interfaz no recibe respuesta. Con una sola
# interfaz (la WAN, que SÍ tiene DHCP en vmbr1) el arranque no se bloquea.
# =============================================================================
log_step "[11] qm create (solo WAN)"
msg_info "Creando VM con interfaz WAN únicamente"
if [ -n "$WAN_BRG" ]; then
  WAN_MAC_FINAL="$WAN_MAC"
else
  # Modo single: usar LAN bridge como única interfaz, con MAC de LAN
  WAN_BRG="$BRG"
  WAN_MAC_FINAL="$MAC"
fi
qm create $VMID ${MACHINE} -tablet 0 -localtime 1 -bios ovmf${CPU_TYPE} \
  -cores $CORE_COUNT -memory $RAM_SIZE -name $HN -tags community-script \
  -net0 virtio,bridge=$WAN_BRG,macaddr=$WAN_MAC_FINAL$VLAN$MTU \
  -onboot 1 -ostype l26 -scsihw virtio-scsi-pci
# Sin -agent 1 (evita reinicios por falta de QEMU guest agent)

log_step "[12] pvesm alloc"
aa=1; am=4; ad=5
while :; do
  err=$(pvesm alloc $STORAGE $VMID $DISK0 4M 2>&1 >/dev/null) && break
  if [[ "$err" == *"got timeout"* && $aa -lt $am ]]; then
    pvesm free "${DISK0_REF}" &>/dev/null || true
    sleep "$ad"; aa=$((aa+1)); ad=$((ad*2)); continue
  fi
  echo "$err" >&2; exit 220
done
msg_ok "efidisk asignada"

log_step "[13] qm importdisk"
msg_info "Importando disco"
qm importdisk $VMID ${FILE} $STORAGE ${DISK_IMPORT:-} &>/dev/null
msg_ok "Importado"

log_step "[14] qm set disks"
qm set $VMID -efidisk0 ${DISK0_REF}${FORMAT} -scsi0 ${DISK1_REF},${DISK_CACHE}${THIN}size=2G \
  -boot order=scsi0 -serial0 socket -tags community-script >/dev/null
qm resize $VMID scsi0 20G >/dev/null
msg_ok "Discos OK"

DESC="<div align='center'><h2>OPNsense VM (FreeBSD ${FREEBSD_MAJOR}.x)</h2><p>OPNsense ${OPNSENSE_VERSION}</p></div>"
qm set $VMID -description "$DESC" >/dev/null

log_info "VM config inicial:"; qm config $VMID 2>&1 | tee -a "$LOG_FILE"

# --- ARRANQUE ---
log_step "[15] Iniciando VM"
msg_ok "Arrancando VM"
qm start $VMID
sleep 5

log_step "[16] Serial reader"
serial_reader_start || { msg_error "Serial reader falló"; exit 1; }
sleep 3
dump_serial_tail 20

log_step "[17] Esperando login"
msg_info "Esperando prompt 'login:'"
if ! wait_for_serial_pattern "login:" 600 "FreeBSD login"; then
  dump_serial_tail 80
  msg_error "Sin login tras 600s"
  exit 1
fi
msg_ok "Login detectado"

log_step "[18] Login root"
send_line_to_vm "root"; sleep 3
send_line_to_vm "";     sleep 3

log_step "[19] Esperando shell root"
if ! wait_for_serial_pattern "root@[^:]*:[^#]*#" 180 "root shell"; then
  dump_serial_tail 40; msg_error "Sin shell root"; exit 1
fi
msg_ok "Shell root lista"

# --- BOOTSTRAP ---
log_step "[20] Descargando bootstrap"
msg_info "fetch bootstrap"
send_line_to_vm "fetch https://raw.githubusercontent.com/opnsense/update/master/src/bootstrap/opnsense-bootstrap.sh.in"
sleep 10
dump_serial_tail 15

log_step "[21] Ejecutando bootstrap"
msg_ok "Ejecutando bootstrap (15-25 min)"
send_line_to_vm "sh ./opnsense-bootstrap.sh.in -y -f -r ${var_version}"

log_step "[22] Esperando fin del bootstrap"
el=0
while [ $el -lt 2400 ]; do
  sleep 30; el=$((el+30))
  if tail -n 80 "$SERIAL_LOG" | grep -qE "OPNsense.*login:|login: ?$"; then
    log_info "Reboot detectado tras bootstrap ($((el/60)) min)"; break
  fi
  (( el % 120 == 0 )) && { log_info "Bootstrap: $((el/60)) min"; dump_serial_tail 8; }
done
msg_ok "Bootstrap terminado (~$((el/60)) min)"
sleep 60

# =============================================================================
# FASE 2: apagar, añadir la LAN (net1 en vmbr0), arrancar de nuevo
# =============================================================================
log_step "[23] Añadiendo interfaz LAN"
msg_info "Apagando VM para añadir la LAN"
qm shutdown $VMID --timeout 90 2>/dev/null || qm stop $VMID
sleep 10
# En OPNsense, la primera interfaz (vtnet0) será la WAN.
# Añadimos vtnet1 como LAN en vmbr0.
qm set $VMID -net1 virtio,bridge=$BRG,macaddr=$MAC$VLAN$MTU &>/dev/null
msg_ok "LAN añadida en $BRG"

log_info "VM config final:"; qm config $VMID 2>&1 | tee -a "$LOG_FILE"

log_step "[24] Rearrancando VM"
qm start $VMID
sleep 10
serial_reader_stop
serial_reader_start || { msg_error "Serial reader falló"; exit 1; }
sleep 3

log_step "[25] Esperando login de OPNsense"
if ! wait_for_serial_pattern "login:" 600 "OPNsense login"; then
  dump_serial_tail 60
fi
msg_ok "Login OPNsense detectado"

log_step "[26] Login OPNsense"
send_line_to_vm "root";     sleep 4
send_line_to_vm "opnsense"; sleep 10
dump_serial_tail 20

log_step "[27] Configurando interfaces"
msg_info "Menú 1: asignar interfaces"
send_line_to_vm "1"; sleep 5     # Assign interfaces
send_line_to_vm "n"; sleep 3     # No LAGGs
send_line_to_vm "n"; sleep 3     # No VLANs
if [ -n "$WAN_BRG" ]; then
  # vtnet0 = WAN (ya arrancado con dhclient), vtnet1 = LAN (recién añadido)
  send_line_to_vm "vtnet0"; sleep 4    # WAN
  send_line_to_vm "vtnet1"; sleep 4    # LAN
else
  send_line_to_vm "";       sleep 4
  send_line_to_vm "vtnet0"; sleep 4
fi
send_line_to_vm ""; sleep 3
send_line_to_vm "y"; sleep 10
dump_serial_tail 30

log_step "[28] Configurando LAN IP"
if [ -n "$IP_ADDR" ] && [ -n "$NETMASK" ]; then
  msg_info "LAN: $IP_ADDR/$NETMASK"
  send_line_to_vm "2"; sleep 5     # Set interface IP
  send_line_to_vm "2"; sleep 4     # LAN (opción 2)
  send_line_to_vm "$IP_ADDR"; sleep 4
  send_line_to_vm "$NETMASK"; sleep 4
  send_line_to_vm ""; sleep 4      # Gateway vacío
  send_line_to_vm ""; sleep 4      # IPv6 vacío
  send_line_to_vm "y"; sleep 4     # DHCP server sí
  DS=$(echo "$IP_ADDR" | awk -F. '{print $1"."$2"."$3".100"}')
  DE=$(echo "$IP_ADDR" | awk -F. '{print $1"."$2"."$3".199"}')
  send_line_to_vm "$DS"; sleep 4
  send_line_to_vm "$DE"; sleep 4
  send_line_to_vm "n"; sleep 3     # No revertir HTTP
  send_line_to_vm ""; sleep 6
  msg_ok "LAN configurada: $IP_ADDR/$NETMASK"
fi

log_step "[29] Volviendo al menú"
send_line_to_vm "0"; sleep 4

log_step "[30] Finalizado"
serial_reader_stop || true
msg_ok "OPNsense VM lista"
echo
msg_ok "WebUI: https://${IP_ADDR}"
echo -e "${YW}Credenciales:${CL} root / opnsense"
[ -n "$WAN_BRG" ] && echo -e "${YW}WAN:${CL} bridge ${WAN_BRG} (DHCP)"
echo -e "${YW}LAN:${CL} bridge ${BRG} (${IP_ADDR}/${NETMASK})"
echo -e "${YW}Log:${CL} $LOG_FILE"
log_info "Script finalizado"
