#!/usr/bin/env bash
#
# holaOS VM for Proxmox VE (Community-Scripts style, host-side)
#
# Run ON YOUR PROXMOX HOST as root (one-liner):
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/HolaOS-Proxmox/main/holaos-vm.sh)"
#
# What it does:
#   - creates an Ubuntu 24.04 (noble) QEMU VM via qm + cloud image
#   - configures Cloud-Init (user, DHCP, qemu-guest-agent)
#   - optionally auto-installs holaOS on first boot via a snippets
#     vendor config that curls holaos-install.sh inside the guest
#   - falls back to a manual one-liner if no snippets storage exists
#
# After the VM boots, open it and run (if autoinstall was skipped):
#   curl -fsSL https://raw.githubusercontent.com/HatchetMan111/HolaOS-Proxmox/main/holaos-install.sh | sudo bash
#
# Env overrides (optional):
#   HOLAOS_INSTALL_URL=...   URL of holaos-install.sh (default below)
#   HOLAOS_REF=main          git ref installed inside the VM
#   HOLAOS_WITH_DESKTOP=0    set to 1 to pass --with-desktop to guest installer

# api.func (Community-Scripts) ist optional — Skript muss auch ohne Netz/API laufen.
# Alle post_* Aufrufe sind daher best-effort (|| true) und per command -v abgesichert.
if curl -fsSL --max-time 15 https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/api.func -o /tmp/holaos-api.func 2>/dev/null; then
  # shellcheck disable=SC1091
  source /tmp/holaos-api.func || true
fi
post_to_api_vm_safe() { command -v post_to_api_vm >/dev/null 2>&1 && post_to_api_vm || true; }
post_update_to_api_safe() { command -v post_update_to_api >/dev/null 2>&1 && post_update_to_api "$@" || true; }

HOLAOS_INSTALL_URL="${HOLAOS_INSTALL_URL:-https://raw.githubusercontent.com/HatchetMan111/HolaOS-Proxmox/main/holaos-install.sh}"
HOLAOS_REF="${HOLAOS_REF:-main}"
HOLAOS_WITH_DESKTOP="${HOLAOS_WITH_DESKTOP:-0}"
HOLAOS_WITH_WEBTERM="${HOLAOS_WITH_WEBTERM:-1}"
HOLAOS_REPO_URL="https://github.com/holaboss-ai/holaOS.git"

function header_info {
  clear
  cat <<"EOF"
        __      __        ___  ____
   / /___  / /___ _   / _ \/ ___/
  / __/ / / / __ `/  / / / \__ \
 / /_/ /_/ / /_/ /  / /_/ /___/ /
 \__/\__,_/\__,_/   \____//____/

   holaOS VM for Proxmox VE

EOF
}
header_info
echo -e "\n Loading..."
GEN_MAC=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')
NSAPP="holaos-vm"
var_os="ubuntu"
var_version="2404"

YW=$(echo "\033[33m"); BL=$(echo "\033[36m"); RD=$(echo "\033[01;31m")
BGN=$(echo "\033[4;92m"); GN=$(echo "\033[1;92m"); DGN=$(echo "\033[32m")
CL=$(echo "\033[m"); BOLD=$(echo "\033[1m"); BFR="\\r\\033[K"; HOLD=" "
TAB="  "
CM="${TAB}✔️${TAB}${CL}"; CROSS="${TAB}✖️${TAB}${CL}"; INFO="${TAB}💡${TAB}${CL}"
OS="${TAB}🖥️${TAB}${CL}"; CONTAINERTYPE="${TAB}📦${TAB}${CL}"; DISKSIZE="${TAB}💾${TAB}${CL}"
CPUCORE="${TAB}🧠${TAB}${CL}"; RAMSIZE="${TAB}🛠️${TAB}${CL}"; CONTAINERID="${TAB}🆔${TAB}${CL}"
HOSTNAME="${TAB}🏠${TAB}${CL}"; BRIDGE="${TAB}🌉${TAB}${CL}"; GATEWAY="${TAB}🌐${TAB}${CL}"
DEFAULT="${TAB}⚙️${TAB}${CL}"; MACADDRESS="${TAB}🔗${TAB}${CL}"; VLANTAG="${TAB}🏷️${TAB}${CL}"
CREATING="${TAB}🚀${TAB}${CL}"; ADVANCED="${TAB}🧩${TAB}${CL}"

THIN="discard=on,ssd=1,"
set -e -o pipefail
VM_CREATED="no"
CLEANUP_ON_ERROR="yes"
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT
trap 'post_update_to_api_safe "failed" "130"' SIGINT
trap 'post_update_to_api_safe "failed" "143"' SIGTERM

function error_handler() {
  local exit_code="$?"; local line_number="$1"; local command="$2"
  # ERR-Trap nicht für erwartete Fehlschläge in if/||-Kontexten feuern lassen:
  # (bash ruft ERR bei `set -e` in Funktionen/Subshels trotzdem auf – daher hier filtern)
  case "$command" in
    *"post_update_to_api_safe"*|*"post_to_api_vm_safe"*) return 0 ;;
  esac
  post_update_to_api_safe "failed" "$exit_code"
  echo -e "\n${RD}[ERROR]${CL} line ${RD}$line_number${CL}: exit ${RD}$exit_code${CL}: ${YW}$command${CL}\n"
  if [[ "$VM_CREATED" == "yes" && "$CLEANUP_ON_ERROR" == "yes" ]]; then
    cleanup_vmid
  else
    echo -e "${YW}VM bleibt erhalten (qm config $VMID / qm status $VMID prüfen).${CL}"
  fi
}
function get_valid_nextid() {
  local try_id; try_id=$(pvesh get /cluster/nextid)
  while true; do
    if [ -f "/etc/pve/qemu-server/${try_id}.conf" ] || [ -f "/etc/pve/lxc/${try_id}.conf" ]; then try_id=$((try_id+1)); continue; fi
    break
  done
  echo "$try_id"
}
function cleanup_vmid() {
  if [[ -z "${VMID:-}" ]]; then return 0; fi
  if qm status "$VMID" &>/dev/null; then qm stop "$VMID" &>/dev/null || true; fi
  # Nur zerstören, wenn die VM von diesem Skriptlauf erstellt wurde.
  if [[ "$VM_CREATED" == "yes" ]]; then qm destroy "$VMID" --destroy-unreferenced-disks 1 &>/dev/null || qm destroy "$VMID" &>/dev/null || true; fi
}
function cleanup() {
  local exit_code=$?
  popd >/dev/null 2>&1 || true
  if [[ "${POST_TO_API_DONE:-}" == "true" && "${POST_UPDATE_DONE:-}" != "true" ]]; then
    if [[ $exit_code -eq 0 ]]; then post_update_to_api_safe "done" "none"; else post_update_to_api_safe "failed" "$exit_code"; fi
  fi
  rm -rf "${TEMP_DIR:-}" /tmp/holaos-api.func 2>/dev/null || true
}
# Löst das Host-Verzeichnis für <store>:snippets/... robust auf.
# `pvesm path <store>:snippets` ohne Dateiname schlägt fehl — deshalb mit Dummy-Datei arbeiten
# und zusätzlich Storage-Config (/etc/pve/storage.cfg, pvesh) auswerten.
# Echo: Verzeichnis (ohne trailing slash). Exit 1 wenn nicht ermittelbar.
function get_snippets_dir() {
  local store="$1" guess=""
  # 1) pvesm path mit Dummy-Datei (prüft nichts, parst nur die Volume-ID)
  guess="$(pvesm path "${store}:snippets/holaos-probe-dummy.yaml" 2>/dev/null || true)"
  if [[ -n "$guess" ]]; then dirname "$guess"; return 0; fi
  # 2) Storage-Pfad aus pvesh (dir/nfs/cifs: path + /snippets)
  local base=""
  base="$(pvesh get "/storage/${store}" 2>/dev/null | awk '$1=="path"{print $2}' | head -1 || true)"
  if [[ -n "$base" && -d "$base" ]]; then echo "${base}/snippets"; return 0; fi
  # 3) /etc/pve/storage.cfg parsen (dir: <store> ... path <pfad>)
  base="$(awk -v s="$store" '
    $1=="dir:" && $2==s {found=1; next}
    found && $1=="path" {print $2; exit}
    found && $1~/:$/ {exit}
  ' /etc/pve/storage.cfg 2>/dev/null || true)"
  if [[ -n "$base" ]]; then echo "${base}/snippets"; return 0; fi
  # 4) Standard-lokal (NICHT template/snippets — das war der alte falsche Fallback!)
  for cand in "/var/lib/vz/snippets" "/mnt/pve/${store}/snippets"; do
    if [[ -d "$(dirname "$cand")" ]]; then echo "$cand"; return 0; fi
  done
  return 1
}
# Liefer den ersten Storage, der einen Content-Typ unterstützt (Komma-getrennt prüfen).
function first_storage_with_content() {
  local want="$1" s
  s="$(pvesm status -content "$want" 2>/dev/null | awk 'NR>1 {print $1}' | head -1 || true)"
  echo "$s"
}
# Erste globale IPv4 der VM via QEMU Guest Agent (echo IP, RC 1 wenn noch keine).
function get_vm_ip() {
  local vmid="$1" out="$2" ip=""
  if [[ -z "$out" ]]; then out="$(qm guest cmd "$vmid" network-get-interfaces 2>/dev/null || true)"; fi
  [[ -z "$out" ]] && return 1
  if command -v python3 >/dev/null 2>&1; then
    ip="$(echo "$out" | python3 -c '
import json,sys
try:
  data = json.load(sys.stdin)
except Exception:
  sys.exit(1)
ips = []
if isinstance(data, dict):
  data = data.get("result", data)
items = data if isinstance(data, list) else []
for iface in items:
  for a in (iface.get("ip-addresses", []) or []):
    ip = a.get("ip-address", "")
    if a.get("ip-address-type", "") == "ipv4" and ip and not ip.startswith("127.") and not ip.startswith("169.254."):
      print(ip)
      sys.exit(0)
sys.exit(1)
' 2>/dev/null || true)"
  else
    ip="$(echo "$out" | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | grep -v '^127\.' | grep -v '^169\.254\.' | head -1 || true)"
  fi
  [[ -n "$ip" ]] && echo "$ip" && return 0
  return 1
}
TEMP_DIR=$(mktemp -d); pushd $TEMP_DIR >/dev/null

if whiptail --backtitle "Proxmox VE Helper Scripts" --title "holaOS VM" \
  --yesno "This will create a new holaOS VM (Ubuntu 24.04 + holaOS auto-install). Proceed?" 10 66; then :;
else header_info && echo -e "${CROSS}${RD}User exited${CL}\n" && exit; fi

function msg_info() { local msg="$1"; echo -ne "${TAB}${YW}${HOLD}${msg}${HOLD}"; }
function msg_ok() { local msg="$1"; echo -e "${BFR}${CM}${GN}${msg}${CL}"; }
function msg_error() { local msg="$1"; echo -e "${BFR}${CROSS}${RD}${msg}${CL}"; }
function check_root() {
  if [[ "$(id -u)" -ne 0 || $(ps -o comm= -p $PPID) == "sudo" ]]; then
    clear; msg_error "Please run this script as root."; echo -e "\nExiting..."; sleep 2; exit; fi
}
pve_check() {
  local PVE_VER; PVE_VER="$(pveversion | awk -F'/' '{print $2}' | awk -F'-' '{print $1}')"
  if [[ "$PVE_VER" =~ ^8\.([0-9]+) ]]; then (( BASH_REMATCH[1] >= 0 && BASH_REMATCH[1] <= 9 )) || { msg_error "PVE 8.0-8.9 required."; exit 105; }; return 0; fi
  if [[ "$PVE_VER" =~ ^9\.([0-9]+) ]]; then (( BASH_REMATCH[1] >= 0 && BASH_REMATCH[1] <= 2 )) || { msg_error "PVE 9.0-9.2 required."; exit 105; }; return 0; fi
  msg_error "Unsupported PVE (need 8.0-8.x or 9.0-9.2)."; exit 105
}
function arch_check() {
  if [ "$(dpkg --print-architecture)" != "amd64" ]; then echo -e "\nNo PiMox/ARM support.\n"; sleep 2; exit; fi
}
function ssh_check() {
  if command -v pveversion >/dev/null 2>&1 && [ -n "${SSH_CLIENT:+x}" ]; then
    if whiptail --backtitle "Proxmox VE Helper Scripts" --defaultno --title "SSH DETECTED" \
      --yesno "Use the Proxmox shell instead of SSH if possible. Continue with SSH?" 10 62; then echo "warned";
    else clear; exit; fi
  fi
}
function exit-script() { clear; echo -e "\n${CROSS}${RD}User exited${CL}\n"; exit; }

# ---- holaOS-sized defaults: Electron/bun build needs RAM+disk ----
function default_settings() {
  VMID=$(get_valid_nextid); FORMAT=",efitype=4m"; MACHINE=""; DISK_SIZE="40G"
  DISK_CACHE=""; HN="holaos"; CPU_TYPE=""; CORE_COUNT="4"; RAM_SIZE="8192"
  BRG="vmbr0"; MAC="$GEN_MAC"; VLAN=""; MTU=""; START_VM="yes"
  CI_USER="hola"; CI_SSHKEY="${HOLAOS_SSH_PUBKEY:-}"; AUTOINSTALL="yes"; METHOD="default"
  echo -e "${CONTAINERID}${BOLD}${DGN}VM ID: ${BGN}${VMID}${CL}"
  echo -e "${HOSTNAME}${BOLD}${DGN}Hostname: ${BGN}${HN}${CL}"
  echo -e "${CPUCORE}${BOLD}${DGN}CPU: ${BGN}${CORE_COUNT} (KVM64)${CL}"
  echo -e "${RAMSIZE}${BOLD}${DGN}RAM: ${BGN}${RAM_SIZE} MiB${CL}"
  echo -e "${DISKSIZE}${BOLD}${DGN}Disk: ${BGN}${DISK_SIZE}${CL}"
  echo -e "${BRIDGE}${BOLD}${DGN}Bridge: ${BGN}${BRG}${CL}"
  echo -e "${MACADDRESS}${BOLD}${DGN}MAC: ${BGN}${MAC}${CL}"
  echo -e "${DEFAULT}${BOLD}${DGN}Cloud-Init user: ${BGN}${CI_USER}${CL}"
  echo -e "${DEFAULT}${BOLD}${DGN}holaOS auto-install: ${BGN}${AUTOINSTALL}${CL}"
  echo -e "${GATEWAY}${BOLD}${DGN}Start when done: ${BGN}yes${CL}"
  echo -e "${CREATING}${BOLD}${DGN}Creating holaOS VM with defaults${CL}"
}

function advanced_settings() {
  METHOD="advanced"
  [ -z "${VMID:-}" ] && VMID=$(get_valid_nextid)
  while true; do
    if VMID=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "VM ID" 8 58 $VMID --title "VM ID" --cancel-button Exit 3>&1 1>&2 2>&3); then
      [ -z "$VMID" ] && VMID=$(get_valid_nextid)
      if qm status "$VMID" &>/dev/null || pct status "$VMID" &>/dev/null; then echo -e "${CROSS}${RD}ID $VMID in use${CL}"; sleep 2; continue; fi
      echo -e "${CONTAINERID}${BOLD}${DGN}VM ID: ${BGN}$VMID${CL}"; break
    else exit-script; fi
  done
  if HN_IN=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Hostname" 8 58 holaos --title "HOSTNAME" --cancel-button Exit 3>&1 1>&2 2>&3); then
    HN=$([ -z "$HN_IN" ] && echo "holaos" || echo "${HN_IN,,}" | tr -cs 'a-z0-9-' '-' | sed 's/^-//;s/-$//')
    echo -e "${HOSTNAME}${BOLD}${DGN}Hostname: ${BGN}$HN${CL}"
  else exit-script; fi
  if CORE_COUNT=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "CPU cores (min 2, empfohlen 4)" 8 58 4 --title "CORES" --cancel-button Exit 3>&1 1>&2 2>&3); then
    [ -z "$CORE_COUNT" ] && CORE_COUNT="4"
    echo -e "${CPUCORE}${BOLD}${DGN}CPU: ${BGN}$CORE_COUNT${CL}"
  else exit-script; fi
  if RAM_SIZE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "RAM in MiB (min 4096, empfohlen 8192)" 8 58 8192 --title "RAM" --cancel-button Exit 3>&1 1>&2 2>&3); then
    [ -z "$RAM_SIZE" ] && RAM_SIZE="8192"
    echo -e "${RAMSIZE}${BOLD}${DGN}RAM: ${BGN}$RAM_SIZE${CL}"
  else exit-script; fi
  if DS_RAW=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Disk in GiB (min 20, empfohlen 40)" 8 58 40 --title "DISK" --cancel-button Exit 3>&1 1>&2 2>&3); then
    DS_NUM=$(echo "$DS_RAW" | tr -cd '0-9')
    [ -z "$DS_NUM" ] && DS_NUM="40"
    [ "$DS_NUM" -lt 20 ] && DS_NUM="20"
    DISK_SIZE="${DS_NUM}G"; echo -e "${DISKSIZE}${BOLD}${DGN}Disk: ${BGN}$DISK_SIZE${CL}"
  else exit-script; fi
  if BRG=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Bridge" 8 58 vmbr0 --title "BRIDGE" --cancel-button Exit 3>&1 1>&2 2>&3); then
    [ -z "$BRG" ] && BRG="vmbr0"; echo -e "${BRIDGE}${BOLD}${DGN}Bridge: ${BGN}$BRG${CL}"
  else exit-script; fi
  if CI_USER=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Cloud-Init user (SSH login)" 8 58 hola --title "CI USER" --cancel-button Exit 3>&1 1>&2 2>&3); then
    [ -z "$CI_USER" ] && CI_USER="hola"; echo -e "${DEFAULT}${BOLD}${DGN}CI user: ${BGN}$CI_USER${CL}"
  else exit-script; fi
  if CI_SSHKEY_IN=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "SSH Public Key (optional, leer = Login per Konsole/Passwort). Key oder Pfad, z.B. /root/.ssh/id_rsa.pub" 10 70 "${HOLAOS_SSH_PUBKEY:-}" --title "SSH KEY" --cancel-button Exit 3>&1 1>&2 2>&3); then
    CI_SSHKEY="$CI_SSHKEY_IN"
    if [[ -n "$CI_SSHKEY" && -f "$CI_SSHKEY" ]]; then
      echo -e "${DEFAULT}${BOLD}${DGN}SSH key: ${BGN}aus Datei $CI_SSHKEY${CL}"
    elif [[ -n "$CI_SSHKEY" ]]; then
      echo -e "${DEFAULT}${BOLD}${DGN}SSH key: ${BGN}direkt hinterlegt${CL}"
    else
      echo -e "${DEFAULT}${BOLD}${DGN}SSH key: ${BGN}keiner (Passwort via Konsole)${CL}"
    fi
  else exit-script; fi
  if (whiptail --backtitle "Proxmox VE Helper Scripts" --title "AUTO-INSTALL" --yesno "holaOS beim ersten Boot automatisch installieren? (braucht snippets-Storage)" 10 66); then
    AUTOINSTALL="yes"
  else AUTOINSTALL="no"; fi
  echo -e "${DEFAULT}${BOLD}${DGN}Auto-install: ${BGN}$AUTOINSTALL${CL}"
  if (whiptail --backtitle "Proxmox VE Helper Scripts" --title "START VM" --yesno "VM nach Erstellung starten?" 10 58); then START_VM="yes"; else START_VM="no"; fi
  echo -e "${GATEWAY}${BOLD}${DGN}Start: ${BGN}$START_VM${CL}"
  FORMAT=",efitype=4m"; MACHINE=""; DISK_CACHE=""; CPU_TYPE=""; MAC="$GEN_MAC"; VLAN=""; MTU=""
  if (whiptail --backtitle "Proxmox VE Helper Scripts" --title "READY" --yesno "holaOS VM jetzt erstellen?" --no-button Do-Over 10 58); then
    echo -e "${CREATING}${BOLD}${DGN}Creating holaOS VM (advanced)${CL}"
  else header_info; echo -e "${ADVANCED}${BOLD}${RD}Advanced${CL}"; advanced_settings; fi
}

function start_script() {
  if (whiptail --backtitle "Proxmox VE Helper Scripts" --title "SETTINGS" --yesno "Default-Einstellungen verwenden? (4 Cores / 8 GB / 40 GB)" --no-button Advanced 10 66); then
    header_info; echo -e "${DEFAULT}${BOLD}${BL}Defaults${CL}"; default_settings
  else header_info; echo -e "${ADVANCED}${BOLD}${RD}Advanced${CL}"; advanced_settings; fi
}

check_root; arch_check; pve_check; ssh_check; start_script
post_to_api_vm_safe

# Bridge existiert?
if ! ip link show "$BRG" &>/dev/null; then
  msg_error "Bridge ${BRG} existiert nicht (ip link). Bitte vmbrX prüfen."
  exit 104
fi

# ---------- storage ----------
msg_info "Validating storage"
STORAGE_MENU=(); MSG_MAX_LENGTH=0
while read -r line; do
  TAG=$(echo $line | awk '{print $1}'); TYPE=$(echo $line | awk '{printf "%-10s", $2}')
  FREE=$(echo $line | numfmt --field 4-6 --from-unit=K --to=iec --format %.2f | awk '{printf("%9sB",$6)}')
  ITEM="Type: $TYPE Free: $FREE "; OFFSET=2
  if [[ $((${#ITEM}+$OFFSET)) -gt ${MSG_MAX_LENGTH:-} ]]; then MSG_MAX_LENGTH=$((${#ITEM}+$OFFSET)); fi
  STORAGE_MENU+=("$TAG" "$ITEM" "OFF")
done < <(pvesm status -content images | awk 'NR>1')
VALID=$(pvesm status -content images | awk 'NR>1')
[ -z "$VALID" ] && { msg_error "No valid storage for images."; exit; }
if [ $((${#STORAGE_MENU[@]}/3)) -eq 1 ]; then STORAGE=${STORAGE_MENU[0]};
else while [ -z "${STORAGE:+x}" ]; do
  STORAGE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Storage" --radiolist \
    "Storage für ${HN} wählen (Spacebar):" 16 $(($MSG_MAX_LENGTH+23)) 6 "${STORAGE_MENU[@]}" 3>&1 1>&2 2>&3)
 done; fi
msg_ok "Using ${CL}${BL}$STORAGE${CL}."
msg_ok "VM ID ${CL}${BL}$VMID${CL}."

# ---------- cloud image ----------
msg_info "Downloading Ubuntu 24.04 cloud image"
URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
sleep 1; msg_ok "${CL}${BL}${URL}${CL}"
curl -f#SL -o "$(basename "$URL")" "$URL"
echo -en "\e[1A\e[0K"; FILE=$(basename $URL)
msg_ok "Downloaded ${CL}${BL}${FILE}${CL}"

STORAGE_TYPE=$(pvesm status -storage $STORAGE | awk 'NR>1 {print $2}')
case $STORAGE_TYPE in
  nfs|dir|cifs) DISK_EXT=".qcow2"; DISK_REF="$VMID/"; DISK_IMPORT="-format qcow2"; THIN="" ;;
  btrfs) DISK_EXT=".raw"; DISK_REF="$VMID/"; DISK_IMPORT="-format raw"; FORMAT=",efitype=4m"; THIN="" ;;
  *) DISK_EXT=""; DISK_REF=""; DISK_IMPORT="-format raw" ;;
esac
for i in 0 1; do disk="DISK$i"; eval DISK${i}=vm-${VMID}-disk-${i}${DISK_EXT:-}; eval DISK${i}_REF=${STORAGE}:${DISK_REF:-}${!disk}; done

# ---------- create VM ----------
msg_info "Creating holaOS VM"
qm create "$VMID" -agent 1"${MACHINE}" -tablet 0 -localtime 1 -bios ovmf"${CPU_TYPE}" -cores "$CORE_COUNT" -memory "$RAM_SIZE" \
  -name "$HN" -tags community-script,holaos -net0 virtio,bridge="$BRG",macaddr="$MAC$VLAN$MTU" -onboot 1 -ostype l26 -scsihw virtio-scsi-pci
VM_CREATED="yes"
pvesm alloc "$STORAGE" "$VMID" "$DISK0" 4M 1>&/dev/null
qm importdisk "$VMID" "${FILE}" "$STORAGE" ${DISK_IMPORT:-} 1>&/dev/null
# CloudInit-Drive: bevorzugt auf dem gewählten Storage, sonst erster Storage mit cloudinit-Content.
CLOUDINIT_STORE="$STORAGE"
if ! pvesm status -content cloudinit 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$STORAGE"; then
  FALLBACK_CI="$(first_storage_with_content cloudinit)"
  if [[ -n "$FALLBACK_CI" ]]; then
    msg_error "Storage $STORAGE ohne cloudinit-Content — nutze $FALLBACK_CI für CloudInit-Drive"
    CLOUDINIT_STORE="$FALLBACK_CI"
  fi
fi
if ! qm set "$VMID" -efidisk0 "${DISK0_REF}${FORMAT}" -scsi0 "${DISK1_REF},${DISK_CACHE}${THIN}size=${DISK_SIZE}" \
  -ide2 "${CLOUDINIT_STORE}:cloudinit" -boot order=scsi0 -serial0 socket >/dev/null; then
  msg_error "qm set (disks/cloudinit) failed — versuche CloudInit auf Alternativ-Storage"
  FALLBACK_CI="$(first_storage_with_content cloudinit)"
  if [[ -n "$FALLBACK_CI" && "$FALLBACK_CI" != "$CLOUDINIT_STORE" ]]; then
    CLOUDINIT_STORE="$FALLBACK_CI"
    qm set "$VMID" -efidisk0 "${DISK0_REF}${FORMAT}" -scsi0 "${DISK1_REF},${DISK_CACHE}${THIN}size=${DISK_SIZE}" \
      -ide2 "${CLOUDINIT_STORE}:cloudinit" -boot order=scsi0 -serial0 socket >/dev/null
  else
    exit 1
  fi
fi

# ---------- cloud-init user/net ----------
CI_PASS="$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 12)"
qm set "$VMID" --ciuser "${CI_USER}" --cipassword "${CI_PASS}" --ipconfig0 ip=dhcp --ciupgrade 0 >/dev/null
# Optionaler SSH-Key (Datei-Pfad oder Key-String aus Advanced-Setup / HOLAOS_SSH_PUBKEY).
if [[ -n "${CI_SSHKEY:-}" ]]; then
  SSHKEY_FILE="${TEMP_DIR}/holaos-ssh.pub"
  if [[ -f "$CI_SSHKEY" ]]; then cp "$CI_SSHKEY" "$SSHKEY_FILE"
  else echo "$CI_SSHKEY" > "$SSHKEY_FILE"; fi
  if qm set "$VMID" --sshkeys "$SSHKEY_FILE" >/dev/null 2>&1; then
    msg_ok "Cloud-Init: SSH-Key hinterlegt"
  else
    msg_error "SSH-Key konnte nicht gesetzt werden — weiter ohne Key"
  fi
fi
msg_ok "Cloud-Init: user=${CL}${BL}${CI_USER}${CL} / DHCP / qemu-agent on"

# ---------- vendor snippet for auto-install ----------
# FIX für: "volume 'local:snippets/holaos-...-vendor.yaml' does not exist" bei `qm start`:
# Ursache war `pvesm path <store>:snippets` (ohne Datei -> Fehler) + falscher Fallback
# /var/lib/vz/template/snippets (richtig: /var/lib/vz/snippets). Datei landete im falschen
# Verzeichnis, `qm set --cicustom` gab trotzdem 0 zurück, erst `qm start` schlug fehl und
# der ERR-Trap hat danach die VM gelöscht. Jetzt: korrekte Pfadauflösung + Verifikation
# VOR dem Start + Retry ohne cicustom statt VM-Verlust.
SNIPPET_OK="no"
VENDOR_VOLID=""
if [ "${AUTOINSTALL}" == "yes" ]; then
  SNIP_STORE="$(first_storage_with_content snippets)"
  if [ -n "${SNIP_STORE:-}" ]; then
    if SNIP_PATH="$(get_snippets_dir "$SNIP_STORE")"; then
      mkdir -p "${SNIP_PATH}"
      VENDOR_FILE="${SNIP_PATH}/holaos-${VMID}-vendor.yaml"
      EXTRA_ARGS=""
      [ "${HOLAOS_WITH_DESKTOP}" == "1" ] && EXTRA_ARGS="${EXTRA_ARGS} --with-desktop"
      [ "${HOLAOS_WITH_WEBTERM}" == "1" ] && EXTRA_ARGS="${EXTRA_ARGS} --with-webterm"
      cat > "${VENDOR_FILE}" <<EOF
#cloud-config
package_update: true
package_upgrade: false
# Ubuntu-Cloud-Images verweigern SSH-Passwort-Login per Default (Permission denied
# (publickey) trotz gesetztem cipassword). Zusammen mit dem Passwort aus `qm set`
# erlaubt das den Login per Konsole UND per SSH.
ssh_pwauth: true
packages: [curl, ca-certificates, qemu-guest-agent, openssh-server]
runcmd:
  - systemctl enable --now qemu-guest-agent
  - curl -fsSL ${HOLAOS_INSTALL_URL} -o /root/holaos-install.sh
  - bash /root/holaos-install.sh --ref ${HOLAOS_REF}${EXTRA_ARGS}
EOF
      chmod 0644 "${VENDOR_FILE}"
      VENDOR_VOLID="${SNIP_STORE}:snippets/holaos-${VMID}-vendor.yaml"
      # Verifizieren: Datei liegt wirklich da UND pvesm kennt das Volume.
      if [[ -f "$VENDOR_FILE" ]] \
        && pvesm list "$SNIP_STORE" 2>/dev/null | grep -q "holaos-${VMID}-vendor.yaml" \
        && pvesm path "$VENDOR_VOLID" >/dev/null 2>&1 \
        && qm set "$VMID" --cicustom "vendor=${VENDOR_VOLID}" >/dev/null 2>&1 \
        && qm config "$VMID" 2>/dev/null | grep -q "cicustom:.*${VENDOR_VOLID}"; then
        SNIPPET_OK="yes"
        msg_ok "Auto-install via ${CL}${BL}${VENDOR_VOLID}${CL}"
      else
        msg_error "cicustom-Verifikation fehlgeschlagen — fahre ohne vendor fort (manuell installieren)"
        qm set "$VMID" --delete cicustom >/dev/null 2>&1 || qm set "$VMID" --cicustom "" >/dev/null 2>&1 || true
        rm -f "$VENDOR_FILE" || true
        VENDOR_VOLID=""; SNIPPET_OK="no"
      fi
    else
      msg_error "Snippets-Pfad für ${SNIP_STORE} nicht auflösbar — skipping auto-install"
    fi
  else
    msg_error "No snippets storage — skipping auto-install (manual step below)"
  fi
fi

DESCRIPTION=$(cat <<EOF
<div align='center'>
  <h2>holaOS VM (${HN})</h2>
  <p>Ubuntu 24.04 + <a href='https://github.com/holaboss-ai/holaOS'>holaboss-ai/holaOS</a></p>
  <p>Inside the VM: <code>curl -fsSL ${HOLAOS_INSTALL_URL} | sudo bash</code></p>
  <p>Then: <code>cd ~/holaboss-ai && npm run desktop:dev</code> (needs display)</p>
</div>
EOF
)
qm set "$VMID" -description "$DESCRIPTION" >/dev/null
# scsi0 kommt aus dem ~2-3 GB Cloud-Image: `size=` in `qm set` wächst ein bereits
# importiertes Volume NICHT (Platte blieb 3,5 GB statt 30 GB -> ENOSPC im Installer).
# Daher explizit resizen und am `qm config` verifizieren.
qm resize "$VMID" scsi0 "$DISK_SIZE" >/dev/null
if qm config "$VMID" 2>/dev/null | grep -E '^scsi0:' | grep -q "size=${DISK_SIZE}"; then
  msg_ok "Disk scsi0 auf ${CL}${BL}${DISK_SIZE}${CL} erweitert"
else
  msg_error "Resize-Verifikation fehlgeschlagen (qm config scsi0 prüfen!)"
  qm config "$VMID" 2>/dev/null | grep -E '^scsi0:' || true
fi
msg_ok "Created holaOS VM ${CL}${BL}(${HN}, #${VMID})${CL}"

if [ "$START_VM" == "yes" ]; then
  msg_info "Starting VM"
  # Ab hier VM nicht mehr bei Fehlern löschen — lieber retten als zerstören.
  CLEANUP_ON_ERROR="no"
  set +e
  trap - ERR
  qm start "$VMID"
  START_RC=$?
  if [[ $START_RC -ne 0 && "$SNIPPET_OK" == "yes" ]]; then
    msg_error "Start mit vendor-Snippet fehlgeschlagen (RC $START_RC) — entferne cicustom und starte erneut"
    qm set "$VMID" --delete cicustom >/dev/null 2>&1 || qm set "$VMID" --cicustom "" >/dev/null 2>&1 || true
    SNIPPET_OK="no"
    qm start "$VMID"
    START_RC=$?
  fi
  # ERR-Trap wieder scharf (aber Cleanup bleibt aus — VM erhalten).
  trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
  set -e
  if [[ $START_RC -ne 0 ]]; then
    msg_error "qm start failed (RC $START_RC). VM bleibt erhalten: qm config $VMID / qm start $VMID"
    post_update_to_api_safe "failed" "$START_RC"
  else
    msg_ok "Started"
  fi
fi
post_update_to_api_safe "done" "none"
msg_ok "Done!\n"
# ---------- Abschluss-Check: IP + Erreichbarkeit, damit man sieht ob es sauber durchlief ----------
VM_IP=""; AGENT_STATE="unbekannt"
if [[ "${START_VM}" == "yes" && "${START_RC:-1}" -eq 0 ]]; then
  msg_info "Warte auf VM-IP (Guest Agent/DHCP, max ~2 Min)"
  for _try in $(seq 1 24); do
    if VM_IP="$(get_vm_ip "$VMID")"; then break; fi
    sleep 5
  done
  if [[ -n "$VM_IP" ]]; then msg_ok "VM-IP: ${CL}${BL}${VM_IP}${CL}"; AGENT_STATE="ok";
  else msg_error "Noch keine VM-IP (Agent/DHCP braucht noch) — unten Fallback prüfen"; AGENT_STATE="pending"; fi
fi
# PVE-LAN-IP robust bestimmen: Quell-IP der Default-Route (nicht blind hostname -I #1,
# das kann Docker/Tailscale sein). Fallback: erste RFC1918-Adresse aus hostname -I.
PVE_IP="$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -1 || true)"
if [[ -z "$PVE_IP" ]]; then
  PVE_IP="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)' | head -1 || true)"
fi
[[ -z "$PVE_IP" ]] && PVE_IP="<PVE-IP>"
# Erreichbarkeits-Checks direkt auf dem Host (sehen, nicht raten).
PVE_8006="unbekannt"; SSH22="unbekannt"
if ss -ltn 2>/dev/null | grep -q ':8006 '; then PVE_8006="offen (pveproxy lauscht)"; else PVE_8006="ZU (pveproxy/firewall prüfen!)"; fi
if systemctl is-active --quiet pveproxy 2>/dev/null; then PVE_8006="${PVE_8006}, pveproxy aktiv"; else PVE_8006="${PVE_8006}, pveproxy NICHT aktiv!"; fi
if [[ -n "$VM_IP" ]]; then
  if nc -z -w 3 "$VM_IP" 22 2>/dev/null; then SSH22="offen"; else SSH22="noch zu (bootet noch / Firewall)"; fi
  WEB7680="unbekannt"
  if nc -z -w 3 "$VM_IP" 7680 2>/dev/null; then WEB7680="offen"; else WEB7680="noch zu (Auto-Install läuft noch?)"; fi
fi
echo -e " ── holaOS Ergebnis ───────────────────────────────────"
if [[ "${START_VM}" == "yes" && "${START_RC:-1}" -eq 0 && -n "$VM_IP" ]]; then
  echo -e " Status:    ✅ GESTARTET, sauber durchgelaufen (Agent: ok, IP: $VM_IP)"
elif [[ "${START_VM}" == "yes" && "${START_RC:-1}" -eq 0 ]]; then
  echo -e " Status:    ⚠️  GESTARTET, aber IP noch pending (Agent: $AGENT_STATE)"
  echo -e " Prüfen:   qm status $VMID && qm guest cmd $VMID network-get-interfaces"
else
  echo -e " Status:    ⏸️  NICHT gestartet (START_VM=$START_VM) — manuell: qm start $VMID"
fi
echo -e " VMID:      $VMID   Hostname: $HN"
echo -e " CI-User:   ${CI_USER}   Passwort: ${CI_PASS}  (bitte notieren!)"
if [[ -n "$VM_IP" ]]; then
  echo -e " VM-IP:     $VM_IP  (SSH-Port 22: $SSH22)"
  echo -e " SSH:       ssh ${CI_USER}@${VM_IP}"
  echo -e " Webterminal: http://${VM_IP}:7680  (Port 7680: $WEB7680, Login mit VM-Benutzer)"
  echo -e " Proxmox-Web: https://${PVE_IP}:8006 → VM $VMID → Konsole (Port 8006: $PVE_8006)"
  echo -e " Hinweis:   holaOS selbst ist Electron (kein Webdienst) — Browser-Zugang = Webterminal + Proxmox-noVNC."
else
  echo -e " SSH:       ssh ${CI_USER}@<VM-IP>  (IP holen: qm guest cmd $VMID network-get-interfaces)"
  echo -e " Webterminal: kommt mit Auto-Install auf http://<VM-IP>:7680 (ttyd, Login mit VM-Benutzer)"
  echo -e " Proxmox-Web: https://${PVE_IP}:8006 → VM $VMID → Konsole (Port 8006: $PVE_8006)"
  echo -e " Hinweis:   holaOS selbst ist Electron (kein Webdienst) — Browser-Zugang = Webterminal + Proxmox-noVNC."
fi
echo -e " Diagnose auf dem Host:"
echo -e "   qm status $VMID; ss -ltn | grep 8006; systemctl status pveproxy --no-pager | head -5"
echo -e "   qm guest cmd $VMID network-get-interfaces  # echte VM-IP"
if [ "$SNIPPET_OK" == "yes" ]; then
  echo -e " Auto-Install: LÄUFT beim ersten Boot (~10-20 Min). Log in der VM:"
  echo -e "   tail -f /var/log/holaos-install.log  /  cloud-init status --wait"
else
  echo -e " Manuell in der VM installieren:"
  echo -e "   curl -fsSL ${HOLAOS_INSTALL_URL} | sudo bash -s -- --ref ${HOLAOS_REF}"
fi
echo -e " Starten (braucht Display/Konsole/RDP):"
echo -e "   cd ~/holaboss-ai && npm run desktop:dev"
echo -e " Repo: ${HOLAOS_REPO_URL}  Ref: ${HOLAOS_REF}"
echo -e " ─────────────────────────────────────────────────────"
