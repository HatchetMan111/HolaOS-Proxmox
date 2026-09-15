#!/usr/bin/env bash
#
# holaOS in-VM installer (runs INSIDE the Ubuntu/Debian VM)
#
# Usage on a fresh Ubuntu 24.04 VM:
#   curl -fsSL https://raw.githubusercontent.com/HatchetMan111/HolaOS-Proxmox/main/holaos-install.sh | sudo bash
#   curl -fsSL https://raw.githubusercontent.com/HatchetMan111/HolaOS-Proxmox/main/holaos-install.sh | sudo bash -s -- --with-desktop
#
# What it does:
#   1. installs git, curl, build tools, Node.js 24.14.1, bun 1.3.6
#   2. clones https://github.com/holaboss-ai/holaOS.git
#   3. runs npm run desktop:install (bun install)
#   4. creates apps/desktop/.env from .env.example
#   5. runs npm run desktop:prepare-runtime:local
#   6. runs npm run desktop:typecheck (verification, no GUI needed)
#   7. stops BEFORE launching Electron (headless VMs have no display)
#
# After that, open the VM console / RDP and run:
#   cd ~/holaboss-ai && npm run desktop:dev
#
set -euo pipefail

REPO_URL="https://github.com/holaboss-ai/holaOS.git"
REF="main"
INSTALL_DIR="/root/holaboss-ai"
if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
  INSTALL_DIR="/home/${SUDO_USER}/holaboss-ai"
elif [ "$(id -u)" -ne 0 ] && [ -n "${HOME:-}" ]; then
  INSTALL_DIR="${HOME}/holaboss-ai"
fi
WITH_DESKTOP=0
WITH_WEBTERM=0
SKIP_BUILD=0
LOG_FILE="/var/log/holaos-install.log"

# Owner bestimmen (CI-User bzw. SUDO_USER), damit bun/npm-Cache + Checkout die richtigen Rechte haben.
OWNER_USER="${SUDO_USER:-root}"
OWNER_HOME="$(getent passwd "$OWNER_USER" | cut -d: -f6)"
[ -z "${OWNER_HOME:-}" ] && OWNER_HOME="$HOME"
BUN_DIR="${OWNER_HOME}/.bun"

NODE_VERSION="24.14.1"
BUN_VERSION="1.3.6"

GREEN='\033[1;92m'; YELLOW='\033[33m'; RED='\033[01;31m'; CYAN='\033[36m'; CL='\033[m'

usage() {
  cat <<EOF
holaOS in-VM installer

Usage:
  holaos-install.sh [OPTIONS]

Options:
  --dir PATH        checkout directory (default: ${INSTALL_DIR})
  --ref NAME        git branch/tag (default: main)
  --with-desktop    additionally install Ubuntu Desktop + xRDP
                    (needed to actually SEE the Electron app in the VM)
  --with-webterm    install ttyd web terminal on port 7680 (browser login)
  --skip-build      only install prerequisites + clone, no bun install/build
  -h, --help        show this help
EOF
}

msg()  { echo -e "${CYAN}==>${CL} $1" | tee -a "${LOG_FILE}" 2>/dev/null || echo -e "${CYAN}==>${CL} $1"; }
ok()   { echo -e "${GREEN}✓${CL} $1" | tee -a "${LOG_FILE}" 2>/dev/null || echo -e "${GREEN}✓${CL} $1"; }
warn() { echo -e "${YELLOW}!${CL} $1" | tee -a "${LOG_FILE}" 2>/dev/null || echo -e "${YELLOW}!${CL} $1"; }
fail() { echo -e "${RED}x${CL} $1" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) INSTALL_DIR="$2"; shift 2 ;;
    --ref|--branch) REF="$2"; shift 2 ;;
    --with-desktop) WITH_DESKTOP=1; shift ;;
    --with-webterm) WITH_WEBTERM=1; shift ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown option: $1 (see --help)" ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  fail "Please run as root (use sudo): curl ... | sudo bash"
fi

mkdir -p "$(dirname "${LOG_FILE}")"
touch "${LOG_FILE}"
exec > >(tee -a "${LOG_FILE}") 2>&1

msg "holaOS installer — ref=${REF} dir=${INSTALL_DIR}"

# ---------- 0. OS check ----------
if [ -f /etc/os-release ]; then
  . /etc/os-release
  msg "OS: ${PRETTY_NAME:-$ID}"
else
  warn "No /etc/os-release found, continuing anyway"
fi

# ---------- 1. system packages ----------
msg "Installing system packages (git, curl, build tools)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  git curl ca-certificates tar xz-utils unzip \
  build-essential python3 pkg-config \
  libsqlite3-dev libsecret-1-0 libgtk-3-0 libnss3 libasound2t64 \
  openssh-server qemu-guest-agent
systemctl enable --now qemu-guest-agent 2>/dev/null || true
ok "System packages ready ($(git --version))"

# ---------- 2. Node.js 24.14.1 ----------
install_node() {
  local node_os node_arch tarball tmp
  case "$(uname -m)" in
    x86_64|amd64) node_arch="x64" ;;
    arm64|aarch64) node_arch="arm64" ;;
    *) fail "Unsupported architecture: $(uname -m)" ;;
  esac
  case "$(uname -s)" in
    Linux) node_os="linux" ;;
    *) fail "Unsupported OS for managed Node install" ;;
  esac
  if command -v node >/dev/null 2>&1; then
    local major
    major="$(node --version | sed -E 's/^v([0-9]+).*/\1/')"
    if [[ "${major}" =~ ^[0-9]+$ ]] && [ "${major}" -ge 24 ]; then
      ok "Node.js already ok ($(node --version), $(npm --version))"
      return
    fi
    warn "Node.js $(node --version) too old, installing ${NODE_VERSION}"
  fi
  msg "Installing Node.js ${NODE_VERSION} (${node_os}-${node_arch})..."
  tmp="$(mktemp -d)"
  tarball="node-v${NODE_VERSION}-${node_os}-${node_arch}.tar.xz"
  curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/${tarball}" -o "${tmp}/${tarball}"
  tar -xJf "${tmp}/${tarball}" -C "${tmp}"
  rm -rf /usr/local/node-holaos
  mv "${tmp}/node-v${NODE_VERSION}-${node_os}-${node_arch}" /usr/local/node-holaos
  ln -sf /usr/local/node-holaos/bin/node /usr/local/bin/node
  ln -sf /usr/local/node-holaos/bin/npm /usr/local/bin/npm
  ln -sf /usr/local/node-holaos/bin/npx /usr/local/bin/npx
  ln -sf /usr/local/node-holaos/bin/corepack /usr/local/bin/corepack
  rm -rf "${tmp}"
  ok "Node.js ready ($(node --version), npm $(npm --version))"
}
install_node

# ---------- 3. bun 1.3.6 (packageManager in package.json) ----------
install_bun() {
  if command -v bun >/dev/null 2>&1 && bun --version 2>/dev/null | grep -q "^${BUN_VERSION}$"; then
    ok "bun already ok ($(bun --version))"
    return
  fi
  msg "Installing bun ${BUN_VERSION} for ${OWNER_USER} (${BUN_DIR})..."
  mkdir -p "${BUN_DIR}"
  curl -fsSL https://bun.sh/install | BUN_VERSION="${BUN_VERSION}" BUN_INSTALL="${BUN_DIR}" bash
  ln -sf "${BUN_DIR}/bin/bun" /usr/local/bin/bun
  ln -sf "${BUN_DIR}/bin/bunx" /usr/local/bin/bunx 2>/dev/null || true
  if [ "$OWNER_USER" != "root" ]; then chown -R "${OWNER_USER}:${OWNER_USER}" "${BUN_DIR}"; fi
  export PATH="${BUN_DIR}/bin:/usr/local/node-holaos/bin:${PATH}"
  ok "bun ready ($(bun --version))"
  if ! grep -q '.bun/bin' /etc/profile.d/holaos.sh 2>/dev/null; then
    echo 'export PATH="$HOME/.bun/bin:/usr/local/node-holaos/bin:$PATH"' > /etc/profile.d/holaos.sh
  fi
}
install_bun
export PATH="${BUN_DIR}/bin:/usr/local/node-holaos/bin:${PATH}"

# ---------- 4. optional desktop (for Electron GUI) ----------
if [ "${WITH_DESKTOP}" -eq 1 ]; then
  msg "Installing Ubuntu Desktop + xRDP (takes a while)..."
  apt-get install -y ubuntu-desktop-minimal xrdp
  systemctl enable --now xrdp
  ok "Desktop ready — connect via SPICE console or RDP"
fi

# ---------- 4b. optional web terminal (ttyd on :7680 with system login) ----------
if [ "${WITH_WEBTERM}" -eq 1 ]; then
  msg "Installing ttyd web terminal (port 7680, login with VM user account)..."
  if ! command -v ttyd >/dev/null 2>&1; then
    if apt-get install -y ttyd 2>/dev/null; then
      ok "ttyd installed via apt"
    else
      TTYD_VER="1.7.7"; TTYD_ARCH=""
      case "$(uname -m)" in
        x86_64|amd64) TTYD_ARCH="x86_64" ;;
        arm64|aarch64) TTYD_ARCH="aarch64" ;;
        *) fail "Unsupported architecture for ttyd: $(uname -m)" ;;
      esac
      curl -fsSL -o /usr/local/bin/ttyd "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VER}/ttyd.${TTYD_ARCH}"
      chmod +x /usr/local/bin/ttyd
      ok "ttyd ${TTYD_VER} installed to /usr/local/bin/ttyd"
    fi
  else
    ok "ttyd already installed"
  fi
  TTYD_BIN="$(command -v ttyd)"
  cat > /etc/systemd/system/ttyd.service <<EOF
[Unit]
Description=ttyd web terminal (holaOS)
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=${TTYD_BIN} --writable -p 7680 login
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now ttyd
  ok "Web terminal ready: http://<VM-IP>:7680 (login with VM user account)"
fi

# ---------- 5. clone / update ----------
msg "Cloning ${REPO_URL} (ref ${REF}) into ${INSTALL_DIR}..."
mkdir -p "$(dirname "${INSTALL_DIR}")"
if [ -d "${INSTALL_DIR}/.git" ]; then
  git -C "${INSTALL_DIR}" fetch origin
  git -C "${INSTALL_DIR}" checkout "${REF}"
  git -C "${INSTALL_DIR}" pull --ff-only origin "${REF}"
  ok "Repository updated"
else
  if [ -e "${INSTALL_DIR}" ]; then
    fail "Install dir exists but is not a git checkout: ${INSTALL_DIR}"
  fi
  git clone --branch "${REF}" "${REPO_URL}" "${INSTALL_DIR}"
  ok "Repository cloned"
fi
cd "${INSTALL_DIR}"
if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
  chown -R "${SUDO_USER}:${SUDO_USER}" "${INSTALL_DIR}"
fi

if [ "${SKIP_BUILD}" -eq 1 ]; then
  warn "--skip-build: stopping after clone."
  echo "Next: cd ${INSTALL_DIR} && npm run desktop:install"
  exit 0
fi

# bun install muss als Owner laufen (nicht root-nobody-quirks) — als SUDO_USER wenn vorhanden
run_as_owner() {
  if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    sudo -u "${SUDO_USER}" -H env PATH="${BUN_DIR}/bin:/usr/local/node-holaos/bin:/usr/local/bin:/usr/bin:/bin" "$@"
  else
    env PATH="${BUN_DIR}/bin:/usr/local/node-holaos/bin:/usr/local/bin:/usr/bin:/bin" "$@"
  fi
}

# ---------- 6. desktop:install (bun install) ----------
msg "Installing desktop dependencies (npm run desktop:install — bun install, can take 5-15 min)..."
run_as_owner npm run desktop:install
ok "Dependencies installed"

# ---------- 7. .env ----------
if [ ! -f apps/desktop/.env ]; then
  msg "Creating apps/desktop/.env from .env.example..."
  run_as_owner cp apps/desktop/.env.example apps/desktop/.env
else
  msg "apps/desktop/.env exists, leaving it unchanged"
fi

# ---------- 8. runtime + typecheck ----------
msg "Preparing local runtime bundle (npm run desktop:prepare-runtime:local)..."
run_as_owner npm run desktop:prepare-runtime:local
ok "Runtime staged"

msg "Verifying (npm run desktop:typecheck)..."
run_as_owner npm run desktop:typecheck
ok "Typecheck passed"

# ---------- 9. done ----------
cat > /etc/motd <<EOF

  _          _        ___  ____
 | |__  ___ | | __ _ / _ \/ ___|
 | '_ \/ _ \| |/ _\` | | | \___ \\
 | | | | (_) | | (_| | |_| |___) |
 |_| |_|\___/|_|\__,_|\___/|____/

 holaOS is installed in ${INSTALL_DIR}
 Start it (needs display / console / RDP):
   cd ${INSTALL_DIR} && npm run desktop:dev
 Docs: https://github.com/holaboss-ai/holaOS/blob/main/INSTALL.md
EOF

echo
ok "holaOS setup complete in ${INSTALL_DIR}"
echo -e "${YELLOW}NOTE:${CL} Electron needs a display. On a headless VM, open the"
echo -e "Proxmox console (SPICE) or RDP (with --with-desktop), then run:"
echo -e "  cd ${INSTALL_DIR} && npm run desktop:dev"
echo -e "Versions: node $(node --version) / npm $(npm --version) / bun $(bun --version)"
