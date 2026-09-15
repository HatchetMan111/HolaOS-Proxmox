# HolaOS-Proxmox

Proxmox VE Helper-Scripts für **holaOS** (https://github.com/holaboss-ai/holaOS) — Ubuntu 24.04 VM + automatischer holaOS-Build.

## Einzeiler auf dem Proxmox-Host (als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/HolaOS-Proxmox/main/holaos-vm.sh)"
```

Erstellt eine Ubuntu 24.04 Cloud-VM (Default: **4 Cores / 8 GB RAM / 40 GB Disk**), Cloud-Init (DHCP, User `hola`), und installiert holaOS beim ersten Boot automatisch (wenn ein `snippets`-Storage vorhanden ist).

Mit Advanced-Setup (Whiptail):
- wähle Default oder Advanced (Cores/RAM/Disk/Bridge/CI-User)
- Auto-Install ja/nein, VM sofort starten ja/nein

Mit Env-Overrides:

```bash
HOLAOS_REF="main" HOLAOS_WITH_DESKTOP=1 \
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/HolaOS-Proxmox/main/holaos-vm.sh)"
```

## Falls kein Auto-Install (kein snippets-Storage)

In der VM als root:

```bash
curl -fsSL https://raw.githubusercontent.com/HatchetMan111/HolaOS-Proxmox/main/holaos-install.sh | sudo bash
# mit Desktop+RDP (für Electron-GUI):
curl -fsSL https://raw.githubusercontent.com/HatchetMan111/HolaOS-Proxmox/main/holaos-install.sh | sudo bash -s -- --with-desktop
```

Log: `tail -f /var/log/holaos-install.log` oder `cloud-init status --wait`

## holaOS starten

holaOS ist eine **Electron-Desktop-App** — sie braucht ein Display. In der VM (SPICE-Konsole oder RDP bei `--with-desktop`):

```bash
cd ~/holaboss-ai && npm run desktop:dev
```

## Was der Installer tut (`holaos-install.sh`)

1. Systempakete (git, curl, build-essential, libsqlite3-dev, …)
2. Node.js **24.14.1** (aus `.nvmrc`) + **bun 1.3.6** (aus `packageManager`)
3. `git clone https://github.com/holaboss-ai/holaOS.git`
4. `npm run desktop:install` (bun install)
5. `apps/desktop/.env` aus `.env.example`
6. `npm run desktop:prepare-runtime:local`
7. `npm run desktop:typecheck`

Flags: `--dir PATH`, `--ref NAME`, `--with-desktop`, `--skip-build`, `--help`

## Dateien

| Datei | Wo? | Zweck |
|---|---|---|
| `holaos-vm.sh` | Proxmox-Host (root) | VM erstellen |
| `holaos-install.sh` | in der VM (root) | holaOS installieren |
