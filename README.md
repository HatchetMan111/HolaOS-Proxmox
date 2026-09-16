# HolaOS-Proxmox

Proxmox VE Helper-Scripts für **holaOS** (https://github.com/holaboss-ai/holaOS) — Ubuntu 24.04 VM + automatischer holaOS-Build.

## Voraussetzungen (Hardware)

holaOS braucht **moderne CPU-Instruktionen** (`bun` + Electron setzen **AVX2** voraus).
Auf alter Hardware ohne AVX2 scheitert der Auto-Install — Symptome: `Illegal instruction
(core dumped)` bei `bun --version` bzw. `bun install`, das ewig bei 100 % CPU dreht,
ohne je `node_modules` zu füllen.

- **Proxmox-Host mit AVX2-CPU** (Intel Haswell/2013+ bzw. AMD Ryzen/Excavator+). Prüfen:
  ```bash
  grep -o -m1 avx2 /proc/cpuinfo   # muss `avx2` ausgeben — sonst ist der Host zu alt
  ```
- **VM-CPU-Typ `x86-64-v3`** (nicht der Proxmox-Default `kvm64`!). Für eine bestehende VM:
  ```bash
  qm shutdown <VMID>   # CPU-Typ braucht gestoppte VM
  qm set <VMID> --cpu x86-64-v3
  qm start <VMID>
  qm guest exec <VMID> -- bash -c 'grep -o -m1 avx2 /proc/cpuinfo'   # Kontrolle
  ```
- **4 Cores / 8 GB RAM / 40 GB Disk** (Defaults des Skripts) — darunter wird der
  Electron/bun-Build extrem langsam oder stirbt (OOM/ENOSPC).
- **`snippets`-Storage** auf dem Host für den Auto-Install (sonst manuell installieren, s. unten).

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
HOLAOS_REF="main" HOLAOS_WITH_DESKTOP=1 HOLAOS_WITH_WEBTERM=1 \
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/HolaOS-Proxmox/main/holaos-vm.sh)"
```

`HOLAOS_WITH_WEBTERM=1` ist Standard: der Auto-Install richtet dann ein **Webterminal (ttyd) auf `http://<VM-IP>:7680`** ein (Login mit VM-Benutzer) — das ist die Browser-Oberfläche zur VM. holaOS selbst bleibt eine **Electron-Desktop-App** ohne eigenen Webserver.

## Falls kein Auto-Install (kein snippets-Storage)

In der VM als root:

```bash
curl -fsSL https://raw.githubusercontent.com/HatchetMan111/HolaOS-Proxmox/main/holaos-install.sh | sudo bash
# mit Desktop+RDP (für Electron-GUI):
curl -fsSL https://raw.githubusercontent.com/HatchetMan111/HolaOS-Proxmox/main/holaos-install.sh | sudo bash -s -- --with-desktop
```

Log: `tail -f /var/log/holaos-install.log` oder `cloud-init status --wait`

## Weboberflächen tot? (`:7680` / `:3389` nicht erreichbar)

**Wichtig vorweg:** holaOS selbst ist eine **Electron-Desktop-App ohne Webserver**.
Im Browser erreichbar sind nur das **Webterminal (`http://<VM-IP>:7680`, ttyd)**
und ggf. **RDP (`<VM-IP>:3389`)** — kein holaOS-Web-UI.

Checkliste, wenn `:7680` nicht antwortet:

1. **Abwarten:** Auto-Install braucht ohne Desktop ~5–15 Min, mit Desktop
   ~15–30 Min. ttyd kommt nach ~1 Min, RDP erst ganz am Schluss.
2. **Vom Proxmox-Host ohne SSH prüfen** (geht sobald der Guest Agent läuft):
   ```bash
   qm guest cmd 101 network-get-interfaces  # echte VM-IP?
   qm guest exec 101 -- bash -c 'tail -n 30 /var/log/holaos-install.log'
   qm guest exec 101 -- bash -c 'systemctl is-active ttyd xrdp; ss -ltn | grep -E "7680|3389"'
   ```
3. **In der VM** (SSH/Konsole/Webterminal): `holaos-status` zeigt Dienste + Log.
4. Typische Ursachen (in dieser Reihenfolge prüfen):
   - Install läuft noch (`tail` im Log bewegt sich) → einfach warten.
   - Platte voll (`df -h /`) → der Installer versucht `growpart` selbst;
     sonst auf dem Host `qm resize 101 scsi0 +20G`.
   - `ttyd` lauscht nur auf localhost → behoben (bindet jetzt `0.0.0.0`,
     Unit nutzt `/bin/login` absolut, UFW-Regeln für 22/7680/3389 werden gesetzt).
   - RDP schwarz trotz offenem Port → war Wayland; der Installer erzwingt
     jetzt Xorg (`WaylandEnable=false`) + `xrdp` in `ssl-cert`.
   - `400 not enough arguments / qm set <vmid>` im Host-Log → war die
     mehrzeilige VM-Beschreibung; ist jetzt einzeilig + best-effort.

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

Flags: `--dir PATH`, `--ref NAME`, `--with-desktop`, `--with-webterm`, `--skip-build`, `--help`

## Dateien

| Datei | Wo? | Zweck |
|---|---|---|
| `holaos-vm.sh` | Proxmox-Host (root) | VM erstellen |
| `holaos-install.sh` | in der VM (root) | holaOS installieren |
