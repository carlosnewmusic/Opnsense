#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: michelroegl-brunner
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
#
# DEBUG EDITION - heavily instrumented for troubleshooting
# ---------------------------------------------------------------------------
# Environment variables you can set before running:
#   DEBUG_SERIAL=1     Stream full serial console to stdout
#   KEEP_ON_ERROR=1    Do NOT destroy the VM on error (keep for inspection)
#   WAIT_EXTRA=N       Extra seconds to wait between critical steps
#   LOG_FILE=/path     Override log file (default /var/log/opnsense-vm-install.log)
# ---------------------------------------------------------------------------

# ------------------------- LOGGING (before anything else) ------------------
LOG_FILE="${LOG_FILE:-/var/log/opnsense-vm-install.log}"
DEBUG_SERIAL="${DEBUG_SERIAL:-0}"
KEEP_ON_ERROR="${KEEP_ON_ERROR:-0}"
WAIT_EXTRA="${WAIT_EXTRA:-0}"

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
log_dbg()   { [ "$DEBUG_SERIAL" = "1" ] && log "DEBUG" "$@" || log "DEBUG" "$@" >>"$LOG_FILE" 2>/dev/null; }
log_step()  { log "STEP " "$@"; }

# Redirect all stderr and stdout also to the log file (keeps terminal visible)
exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)

log_info "==============================================================="
log_info "OPNsense VM install script - DEBUG EDITION"
log_info "Log file: $LOG_FILE"
log_info "DEBUG_SERIAL=$DEBUG_SERIAL  KEEP_ON_ERROR=$KEEP_ON_ERROR  WAIT_EXTRA=$WAIT_EXTRA"
log_info "==============================================================="

# ------------------------- BASIC SETUP -------------------------------------
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
#API VARIABLES
RANDOM_UUID="$(cat /proc/sys/kernel/random/uuid)"
METHOD=""
NSAPP="opnsense-vm"
var_os="opnsense"
var_version="26.7"
FREEBSD_MAJOR="15"
#
GEN_MAC=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')
GEN_MAC_LAN=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')

YW=$(echo "\033[33m")
BL=$(echo "\033[36m")
HA=$(echo "\033[1;34m")
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
  dump_serial_tail 80 2>/dev/null || true
  post_update_to_api "failed" "$exit_code" 2>/dev/null || true
  if [ "$KEEP_ON_ERROR" = "1" ]; then
    log_warn "KEEP_ON_ERROR=1 -> VM $VMID is NOT destroyed. Inspect it in the Proxmox UI."
    log_warn "Serial log: $SERIAL_LOG"
    log_warn "VM config:"; qm config "$VMID" 2>&1 | tee -a "$LOG_FILE" || true
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
      try_id=$((try_id + 1))
      continue
    fi
    if lvs --noheadings -o lv_name | grep -qE "(^|[-_])${try_id}($|[-_])"; then
      try_id=$((try_id + 1))
      continue
    fi
    break
  done
  echo "$try_id"
}

function cleanup_vmid() {
  if qm status $VMID &>/dev/null; then
    log_info "Stopping VM $VMID"
    qm stop $VMID &>/dev/null || true
    log_info "Destroying VM $VMID"
    qm destroy $VMID &>/dev/null || true
  fi
}

function cleanup() {
  local exit_code=$?
  log_info "cleanup() called with exit code $exit_code"
  serial_reader_stop 2>/dev/null || true
  popd >/dev/null 2>&1 || true
  if [[ "${POST_TO_API_DONE:-}" == "true" && "${POST_UPDATE_DONE:-}" != "true" ]]; then
    if [[ $exit_code -eq 0 ]]; then
      post_update_to_api "done" "none" 2>/dev/null || true
    else
      post_update_to_api "failed" "$exit_code" 2>/dev/null || true
    fi
  fi
  # Keep the temp dir on error so we can inspect downloaded files
  if [ "$exit_code" -eq 0 ]; then
    rm -rf $TEMP_DIR
  else
    log_warn "Keeping temp dir for inspection: $TEMP_DIR"
    log_warn "Final log file: $LOG_FILE"
  fi
}

function check_disk_space() {
  local path="$1"
  local required_gb="$2"
  local available_kb=$(df -k "$path" | awk 'NR==2 {print $4}')
  local available_gb=$((available_kb / 1024 / 1024))
  if [ $available_gb -lt $required_gb ]; then
    return 1
  fi
  return 0
}

# Use disk-backed temp directory to avoid tmpfs/RAM size limits in /tmp
if [ -d "/var/tmp" ] && check_disk_space "/var/tmp" 20; then
  TEMP_DIR=$(mktemp -d /var/tmp/opnsense-vm.XXXXXX)
elif [ -d "/tmp" ] && check_disk_space "/tmp" 20; then
  TEMP_DIR=$(mktemp -d)
else
  TEMP_DIR=$(mktemp -d /var/tmp/opnsense-vm.XXXXXX)
fi
log_info "TEMP_DIR=$TEMP_DIR"
pushd $TEMP_DIR >/dev/null

# Mirror the log inside TEMP_DIR too so it survives cleanup on error
touch "$TEMP_DIR/script.log" 2>/dev/null || true
exec 3>&1 4>&2
# (no further redirection here; log() already writes to LOG_FILE)

# ---------------------------------------------------------------------------
# Serial helpers
# ---------------------------------------------------------------------------
SERIAL_LOG=""
SERIAL_READER_PID=""
SERIAL_PIPE_FIFO=""

function serial_reader_start() {
  serial_reader_stop
  SERIAL_LOG="${TEMP_DIR}/serial-${VMID}.log"
  : > "$SERIAL_LOG"
  if ! command -v socat >/dev/null 2>&1; then
    log_err "socat not found - serial prompt detection disabled"
    log_err "Install it with: apt install socat"
    return 1
  fi
  local sock="/var/run/qemu-server/${VMID}.serial0"
  local i
  for i in $(seq 1 30); do
    [ -S "$sock" ] && break
    sleep 1
  done
  if [ ! -S "$sock" ]; then
    log_err "Serial socket $sock not found after 30s"
    return 1
  fi
  log_info "Attaching to serial socket $sock -> $SERIAL_LOG"

  # Use a coprocess-style background reader that writes to the log file and
  # (optionally) to stdout for live debugging.
  if [ "$DEBUG_SERIAL" = "1" ]; then
    socat -u UNIX-CONNECT:"$sock" - 2>/dev/null | tee -a "$SERIAL_LOG" &
    SERIAL_READER_PID=$!
  else
    socat -u UNIX-CONNECT:"$sock" - >>"$SERIAL_LOG" 2>/dev/null &
    SERIAL_READER_PID=$!
  fi
  sleep 1
  log_info "Serial reader PID=$SERIAL_READER_PID"
  return 0
}

function serial_reader_stop() {
  if [ -n "${SERIAL_READER_PID:-}" ] && kill -0 "$SERIAL_READER_PID" 2>/dev/null; then
    log_dbg "Stopping serial reader PID=$SERIAL_READER_PID"
    kill "$SERIAL_READER_PID" 2>/dev/null || true
    wait "$SERIAL_READER_PID" 2>/dev/null || true
  fi
  SERIAL_READER_PID=""
}

# wait_for_serial_pattern <regex> <timeout_seconds> <label>
function wait_for_serial_pattern() {
  local pattern="$1"
  local timeout="${2:-600}"
  local label="${3:-$pattern}"
  local elapsed=0
  if [ -z "$SERIAL_LOG" ] || [ ! -f "$SERIAL_LOG" ]; then
    log_warn "wait_for_serial_pattern: no serial log available"
    return 1
  fi
  log_info "Waiting up to ${timeout}s for pattern: '$label' (regex: $pattern)"
  while [ $elapsed -lt "$timeout" ]; do
    if grep -qE "$pattern" "$SERIAL_LOG" 2>/dev/null; then
      log_info "Pattern matched after ${elapsed}s: '$label'"
      return 0
    fi
    sleep 3
    elapsed=$((elapsed + 3))
    if (( elapsed % 30 == 0 )); then
      log_info "  ... still waiting for '$label' (${elapsed}s / ${timeout}s)"
    fi
  done
  log_warn "TIMEOUT waiting for '$label' after ${timeout}s"
  return 1
}

# dump_serial_tail [lines]
function dump_serial_tail() {
  local lines="${1:-40}"
  if [ -n "$SERIAL_LOG" ] && [ -f "$SERIAL_LOG" ]; then
    log_info "--- last $lines lines of serial console ---"
    tail -n "$lines" "$SERIAL_LOG" | sed 's/^/  | /' | tee -a "$LOG_FILE"
    log_info "--- end of serial tail ---"
  else
    log_warn "dump_serial_tail: no serial log"
  fi
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
    "A") character="shift-a" ;;
    "B") character="shift-b" ;;
    "C") character="shift-c" ;;
    "D") character="shift-d" ;;
    "E") character="shift-e" ;;
    "F") character="shift-f" ;;
    "G") character="shift-g" ;;
    "H") character="shift-h" ;;
    "I") character="shift-i" ;;
    "J") character="shift-j" ;;
    "K") character="shift-k" ;;
    "L") character="shift-l" ;;
    "M") character="shift-m" ;;
    "N") character="shift-n" ;;
    "O") character="shift-o" ;;
    "P") character="shift-p" ;;
    "Q") character="shift-q" ;;
    "R") character="shift-r" ;;
    "S") character="shift-s" ;;
    "T") character="shift-t" ;;
    "U") character="shift-u" ;;
    "V") character="shift-v" ;;
    "W") character="shift-w" ;;
    "X") character="shift-x" ;;
    "Y") character="shift-y" ;;
    "Z") character="shift-z" ;;
    "!") character="shift-1" ;;
    "@") character="shift-2" ;;
    "#") character="shift-3" ;;
    '$') character="shift-4" ;;
    "%") character="shift-5" ;;
    "^") character="shift-6" ;;
    "&") character="shift-7" ;;
    "*") character="shift-8" ;;
    "(") character="shift-9" ;;
    ")") character="shift-0" ;;
    esac
    qm sendkey $VMID "$character"
  done
  qm sendkey $VMID ret
  sleep "${WAIT_EXTRA:-0}"
}

if (whiptail --backtitle "Proxmox VE Helper Scripts" --title "OPNsense VM" --yesno "This will create a New OPNsense VM. Proceed?" 10 58); then
  :
else
  header_info && echo -e "⚠ User exited script \n" && exit
fi

function msg_info() { local msg="$1"; echo -ne " ${HOLD} ${YW}${msg}..."; }
function msg_ok()   { local msg="$1"; echo -e "${BFR} ${CM} ${GN}${msg}${CL}"; log_ok "$msg"; }
function msg_error(){ local msg="$1"; echo -e "${BFR} ${CROSS} ${RD}${msg}${CL}"; log_err "$msg"; }
log_ok() { log "OK   " "$@"; }

pve_check() {
  local PVE_VER
  PVE_VER="$(pveversion | awk -F'/' '{print $2}' | awk -F'-' '{print $1}')"
  log_info "Proxmox VE version detected: $PVE_VER"
  if [[ "$PVE_VER" =~ ^8\.([0-9]+) ]]; then
    local MINOR="${BASH_REMATCH[1]}"
    if ((MINOR < 0 || MINOR > 9)); then
      msg_error "This version of Proxmox VE is not supported."
      msg_error "Supported: Proxmox VE version 8.0 – 8.9"
      exit 105
    fi
    return 0
  fi
  if [[ "$PVE_VER" =~ ^9\.([0-9]+) ]]; then
    local MINOR="${BASH_REMATCH[1]}"
    if ((MINOR < 0 || MINOR > 2)); then
      msg_error "This version of Proxmox VE is not supported."
      msg_error "Supported: Proxmox VE version 9.0 – 9.2"
      exit 105
    fi
    return 0
  fi
  msg_error "This version of Proxmox VE is not supported."
  exit 105
}

function arch_check() {
  if [ "$(dpkg --print-architecture)" != "amd64" ]; then
    echo -e "\n ${CROSS} This script will not work with PiMox! \n"
    exit
  fi
}

function ssh_check() {
  if command -v pveversion >/dev/null 2>&1; then
    if [ -n "${SSH_CLIENT:+x}" ]; then
      if whiptail --backtitle "Proxmox VE Helper Scripts" --defaultno --title "SSH DETECTED" --yesno "It's suggested to use the Proxmox shell instead of SSH, since SSH can create issues while gathering variables. Would you like to proceed with using SSH?" 10 62; then
        echo "you've been warned"
      else
        clear
        exit
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
  if ! ip link show "${BRG}" &>/dev/null; then
    msg_error "Bridge '${BRG}' does not exist"
    exit
  fi
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
    else
      exit-script
    fi
  else
    echo -e "${DGN}Network Mode: ${BGN}Single Interface (Proxy/VPN/IDS)${CL}"
    echo -e "${YW}  (Only one bridge detected, dual interface requires a second bridge)${CL}"
    WAN_BRG=""
  fi
  echo -e "${DGN}Using Interface MTU Size: ${BGN}Default${CL}"
  echo -e "${DGN}Start VM when completed: ${BGN}yes${CL}"
  echo -e "${BL}Creating a OPNsense VM using the above default settings${CL}"
  log_info "default_settings: VMID=$VMID HN=$HN Cores=$CORE_COUNT RAM=$RAM_SIZE BRG=$BRG WAN_BRG=$WAN_BRG"
}

function advanced_settings() {
  local ip_regex='^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$'
  METHOD="advanced"
  [ -z "${VMID:-}" ] && VMID=$(get_valid_nextid)
  # (unchanged from original)
  while true; do
    if VMID=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Virtual Machine ID" 8 58 $VMID --title "VIRTUAL MACHINE ID" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
      if [ -z "$VMID" ]; then VMID=$(get_valid_nextid); fi
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
      if [ -z "$CORE_COUNT" ]; then CORE_COUNT="4"; fi
      if [[ "$CORE_COUNT" =~ ^[1-9][0-9]*$ ]]; then echo -e "${DGN}Allocated Cores: ${BGN}$CORE_COUNT${CL}"; break; fi
      whiptail --backtitle "Proxmox VE Helper Scripts" --title "INVALID INPUT" --msgbox "CPU Cores must be a positive integer (e.g., 4)." 8 58
    else exit-script; fi
  done
  while true; do
    if RAM_SIZE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Allocate RAM in MiB" 8 58 8192 --title "RAM" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
      if [ -z "$RAM_SIZE" ]; then RAM_SIZE="8192"; fi
      if [[ "$RAM_SIZE" =~ ^[1-9][0-9]*$ ]]; then echo -e "${DGN}Allocated RAM: ${BGN}$RAM_SIZE${CL}"; break; fi
      whiptail --backtitle "Proxmox VE Helper Scripts" --title "INVALID INPUT" --msgbox "RAM Size must be a positive integer in MiB (e.g., 8192)." 8 58
    else exit-script; fi
  done
  if BRG=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set a LAN Bridge" 8 58 vmbr0 --title "LAN BRIDGE" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $BRG ]; then BRG="vmbr0"; fi
    if ! ip link show "${BRG}" &>/dev/null; then msg_error "Bridge '${BRG}' does not exist"; exit; fi
    echo -e "${DGN}Using LAN Bridge: ${BGN}$BRG${CL}"
  else exit-script; fi
  if IP_ADDR=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set a LAN IP" 8 58 $IP_ADDR --title "LAN IP ADDRESS" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $IP_ADDR ]; then echo -e "${DGN}Using DHCP AS LAN IP ADDRESS${CL}"; else
      if [[ -n "$IP_ADDR" && ! "$IP_ADDR" =~ $ip_regex ]]; then msg_error "Invalid IP Address format for LAN IP. Needs to be 0.0.0.0, was $IP_ADDR"; exit; fi
      echo -e "${DGN}Using LAN IP ADDRESS: ${BGN}$IP_ADDR${CL}"
      if LAN_GW=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set a LAN GATEWAY IP" 8 58 $LAN_GW --title "LAN GATEWAY IP ADDRESS" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
        if [ -z $LAN_GW ]; then exit-script; fi
        if [[ -n "$LAN_GW" && ! "$LAN_GW" =~ $ip_regex ]]; then msg_error "Invalid IP Address format for Gateway. Needs to be 0.0.0.0, was $LAN_GW"; exit; fi
        echo -e "${DGN}Using LAN GATEWAY ADDRESS: ${BGN}$LAN_GW${CL}"
      fi
      if NETMASK=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set a LAN netmask (24 for example)" 8 58 $NETMASK --title "LAN NETMASK" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
        if [ -z $NETMASK ]; then echo -e "${DGN}Netmask needs to be set if ip is not dhcp${CL}"; fi
        if [[ -n "$NETMASK" && ! ("$NETMASK" =~ ^[0-9]+$ && "$NETMASK" -ge 1 && "$NETMASK" -le 32) ]]; then msg_error "Invalid LAN NETMASK format. Needs to be 1-32, was $NETMASK"; exit; fi
        echo -e "${DGN}Using LAN NETMASK: ${BGN}$NETMASK${CL}"
      else exit-script; fi
    fi
  else exit-script; fi
  local WAN_BRIDGES
  WAN_BRIDGES=$(get_available_bridges | grep -v "^${BRG}$" || true)
  if [ -z "$WAN_BRIDGES" ]; then msg_error "No additional bridge available for WAN. Only '${BRG}' exists."; exit; fi
  local WAN_MENU=(); local first=true
  while IFS= read -r brg; do
    if $first; then WAN_MENU+=("$brg" "" "ON"); first=false; else WAN_MENU+=("$brg" "" "OFF"); fi
  done <<<"$WAN_BRIDGES"
  if WAN_BRG=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "WAN BRIDGE" --radiolist "Select WAN Bridge" 14 58 6 "${WAN_MENU[@]}" 3>&1 1>&2 2>&3); then
    if [ -z "$WAN_BRG" ]; then WAN_BRG=$(echo "$WAN_BRIDGES" | head -n1); fi
    echo -e "${DGN}Using WAN Bridge: ${BGN}$WAN_BRG${CL}"
  else exit-script; fi
  if WAN_IP_ADDR=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set a WAN IP" 8 58 $WAN_IP_ADDR --title "WAN IP ADDRESS" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z $WAN_IP_ADDR ]; then echo -e "${DGN}Using DHCP AS WAN IP ADDRESS${CL}"; else
      if [[ -n "$WAN_IP_ADDR" && ! "$WAN_IP_ADDR" =~ $ip_regex ]]; then msg_error "Invalid IP Address format for WAN IP. Needs to be 0.0.0.0, was $WAN_IP_ADDR"; exit; fi
      echo -e "${DGN}Using WAN IP ADDRESS: ${BGN}$WAN_IP_ADDR${CL}"
      if WAN_GW=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set a WAN GATEWAY IP" 8 58 $WAN_GW --title "WAN GATEWAY IP ADDRESS" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
        if [ -z $WAN_GW ]; then exit-script; fi
        if [[ -n "$WAN_GW" && ! "$WAN_GW" =~ $ip_regex ]]; then msg_error "Invalid IP Address format for WAN Gateway. Needs to be 0.0.0.0, was $WAN_GW"; exit; fi
        echo -e "${DGN}Using WAN GATEWAY ADDRESS: ${BGN}$WAN_GW${CL}"
      else exit-script; fi
      if WAN_NETMASK=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set a WAN netmask (24 for example)" 8 58 $WAN_NETMASK --title "WAN NETMASK" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
        if [ -z $WAN_NETMASK ]; then echo -e "${DGN}WAN Netmask needs to be set if ip is not dhcp${CL}"; fi
        if [[ -n "$WAN_NETMASK" && ! ("$WAN_NETMASK" =~ ^[0-9]+$ && "$WAN_NETMASK" -ge 1 && "$WAN_NETMASK" -le 32) ]]; then msg_error "Invalid WAN NETMASK format. Needs to be 1-32, was $WAN_NETMASK"; exit; fi
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
    echo -e "${RD}Creating a OPNsense VM using the above advanced settings${CL}"
  else header_info; advanced_settings; fi
}

function start_script() {
  if (whiptail --backtitle "Proxmox VE Helper Scripts" --title "SETTINGS" --yesno "Use Default Settings?" --no-button Advanced 10 58); then
    header_info; echo -e "${BL}Using Default Settings${CL}"; default_settings
  else
    header_info; echo -e "${RD}Using Advanced Settings${CL}"; advanced_settings
  fi
}

log_step "[STEP 01] arch_check"
arch_check
log_step "[STEP 02] pve_check"
pve_check
log_step "[STEP 03] ssh_check"
ssh_check
log_step "[STEP 04] start_script (interactive)"
start_script
log_step "[STEP 05] post_to_api_vm"
post_to_api_vm || true

msg_info "Validating Storage"
while read -r line; do
  TAG=$(echo $line | awk '{print $1}')
  TYPE=$(echo $line | awk '{printf "%-10s", $2}')
  FREE=$(echo $line | numfmt --field 4-6 --from-unit=K --to=iec --format %.2f | awk '{printf( "%9sB", $6)}')
  ITEM="  Type: $TYPE Free: $FREE "
  OFFSET=2
  if [[ $((${#ITEM} + $OFFSET)) -gt ${MSG_MAX_LENGTH:-} ]]; then
    MSG_MAX_LENGTH=$((${#ITEM} + $OFFSET))
  fi
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

log_step "[STEP 06] Resolving FreeBSD image URL"
msg_info "Retrieving the URL for the OPNsense Qcow2 Disk Image"
RELEASE_LIST="$(curl -s https://download.freebsd.org/releases/VM-IMAGES/ |
  grep -Eo "${FREEBSD_MAJOR}\.[0-9]+-RELEASE" | sort -Vr | uniq)"
log_info "FreeBSD releases found: $(echo $RELEASE_LIST | tr '\n' ' ')"
URL=""; FREEBSD_VER=""
for ver in $RELEASE_LIST; do
  for variant in "" "-ufs" "-zfs"; do
    candidate="https://download.freebsd.org/releases/VM-IMAGES/${ver}/amd64/Latest/FreeBSD-${ver}-amd64${variant}.qcow2.xz"
    log_dbg "Testing $candidate"
    if curl -fsI "$candidate" >/dev/null 2>&1; then
      FREEBSD_VER="$ver"; URL="$candidate"; break 2
    fi
  done
done
if [ -z "$URL" ]; then msg_error "Could not find a FreeBSD ${FREEBSD_MAJOR}.x amd64 qcow2 image."; exit 115; fi
msg_ok "Download URL: ${CL}${BL}${URL}${CL}"

log_step "[STEP 07] Disk space check (download)"
if ! check_disk_space "$TEMP_DIR" 20; then
  AVAILABLE_GB=$(df -h "$TEMP_DIR" | awk 'NR==2 {print $4}')
  msg_error "Insufficient disk space: $AVAILABLE_GB"; exit 214
fi

log_step "[STEP 08] Downloading FreeBSD image"
msg_info "Downloading FreeBSD Image"
curl -f#SL -o "$(basename "$URL")" "$URL"
echo -en "\e[1A\e[0K"
msg_ok "Downloaded ${CL}${BL}$(basename "$URL")${CL}"

log_step "[STEP 09] Disk space check (decompress)"
if ! check_disk_space "$TEMP_DIR" 15; then
  AVAILABLE_GB=$(df -h "$TEMP_DIR" | awk 'NR==2 {print $4}')
  msg_error "Insufficient disk space for decompression: $AVAILABLE_GB"; exit 214
fi

log_step "[STEP 10] Decompressing FreeBSD image"
msg_info "Decompressing FreeBSD Image"
FILE=FreeBSD.qcow2
if ! unxz -cv $(basename $URL) >${FILE}; then
  msg_error "Failed to decompress FreeBSD image."; df -h "$TEMP_DIR"; exit 115
fi
rm -f "$(basename "$URL")"
msg_ok "Decompressed ${CL}${BL}${FILE}${CL}"

log_step "[STEP 11] Preparing storage mapping"
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

log_step "[STEP 12] qm create"
msg_info "Creating a OPNsense VM"
log_info "qm create $VMID -agent 1${MACHINE} -tablet 0 -localtime 1 -bios ovmf${CPU_TYPE} -cores $CORE_COUNT -memory $RAM_SIZE -name $HN -tags community-script -net0 virtio,bridge=$BRG,macaddr=$MAC$VLAN$MTU -onboot 1 -ostype l26 -scsihw virtio-scsi-pci"
qm create $VMID -agent 1${MACHINE} -tablet 0 -localtime 1 -bios ovmf${CPU_TYPE} -cores $CORE_COUNT -memory $RAM_SIZE \
  -name $HN -tags community-script -net0 virtio,bridge=$BRG,macaddr=$MAC$VLAN$MTU -onboot 1 -ostype l26 -scsihw virtio-scsi-pci

log_step "[STEP 13] pvesm alloc (efidisk)"
alloc_attempt=1; alloc_max=4; alloc_delay=5
while :; do
  alloc_err=$(pvesm alloc $STORAGE $VMID $DISK0 4M 2>&1 >/dev/null) && break
  log_warn "pvesm alloc attempt $alloc_attempt failed: $alloc_err"
  if [[ "$alloc_err" == *"got timeout"* && $alloc_attempt -lt $alloc_max ]]; then
    pvesm free "${DISK0_REF}" &>/dev/null || true
    sleep "$alloc_delay"
    alloc_attempt=$((alloc_attempt + 1))
    alloc_delay=$((alloc_delay * 2))
    continue
  fi
  echo -e "$alloc_err" >&2; exit 220
done
log_info "pvesm alloc OK"

log_step "[STEP 14] qm importdisk"
log_info "qm importdisk $VMID ${FILE} $STORAGE ${DISK_IMPORT:-}"
qm importdisk $VMID ${FILE} $STORAGE ${DISK_IMPORT:-} &>/dev/null
log_info "qm importdisk OK"

log_step "[STEP 15] qm set disks"
qm set $VMID \
  -efidisk0 ${DISK0_REF}${FORMAT} \
  -scsi0 ${DISK1_REF},${DISK_CACHE}${THIN}size=2G \
  -boot order=scsi0 \
  -serial0 socket \
  -tags community-script >/dev/null
log_info "qm set OK"

log_step "[STEP 16] qm resize scsi0 to 20G"
qm resize $VMID scsi0 20G >/dev/null

log_step "[STEP 17] Setting VM description"
DESCRIPTION=$(
  cat <<EOF
<div align='center'>
  <h2 style='font-size: 24px; margin: 20px 0;'>OPNsense VM</h2>
  <p><a href='https://github.com/community-scripts/ProxmoxVE'>GitHub</a></p>
</div>
EOF
)
qm set $VMID -description "$DESCRIPTION" >/dev/null

log_step "[STEP 18] Adding WAN bridge to net0"
msg_info "Bridge interfaces are being added."
qm set $VMID -net0 virtio,bridge=${BRG},macaddr=${MAC}${VLAN}${MTU} 2>/dev/null
msg_ok "Bridge interfaces have been successfully added."

msg_ok "Created a OPNsense VM ${CL}${BL}(${HN})"
log_info "VM config after creation:"
qm config $VMID 2>&1 | tee -a "$LOG_FILE"

log_step "[STEP 19] Starting VM"
msg_ok "Starting OPNsense VM (Patience this takes 20-30 minutes)"
qm start $VMID
log_info "VM started, waiting 5s for serial socket"
sleep 5

log_step "[STEP 20] Attaching serial reader"
serial_reader_start || true
sleep 3
dump_serial_tail 30

log_step "[STEP 21] Waiting for FreeBSD login prompt"
msg_info "Waiting for FreeBSD login prompt (timeout 600s)"
if wait_for_serial_pattern "login: ?$" 600 "FreeBSD login:"; then
  msg_ok "FreeBSD login prompt detected"
else
  msg_error "Login prompt not detected - dumping console and using fixed wait"
  dump_serial_tail 60
  sleep 120
fi

log_step "[STEP 22] Sending root username"
msg_info "Logging in as root"
send_line_to_vm "root"
sleep 2

log_step "[STEP 23] Waiting for Password/root prompt"
if wait_for_serial_pattern "(Password:|root@)" 120 "Password/shell prompt"; then
  msg_ok "Password/shell prompt detected"
else
  msg_error "Password prompt not detected - dumping console"
  dump_serial_tail 30
  sleep 5
fi

log_step "[STEP 24] Sending empty password"
send_line_to_vm ""
sleep 2

log_step "[STEP 25] Waiting for root shell"
if wait_for_serial_pattern "root@[^:]*:[^#]*#" 180 "root shell"; then
  msg_ok "Root shell is ready"
else
  msg_error "Root shell not detected - dumping console"
  dump_serial_tail 40
  sleep 30
fi
dump_serial_tail 20

log_step "[STEP 26] Fetching bootstrap script"
msg_info "Fetching OPNsense bootstrap script"
send_line_to_vm "fetch https://raw.githubusercontent.com/opnsense/update/master/src/bootstrap/opnsense-bootstrap.sh.in"
sleep 8
dump_serial_tail 20

if [ -n "$WAN_BRG" ]; then
  log_step "[STEP 27] Adding WAN interface"
  msg_info "Adding WAN interface"
  qm set $VMID -net1 virtio,bridge=${WAN_BRG},macaddr=${WAN_MAC} &>/dev/null
  msg_ok "WAN interface added"
  sleep 5
fi

log_step "[STEP 28] Deregistering FreeBSD pkgbase packages"
# Use pkg delete with -G exclusion pattern: much more robust than piping SQL
send_line_to_vm "pkg delete -af -G \"FreeBSD-*\""
sleep 8
dump_serial_tail 30

log_step "[STEP 29] Running OPNsense bootstrap"
send_line_to_vm "sh ./opnsense-bootstrap.sh.in -y -f -r ${var_version}"
msg_ok "OPNsense VM is being installed, do not close the terminal, or the installation will fail."

log_step "[STEP 30] Polling screendump for stability"
SCREEN_PPM="${TEMP_DIR}/screen-${VMID}.ppm"
function screen_hash() {
  rm -f "$SCREEN_PPM"
  timeout 10 pvesh create /nodes/$(hostname -s)/qemu/$VMID/monitor --command "screendump ${SCREEN_PPM}" >/dev/null 2>&1 || true
  md5sum "$SCREEN_PPM" 2>/dev/null | cut -d' ' -f1 || true
}
build_elapsed=300
build_stable=0
screen_ok=0
hash_a=""
hash_b=""
log_info "Sleeping 300s before starting stability poll"
sleep 300
while [ $build_stable -lt 6 ] && [ $build_elapsed -lt 2400 ]; do
  sleep 30
  build_elapsed=$((build_elapsed + 30))
  new_hash=$(screen_hash)
  if [ -n "$new_hash" ]; then
    screen_ok=1
    if [ "$new_hash" = "$hash_a" ] || [ "$new_hash" = "$hash_b" ]; then
      build_stable=$((build_stable + 1))
    else
      build_stable=0
    fi
  else
    build_stable=0
  fi
  hash_b="$hash_a"; hash_a="$new_hash"
  if [ -n "$new_hash" ]; then
    log_info "Build poll: ${build_elapsed}s elapsed, screen ${new_hash:0:8}, stable ${build_stable}/6"
  else
    log_info "Build poll: ${build_elapsed}s elapsed, screendump failed"
  fi
  # Also dump the serial log tail every 2 minutes for easier debugging
  if (( build_elapsed % 120 == 0 )); then
    dump_serial_tail 15
  fi
  if [ $screen_ok -eq 0 ] && [ $build_elapsed -ge 480 ]; then
    msg_error "Console screendump not available - falling back to fixed 12 min wait."
    sleep 720
    build_elapsed=$((build_elapsed + 720))
    break
  fi
done
msg_ok "OPNsense build finished after $((build_elapsed / 60)) minutes"
dump_serial_tail 40

log_step "[STEP 31] Post-install menu configuration"
sleep 30
send_line_to_vm "root"
sleep 3
send_line_to_vm "opnsense"
sleep 3
send_line_to_vm "2"

if [ "$IP_ADDR" != "" ]; then
  log_info "Configuring LAN with static IP $IP_ADDR/$NETMASK gw $LAN_GW"
  send_line_to_vm "1"; send_line_to_vm "n"; send_line_to_vm "${IP_ADDR}"; send_line_to_vm "${NETMASK}"; send_line_to_vm "${LAN_GW}"
  send_line_to_vm "n"; send_line_to_vm " "; send_line_to_vm "n"; send_line_to_vm "n"; send_line_to_vm " "
  send_line_to_vm "n"; send_line_to_vm "n"; send_line_to_vm "n"; send_line_to_vm "n"; send_line_to_vm "n"
else
  log_info "Configuring LAN with DHCP"
  send_line_to_vm "1"; send_line_to_vm "y"; send_line_to_vm "n"; send_line_to_vm "n"; send_line_to_vm " "
  send_line_to_vm "n"; send_line_to_vm "n"; send_line_to_vm "n"
fi
sleep 20
if [ -n "$WAN_BRG" ] && [ "$WAN_IP_ADDR" != "" ]; then
  log_info "Configuring WAN with static IP $WAN_IP_ADDR/$WAN_NETMASK gw $WAN_GW"
  send_line_to_vm "2"; send_line_to_vm "2"; send_line_to_vm "n"; send_line_to_vm "${WAN_IP_ADDR}"; send_line_to_vm "${WAN_NETMASK}"; send_line_to_vm "${WAN_GW}"
  send_line_to_vm "n"; send_line_to_vm " "; send_line_to_vm "n"; send_line_to_vm " "; send_line_to_vm "n"; send_line_to_vm "n"; send_line_to_vm "n"
fi
sleep 10
send_line_to_vm "0"
msg_ok "Started OPNsense VM"

log_step "[STEP 32] Finalizing"
serial_reader_stop || true
msg_ok "Completed successfully!\n"
if [ "$IP_ADDR" != "" ]; then
  echo -e "${INFO}${YW} Access it using the following URL:${CL}"
  echo -e "${TAB}${GATEWAY}${BGN}http://${IP_ADDR}${CL}"
else
  echo -e "${INFO}${YW} LAN IP was DHCP.${CL}"
  echo -e "${INFO}${BGN}To find the IP login to the VM shell${CL}"
fi
log_info "Script finished. Log file: $LOG_FILE"
