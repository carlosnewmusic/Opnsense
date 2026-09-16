#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: michelroegl-brunner
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
#
# OPNsense VM - Instalación automatizada desde imagen oficial
# ---------------------------------------------------------------------------
# Variables de entorno opcionales:
#   OPNSENSE_VERSION=26.7         Versión de OPNsense a instalar
#   OPNSENSE_DEFAULT_PASSWORD=opnsense  Contraseña por defecto
#   DEBUG_SERIAL=1                Muestra el log completo en pantalla
#   KEEP_ON_ERROR=1               No destruye la VM si hay un error
#   WAIT_EXTRA=N                  Segundos extra entre pasos críticos
# ---------------------------------------------------------------------------

LOG_FILE="${LOG_FILE:-/var/log/opnsense-vm-install.log}"
DEBUG_SERIAL="${DEBUG_SERIAL:-0}"
KEEP_ON_ERROR="${KEEP_ON_ERROR:-0}"
WAIT_EXTRA="${WAIT_EXTRA:-0}"
OPNSENSE_VERSION="${OPNSENSE_VERSION:-26.7}"
OPNSENSE_DEFAULT_PASSWORD="${OPNSENSE_DEFAULT_PASSWORD:-opnsense}"

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

log() {
  local level="$1"; shift
  local ts msg
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  msg="[${ts}] [${level}] $*"
  echo -e "$msg"
  echo -e "$msg" >>"$LOG_FILE" 2>/dev/null || true
}
log_info()  { log "INFO " "$@"; }
log_warn()  { log "WARN " "$@"; }
log_err()   { log "ERROR" "$@"; }
log_step()  { log "STEP " "$@"; }
log_ok()    { log "OK   " "$@"; }

exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)

log_info "==============================================================="
log_info "OPNsense VM install script (official image)"
log_info "Log file: $LOG_FILE"
log_info "OPNsense version: $OPNSENSE_VERSION"
log_info "DEBUG_SERIAL=$DEBUG_SERIAL  KEEP_ON_ERROR=$KEEP_ON_ERROR  WAIT_EXTRA=$WAIT_EXTRA"
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

RANDOM_UUID="$(cat /proc/sys/kernel/random/uuid)"
METHOD=""
NSAPP="opnsense-vm"
var_os="opnsense"
var_version="${OPNSENSE_VERSION}"

GEN_MAC=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')
GEN_MAC_LAN=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')

YW=$(echo "\033[33m")
BL=$(echo "\033[36m")
RD=$(echo "\033[01;31m")
BGN=$(echo "\033[4;92m")
GN=$(echo "\033[1;92m")
DGN=$(echo "\033[32m")
CL=$(echo "\033[m")
BFR="\\r\\033[K"
HOLD="-"
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"
set -Eeo pipefail
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT
trap 'post_update_to_api "failed" "130"' SIGINT
trap 'post_update_to_api "failed" "143"' SIGTERM
trap 'post_update_to_api "failed" "129"; exit 129' SIGHUP

function error_handler() {
  local exit_code="$?"
  local line_number="$1"
  local command="$2"
  log_err "==============================================================="
  log_err "ERROR in line $line_number: exit code $exit_code"
  log_err "Command: $command"
  log_err "==============================================================="
  dump_screen 2>/dev/null || true
  post_update_to_api "failed" "$exit_code" 2>/dev/null || true
  if [ "$KEEP_ON_ERROR" = "1" ]; then
    log_warn "KEEP_ON_ERROR=1 -> VM $VMID is NOT destroyed. Inspect it in the Proxmox UI."
  else
    log_warn "Destroying VM $VMID (set KEEP_ON_ERROR=1 to keep it)."
    cleanup_vmid
  fi
}

function get_valid_nextid() {
  local try_id
  try_id=$(pvesh get /cluster/nextid)
  while true; do
    if [ -f "/etc/pve/qemu-server/${try_id}.conf" ] || [ -f "/etc/pve/lxc/${try_id}.conf" ]; then
      try_id=$((try_id + 1)); continue
    fi
    if lvs --noheadings -o lv_name | grep -qE "(^|[-_])${try_id}($|[-_])"; then
      try_id=$((try_id + 1)); continue
    fi
    break
  done
  echo "$try_id"
}

function cleanup_vmid() {
  if qm status $VMID &>/dev/null; then
    log_info "Stopping VM $VMID"; qm stop $VMID &>/dev/null || true
    log_info "Destroying VM $VMID"; qm destroy $VMID &>/dev/null || true
  fi
}

function cleanup() {
  local exit_code=$?
  log_info "cleanup() called with exit code $exit_code"
  popd >/dev/null 2>&1 || true
  if [[ "${POST_TO_API_DONE:-}" == "true" && "${POST_UPDATE_DONE:-}" != "true" ]]; then
    if [[ $exit_code -eq 0 ]]; then
      post_update_to_api "done" "none" 2>/dev/null || true
    else
      post_update_to_api "failed" "$exit_code" 2>/dev/null || true
    fi
  fi
  if [ "$exit_code" -eq 0 ]; then
    rm -rf $TEMP_DIR
  else
    log_warn "Keeping temp dir for inspection: $TEMP_DIR"
    log_warn "Final log file: $LOG_FILE"
  fi
}

function check_disk_space() {
  local path="$1"; local required_gb="$2"
  local available_kb=$(df -k "$path" | awk 'NR==2 {print $4}')
  local available_gb=$((available_kb / 1024 / 1024))
  [ $available_gb -ge $required_gb ]
}

if [ -d "/var/tmp" ] && check_disk_space "/var/tmp" 20; then
  TEMP_DIR=$(mktemp -d /var/tmp/opnsense-vm.XXXXXX)
elif [ -d "/tmp" ] && check_disk_space "/tmp" 20; then
  TEMP_DIR=$(mktemp -d)
else
  TEMP_DIR=$(mktemp -d /var/tmp/opnsense-vm.XXXXXX)
fi
log_info "TEMP_DIR=$TEMP_DIR"
pushd $TEMP_DIR >/dev/null

SCREEN_PPM=""

function dump_screen() {
  [ -z "$VMID" ] && return 0
  SCREEN_PPM="${TEMP_DIR}/screen-${VMID}.ppm"
  rm -f "$SCREEN_PPM"
  timeout 10 pvesh create /nodes/$(hostname -s)/qemu/$VMID/monitor --command "screendump ${SCREEN_PPM}" >/dev/null 2>&1 || true
  if [ -f "$SCREEN_PPM" ]; then
    log_info "Screendump saved: $SCREEN_PPM ($(stat -c%s "$SCREEN_PPM") bytes)"
  else
    log_warn "Screendump failed (no PPM produced)"
  fi
}

function screen_hash() {
  [ -z "$VMID" ] && { echo ""; return; }
  SCREEN_PPM="${TEMP_DIR}/screen-${VMID}.ppm"
  rm -f "$SCREEN_PPM"
  timeout 10 pvesh create /nodes/$(hostname -s)/qemu/$VMID/monitor --command "screendump ${SCREEN_PPM}" >/dev/null 2>&1 || true
  md5sum "$SCREEN_PPM" 2>/dev/null | cut -d' ' -f1 || true
}

function send_line_to_vm() {
  log_dbg "TX -> $1"
  for ((i = 0; i < ${#1}; i++)); do
    character=${1:i:1}
    case $character in
    " ") character="spc" ;;
    "-") character="minus" ;;
    "=") character="equal" ;;
    ",") character="comma" ;;
    ".") character="dot" ;;
    "/") character="slash" ;;
    "'") character="apostrophe" ;;
    ";") character="semicolon" ;;
    '\') character="backslash" ;;
    '`') character="grave_accent" ;;
    "[") character="bracket_left" ;;
    "]") character="bracket_right" ;;
    "_") character="shift-minus" ;;
    "+") character="shift-equal" ;;
    "?") character="shift-slash" ;;
    "<") character="shift-comma" ;;
    ">") character="shift-dot" ;;
    '"') character="shift-apostrophe" ;;
    ":") character="shift-semicolon" ;;
    "|") character="shift-backslash" ;;
    "~") character="shift-grave_accent" ;;
    "{") character="shift-bracket_left" ;;
    "}") character="shift-bracket_right" ;;
    "A") character="shift-a" ;; "B") character="shift-b" ;; "C") character="shift-c" ;;
    "D") character="shift-d" ;; "E") character="shift-e" ;; "F") character="shift-f" ;;
    "G") character="shift-g" ;; "H") character="shift-h" ;; "I") character="shift-i" ;;
    "J") character="shift-j" ;; "K") character="shift-k" ;; "L") character="shift-l" ;;
    "M") character="shift-m" ;; "N") character="shift-n" ;; "O") character="shift-o" ;;
    "P") character="shift-p" ;; "Q") character="shift-q" ;; "R") character="shift-r" ;;
    "S") character="shift-s" ;; "T") character="shift-t" ;; "U") character="shift-u" ;;
    "V") character="shift-v" ;; "W") character="shift-w" ;; "X") character="shift-x" ;;
    "Y") character="shift-y" ;; "Z") character="shift-z" ;;
    "!") character="shift-1" ;; "@") character="shift-2" ;; "#") character="shift-3" ;;
    '$') character="shift-4" ;; "%") character="shift-5" ;; "^") character="shift-6" ;;
    "&") character="shift-7" ;; "*") character="shift-8" ;; "(") character="shift-9" ;;
    ")") character="shift-0" ;;
    esac
    qm sendkey $VMID "$character"
  done
  qm sendkey $VMID ret
  sleep "${WAIT_EXTRA:-0}"
}

# --------------------------- USER PROMPT -----------------------------------
if (whiptail --backtitle "Proxmox VE Helper Scripts" --title "OPNsense VM" --yesno "This will create a New OPNsense VM (official image). Proceed?" 10 58); then
  :
else
  header_info && echo -e "⚠ User exited script \n" && exit
fi

function msg_info() { local msg="$1"; echo -ne " ${HOLD} ${YW}${msg}..."; }
function msg_ok()   { local msg="$1"; echo -e "${BFR} ${CM} ${GN}${msg}${CL}"; log_ok "$msg"; }
function msg_error(){ local msg="$1"; echo -e "${BFR} ${CROSS} ${RD}${msg}${CL}"; log_err "$msg"; }

function pve_check() {
  local PVE_VER
  PVE_VER="$(pveversion | awk -F'/' '{print $2}' | awk -F'-' '{print $1}')"
  log_info "Proxmox VE version detected: $PVE_VER"
  if [[ "$PVE_VER" =~ ^8\.([0-9]+) ]]; then
    local MINOR="${BASH_REMATCH[1]}"
    ((MINOR < 0 || MINOR > 9)) && { msg_error "PVE $PVE_VER not supported (8.0-8.9)"; exit 105; }
    return 0
  fi
  if [[ "$PVE_VER" =~ ^9\.([0-9]+) ]]; then
    local MINOR="${BASH_REMATCH[1]}"
    ((MINOR < 0 || MINOR > 2)) && { msg_error "PVE $PVE_VER not supported (9.0-9.2)"; exit 105; }
    return 0
  fi
  msg_error "PVE $PVE_VER not supported"; exit 105
}

function arch_check() {
  if [ "$(dpkg --print-architecture)" != "amd64" ]; then
    echo -e "\n ${CROSS} This script will not work with PiMox! \n"; exit
  fi
}

function ssh_check() {
  if command -v pveversion >/dev/null 2>&1; then
    if [ -n "${SSH_CLIENT:+x}" ]; then
      if whiptail --backtitle "Proxmox VE Helper Scripts" --defaultno --title "SSH DETECTED" --yesno "It's suggested to use the Proxmox shell instead of SSH. Proceed anyway?" 10 62; then
        echo "you've been warned"
      else
        clear; exit
      fi
    fi
  fi
}

function exit-script() { clear; echo -e "⚠  User exited script \n"; exit; }
function get_available_bridges() { ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | sort; }

function default_settings() {
  VMID=$(get_valid_nextid)
  FORMAT=",efitype=4m"
  MACHINE=""
  DISK_CACHE=""
  HN="opnsense"
  CPU_TYPE=""
  CORE_COUNT="4"
  RAM_SIZE="8192"
  BRG="vmbr0"
  IP_ADDR=""
  WAN_IP_ADDR=""
  LAN_GW=""
  WAN_GW=""
  NETMASK=""
  WAN_NETMASK=""
  VLAN=""
  MAC=$GEN_MAC
  WAN_MAC=$GEN_MAC_LAN
  WAN_BRG=""
  MTU=""
  START_VM="yes"
  METHOD="default"

  local AVAILABLE_BRIDGES
  AVAILABLE_BRIDGES=$(get_available_bridges)
  local BRIDGE_COUNT
  BRIDGE_COUNT=$(echo "$AVAILABLE_BRIDGES" | wc -l)
  log_info "Available bridges: $(echo $AVAILABLE_BRIDGES | tr '\n' ' ')"

  echo -e "${DGN}Using Virtual Machine ID: ${BGN}${VMID}${CL}"
  echo -e "${DGN}Using Hostname: ${BGN}${HN}${CL}"
  echo -e "${DGN}Allocated Cores: ${BGN}${CORE_COUNT}${CL}"
  echo -e "${DGN}Allocated RAM: ${BGN}${RAM_SIZE}${CL}"
  if ! ip link show "${BRG}" &>/dev/null; then msg_error "Bridge '${BRG}' does not exist"; exit; fi
  echo -e "${DGN}Using LAN Bridge: ${BGN}${BRG}${CL}"
  echo -e "${DGN}Using LAN VLAN: ${BGN}Default${CL}"
  echo -e "${DGN}Using LAN MAC Address: ${BGN}${MAC}${CL}"

  local DEFAULT_WAN_BRG
  DEFAULT_WAN_BRG=$(echo "$AVAILABLE_BRIDGES" | grep -v "^${BRG}$" | head -n1 || true)

  if [ "$BRIDGE_COUNT" -ge 2 ]; then
    if NETWORK_MODE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "NETWORK CONFIGURATION" --radiolist --cancel-button Exit-Script \
      "Choose network setup mode for OPNsense:\n" 14 70 2 \
      "dual" "Dual Interface (Firewall/Router) - uses ${DEFAULT_WAN_BRG}" ON \
      "single" "Single Interface (Proxy/VPN/IDS Server)" OFF \
      3>&1 1>&2 2>&3); then
      if [ "$NETWORK_MODE" = "dual" ]; then
        WAN_BRG="$DEFAULT_WAN_BRG"
        echo -e "${DGN}Network Mode: ${BGN}Dual Interface (Firewall)${CL}"
        echo -e "${DGN}Using WAN Bridge: ${BGN}${WAN_BRG}${CL}"
        echo -e "${DGN}Using WAN MAC Address: ${BGN}${WAN_MAC}${CL}"
      else
        echo -e "${DGN}Network Mode: ${BGN}Single Interface (Proxy/VPN/IDS)${CL}"
        WAN_BRG=""
      fi
    else exit-script; fi
  else
    echo -e "${DGN}Network Mode: ${BGN}Single Interface (Proxy/VPN/IDS)${CL}"
    echo -e "${YW}  (Only one bridge detected)${CL}"
    WAN_BRG=""
  fi
  echo -e "${DGN}Using Interface MTU Size: ${BGN}Default${CL}"
  echo -e "${DGN}Start VM when completed: ${BGN}yes${CL}"
  echo -e "${BL}Creating an OPNsense VM using the above default settings${CL}"
  log_info "default_settings: VMID=$VMID HN=$HN Cores=$CORE_COUNT RAM=$RAM_SIZE BRG=$BRG WAN_BRG=$WAN_BRG"
}

function advanced_settings() {
  local ip_regex='^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$'
  METHOD="advanced"
  [ -z "${VMID:-}" ] && VMID=$(get_valid_nextid)
  while true; do
    if VMID=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Virtual Machine ID" 8 58 $VMID --title "VIRTUAL MACHINE ID" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
      [ -z "$VMID" ] && VMID=$(get_valid_nextid)
      if pct status "$VMID" &>/dev/null || qm status "$VMID" &>/dev/null; then
        echo -e "${CROSS}${RD} ID $VMID is already in use${CL}"; sleep 2; continue
      fi
      echo -e "${DGN}Virtual Machine ID: ${BGN}$VMID${CL}"; break
    else exit-script; fi
  done
  if MACH=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "MACHINE TYPE" --radiolist --cancel-button Exit-Script "Choose Type" 10 58 2 \
    "i440fx" "Machine i440fx" ON "q35" "Machine q35" OFF 3>&1 1>&2 2>&3); then
    if [ $MACH = q35 ]; then FORMAT=""; MACHINE=" -machine q35"; else FORMAT=",efitype=4m"; MACHINE=""; fi
    echo -e "${DGN}Using Machine Type: ${BGN}$MACH${CL}"
  else exit-script; fi
  if CPU_TYPE1=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "CPU MODEL" --radiolist "Choose" --cancel-button Exit-Script 10 58 2 \
    "0" "KVM64 (Default)" ON "1" "Host" OFF 3>&1 1>&2 2>&3); then
    if [ $CPU_TYPE1 = "1" ]; then CPU_TYPE=" -cpu host"; else CPU_TYPE=""; fi
    echo -e "${DGN}Using CPU Model: ${BGN}${CPU_TYPE:-KVM64}${CL}"
  else exit-script; fi
  if DISK_CACHE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "DISK CACHE" --radiolist "Choose" --cancel-button Exit-Script 10 58 2 \
    "0" "None (Default)" ON "1" "Write Through" OFF 3>&1 1>&2 2>&3); then
    if [ $DISK_CACHE = "1" ]; then DISK_CACHE="cache=writethrough,"; else DISK_CACHE=""; fi
    echo -e "${DGN}Using Disk Cache: ${BGN}${DISK_CACHE:-None}${CL}"
  else exit-script; fi
  if VM_NAME=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Hostname" 8 58 OPNsense --title "HOSTNAME" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z "$VM_NAME" ]; then HN="OPNsense"; else HN=$(echo "${VM_NAME,,}" | tr -cs 'a-z0-9-' '-' | sed 's/^-//;s/-$//'); fi
    echo -e "${DGN}Using Hostname: ${BGN}$HN${CL}"
  else exit-script; fi
  while true; do
    if CORE_COUNT=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Allocate CPU Cores" 8 58 4 --title "CORE COUNT" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
      [ -z "$CORE_COUNT" ] && CORE_COUNT="4"
      if [[ "$CORE_COUNT" =~ ^[1-9][0-9]*$ ]]; then echo -e "${DGN}Allocated Cores: ${BGN}$CORE_COUNT${CL}"; break; fi
      whiptail --backtitle "Proxmox VE Helper Scripts" --title "INVALID INPUT" --msgbox "CPU Cores must be a positive integer (e.g., 4)." 8 58
    else exit-script; fi
  done
  while true; do
    if RAM_SIZE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Allocate RAM in MiB" 8 58 8192 --title "RAM" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
      [ -z "$RAM_SIZE" ] && RAM_SIZE="8192"
      if [[ "$RAM_SIZE" =~ ^[1-9][0-9]*$ ]]; then echo -e "${DGN}Allocated RAM: ${BGN}$RAM_SIZE${CL}"; break; fi
      whiptail --backtitle "Proxmox VE Helper Scripts" --title "INVALID INPUT" --msgbox "RAM Size must be a positive integer in MiB (e.g., 8192)." 8 58
    else exit-script; fi
  done
  if BRG=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set a LAN Bridge" 8 58 vmbr0 --title "LAN BRIDGE" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    [ -z $BRG ] && BRG="vmbr0"
    if ! ip link show "${BRG}" &>/dev/null; then msg_error "Bridge '${BRG}' does not exist"; exit; fi
    echo -e "${DGN}Using LAN Bridge: ${BGN}$BRG${CL}"
  else exit-script; fi
  if IP_ADDR=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set a LAN IP (empty for DHCP)" 8 58 $IP_ADDR --title "LAN IP ADDRESS" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $IP_ADDR ]; then echo -e "${DGN}Using DHCP AS LAN IP ADDRESS${CL}"; else
      if [[ -n "$IP_ADDR" && ! "$IP_ADDR" =~ $ip_regex ]]; then msg_error "Invalid LAN IP: $IP_ADDR"; exit; fi
      echo -e "${DGN}Using LAN IP ADDRESS: ${BGN}$IP_ADDR${CL}"
      if LAN_GW=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set a LAN GATEWAY IP" 8 58 $LAN_GW --title "LAN GATEWAY IP" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
        [ -z $LAN_GW ] && exit-script
        if [[ -n "$LAN_GW" && ! "$LAN_GW" =~ $ip_regex ]]; then msg_error "Invalid LAN Gateway: $LAN_GW"; exit; fi
        echo -e "${DGN}Using LAN GATEWAY: ${BGN}$LAN_GW${CL}"
      fi
      if NETMASK=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set a LAN netmask (24 for example)" 8 58 $NETMASK --title "LAN NETMASK" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
        if [[ -n "$NETMASK" && ! ("$NETMASK" =~ ^[0-9]+$ && "$NETMASK" -ge 1 && "$NETMASK" -le 32) ]]; then msg_error "Invalid LAN netmask: $NETMASK"; exit; fi
        echo -e "${DGN}Using LAN NETMASK: ${BGN}$NETMASK${CL}"
      else exit-script; fi
    fi
  else exit-script; fi
  local WAN_BRIDGES
  WAN_BRIDGES=$(get_available_bridges | grep -v "^${BRG}$" || true)
  if [ -z "$WAN_BRIDGES" ]; then msg_error "No additional bridge available for WAN."; exit; fi
  local WAN_MENU=(); local first=true
  while IFS= read -r brg; do
    if $first; then WAN_MENU+=("$brg" "" "ON"); first=false; else WAN_MENU+=("$brg" "" "OFF"); fi
  done <<<"$WAN_BRIDGES"
  if WAN_BRG=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "WAN BRIDGE" --radiolist "Select WAN Bridge" 14 58 6 "${WAN_MENU[@]}" 3>&1 1>&2 2>&3); then
    [ -z "$WAN_BRG" ] && WAN_BRG=$(echo "$WAN_BRIDGES" | head -n1)
    echo -e "${DGN}Using WAN Bridge: ${BGN}$WAN_BRG${CL}"
  else exit-script; fi
  if WAN_IP_ADDR=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set a WAN IP (empty for DHCP)" 8 58 $WAN_IP_ADDR --title "WAN IP ADDRESS" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $WAN_IP_ADDR ]; then echo -e "${DGN}Using DHCP AS WAN IP ADDRESS${CL}"; else
      if [[ -n "$WAN_IP_ADDR" && ! "$WAN_IP_ADDR" =~ $ip_regex ]]; then msg_error "Invalid WAN IP: $WAN_IP_ADDR"; exit; fi
      echo -e "${DGN}Using WAN IP ADDRESS: ${BGN}$WAN_IP_ADDR${CL}"
      if WAN_GW=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set a WAN GATEWAY IP" 8 58 $WAN_GW --title "WAN GATEWAY IP" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
        [ -z $WAN_GW ] && exit-script
        if [[ -n "$WAN_GW" && ! "$WAN_GW" =~ $ip_regex ]]; then msg_error "Invalid WAN Gateway: $WAN_GW"; exit; fi
        echo -e "${DGN}Using WAN GATEWAY: ${BGN}$WAN_GW${CL}"
      else exit-script; fi
      if WAN_NETMASK=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set a WAN netmask (24 for example)" 8 58 $WAN_NETMASK --title "WAN NETMASK" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
        if [[ -n "$WAN_NETMASK" && ! ("$WAN_NETMASK" =~ ^[0-9]+$ && "$WAN_NETMASK" -ge 1 && "$WAN_NETMASK" -le 32) ]]; then msg_error "Invalid WAN netmask: $WAN_NETMASK"; exit; fi
        echo -e "${DGN}Using WAN NETMASK: ${BGN}$WAN_NETMASK${CL}"
      else exit-script; fi
    fi
  else exit-script; fi
  if MAC1=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set a LAN MAC Address" 8 58 $GEN_MAC --title "LAN MAC ADDRESS" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $MAC1 ]; then MAC="$GEN_MAC"; else MAC="$MAC1"; fi
    echo -e "${DGN}Using LAN MAC Address: ${BGN}$MAC${CL}"
  else exit-script; fi
  if MAC2=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set a WAN MAC Address" 8 58 $GEN_MAC_LAN --title "WAN MAC ADDRESS" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $MAC2 ]; then WAN_MAC="$GEN_MAC_LAN"; else WAN_MAC="$MAC2"; fi
    echo -e "${DGN}Using WAN MAC Address: ${BGN}$WAN_MAC${CL}"
  else exit-script; fi
  if (whiptail --backtitle "Proxmox VE Helper Scripts" --title "ADVANCED SETTINGS COMPLETE" --yesno "Ready to create OPNsense VM?" --no-button Do-Over 10 58); then
    echo -e "${RD}Creating an OPNsense VM using the above advanced settings${CL}"
  else header_info; advanced_settings; fi
}

function start_script() {
  if (whiptail --backtitle "Proxmox VE Helper Scripts" --title "SETTINGS" --yesno "Use Default Settings?" --no-button Advanced 10 58); then
    header_info; echo -e "${BL}Using Default Settings${CL}"; default_settings
  else
    header_info; echo -e "${RD}Using Advanced Settings${CL}"; advanced_settings
  fi
}

log_step "[STEP 01] arch_check";      arch_check
log_step "[STEP 02] pve_check";       pve_check
log_step "[STEP 03] ssh_check";       ssh_check
log_step "[STEP 04] start_script";    start_script
log_step "[STEP 05] post_to_api_vm";  post_to_api_vm || true

# ------------------------- STORAGE SELECTION --------------------------------
msg_info "Validating Storage"
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
if [ -z "$VALID" ]; then
  msg_error "Unable to detect a valid storage location."; exit
elif [ $((${#STORAGE_MENU[@]} / 3)) -eq 1 ]; then
  STORAGE=${STORAGE_MENU[0]}
else
  while [ -z "${STORAGE:+x}" ]; do
    STORAGE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Storage Pools" --radiolist \
      "Which storage pool would you like to use for ${HN}?\nTo make a selection, use the Spacebar.\n" \
      16 $(($MSG_MAX_LENGTH + 23)) 6 "${STORAGE_MENU[@]}" 3>&1 1>&2 2>&3)
  done
fi
msg_ok "Using ${CL}${BL}$STORAGE${CL} ${GN}for Storage Location."
msg_ok "Virtual Machine ID is ${CL}${BL}$VMID${CL}."

# ------------------------- DOWNLOAD OPNsense IMAGE --------------------------
log_step "[STEP 06] Resolving OPNsense image URL"
OPNSENSE_URL="https://pkg.opnsense.org/releases/${OPNSENSE_VERSION}/OPNsense-${OPNSENSE_VERSION}-vga-amd64.img.bz2"
log_info "OPNsense image URL: $OPNSENSE_URL"
msg_info "Checking OPNsense image availability"
if ! curl -fsIL "$OPNSENSE_URL" >/dev/null 2>&1; then
  msg_error "OPNsense image not found at $OPNSENSE_URL"
  msg_error "Check OPNsense release directory: https://pkg.opnsense.org/releases/"
  exit 115
fi
REMOTE_SIZE=$(curl -fsIL "$OPNSENSE_URL" | awk 'tolower($1)=="content-length:" {print $2}' | tail -n1 | tr -d '\r')
msg_ok "OPNsense image available (size: ${REMOTE_SIZE:-unknown} bytes)"

log_step "[STEP 07] Disk space check"
if ! check_disk_space "$TEMP_DIR" 20; then
  AVAILABLE_GB=$(df -h "$TEMP_DIR" | awk 'NR==2 {print $4}')
  msg_error "Insufficient disk space: $AVAILABLE_GB (need ~20GB)"; exit 214
fi
msg_ok "Disk space OK"

log_step "[STEP 08] Downloading OPNsense image"
msg_info "Downloading OPNsense image (this may take a while)"
IMG_BZ2="$(basename "$OPNSENSE_URL")"
curl -f#SL -o "$IMG_BZ2" "$OPNSENSE_URL"
echo -en "\e[1A\e[0K"
msg_ok "Downloaded ${CL}${BL}${IMG_BZ2}${CL}"

log_step "[STEP 09] Decompressing OPNsense image"
msg_info "Decompressing OPNsense image with bunzip2"
IMG_FILE="OPNsense.img"
if ! bunzip2 -c "$IMG_BZ2" > "$IMG_FILE"; then
  msg_error "Failed to decompress OPNsense image."; df -h "$TEMP_DIR"; exit 115
fi
rm -f "$IMG_BZ2"
msg_ok "Decompressed ${CL}${BL}${IMG_FILE}${CL} ($(du -h "$IMG_FILE" | awk '{print $1}'))"

# ------------------------- STORAGE MAPPING ----------------------------------
log_step "[STEP 10] Preparing storage mapping"
STORAGE_TYPE=$(pvesm status -storage $STORAGE | awk 'NR>1 {print $2}')
log_info "Storage type: $STORAGE_TYPE"
case $STORAGE_TYPE in
nfs | dir) DISK_EXT=".qcow2"; DISK_REF="$VMID/"; DISK_IMPORT="-format qcow2"; THIN="" ;;
btrfs)     DISK_EXT=".raw";   DISK_REF="$VMID/"; DISK_IMPORT="-format raw";  FORMAT=",efitype=4m"; THIN="" ;;
*)         DISK_EXT="";       DISK_REF="";        DISK_IMPORT="-format raw" ;;
esac
for i in {0,1}; do
  disk="DISK$i"
  eval DISK${i}=vm-${VMID}-disk-${i}${DISK_EXT:-}
  eval DISK${i}_REF=${STORAGE}:${DISK_REF:-}${!disk}
done
log_info "DISK0_REF=$DISK0_REF  DISK1_REF=$DISK1_REF"

# ------------------------- VM CREATION --------------------------------------
log_step "[STEP 11] qm create"
msg_info "Creating the OPNsense VM"
# In OPNsense factory config: vtnet0 = WAN, vtnet1 = LAN.
# So we put the WAN bridge on net0 and the LAN bridge on net1.
if [ -n "$WAN_BRG" ]; then
  NET0_BRG="$WAN_BRG"; NET0_MAC="$WAN_MAC"
  NET1_BRG="$BRG";     NET1_MAC="$MAC"
else
  # Single-interface mode: only LAN bridge is used; we will reassign in the menu.
  NET0_BRG="$BRG";     NET0_MAC="$MAC"
  NET1_BRG="";         NET1_MAC=""
fi

log_info "qm create $VMID ${MACHINE} -tablet 0 -localtime 1 -bios ovmf${CPU_TYPE} -cores $CORE_COUNT -memory $RAM_SIZE -name $HN -tags community-script -net0 virtio,bridge=$NET0_BRG,macaddr=$NET0_MAC -onboot 1 -ostype l26 -scsihw virtio-scsi-pci"
qm create $VMID ${MACHINE} -tablet 0 -localtime 1 -bios ovmf${CPU_TYPE} -cores $CORE_COUNT -memory $RAM_SIZE \
  -name $HN -tags community-script -net0 virtio,bridge=$NET0_BRG,macaddr=$NET0_MAC$VLAN$MTU \
  -onboot 1 -ostype l26 -scsihw virtio-scsi-pci

log_step "[STEP 12] pvesm alloc (efidisk)"
alloc_attempt=1; alloc_max=4; alloc_delay=5
while :; do
  alloc_err=$(pvesm alloc $STORAGE $VMID $DISK0 4M 2>&1 >/dev/null) && break
  log_warn "pvesm alloc attempt $alloc_attempt failed: $alloc_err"
  if [[ "$alloc_err" == *"got timeout"* && $alloc_attempt -lt $alloc_max ]]; then
    pvesm free "${DISK0_REF}" &>/dev/null || true
    sleep "$alloc_delay"; alloc_attempt=$((alloc_attempt + 1)); alloc_delay=$((alloc_delay * 2)); continue
  fi
  echo -e "$alloc_err" >&2; exit 220
done
log_info "pvesm alloc OK"

log_step "[STEP 13] qm importdisk"
msg_info "Importing OPNsense disk image"
log_info "qm importdisk $VMID ${IMG_FILE} $STORAGE ${DISK_IMPORT:-}"
qm importdisk $VMID ${IMG_FILE} $STORAGE ${DISK_IMPORT:-} &>/dev/null
msg_ok "Imported OPNsense disk"

log_step "[STEP 14] qm set disks"
qm set $VMID \
  -efidisk0 ${DISK0_REF}${FORMAT} \
  -scsi0 ${DISK1_REF},${DISK_CACHE}${THIN}size=2G \
  -boot order=scsi0 \
  -serial0 socket \
  -tags community-script >/dev/null
msg_ok "Disks attached"

log_step "[STEP 15] qm resize scsi0"
qm resize $VMID scsi0 20G >/dev/null

log_step "[STEP 16] Setting VM description"
DESCRIPTION=$(
  cat <<EOF
<div align='center'>
  <h2 style='font-size: 24px; margin: 20px 0;'>OPNsense VM (official image ${OPNSENSE_VERSION})</h2>
  <p>Imported from <code>OPNsense-${OPNSENSE_VERSION}-vga-amd64.img.bz2</code></p>
  <p><a href='https://github.com/community-scripts/ProxmoxVE'>GitHub</a></p>
</div>
EOF
)
qm set $VMID -description "$DESCRIPTION" >/dev/null

log_step "[STEP 17] Adding WAN interface (if any)"
if [ -n "$NET1_BRG" ]; then
  msg_info "Adding WAN interface on $NET1_BRG"
  qm set $VMID -net1 virtio,bridge=${NET1_BRG},macaddr=${NET1_MAC} &>/dev/null
  msg_ok "WAN interface added"
else
  log_info "Single-interface mode: WAN interface not added"
fi

msg_ok "Created OPNsense VM ${CL}${BL}(${HN})"
log_info "VM config:"
qm config $VMID 2>&1 | tee -a "$LOG_FILE"

# ------------------------- BOOT & INSTALL -----------------------------------
log_step "[STEP 18] Starting VM for installation"
msg_ok "Starting OPNsense VM in Live mode for installation"
qm start $VMID
log_info "Waiting for OPNsense live media to boot..."
sleep 60

log_step "[STEP 19] Waiting for login prompt"
for i in 1 2 3 4 5 6; do
  sleep 20
  h=$(screen_hash)
  log_info "Boot poll ${i}/6: screen hash=${h:-<none>}"
done
dump_screen

log_step "[STEP 20] Logging in as installer"
msg_info "Logging in as 'installer' to start the installation"
send_line_to_vm "installer"
sleep 3
send_line_to_vm "${OPNSENSE_DEFAULT_PASSWORD}"
sleep 10
dump_screen

log_step "[STEP 21] Running installer (workaround for UFS bug)"
msg_info "Starting installer and selecting 'Install via other modes' -> 'Auto (UFS)'"
# El instalador puede mostrar un menú. Primero seleccionamos "Install" (opción 1)
# Si falla por el bug de UFS en disco vacío, usamos el workaround.
send_line_to_vm "1"
sleep 5
# Si aparece un error, el instalador vuelve al menú. Seleccionamos "Install via other modes"
# En la mayoría de las versiones esta es la opción 3. Enviamos "3" por si acaso.
send_line_to_vm "3"
sleep 5
# En el submenú, seleccionamos "Auto (UFS)" que suele ser la opción 1
send_line_to_vm "1"
sleep 5
dump_screen
msg_ok "Installer started (if a menu is shown, the script will try to proceed automatically)"

log_step "[STEP 22] Selecting installation disk"
msg_info "Selecting target disk (vtbd0 - 20GB virtual disk)"
# El instalador pregunta en qué disco instalar. Seleccionamos vtbd0 (suele ser la opción 1)
send_line_to_vm "1"
sleep 5
dump_screen
# Confirmar particionado
send_line_to_vm "y"
sleep 5
dump_screen

log_step "[STEP 23] Waiting for installation to complete"
msg_info "Installation in progress. This will take a few minutes..."
# Esperamos a que termine la instalación. En lugar de un sleep fijo,
# monitorizamos el hash de la pantalla hasta que se estabilice.
install_stable=0
install_elapsed=0
last_hash=""
while [ $install_stable -lt 10 ] && [ $install_elapsed -lt 600 ]; do
  sleep 30
  install_elapsed=$((install_elapsed + 30))
  new_hash=$(screen_hash)
  if [ -n "$new_hash" ] && [ "$new_hash" = "$last_hash" ]; then
    install_stable=$((install_stable + 1))
  else
    install_stable=0
  fi
  last_hash="$new_hash"
  log_info "Install poll: ${install_elapsed}s elapsed, screen ${new_hash:0:8}, stable ${install_stable}/10"
  if (( install_elapsed % 120 == 0 )); then
    dump_screen
  fi
done
msg_ok "Installation finished after $((install_elapsed / 60)) minutes"

log_step "[STEP 24] Rebooting after installation"
msg_info "Installation complete. Rebooting the VM to boot from the installed disk."
# Enviamos "reboot" o simplemente apagamos y encendemos. Es más seguro apagar.
qm shutdown $VMID --timeout 60 || qm stop $VMID
sleep 10
log_info "VM shut down after installation"

log_step "[STEP 25] Removing installation media"
msg_info "Detaching the installation disk from the VM"
# El disco de instalación es scsi1 (importado como scsi1 en algunos casos) o el mismo scsi0.
# En nuestro script, importamos la imagen como scsi0. Pero luego instalamos en el mismo disco.
# En realidad, la imagen oficial ya está en un disco. Al instalar, se escribe en el mismo.
# NO hay un medio de instalación separado en este flujo. El disco scsi0 es el que contiene
# tanto el instalador como el destino de la instalación.
# Por lo tanto, NO necesitamos extraer ningún medio. Simplemente arrancamos de nuevo.
log_info "No extra installation media to remove (single-disk installation flow)"

log_step "[STEP 26] Starting VM from installed disk"
qm start $VMID
msg_ok "OPNsense VM started"
log_info "Waiting for OPNsense to boot from disk..."
sleep 60

# Verificar que ya no estamos en Live mode
log_step "[STEP 27] Verifying installed system"
for i in 1 2 3 4 5 6; do
  sleep 20
  h=$(screen_hash)
  log_info "Post-install boot poll ${i}/6: screen hash=${h:-<none>}"
done
dump_screen

log_step "[STEP 28] Logging in to configure"
msg_info "Logging in as root to configure the system"
send_line_to_vm "root"
sleep 3
send_line_to_vm "${OPNSENSE_DEFAULT_PASSWORD}"
sleep 8
dump_screen

log_step "[STEP 29] Configuring interfaces (menu option 1)"
msg_info "Assigning interfaces via menu option 1"
# Menú 1 -> Assign Interfaces
# LAGGs -> n
# VLANs -> n
# WAN  -> vtnet0 (o vtnet1 según el modo)
# LAN  -> vtnet1 (o vtnet0)
# Optional -> empty
# Confirm -> y
send_line_to_vm "1"
sleep 3
send_line_to_vm "n"
sleep 2
send_line_to_vm "n"
sleep 2
if [ -n "$NET1_BRG" ]; then
  # Dual interface: WAN=vtnet0, LAN=vtnet1 (coincide con nuestro orden net0/net1)
  send_line_to_vm "vtnet0"
  sleep 2
  send_line_to_vm "vtnet1"
  sleep 2
else
  # Single interface: WAN=none, LAN=vtnet0
  send_line_to_vm ""
  sleep 2
  send_line_to_vm "vtnet0"
  sleep 2
fi
send_line_to_vm ""
sleep 2
send_line_to_vm "y"
sleep 6
dump_screen

log_step "[STEP 30] Configuring LAN IP (menu option 2)"
if [ -n "$IP_ADDR" ] && [ -n "$NETMASK" ]; then
  msg_info "Configuring LAN IP: $IP_ADDR/$NETMASK"
  # Menú 2 -> Set interface IP address
  # Seleccionar LAN -> 2 (asumiendo WAN=1, LAN=2)
  # Nueva dirección IPv4
  # Máscara
  # Gateway (vacío para LAN)
  # IPv6 (vacío)
  # Servidor DHCP (y)
  # Inicio DHCP
  # Fin DHCP
  # Revertir HTTP (n)
  # Enter para continuar
  send_line_to_vm "2"
  sleep 3
  send_line_to_vm "2"
  sleep 2
  send_line_to_vm "${IP_ADDR}"
  sleep 2
  send_line_to_vm "${NETMASK}"
  sleep 2
  send_line_to_vm ""
  sleep 2
  send_line_to_vm ""
  sleep 2
  send_line_to_vm "y"
  sleep 2
  # Rango DHCP: usar .100 y .199 de la misma subred
  DHCP_START=$(echo "$IP_ADDR" | awk -F. '{print $1"."$2"."$3".100"}')
  DHCP_END=$(echo "$IP_ADDR" | awk -F. '{print $1"."$2"."$3".199"}')
  send_line_to_vm "$DHCP_START"
  sleep 2
  send_line_to_vm "$DHCP_END"
  sleep 2
  send_line_to_vm "n"
  sleep 2
  send_line_to_vm ""
  sleep 4
  dump_screen
  msg_ok "LAN IP configured: $IP_ADDR/$NETMASK"
else
  log_info "LAN IP left at default (192.168.1.1/24)"
fi

log_step "[STEP 31] Configuring WAN IP (menu option 2)"
if [ -n "$WAN_BRG" ] && [ -n "$WAN_IP_ADDR" ] && [ -n "$WAN_NETMASK" ]; then
  msg_info "Configuring WAN IP: $WAN_IP_ADDR/$WAN_NETMASK"
  send_line_to_vm "2"
  sleep 3
  send_line_to_vm "1"          # WAN es la opción 1
  sleep 2
  send_line_to_vm "${WAN_IP_ADDR}"
  sleep 2
  send_line_to_vm "${WAN_NETMASK}"
  sleep 2
  send_line_to_vm "${WAN_GW}"
  sleep 2
  send_line_to_vm ""            # IPv6
  sleep 2
  send_line_to_vm ""            # No se pregunta en WAN, Enter seguro
  sleep 4
  dump_screen
  msg_ok "WAN IP configured: $WAN_IP_ADDR/$WAN_NETMASK"
else
  log_info "WAN IP left at DHCP (default)"
fi

log_step "[STEP 32] Returning to main menu"
send_line_to_vm "0"
sleep 3
dump_screen

log_step "[STEP 33] Finalizing"
msg_ok "OPNsense VM is ready"
echo
if [ -n "$IP_ADDR" ]; then
  msg_ok "Access the webConfigurator at: ${CL}${BGN}https://${IP_ADDR}${CL}"
  echo -e "${INFO}${YW}Default credentials:${CL} root / ${OPNSENSE_DEFAULT_PASSWORD}"
else
  msg_ok "LAN IP is default: ${CL}${BGN}https://192.168.1.1${CL}"
  echo -e "${INFO}${YW}Default credentials:${CL} root / ${OPNSENSE_DEFAULT_PASSWORD}"
fi
if [ -n "$WAN_BRG" ]; then
  echo -e "${INFO}${YW}WAN interface:${CL} on bridge ${BGN}${WAN_BRG}${CL}"
fi
echo -e "${INFO}${YW}Full install log:${CL} ${LOG_FILE}"
echo -e "${INFO}${YW}Last screendump:${CL} ${SCREEN_PPM:-<not captured>}"
log_info "Script finished. Log file: $LOG_FILE"
