#!/bin/bash
# Deploy Container LXC Terraria Proxmox VE.

set -euo pipefail
trap 'echo "Error on line $LINENO" >&2; exit 1' ERR

# Usage/help
usage() {
  cat <<USAGE
Usage: $0 [CT_ID] [options]

Positional:
  CT_ID                 Container ID (default: ${CT_ID:-1550})

Options:
  -t, --template TEMPLATE_FAMILY   Template family or regex (env: TEMPLATE_FAMILY)
  -v, --version TERRARIA_VERSION   Terraria version (env: TERRARIA_VERSION)
  --dhcp                          Use DHCP for container network (env: NET_DHCP=yes)
  --ip NET_IP                     Container IP with CIDR (env: NET_IP)
  --gw NET_GW                     Gateway (env: NET_GW)
  -p, --port PORT                  Server port (env: SERVER_PORT)
  -m, --maxplayers N               Max players (env: MAX_PLAYERS)
  -h, --help                       Show this help
USAGE
}

# Parse arguments (simple long/short handling)
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -t|--template) TEMPLATE_FAMILY="$2"; shift 2 ;;
    -v|--version) TERRARIA_VERSION="$2"; shift 2 ;;
    --dhcp) NET_DHCP=yes; shift ;;
    --ip) NET_IP="$2"; shift 2 ;;
    --gw) NET_GW="$2"; shift 2 ;;
    -p|--port) SERVER_PORT="$2"; shift 2 ;;
    -m|--maxplayers) MAX_PLAYERS="$2"; shift 2 ;;
    --) shift; break ;;
    -*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    *) break ;;
  esac
done

# Allow env overrides for key vars (keeps existing defaults if not set)
TEMPLATE_FAMILY=${TEMPLATE_FAMILY:-${TEMPLATE_FAMILY:-'alpine-[0-9]+(\.[0-9]+)?-standard'}}
TERRARIA_VERSION=${TERRARIA_VERSION:-${TERRARIA_VERSION:-'1450'}}
NET_DHCP=${NET_DHCP:-${NET_DHCP:-no}}
NET_IP=${NET_IP:-${NET_IP:-'10.1.15.50/24'}}
NET_GW=${NET_GW:-${NET_GW:-'10.1.15.1'}}
SERVER_PORT=${SERVER_PORT:-${SERVER_PORT:-7777}}
MAX_PLAYERS=${MAX_PLAYERS:-${MAX_PLAYERS:-8}}


# Config - Adjust as needed (preserve any values set via flags/env)
CT_ID=${1:-${CT_ID:-1550}}
CT_NAME=${CT_NAME:-"terraria-server"}
STORAGE=${STORAGE:-"local-lvm"}
MEMORY=${MEMORY:-2048}
CORES=${CORES:-2}
DISK=${DISK:-8}
NET_GW=${NET_GW:-"10.1.15.1"}
NET_IP=${NET_IP:-"10.1.15.50/24"}
TERRARIA_VERSION=${TERRARIA_VERSION:-"1450"} # Version 1.4.5

echo "--- Starting Deploy of Terraria LXC (ID: $CT_ID) ---"

# Guided interactive setup (only when running interactively)
if [ -t 0 ]; then
  echo "Starting guided configuration. Press ENTER to accept defaults."
  read -rp "Use DHCP for container network? (y/N): " _use_dhcp
  if [[ "$_use_dhcp" =~ ^[Yy] ]]; then
    NET_DHCP=yes
  else
    NET_DHCP=no
    read -rp "Gateway [$NET_GW]: " input_gw
    NET_GW=${input_gw:-$NET_GW}
    read -rp "Container IP (with CIDR) [$NET_IP]: " input_ip
    NET_IP=${input_ip:-$NET_IP}
  fi

  read -rp "Server port [7777]: " input_port
  SERVER_PORT=${input_port:-7777}
  read -rp "Max players [8]: " input_players
  MAX_PLAYERS=${input_players:-8}
  read -rp "World size (1=small,2=medium,3=large) [2]: " input_world
  WORLD_SIZE=${input_world:-2}
  read -rp "Difficulty (0=classic,1=expert,2=master,3=journey) [1]: " input_diff
  DIFFICULTY=${input_diff:-1}
  read -rp "World name [Terraria]: " input_wname
  WORLD_NAME=${input_wname:-Terraria}
  read -rp "Seed (optional): " SEED
  read -rp "Password (leave empty for none): " PASSWORD
  read -rp "Message of the day (MOTD) (optional): " MOTD
  read -rp "Enable secure mode? (0/1) [0]: " input_secure
  SECURE=${input_secure:-0}
  read -rp "Auto-create world if missing? (y/N): " _autocreate
  if [[ "$_autocreate" =~ ^[Yy] ]]; then
    AUTOCREATE=$WORLD_SIZE
  else
    AUTOCREATE=0
  fi
else
  # non-interactive: keep current defaults
  NET_DHCP=no
  SERVER_PORT=7777
  MAX_PLAYERS=8
  WORLD_SIZE=2
  DIFFICULTY=1
  WORLD_NAME="Terraria"
  SEED=""
  PASSWORD=""
  MOTD=""
  SECURE=0
  AUTOCREATE=0
fi

# Build network option for pct
if [ "$NET_DHCP" = "yes" ]; then
  NET0_OPTS="name=eth0,bridge=vmbr0,firewall=0,ip=dhcp,type=veth"
else
  NET0_OPTS="name=eth0,bridge=vmbr0,firewall=0,gw=$NET_GW,ip=$NET_IP,type=veth"
fi
# Pre-flight checks
for cmd in pveam pct; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "$cmd not found. This script must be run on a Proxmox host with $cmd available." >&2
    exit 1
  fi
done

# check container id doesn't already exist
if pct status "$CT_ID" >/dev/null 2>&1; then
  echo "Container ID $CT_ID already exists. Aborting to avoid overwrite." >&2
  exit 1
fi

# basic storage check (best-effort)
if command -v pvesm >/dev/null 2>&1; then
  if ! pvesm status | grep -qw "$STORAGE"; then
    echo "Warning: storage '$STORAGE' not found in pvesm status; pct create may fail." >&2
  fi
fi

# 1. Download Template if not exists (prefer lightweight Alpine template)
# To change template, set environment variable `TEMPLATE_FAMILY` before running.
# Example: TEMPLATE_FAMILY="ubuntu-22.04-standard" ./install.sh

# ensure pveam index is fresh (ignore failure if offline)
pveam update >/dev/null 2>&1 || true

# try to find the latest available template for the chosen family
# Try to find the latest available template for the chosen family.
# Be tolerant: `pveam available` may fail or return nothing, so handle empty results
TEMPLATE_FILE=""
if available_out=$(pveam available 2>/dev/null || true); then
  TEMPLATE_FILE=$(printf "%s" "$available_out" | grep -Eo "${TEMPLATE_FAMILY}_[^ ]+" | sort -V | tail -n1 || true)
fi

TEMPLATE_PATH="/var/lib/vz/template/cache/$TEMPLATE_FILE"
if [ -z "$TEMPLATE_FILE" ]; then
  echo "No template found for '${TEMPLATE_FAMILY}' from pveam; refreshing index and retrying..." >&2
  pveam update >/dev/null 2>&1 || true
  TEMPLATE_FILE=$(pveam available 2>/dev/null | grep -Eo "${TEMPLATE_FAMILY}_[^ ]+" | sort -V | tail -n1 || true)
fi

if [ -z "$TEMPLATE_FILE" ]; then
  echo "Error: could not find any template matching '${TEMPLATE_FAMILY}'. Aborting." >&2
  exit 1
fi

if [ ! -f "$TEMPLATE_PATH" ]; then
  echo "Downloading template $TEMPLATE_FILE..."
  pveam update && pveam download local "$TEMPLATE_FILE"
fi

# 2. Create the Container
pct create $CT_ID $TEMPLATE_PATH \
  --arch amd64 --hostname $CT_NAME \
  --cores $CORES --memory $MEMORY --swap 512 \
  --storage $STORAGE --rootfs $DISK \
  --net0 $NET0_OPTS \
  --unprivileged 1 --onboot 1

pct start $CT_ID
echo "Waiting for network initialization..."
sleep 15

# 3. Internal Provisioning
pct exec $CT_ID -- sh -c "
  set -e
  if command -v dnf >/dev/null 2>&1; then
    PKG_UPDATE='dnf -y update'
    PKG_INSTALL='dnf -y install wget unzip tmux libicu'
  elif command -v apt-get >/dev/null 2>&1; then
    PKG_UPDATE='apt-get update'
    PKG_INSTALL='apt-get install -y wget unzip tmux libicu-dev'
  elif command -v apk >/dev/null 2>&1; then
    PKG_UPDATE='apk update'
    PKG_INSTALL='apk add --no-cache wget unzip tmux icu-libs'
  else
    echo 'No supported package manager found inside container' >&2
    exit 1
  fi
  eval "\$PKG_UPDATE"
  eval "\$PKG_INSTALL"
  mkdir -p /opt/terraria && cd /opt/terraria
  ZIP_URL="https://terraria.org/api/download/pc-dedicated-server/terraria-server-$TERRARIA_VERSION.zip"
  ZIP_FILE="terraria-server-${TERRARIA_VERSION}.zip"
  RETRIES=3
  ok=0
  for i in $(seq 1 $RETRIES); do
    if command -v wget >/dev/null 2>&1; then
      wget -q -O "$ZIP_FILE" "$ZIP_URL" || true
    elif command -v curl >/dev/null 2>&1; then
      curl -sSfL -o "$ZIP_FILE" "$ZIP_URL" || true
    else
      echo 'No downloader available inside container' >&2
      exit 1
    fi

    # optional checksum verification if provided via env TERRARIA_ZIP_SHA256
    if [ -n "${TERRARIA_ZIP_SHA256:-}" ]; then
      echo "${TERRARIA_ZIP_SHA256}  $ZIP_FILE" > /tmp/sha256sum.txt
      if sha256sum -c /tmp/sha256sum.txt >/dev/null 2>&1; then
        ok=1; break
      else
        echo "Checksum mismatch, retrying..." >&2
      fi
    else
      # basic archive sanity check
      if unzip -tq "$ZIP_FILE" >/dev/null 2>&1; then
        ok=1; break
      else
        echo "Archive test failed, retrying..." >&2
      fi
    fi
    sleep 2
  done
  if [ "$ok" -ne 1 ]; then
    echo "Failed to download or verify Terraria server zip" >&2
    exit 1
  fi
  unzip -q "$ZIP_FILE"
  # locate the folder that contains the Linux binary (works with BusyBox find)
  FIRST_BIN=$(find . -maxdepth 3 -type f -name 'TerrariaServer.bin.x86_64' -print | head -n1)
  if [ -n "\$FIRST_BIN" ]; then
    EXTRACT_DIR=$(dirname "\$FIRST_BIN")
    mv "\$EXTRACT_DIR"/* .
  else
    echo 'Could not find extracted Linux binaries; listing archive contents:' >&2
    ls -la
    exit 1
  fi
  chmod +x TerrariaServer.bin.x86_64 || true
  rm -rf "terraria-server-$TERRARIA_VERSION" "$TERRARIA_VERSION" "$ZIP_FILE"

  # create terraria user and set ownership
  if ! id -u terraria >/dev/null 2>&1; then
    if command -v adduser >/dev/null 2>&1; then
      adduser -D terraria || true
    else
      useradd -m -s /bin/sh terraria || true
    fi
  fi
  chown -R terraria:terraria /opt/terraria || true

  # generate server config
  cat > /opt/terraria/serverconfig.txt <<CONFIG
port=$SERVER_PORT
maxplayers=$MAX_PLAYERS
autocreate=$AUTOCREATE
worldname=$WORLD_NAME
seed=$SEED
difficulty=$DIFFICULTY
password=$PASSWORD
motd=$MOTD
secure=$SECURE
upnp=0
CONFIG

  # install systemd unit or supervisor to manage the server
  if command -v systemctl >/dev/null 2>&1; then
    cat > /etc/systemd/system/terraria.service <<SERVICE
[Unit]
Description=Terraria Server
After=network.target

[Service]
Type=simple
User=terraria
WorkingDirectory=/opt/terraria
ExecStart=/opt/terraria/TerrariaServer -config /opt/terraria/serverconfig.txt
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICE
    systemctl daemon-reload || true
    systemctl enable --now terraria.service || true
  else
    # fallback: try to install and start supervisor
    if command -v apk >/dev/null 2>&1; then
      apk add --no-cache supervisor || true
    elif command -v apt-get >/dev/null 2>&1; then
      apt-get install -y supervisor || true
    elif command -v dnf >/dev/null 2>&1; then
      dnf -y install supervisor || true
    fi

    mkdir -p /etc/supervisor.d || true
    cat > /etc/supervisord.conf <<SUPERVISOR
[unix_http_server]
file=/var/run/supervisor.sock

[supervisord]
childlogdir=/var/log

[program:terraria]
command=/opt/terraria/TerrariaServer -config /opt/terraria/serverconfig.txt
directory=/opt/terraria
user=terraria
autostart=true
autorestart=true
stdout_logfile=/var/log/terraria.log
stderr_logfile=/var/log/terraria.err
SUPERVISOR

    if command -v supervisord >/dev/null 2>&1; then
      supervisord -c /etc/supervisord.conf || true
    fi
  fi
"
echo "--- Terraria LXC Deployment Completed ---"
echo "Access with: pct enter $CT_ID"