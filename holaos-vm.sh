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

source /dev/stdin <<<$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/api.func)

HOLAOS_INSTALL_URL="${HOLAOS_INSTALL_URL:-https://raw.githubusercontent.com/HatchetMan111/HolaOS-Proxmox/main/holaos-install.sh}"
HOLAOS_REF="${HOLAOS_REF:-main}"
HOLAOS_WITH_DESKTOP="${HOLAOS_WITH_DESKTOP:-0}"
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
set -e
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT
trap 'post_update_to_api "failed" "130"' SIGINT
trap 'post_update_to_api "failed" "143"' SIGTERM

function error_handler() {
  local exit_code="$?"; local line_number="$1"; local command="$2"
  post_update_to_api "failed" "$exit_code"
  echo -e "\n${RD}[ERROR]${CL} line ${RD}$line_number${CL}: exit ${RD}$exit_code${CL}: ${YW}$command${CL}\n"
  cleanup_vmid
}
function get_valid_nextid() {
  local try_id; try_id=$(pvesh get /cluster/nextid)
  while true; do
    if [ -f "/etc/pve/qemu-server/${try_id}.conf" ] || [ -f "/etc/pve/lxc/${try_id}.conf" ]; then try_id=$((try_id+1)); continue; fi
    break
  done
  echo "$try_id"
}
function cleanup_vmid() { if qm status $VMID &>/dev/null; then qm stop $VMID &>/dev/null; qm destroy $VMID &>/dev/null; fi; }
function cleanup() {
  local exit_code=$?
  popd >/dev/null 2>&1 || true
  if [[ "${POST_TO_API_DONE:-}" == "true" && "${POST_UPDATE_DONE:-}" != "true" ]]; then
    if [[ $exit_code -eq 0 ]]; then post_update_to_api "done" "none"; else post_update_to_api "failed" "$exit_code"; fi
  fi
  rm -rf "${TEMP_DIR:-}"
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
  CI_USER="hola"; AUTOINSTALL="yes"; METHOD="default"
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
  if DS=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Disk in GiB (min 20, empfohlen 40)" 8 58 40 --title "DISK" --cancel-button Exit 3>&1 1>&2 2>&3); then
    DS=$(echo "$DS" | tr -d ' '); [[ "$DS" =~ ^[0-9]+G$ ]] || DS="${DS}G"
    DISK_SIZE="$DS"; echo -e "${DISKSIZE}${BOLD}${DGN}Disk: ${BGN}$DISK_SIZE${CL}"
  else exit-script; fi
  if BRG=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Bridge" 8 58 vmbr0 --title "BRIDGE" --cancel-button Exit 3>&1 1>&2 2>&3); then
    [ -z "$BRG" ] && BRG="vmbr0"; echo -e "${BRIDGE}${BOLD}${DGN}Bridge: ${BGN}$BRG${CL}"
  else exit-script; fi
  if CI_USER=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Cloud-Init user (SSH login)" 8 58 hola --title "CI USER" --cancel-button Exit 3>&1 1>&2 2>&3); then
    [ -z "$CI_USER" ] && CI_USER="hola"; echo -e "${DEFAULT}${BOLD}${DGN}CI user: ${BGN}$CI_USER${CL}"
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
post_to_api_vm

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
qm create $VMID -agent 1${MACHINE} -tablet 0 -localtime 1 -bios ovmf${CPU_TYPE} -cores $CORE_COUNT -memory $RAM_SIZE \
  -name $HN -tags community-script,holaos -net0 virtio,bridge=$BRG,macaddr=$MAC$VLAN$MTU -onboot 1 -ostype l26 -scsihw virtio-scsi-pci
pvesm alloc $STORAGE $VMID $DISK0 4M 1>&/dev/null
qm importdisk $VMID ${FILE} $STORAGE ${DISK_IMPORT:-} 1>&/dev/null
qm set $VMID -efidisk0 ${DISK0_REF}${FORMAT} -scsi0 ${DISK1_REF},${DISK_CACHE}${THIN}size=${DISK_SIZE} \
  -ide2 ${STORAGE}:cloudinit -boot order=scsi0 -serial0 socket >/dev/null

# ---------- cloud-init user/net ----------
CI_PASS="$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 12)"
qm set $VMID --ciuser "${CI_USER}" --cipassword "${CI_PASS}" --ipconfig0 ip=dhcp --ciupgrade 0 >/dev/null
msg_ok "Cloud-Init: user=${CL}${BL}${CI_USER}${CL} / DHCP / qemu-agent on"

# ---------- vendor snippet for auto-install ----------
SNIPPET_OK="no"
if [ "${AUTOINSTALL}" == "yes" ]; then
  SNIP_STORE="$(pvesm status -content snippets 2>/dev/null | awk 'NR>1 {print $1}' | head -1)"
  if [ -n "${SNIP_STORE:-}" ]; then
    SNIP_PATH="$(pvesm path ${SNIP_STORE}:snippets 2>/dev/null || echo "/var/lib/vz/template/snippets")"
    mkdir -p "${SNIP_PATH}"
    VENDOR_FILE="${SNIP_PATH}/holaos-${VMID}-vendor.yaml"
    EXTRA_ARGS=""
    [ "${HOLAOS_WITH_DESKTOP}" == "1" ] && EXTRA_ARGS="--with-desktop"
    cat > "${VENDOR_FILE}" <<EOF
#cloud-config
package_update: true
packages: [curl, ca-certificates, qemu-guest-agent]
runcmd:
  - [ systemctl, enable, --now, qemu-guest-agent ]
  - [ bash, -c, "curl -fsSL ${HOLAOS_INSTALL_URL} -o /root/holaos-install.sh && bash /root/holaos-install.sh --ref ${HOLAOS_REF} ${EXTRA_ARGS} 2>&1 | tee /var/log/holaos-install.log" ]
EOF
    if qm set $VMID --cicustom "vendor=${SNIP_STORE}:snippets/holaos-${VMID}-vendor.yaml" >/dev/null 2>&1; then
      SNIPPET_OK="yes"
      msg_ok "Auto-install via ${CL}${BL}${SNIP_STORE}:snippets/holaos-${VMID}-vendor.yaml${CL}"
    else
      msg_error "cicustom failed — manual install needed"
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
qm set $VMID -description "$DESCRIPTION" >/dev/null
qm resize $VMID scsi0 ${DISK_SIZE} >/dev/null
msg_ok "Created holaOS VM ${CL}${BL}(${HN}, #${VMID})${CL}"

if [ "$START_VM" == "yes" ]; then msg_info "Starting VM"; qm start $VMID; msg_ok "Started"; fi
post_update_to_api "done" "none"
msg_ok "Done!\n"
echo -e " ── holaOS Zugang ─────────────────────────────────────"
echo -e " VMID:      $VMID   Hostname: $HN"
echo -e " CI-User:   ${CI_USER}   Passwort: ${CI_PASS}  (bitte notieren!)"
echo -e " SSH:       ssh ${CI_USER}@<VM-IP>  (IP: qm guest cmd $VMID network-get-interfaces)"
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
