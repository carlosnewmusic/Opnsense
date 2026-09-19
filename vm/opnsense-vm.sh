#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: michelroegl-brunner
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
#
# OPNsense VM - imagen SERIAL oficial (BIOS Legacy)
# Fix: el login en OPNsense entra al MENÚ, no a un shell. Interactuamos con el menú.

LOG_FILE="${LOG_FILE:-/var/log/opnsense-vm-install.log}"
DEBUG_SERIAL="${DEBUG_SERIAL:-0}"
KEEP_ON_ERROR="${KEEP_ON_ERROR:-0}"
OPNSENSE_VERSION="${OPNSENSE_VERSION:-26.7}"
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
log_info "OPNsense VM install (imagen SERIAL oficial - Legacy BIOS)"
log_info "Versión: $OPNSENSE_VERSION"
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
  dump_serial_tail 60 2>/dev/null || true
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
  serial_stop 2>/dev/null || true
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

# =============================================================================
# CONSOLA SERIE
# =============================================================================
SERIAL_PTY=""; SERIAL_LOG=""; SOCAT_PID=""; READER_PID=""

function serial_start() {
  serial_stop
  SERIAL_LOG="${TEMP_DIR}/serial-${VMID}.log"; : > "$SERIAL_LOG"
  SERIAL_PTY="${TEMP_DIR}/serial-${VMID}.pty"; rm -f "$SERIAL_PTY"
  command -v socat >/dev/null 2>&1 || { log_err "socat no instalado (apt install socat)"; return 1; }
  local sock="/var/run/qemu-server/${VMID}.serial0"
  for _ in $(seq 1 30); do [ -S "$sock" ] && break; sleep 1; done
  [ -S "$sock" ] || { log_err "Socket serie $sock no aparece"; return 1; }
  socat UNIX-CONNECT:"$sock" PTY,link="$SERIAL_PTY",raw,echo=0,waitslave &
  SOCAT_PID=$!
  for _ in $(seq 1 50); do [ -L "$SERIAL_PTY" ] && break; sleep 0.2; done
  [ -L "$SERIAL_PTY" ] || { log_err "PTY $SERIAL_PTY no aparece"; return 1; }
  kill -0 "$SOCAT_PID" 2>/dev/null || { log_err "socat murió"; return 1; }
  exec 3<>"$SERIAL_PTY"
  stdbuf -o0 cat <&3 >> "$SERIAL_LOG" &
  READER_PID=$!
  sleep 1
  log_info "Serial PTY activo: $SERIAL_PTY (socat=$SOCAT_PID reader=$READER_PID)"
  return 0
}

function serial_stop() {
  exec 3>&- 2>/dev/null || true
  [ -n "${READER_PID:-}" ] && { kill "$READER_PID" 2>/dev/null || true; wait "$READER_PID" 2>/dev/null || true; }
  [ -n "${SOCAT_PID:-}" ]  && { kill "$SOCAT_PID" 2>/dev/null || true; wait "$SOCAT_PID" 2>/dev/null || true; }
  READER_PID=""; SOCAT_PID=""
}

function send_line() {
  log_dbg "TX->$1"
  printf '%s\r' "$1" >&3 2>/dev/null || log_warn "Escritura en consola serie falló"
  sleep 0.5
}

function wait_for_pattern() {
  local pat="$1" to="${2:-600}" label="${3:-$pat}" el=0
  [ -f "$SERIAL_LOG" ] || return 1
  log_info "Esperando hasta ${to}s a '$label' (regex: $pat)"
  while [ $el -lt "$to" ]; do
    if grep -qE "$pat" "$SERIAL_LOG" 2>/dev/null; then
      log_info "Match tras ${el}s"
      return 0
    fi
    sleep 3; el=$((el+3))
    (( el % 60 == 0 )) && { log_info "  ... ${el}s / ${to}s"; dump_serial_tail 5; }
  done
  log_warn "TIMEOUT '$label'"
  return 1
}

function dump_serial_tail() {
  local n="${1:-30}"
  [ -f "$SERIAL_LOG" ] && { log_info "--- últimas $n líneas ---"; tail -n "$n" "$SERIAL_LOG" | sed 's/^/  | /' | tee -a "$LOG_FILE"; log_info "--- fin ---"; }
}

# --- PROMPT ---
if ! whiptail --backtitle "Proxmox VE Helper Scripts" --title "OPNsense VM" \
     --yesno "Crear VM OPNsense (imagen SERIAL oficial, Legacy BIOS)?" 10 58; then
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
    --yesno "Usar el shell de Proxmox es mejor. ¿Continuar por SSH?" 10 62 || { clear; exit; }
}
function exit-script() { clear; echo "⚠ User exited"; exit; }
function get_available_bridges() { ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | sort; }

function default_settings() {
  VMID=$(get_valid_nextid)
  MACHINE=""; DISK_CACHE=""; HN="opnsense"; CPU_TYPE=""
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

# --- URL imagen SERIAL ---
log_step "[06] Resolviendo imagen SERIAL oficial OPNsense ${OPNSENSE_VERSION}"
OPNSENSE_URL="https://pkg.opnsense.org/releases/${OPNSENSE_VERSION}/OPNsense-${OPNSENSE_VERSION}-serial-amd64.img.bz2"
log_info "URL: $OPNSENSE_URL"

if [[ "$OPNSENSE_URL" != *"-serial-"* ]]; then
  msg_error "URL no es la imagen SERIAL. Abortando."
  exit 1
fi

if ! curl -fsIL "$OPNSENSE_URL" >/dev/null 2>&1; then
  msg_error "Imagen SERIAL no encontrada en $OPNSENSE_URL"
  exit 115
fi
msg_ok "Imagen disponible"

log_step "[07] Espacio"; check_disk_space "$TEMP_DIR" 20 || { msg_error "Espacio insuficiente"; exit 214; }
log_step "[08] Descargando"; msg_info "Descargando $(basename $OPNSENSE_URL)"
curl -f#SL -o "$(basename "$OPNSENSE_URL")" "$OPNSENSE_URL"; echo -en "\e[1A\e[0K"; msg_ok "Descargado"

log_step "[09] Descomprimiendo"
check_disk_space "$TEMP_DIR" 15 || { msg_error "Espacio insuficiente"; exit 214; }
FILE="OPNsense-serial.img"
bunzip2 -c "$(basename "$OPNSENSE_URL")" > "$FILE" || { msg_error "Fallo al descomprimir"; exit 115; }
rm -f "$(basename "$OPNSENSE_URL")"; msg_ok "Descomprimido: $FILE"

# --- MAPEO ---
log_step "[10] Mapeando storage"
STORAGE_TYPE=$(pvesm status -storage $STORAGE | awk 'NR>1 {print $2}')
case $STORAGE_TYPE in
nfs|dir)  DISK_IMPORT="-format qcow2"; THIN="" ;;
btrfs)    DISK_IMPORT="-format raw";   THIN="" ;;
*)        DISK_IMPORT="-format raw" ;;
esac
log_info "Storage type: $STORAGE_TYPE"

# --- CREAR VM (BIOS Legacy) ---
log_step "[11] qm create (Legacy BIOS)"
msg_info "Creando VM con arranque Legacy"
if [ -n "$WAN_BRG" ]; then
  NET0_BRG="$BRG";     NET0_MAC="$MAC"      # vtnet0 = LAN
  NET1_BRG="$WAN_BRG"; NET1_MAC="$WAN_MAC"  # vtnet1 = WAN
else
  NET0_BRG="$BRG"; NET0_MAC="$MAC"; NET1_BRG=""; NET1_MAC=""
fi
qm create $VMID ${MACHINE} -tablet 0 -localtime 1 -bios seabios${CPU_TYPE} \
  -cores $CORE_COUNT -memory $RAM_SIZE -name $HN -tags community-script \
  -net0 virtio,bridge=$NET0_BRG,macaddr=$NET0_MAC$VLAN$MTU \
  -onboot 1 -ostype l26 -scsihw virtio-scsi-pci

log_step "[12] qm importdisk"
msg_info "Importando disco (puede tardar)"
IMPORT_OUTPUT=$(qm importdisk $VMID ${FILE} $STORAGE ${DISK_IMPORT:-} 2>&1 | grep -v "^transferred" || true)
log_info "Salida de qm importdisk:"
echo "$IMPORT_OUTPUT" | tee -a "$LOG_FILE"
VOL_NAME=$(echo "$IMPORT_OUTPUT" | awk -F"'" '/successfully imported disk/ {print $2; exit}')
if [ -z "$VOL_NAME" ]; then
  VOL_NAME="${STORAGE}:vm-${VMID}-disk-0"
  log_warn "No se pudo detectar el nombre del volumen, usando fallback: $VOL_NAME"
fi
log_info "Volumen importado detectado: $VOL_NAME"
sleep 5

log_step "[13] qm set disks"
msg_info "Asignando disco a scsi0"
if ! qm set $VMID -scsi0 "${VOL_NAME},${DISK_CACHE}${THIN}size=2G" \
    -boot order=scsi0 -serial0 socket -tags community-script >/dev/null 2>&1; then
  msg_error "Fallo al asignar el disco con volumen '$VOL_NAME'"
  pvesm list "$STORAGE" 2>&1 | tee -a "$LOG_FILE" || true
  exit 220
fi
msg_ok "Disco asignado"

log_step "[14] qm resize scsi0"
qm resize $VMID scsi0 20G >/dev/null
msg_ok "Disco redimensionado a 20G"

DESC="<div align='center'><h2>OPNsense VM (imagen SERIAL ${OPNSENSE_VERSION})</h2></div>"
qm set $VMID -description "$DESC" >/dev/null

if [ -n "$NET1_BRG" ]; then
  log_step "[15] Añadiendo WAN"
  qm set $VMID -net1 virtio,bridge=${NET1_BRG},macaddr=${NET1_MAC} &>/dev/null
  msg_ok "WAN añadida en $NET1_BRG"
fi

log_info "VM config inicial:"; qm config $VMID 2>&1 | tee -a "$LOG_FILE"

# --- ARRANQUE ---
log_step "[16] Iniciando VM"
qm start $VMID
sleep 5

log_step "[17] Serial reader"
serial_start || { msg_error "Serial no disponible"; exit 1; }
sleep 3
dump_serial_tail 20

# --- LOGIN ---
log_step "[18] Esperando login de OPNsense (ttyu0)"
wait_for_pattern "login:" 600 "OPNsense login" || { dump_serial_tail 80; msg_error "Sin login"; exit 1; }
msg_ok "Login detectado"

log_step "[19] Login como root"
send_line "root"
sleep 3
wait_for_pattern "Password:" 60 "Password prompt" || { dump_serial_tail 20; }
msg_ok "Password prompt recibido"
send_line "opnsense"
sleep 10
dump_serial_tail 40

# =============================================================================
# FIX: tras el login NO hay shell, hay MENÚ de OPNsense.
# Esperamos "Enter an option:" en lugar de "root@...#".
# =============================================================================
log_step "[20] Esperando menú de OPNsense"
wait_for_pattern "Enter an option:" 120 "OPNsense menu" || { dump_serial_tail 60; msg_error "Sin menú de OPNsense"; exit 1; }
msg_ok "Menú de OPNsense disponible"

# OPNsense asigna por defecto vtnet0=LAN y vtnet1=WAN según el orden PCI.
# Como hemos creado net0=vmbr0 (LAN) y net1=vmbr1 (WAN), las interfaces
# ya están correctas al arrancar. No hace falta el menú 1 (Assign interfaces).
log_step "[21] Interfaces ya asignadas (vtnet0=LAN, vtnet1=WAN)"
dump_serial_tail 30

# =============================================================================
# Menú 2: Set interface IP address -> configurar LAN estática
# Flujo típico de OPNsense:
#   1) Selecciona interfaz (1=WAN, 2=LAN)
#   2) Configure IPv4 via DHCP? [y/N]:  -> n
#   3) IPv4 address:                    -> 192.168.2.1
#   4) Subnet bits:                     -> 24
#   5) Upstream gateway:                -> (vacío)
#   6) Configure IPv6 via DHCP? [y/N]:  -> n
#   7) Do you want to enable the DHCP server? [y/N]: -> y
#   8) DHCP start:                      -> 192.168.2.100
#   9) DHCP end:                        -> 192.168.2.199
#  10) Revert to HTTP? [y/N]:           -> n
# =============================================================================
log_step "[22] Configurando LAN estática ($IP_ADDR/$NETMASK)"
msg_info "Menú 2: configurar IP de LAN"

send_line "2"                # Set interface IP address
sleep 4
send_line "2"                # 2 = LAN
sleep 3
send_line "n"                # No DHCP para IPv4
sleep 3
send_line "$IP_ADDR"         # IPv4 address
sleep 3
send_line "$NETMASK"         # Subnet bits (24)
sleep 3
send_line ""                 # Upstream gateway (vacío)
sleep 3
send_line "n"                # No IPv6 DHCP
sleep 3
send_line "y"                # Habilitar DHCP server en LAN
sleep 3
DS=$(echo "$IP_ADDR" | awk -F. '{print $1"."$2"."$3".100"}')
DE=$(echo "$IP_ADDR" | awk -F. '{print $1"."$2"."$3".199"}')
send_line "$DS"              # DHCP start
sleep 3
send_line "$DE"              # DHCP end
sleep 3
send_line "n"                # No revertir a HTTP
sleep 5
dump_serial_tail 60

# Esperar a que vuelva al menú principal
log_step "[23] Esperando retorno al menú"
wait_for_pattern "Enter an option:" 60 "Menú tras config LAN" || { dump_serial_tail 40; }
msg_ok "LAN configurada (menú principal de vuelta)"

# =============================================================================
# Opcional: si hay IP de WAN estática, configurarla. Si no, dejamos DHCP.
# =============================================================================
if [ -n "$WAN_IP_ADDR" ] && [ -n "$WAN_NETMASK" ]; then
  log_step "[24] Configurando WAN estática ($WAN_IP_ADDR/$WAN_NETMASK)"
  msg_info "Menú 2: configurar IP de WAN"
  send_line "2"; sleep 4
  send_line "1"              # 1 = WAN
  sleep 3
  send_line "n"              # No DHCP
  sleep 3
  send_line "$WAN_IP_ADDR"; sleep 3
  send_line "$WAN_NETMASK"; sleep 3
  send_line "$WAN_GW"; sleep 3
  send_line "n"              # No IPv6
  sleep 5
  dump_serial_tail 40
  wait_for_pattern "Enter an option:" 60 "Menú tras WAN" || true
  msg_ok "WAN configurada"
else
  log_step "[24] WAN por DHCP (por defecto)"
fi

log_step "[25] Volviendo al menú principal"
send_line "0"
sleep 3

log_step "[26] Finalizado"
serial_stop || true
msg_ok "OPNsense VM lista"
echo
msg_ok "WebUI: https://${IP_ADDR}"
echo -e "${YW}Credenciales:${CL} root / opnsense"
[ -n "$WAN_BRG" ] && echo -e "${YW}WAN:${CL} bridge ${WAN_BRG} (DHCP) en vtnet1"
echo -e "${YW}LAN:${CL} bridge ${BRG} (${IP_ADDR}/${NETMASK}) en vtnet0"
echo -e "${YW}Log:${CL} $LOG_FILE"
log_info "Script finalizado"
