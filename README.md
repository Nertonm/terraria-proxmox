Terraria LXC installer for Proxmox

Repo: nertonm/terraria-proxmox

Overview

This repository contains `install.sh` — a Proxmox LXC installer that deploys a Terraria dedicated server inside an LXC container. The script supports interactive guided configuration and environment/flag overrides.

Quick usage


Run directly (single command, interactive):

```bash
curl -sSL https://raw.githubusercontent.com/nertonm/terraria-proxmox/main/install.sh | sudo bash 
```

Non-interactive example with env/flags:

```
TEMPLATE_FAMILY="alpine-3.18-standard" TERRARIA_VERSION="1450" ./install.sh 1550 --ip 192.168.0.50/24 --gw 192.168.0.1 -p 7777 -m 8
```

Backup

A host-side helper is available at `scripts/backup_terraria.sh`:

```
./scripts/backup_terraria.sh 1550 ./backups
```

To restore:

```
./scripts/restore_terraria.sh 1550 ./backups/terraria-1550-20250101T120000.tar.gz
```

To rotate backups via cron (example keeping 7):

```
# run daily at 03:00
0 3 * * * /home/nertonm/terraria-proxmox/scripts/backup_terraria.sh 1550 /var/backups/terraria 7
```

Notes & recommendations

- The script requires `pveam`, `pct` (Proxmox host). Run it on the Proxmox host as root.
- The container is created unprivileged by default in the script (`--unprivileged 1`).
- Ensure `vmbr0` is configured and connected to the network you want the container on.
- Open or forward port `7777` (default Terraria port) on your router/firewall for internet access.
- The installer will attempt to create a `terraria` user inside the container and install a `systemd` unit or `supervisor` entry to manage the server automatically. Some LXC templates (Alpine) use OpenRC; the script will try to use `supervisor` if `systemd` is not available.

Security

- Keep the container unprivileged and restrict access via your Proxmox firewall / host firewall as needed.

