#!/bin/bash
# Deploy Container LXC Terraria Proxmox VE
# Refactored for resilience, idempotency, MULTI-DISTRO compatibility, and usability.

set -euo pipefail
trap 'echo "Error on line $LINENO" >&2; exit 1' ERR

# -----------------------------------------------------------------------------
# Configuration & Defaults
# -----------------------------------------------------------------------------

# Host Locale
export LC_ALL=${LC_ALL:-C}
export LANG=${LANG:-C}

# Container Defaults
CT_ID=${CT_ID:-1550}
CT_NAME=${CT_NAME:-"terraria-server"}
STORAGE=${STORAGE:-"local-lvm"}
MEMORY=${MEMORY:-2048}
CORES=${CORES:-2}
DISK=${DISK:-8}

# Network Defaults (Resilient)
NET_DHCP="yes"
NET_GW=""
NET_IP=""

# Terraria Server Defaults
TERRARIA_VERSION=${TERRARIA_VERSION:-"1450"}
SERVER_PORT=${SERVER_PORT:-7777}
MAX_PLAYERS=${MAX_PLAYERS:-8}
WORLD_SIZE=${WORLD_SIZE:-2}     # 1=small, 2=medium, 3=large
DIFFICULTY=${DIFFICULTY:-1}     # 0=classic, 1=expert, 2=master, 3=journey
WORLD_NAME=${WORLD_NAME:-"Terraria"}
WORLD_EVIL=${WORLD_EVIL:-1}     # 1=Random, 2=Corrupt, 3=Crimson
SEED=${SEED:-""}
SECRET_SEED=${SECRET_SEED:-""}
PASSWORD=${PASSWORD:-""}
MOTD=${MOTD:-"Welcome explicitly"}
SECURE=${SECURE:-0}
AUTOCREATE=${AUTOCREATE:-0}

# Host Integrations
ENABLE_BACKUP=${ENABLE_BACKUP:-0}
BACKUP_SCHEDULE=${BACKUP_SCHEDULE:-"daily"} # daily, hourly, 6h, weekly, or custom cron
ENABLE_DISCORD=${ENABLE_DISCORD:-0}
ENABLE_MONITOR=${ENABLE_MONITOR:-0}
DISCORD_URL=${DISCORD_URL:-""}
ENABLE_BOT=${ENABLE_BOT:-0}
BOT_TOKEN=${BOT_TOKEN:-""}
BOT_USER_ID=${BOT_USER_ID:-""}

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -----------------------------------------------------------------------------
# 1. Wizard & Argument Parsing
# -----------------------------------------------------------------------------

usage() {
  cat <<USAGE
Usage: $0 [CT_ID] [options]

Positional:
  CT_ID                 Container ID (default: ${CT_ID})

Options:
  -t, --template FAMILY    Template family (e.g. alpine, ubuntu)
  -v, --version VER        Terraria version (default: 1450)
  --static                 Use static IP (requires --ip and --gw)
  --ip CIDR                Static IP (e.g. 10.1.15.50/24)
  --gw IP                  Gateway (e.g. 10.1.15.1)
  -p, --port PORT          Server port
  -m, --maxplayers N       Max players
  --world-name NAME        World Name (default: Terraria)
  --evil TYPE              World Evil (1=Random, 2=Corrupt, 3=Crimson)
  --seed TEXT              World Seed
  --secret-seed TEXT       Enable Secret Seed (e.g. 'not the bees')
  --enable-backup          Enable automated backups
  --backup-schedule TYPE   Schedule: daily, hourly, 6h, weekly, or "cron expr" (def: daily)
  --enable-monitor         Enable resource monitoring (RAM usage > 90%)
  --discord-url URL        Configure Discord Webhook URL (Notifications)
  --enable-bot             Enable Discord Commander Bot
  --bot-token TOKEN        Discord Bot Token
  --bot-userid ID          Your Discord User ID (Admin)
  -h, --help               Show this help
USAGE
}

# Variable to track if arguments were provided
ARGS_PROVIDED=0
if [ "$#" -gt 0 ]; then
    ARGS_PROVIDED=1
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -t|--template) TEMPLATE_FAMILY="$2"; shift 2 ;;
    -v|--version) TERRARIA_VERSION="$2"; shift 2 ;;
    --static) NET_DHCP="no"; shift ;;
    --dhcp) NET_DHCP="yes"; shift ;;
    --ip) NET_IP="$2"; NET_DHCP="no"; shift 2 ;;
    --gw) NET_GW="$2"; shift 2 ;;
    -p|--port) SERVER_PORT="$2"; shift 2 ;;
    -m|--maxplayers) MAX_PLAYERS="$2"; shift 2 ;;
    --world-name) WORLD_NAME="$2"; shift 2 ;;
    --evil) WORLD_EVIL="$2"; shift 2 ;;
    --seed) SEED="$2"; shift 2 ;;
    --enable-backup) ENABLE_BACKUP=1; shift ;;
    --backup-schedule) ENABLE_BACKUP=1; BACKUP_SCHEDULE="$2"; shift 2 ;;
    --enable-monitor) ENABLE_MONITOR=1; shift ;;
    --discord-url) ENABLE_DISCORD=1; DISCORD_URL="$2"; shift 2 ;;
    --enable-bot) ENABLE_BOT=1; shift ;;
    --bot-token) ENABLE_BOT=1; BOT_TOKEN="$2"; shift 2 ;;
    --bot-userid) ENABLE_BOT=1; BOT_USER_ID="$2"; shift 2 ;;
    -*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    *) 
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        CT_ID="$1"; shift
      else
        break
      fi
      ;;
  esac
done

# Wizard Interactive Mode
if [ "$ARGS_PROVIDED" -eq 0 ] && [ -t 0 ]; then
  echo "--- Interactive Configuration ---"
  echo "Press ENTER to accept defaults."
  
  read -rp "Container ID [$CT_ID]: " input_id
  CT_ID=${input_id:-$CT_ID}

  read -rp "Terraria Version [$TERRARIA_VERSION]: " input_ver
  TERRARIA_VERSION=${input_ver:-$TERRARIA_VERSION}

  read -rp "Use DHCP? (Y/n) [Y]: " input_dhcp
  if [[ "$input_dhcp" =~ ^[Nn] ]]; then
      NET_DHCP="no"
      read -rp "Static IP (CIDR) [10.1.15.50/24]: " input_ip
      NET_IP=${input_ip:-"10.1.15.50/24"}
      read -rp "Gateway [10.1.15.1]: " input_gw
      NET_GW=${input_gw:-"10.1.15.1"}
  else
      NET_DHCP="yes"
  fi

  read -rp "Server Port [$SERVER_PORT]: " input_port
  SERVER_PORT=${input_port:-$SERVER_PORT}

  read -rp "Max Players [$MAX_PLAYERS]: " input_players
  MAX_PLAYERS=${input_players:-$MAX_PLAYERS}

  read -rp "World Name [$WORLD_NAME]: " input_wname
  WORLD_NAME=${input_wname:-$WORLD_NAME}
  
  read -rp "World Size (1=small, 2=medium, 3=large) [$WORLD_SIZE]: " input_size
  WORLD_SIZE=${input_size:-$WORLD_SIZE}

  read -rp "Difficulty (0=classic, 1=expert, 2=master, 3=journey) [$DIFFICULTY]: " input_diff
  DIFFICULTY=${input_diff:-$DIFFICULTY}

  read -rp "World Evil (1=Random, 2=Corrupt, 3=Crimson) [$WORLD_EVIL]: " input_evil
  WORLD_EVIL=${input_evil:-$WORLD_EVIL}

  read -rp "Seed (optional): " input_seed
  SEED=${input_seed:-$SEED}
  
  read -rp "Secret Seed (optional, e.g. 'not the bees'): " input_secret
  SECRET_SEED=${input_secret:-$SECRET_SEED}

  read -rp "Password (empty for none): " input_pass
  PASSWORD=${input_pass:-$PASSWORD}

  read -rp "Message of the day (MOTD) [$MOTD]: " input_motd
  MOTD=${input_motd:-$MOTD}

  read -rp "Enable secure mode? (0/1) [$SECURE]: " input_secure
  SECURE=${input_secure:-$SECURE}

  read -rp "Auto-create world if missing? (y/N) [N]: " input_autocreate
  if [[ "$input_autocreate" =~ ^[Yy] ]]; then
    # Auto-create requires passing the world size (1, 2, or 3)
    AUTOCREATE=$WORLD_SIZE
  else
    AUTOCREATE=0
  fi

  read -rp "Enable automated backups? (y/N) [N]: " input_backup
  if [[ "$input_backup" =~ ^[Yy] ]]; then
    ENABLE_BACKUP=1
    echo "Backup Frequency:"
    echo "  1) Daily at 04:00 (default)"
    echo "  2) Hourly"
    echo "  3) Every 6 hours"
    echo "  4) Weekly (Sunday at 04:00)"
    echo "  5) Custom Cron Expression"
    read -rp "Select option [1]: " input_freq
    case "${input_freq:-1}" in
      1) BACKUP_SCHEDULE="daily" ;;
      2) BACKUP_SCHEDULE="hourly" ;;
      3) BACKUP_SCHEDULE="6h" ;;
      4) BACKUP_SCHEDULE="weekly" ;;
      5) read -rp "Enter Cron Expression (e.g. '0 12 * * *'): " BACKUP_SCHEDULE ;;
      *) BACKUP_SCHEDULE="daily" ;;
    esac
  fi

  read -rp "Enable Resource Monitoring (alert if RAM > 90%)? (y/N) [N]: " input_monitor
  if [[ "$input_monitor" =~ ^[Yy] ]]; then
    ENABLE_MONITOR=1
  fi

  read -rp "Setup Discord Notifications (Webhook)? (y/N) [N]: " input_discord
  if [[ "$input_discord" =~ ^[Yy] ]]; then
    ENABLE_DISCORD=1
    read -rp "Webhook URL: " DISCORD_URL
  fi

  read -rp "Enable Discord Commander Bot (Control via chat)? (y/N) [N]: " input_bot
  if [[ "$input_bot" =~ ^[Yy] ]]; then
    ENABLE_BOT=1
    echo "You need a Bot Token from discord.com/developers and your User ID."
    read -rp "Bot Token: " BOT_TOKEN
    read -rp "Your User ID: " BOT_USER_ID
  fi
  
  echo "---------------------------------"
fi


# -----------------------------------------------------------------------------
# 2. Idempotency Check
# -----------------------------------------------------------------------------

# Helper for host-side notifications
notify_install() {
  local status="$1"
  local title="$2"
  local msg="$3"
  local script_dir="$(dirname "$0")"
  
  if [ -x "$script_dir/scripts/discord_webhook.sh" ] && [ -n "${DISCORD_URL:-}" ]; then
    local args=(--title "$title" --desc "$msg" --status "$status" --url "$DISCORD_URL")
    args+=(--field "CT ID:$CT_ID")
    
    # Try to get IP
    local ip=$(pct exec "$CT_ID" -- ip -4 a s eth0 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -n1 || echo "Unknown")
    args+=(--field "Server Address:$ip")
    
    "$script_dir/scripts/discord_webhook.sh" "${args[@]}" || true
  fi
}

trap 'notify_install "error" "Installation Failed" "Terraria installation failed for CT $CT_ID."; echo "Error on line $LINENO" >&2; exit 1' ERR

if [ "$ENABLE_DISCORD" -eq 1 ] && [ -n "$DISCORD_URL" ]; then
  notify_install "info" "Installation Started" "Beginning deployment of Terraria Server on CT $CT_ID..."
fi

DO_CREATE=1

if command -v pct >/dev/null && pct status "$CT_ID" >/dev/null 2>&1; then
  echo "Container '$CT_ID' already exists."
  read -rp "Do you want to skip creation and run provisioning only? (y/N): " _choice
  if [[ "$_choice" =~ ^[Yy] ]]; then
    DO_CREATE=0
  else
    echo "Aborting to prevent overwrite."
    exit 1
  fi
fi

# -----------------------------------------------------------------------------
# 3. Container Creation with Retry Logic
# -----------------------------------------------------------------------------

create_container_attempt() {
    local target_storage="$1"
    
    # Template Logic
    # Default to 'system' which maps to a specific Debian 13 template file
    TEMPLATE_FAMILY=${TEMPLATE_FAMILY:-"system"}

    # If TEMPLATE_FAMILY is 'system' and no explicit TEMPLATE_FILE_OVERRIDE
    # was provided, use the known Debian 13 template file name.
    if [ "${TEMPLATE_FAMILY}" = "system" ] && [ -z "${TEMPLATE_FILE_OVERRIDE:-}" ]; then
      TEMPLATE_FILE_OVERRIDE="debian-13-standard_13.1-2_amd64.tar.zst"
    fi
    
    # Update pveam if needed
    pveam update >/dev/null 2>&1 || true
    
    if [ -n "${TEMPLATE_FILE_OVERRIDE:-}" ]; then
        TEMPLATE_FILE="$TEMPLATE_FILE_OVERRIDE"
    else
        # Robust template search: match templates whose name starts with the family
        TEMPLATE_FILE=$(pveam available | awk '{print $1}' | grep -iE "^${TEMPLATE_FAMILY}" | sort -V | tail -n1)
    fi

    if [ -z "$TEMPLATE_FILE" ]; then
        echo "Error: No template found for '$TEMPLATE_FAMILY'."
        return 1
    fi
    
    TEMPLATE_PATH="/var/lib/vz/template/cache/$TEMPLATE_FILE"
    if [ ! -f "$TEMPLATE_PATH" ]; then
        echo "Downloading template $TEMPLATE_FILE..."
        pveam download local "$TEMPLATE_FILE" || return 1
    fi

    # Network Config
    if [ "$NET_DHCP" = "yes" ]; then
        NET0_OPTS="name=eth0,bridge=vmbr0,firewall=0,ip=dhcp,type=veth"
    else
        # Ensure defaults if empty
        if [ -z "$NET_IP" ]; then NET_IP="10.1.15.50/24"; fi
        if [ -z "$NET_GW" ]; then NET_GW="10.1.15.1"; fi
        NET0_OPTS="name=eth0,bridge=vmbr0,firewall=0,gw=$NET_GW,ip=$NET_IP,type=veth"
    fi

    # DNS Fix: Force 8.8.8.8
    # Using explicit --nameserver checks for valid DNS on container create
    echo "Attempting to create container on storage '$target_storage'..."
    pct create "$CT_ID" "$TEMPLATE_PATH" \
        --arch amd64 --hostname "$CT_NAME" \
        --cores "$CORES" --memory "$MEMORY" --swap 512 \
        --storage "$target_storage" --rootfs "$DISK" \
        --net0 "$NET0_OPTS" \
        --nameserver "8.8.8.8" \
        --unprivileged 1 \
        --onboot 1
}

if [ "$DO_CREATE" -eq 1 ]; then
    echo "--- Creating Container $CT_ID ---"
    
    # Retry/Fallback Logic
    if ! create_container_attempt "$STORAGE"; then
        echo "Creation failed on primary storage '$STORAGE'."
        
        # Try fallback to 'local' if it's different and available
        if [ "$STORAGE" != "local" ] && pvesm status | grep -qw "local"; then
            echo "Retrying on fallback storage 'local'..."
            if ! create_container_attempt "local"; then
                echo "Fallback creation failed."
                exit 1
            fi
        else
            echo "No fallback storage available or already tried."
            exit 1
        fi
    fi

    echo "Starting container..."
    pct start "$CT_ID"
    echo "Waiting for network (10s)..."
    sleep 10
fi

# -----------------------------------------------------------------------------
# 4. Provisioning (Inner Script - Multi-Distro)
# -----------------------------------------------------------------------------
echo "--- Starting Provisioning ---"

# Read Bot Code into variable for injection
if [ "$ENABLE_BOT" -eq 1 ] && [ -f "$PROJECT_DIR/scripts/discord_bot.py" ]; then
    BOT_CODE=$(cat "$PROJECT_DIR/scripts/discord_bot.py")
else
    BOT_CODE=""
fi

# We export variables to the 'env' command so they are available in the shell spawned by 'pct exec'.
pct exec "$CT_ID" -- env \
  TERRARIA_VERSION="$TERRARIA_VERSION" \
  SERVER_PORT="$SERVER_PORT" \
  MAX_PLAYERS="$MAX_PLAYERS" \
  WORLD_NAME="$WORLD_NAME" \
  WORLD_SIZE="$WORLD_SIZE" \
  DIFFICULTY="$DIFFICULTY" \
  WORLD_EVIL="$WORLD_EVIL" \
  SEED="$SEED" \
  SECRET_SEED="$SECRET_SEED" \
  PASSWORD="$PASSWORD" \
  MOTD="$MOTD" \
  SECURE="$SECURE" \
  AUTOCREATE="$AUTOCREATE" \
  DISCORD_URL="$DISCORD_URL" \
  BOT_TOKEN="$BOT_TOKEN" \
  BOT_USER_ID="$BOT_USER_ID" \
  BOT_CODE="$BOT_CODE" \
  LC_ALL=C \
  /bin/sh -s <<'EOF'
    set -e
    
    # Save Discord URL for internal scripts (launch.sh)
    if [ -n "$DISCORD_URL" ]; then
       echo "$DISCORD_URL" > /opt/terraria/.discord_url
       chmod 600 /opt/terraria/.discord_url
       chown terraria:terraria /opt/terraria/.discord_url
    fi

    # Create the Launch Wrapper (handles notifications)
    cat > /opt/terraria/launch.sh <<'LAUNCH'
#!/bin/bash
# Wrapper to run Terraria and handle Start/Stop notifications
DIR="/opt/terraria"
BIN="$DIR/TerrariaServer.bin.x86_64"
CONF="$DIR/serverconfig.txt"
URL_FILE="$DIR/.discord_url"

# Simple Notification Function
notify() {
    [ ! -f "$URL_FILE" ] && return
    local title="$1"
    local color="$2" # integer
    local desc="$3"
    local url=$(cat "$URL_FILE")
    [ -z "$url" ] && return
    
    # Try to get local IP
    local ip=$(ip -4 a s eth0 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -n1 || echo "Unknown")

    # JSON Payload (minimal)
    local json=$(cat <<J
{
  "embeds": [{
    "title": "$title",
    "description": "$desc",
    "color": $color,
    "fields": [
      { "name": "Server IP", "value": "$ip", "inline": true }
    ],
    "footer": { "text": "Terraria Server Status" },
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  }]
}
J
)
    curl -s -H "Content-Type: application/json" -d "$json" "$url" >/dev/null || true
}

notify "Server Starting" 3447003 "Terraria Server is booting up..."

# Run the Server
"$BIN" -config "$CONF"
EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
    notify "Server Stopped" 15158332 "Server shut down normally."
else
    notify "Server Crashed" 15158332 "Server exited with error code $EXIT_CODE."
fi

exit $EXIT_CODE
LAUNCH
    chmod +x /opt/terraria/launch.sh
    chown terraria:terraria /opt/terraria/launch.sh

    # --- DISCORD COMMANDER BOT SETUP (INTERNAL) ---
    if [ -n "$BOT_CODE" ]; then
        echo "Setting up Internal Discord Bot..."
        echo "$BOT_CODE" > /opt/terraria/discord_bot.py
    fi

    # Ensure DNS resolution via fallback if DHCP failed to provide it
    if ! ping -c 1 google.com >/dev/null 2>&1; then
        echo "Network check failed. Forcing DNS 8.8.8.8 in /etc/resolv.conf..."
        echo "nameserver 8.8.8.8" > /etc/resolv.conf
    fi

    echo "Detecting Package Manager..."
    if command -v apk >/dev/null 2>&1; then
        echo "Alpine detected."
        apk update
        apk add --no-cache bash findutils icu-libs wget unzip tmux curl ca-certificates iproute2 python3 py3-pip
    elif command -v apt-get >/dev/null 2>&1; then
      echo "Debian/Ubuntu detected."
      apt-get update
      apt-get install -y wget unzip tmux libicu-dev supervisor curl ca-certificates iproute2 python3 python3-venv python3-pip
    elif command -v dnf >/dev/null 2>&1; then
        echo "Fedora/RHEL detected."
        dnf install -y wget unzip tmux libicu curl ca-certificates iproute python3 python3-pip
    else
        echo "Error: No supported package manager found (apk, apt, dnf)."
        exit 1
    fi
    
    # Finalize Bot Installation (Inside Container)
    if [ -n "$BOT_TOKEN" ]; then
        echo "Finalizing Bot Python Environment..."
        python3 -m venv /opt/terraria/.bot_venv
        /opt/terraria/.bot_venv/bin/pip install discord.py --quiet
        chown -R terraria:terraria /opt/terraria/.bot_venv /opt/terraria/discord_bot.py
    fi
    
    # Create User 'terraria' with predictable home and shell
    if ! id -u terraria >/dev/null 2>&1; then
      echo "Creating user terraria..."
      if command -v apk >/dev/null 2>&1; then
         # Alpine
         adduser -D -h /home/terraria -s /bin/sh terraria
      else
         # Debian/Ubuntu/Fedora/Other -> prefer useradd
         # -m creates home, -U creates a group with the same name
         useradd -m -d /home/terraria -s /bin/bash -U terraria || \
         useradd -m -d /home/terraria -s /bin/sh -U terraria || \
         useradd -m -s /bin/sh terraria
      fi
    fi

    # Determine the terraria user's home directory and ensure it's present
    TERRARIA_HOME=$(getent passwd terraria | cut -d: -f6 || true)
    if [ -z "${TERRARIA_HOME}" ]; then
      TERRARIA_HOME="/home/terraria"
    fi
    mkdir -p "$TERRARIA_HOME" 2>/dev/null || true
    chown -R terraria:terraria "$TERRARIA_HOME" || true

    # Optionally add `terraria` to a supplementary group (default: games)
    TERRARIA_GROUP=${TERRARIA_GROUP:-games}
    if getent group "$TERRARIA_GROUP" >/dev/null 2>&1; then
      if command -v usermod >/dev/null 2>&1; then
        usermod -aG "$TERRARIA_GROUP" terraria || true
      elif command -v adduser >/dev/null 2>&1; then
        # adduser syntax varies; try this form as a fallback
        adduser terraria "$TERRARIA_GROUP" >/dev/null 2>&1 || true
      fi
    fi
    
    mkdir -p /opt/terraria
    cd /opt/terraria
    
    # Save Discord URL for internal scripts (launch.sh)
    if [ -n "$DISCORD_URL" ]; then
       echo "$DISCORD_URL" > /opt/terraria/.discord_url
       chmod 600 /opt/terraria/.discord_url
       chown terraria:terraria /opt/terraria/.discord_url
    fi

    # Create the Launch Wrapper (handles notifications)
    cat > /opt/terraria/launch.sh <<'LAUNCH'
#!/bin/bash
# Wrapper to run Terraria and handle Start/Stop notifications
DIR="/opt/terraria"
BIN="$DIR/TerrariaServer.bin.x86_64"
CONF="$DIR/serverconfig.txt"
URL_FILE="$DIR/.discord_url"

# Simple Notification Function
notify() {
    [ ! -f "$URL_FILE" ] && return
    local title="$1"
    local color="$2" # integer
    local desc="$3"
    local url=$(cat "$URL_FILE")
    [ -z "$url" ] && return
    
    # Try to get local IP
    local ip=$(ip -4 a s eth0 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -n1 || echo "Unknown")

    # JSON Payload (minimal)
    local json=$(cat <<J
{
  "embeds": [{
    "title": "$title",
    "description": "$desc",
    "color": $color,
    "fields": [
      { "name": "Server IP", "value": "$ip", "inline": true }
    ],
    "footer": { "text": "Terraria Server Status" },
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  }]
}
J
)
    curl -s -H "Content-Type: application/json" -d "$json" "$url" >/dev/null || true
}

notify "Server Starting" 3447003 "Terraria Server is booting up..."

# Run the Server
"$BIN" -config "$CONF"
EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
    notify "Server Stopped" 15158332 "Server shut down normally."
else
    notify "Server Crashed" 15158332 "Server exited with error code $EXIT_CODE."
fi

exit $EXIT_CODE
LAUNCH
    chmod +x /opt/terraria/launch.sh
    chown terraria:terraria /opt/terraria/launch.sh

    # Download
    ZIP_FILE="terraria-server.zip"
    URL="https://terraria.org/api/download/pc-dedicated-server/terraria-server-$TERRARIA_VERSION.zip"
    
    echo "Downloading Terraria Server $TERRARIA_VERSION..."
    if command -v wget >/dev/null 2>&1; then
        wget -q -O "$ZIP_FILE" "$URL"
    else
        curl -L -o "$ZIP_FILE" "$URL"
    fi
    
    echo "Extracting..."
    # Check for unzip availability
    if ! command -v unzip >/dev/null 2>&1; then
        echo "Error: unzip not found."
        exit 1
    fi
    unzip -q -o "$ZIP_FILE"
    
    # Dynamic Paths: Find the binary
    echo "Locating binary..."
    BIN_PATH=$(find . -type f -name "TerrariaServer.bin.x86_64" | head -n1)
    
    if [ -z "$BIN_PATH" ]; then
      echo "Error: Could not locate TerrariaServer.bin.x86_64 in extracted files."
      ls -R
      exit 1
    fi
    
    # Move contents to /opt/terraria if nested
    SOURCE_DIR=$(dirname "$BIN_PATH")
    if [ "$SOURCE_DIR" != "." ]; then
      echo "Moving files from $SOURCE_DIR to /opt/terraria..."
      mv "$SOURCE_DIR"/* .
      rmdir "$SOURCE_DIR" || true
    fi
    
    # Permissions
    chmod +x TerrariaServer.bin.x86_64
    if [ -f "TerrariaServer" ]; then
        chmod +x TerrariaServer
    fi
    rm -f "$ZIP_FILE"
    
    chown -R terraria:terraria /opt/terraria
    
    # Generate Config
    echo "Generating serverconfig.txt..."
    cat > serverconfig.txt <<CONFIG
port=$SERVER_PORT
maxplayers=$MAX_PLAYERS
worldname=$WORLD_NAME
autocreate=$AUTOCREATE
seed=$SEED
difficulty=$DIFFICULTY
password=$PASSWORD
motd=$MOTD
secure=$SECURE
upnp=0
CONFIG
    chown terraria:terraria serverconfig.txt

    # Ensure a writable world file path exists and is referenced in the config
    # Use the terraria user's home if available; create both terraria and root fallbacks
    TERRARIA_HOME=${TERRARIA_HOME:-/home/terraria}
    WORLD_FILE="$TERRARIA_HOME/.local/share/Terraria/Worlds/${WORLD_NAME}.wld"
    WORLD_DIR="$(dirname \"$WORLD_FILE\")"
    mkdir -p "$WORLD_DIR" 2>/dev/null || true
    chown -R terraria:terraria "$WORLD_DIR" || true

    # Also create the root fallback used on some templates (Alpine default)
    mkdir -p /root/.local/share/Terraria/Worlds 2>/dev/null || true

    # Append world= only if not already present in config
    if ! grep -Eq '^world=' serverconfig.txt 2>/dev/null; then
      echo "world=$WORLD_FILE" >> serverconfig.txt
      chown terraria:terraria serverconfig.txt || true
    fi

    # Ensure world directories and ownerships for common Terraria locations
    echo "Ensuring Worlds directories and ownership..."
    for p in "/opt/terraria/Worlds" "/opt/terraria/Terraria/Worlds" "/home/terraria/.local/share/Terraria/Worlds"; do
      mkdir -p "$p" 2>/dev/null || true
      chown -R terraria:terraria "$p" || true
    done

    # If no worlds exist, FORCE a generation run to prevent service crash on first boot.
    # We use input injection to answer the "Choose World" prompt that appears when the configured world is missing.
    if ! find /opt/terraria -type f -name '*.wld' -print -quit >/dev/null 2>&1 && \
       ! find /home/terraria -type f -name '*.wld' -print -quit >/dev/null 2>&1; then
       
       echo "No existing worlds found. Starting automatic world generation..."
       echo "This may take a few minutes. Please wait..."
       
       # Prepare inputs: New World (n), Size, Difficulty, World Evil, Name, Seed, Secret Seed, Exit
       # Defaults: Medium (2), Classic (1), "Terraria"
       GEN_SIZE=${AUTOCREATE:-2}
       [ "$GEN_SIZE" -eq 0 ] && GEN_SIZE=2
       
       # Config uses 0=Classic, 1=Expert...
       # Menu uses 1=Classic, 2=Expert...
       # So we map Config+1 to get Menu value.
       GEN_DIFF=${DIFFICULTY:-1}
       GEN_DIFF_MENU=$((GEN_DIFF + 1))
       
       GEN_EVIL=${WORLD_EVIL:-1}
       GEN_NAME=${WORLD_NAME:-Terraria}
       GEN_SEED=${SEED}
       # Secret seed logic is complex (toggle menu), for standard automation we usually skip or just pass enter.
       # If users want a specific seed, they usually provide GEN_SEED.
       # The menu asks for "Seed" then "Secret Seed" confirmation.
       
       cat > /opt/terraria/setup.in <<INPUT
n
$GEN_SIZE
$GEN_DIFF_MENU
$GEN_EVIL
$GEN_NAME
$GEN_SEED

exit
INPUT
       chown terraria:terraria /opt/terraria/setup.in
       
       # Run the server interactively with the input script
       # We use 'timeout' to prevent hanging if something goes wrong, though generation can be slow.
       if command -v timeout >/dev/null 2>&1; then
           TIMEOUT_CMD="timeout 600" # 10 minutes max for generation
       else
           TIMEOUT_CMD=""
       fi
       
       su -s /bin/bash terraria -c "$TIMEOUT_CMD /opt/terraria/TerrariaServer.bin.x86_64 -config /opt/terraria/serverconfig.txt < /opt/terraria/setup.in" >/dev/null 2>&1 || true
       
       echo "World generation attempt finished."
       rm -f /opt/terraria/setup.in
    fi

    # Supervisor fallback for containers without systemd (unprivileged CTs)
    # Only configure if Systemd is NOT present to avoid conflicts/redundancy.
    if command -v supervisord >/dev/null 2>&1 && ! command -v systemctl >/dev/null 2>&1; then
      echo "Configuring Supervisor..."
      mkdir -p /etc/supervisor/conf.d
      cat > /etc/supervisor/conf.d/terraria.conf <<SUPCONF
[program:terraria]
command=/opt/terraria/launch.sh
directory=/opt/terraria
user=terraria
autostart=true
autorestart=true
redirect_stderr=true
stdout_logfile=/var/log/terraria.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=3
SUPCONF
      touch /var/log/terraria.log || true
      chown terraria:terraria /var/log/terraria.log || true

      # If systemd not available, install SysV/OpenRC wrapper to start supervisord on boot
      if ! command -v systemctl >/dev/null 2>&1 && [ -d /etc/init.d ]; then
        cat > /etc/init.d/supervisord <<'INIT'
#!/sbin/openrc-run

name="supervisord"
description="Supervisor daemon"
command="/usr/bin/supervisord"
command_args="-c /etc/supervisor/supervisord.conf -n"
command_background=true
depend() {
  need net
}
INIT
        chmod +x /etc/init.d/supervisord || true
        rc-update add supervisord default || true
        rc-service supervisord restart || rc-service supervisord start || true
      fi

      # Ensure a crontab @reboot fallback to start supervisord if init doesn't
      if command -v crontab >/dev/null 2>&1; then
        F="@reboot /usr/bin/supervisord -c /etc/supervisor/supervisord.conf"
        (crontab -l 2>/dev/null | grep -Fq "$F") || (crontab -l 2>/dev/null; echo "$F") | crontab - || true
      fi
      
      # If systemd exists, enable supervisord unit if present
      if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now supervisor || true
      fi
    fi

    # Service Setup (Universal: Systemd or OpenRC)
    if command -v systemctl >/dev/null 2>&1; then
        echo "Configuring Systemd service..."
        # Cleanup potential Supervisor config to avoid confusion
        rm -f /etc/supervisor/conf.d/terraria.conf

        cat > /etc/systemd/system/terraria.service <<SERVICE
[Unit]
Description=Terraria Server
After=network.target

[Service]
Type=simple
User=terraria
WorkingDirectory=/opt/terraria
ExecStart=/opt/terraria/launch.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICE
        systemctl daemon-reload
        systemctl enable --now terraria
        
        # Bot Service (Internal)
        if [ -n "$BOT_TOKEN" ]; then
            cat > /etc/systemd/system/terraria-bot.service <<BOTSERVICE
[Unit]
Description=Terraria Discord Commander Bot
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/terraria
Environment="DISCORD_BOT_TOKEN=$BOT_TOKEN"
Environment="DISCORD_USER_ID=$BOT_USER_ID"
ExecStart=/opt/terraria/.bot_venv/bin/python /opt/terraria/discord_bot.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
BOTSERVICE
            systemctl enable --now terraria-bot
        fi
        
    elif [ -d /etc/init.d ]; then
        echo "Configuring OpenRC service..."
        # ...
        # (Internal Bot for Supervisor/OpenRC fallback)
        if [ -n "$BOT_TOKEN" ] && command -v supervisord >/dev/null 2>&1; then
            cat > /etc/supervisor/conf.d/terraria-bot.conf <<BOTSUP
[program:terraria-bot]
command=/opt/terraria/.bot_venv/bin/python /opt/terraria/discord_bot.py
directory=/opt/terraria
user=root
autostart=true
autorestart=true
environment=DISCORD_BOT_TOKEN="$BOT_TOKEN",DISCORD_USER_ID="$BOT_USER_ID"
BOTSUP
            supervisorctl update || true
        fi
        # If supervisord is available, create a wrapper that uses supervisorctl
        if command -v supervisorctl >/dev/null 2>&1; then
            cat > /etc/init.d/terraria <<'SERVICE'
#!/sbin/openrc-run

name="Terraria (supervisor)"
description="Terraria Dedicated Server (managed by supervisord)"
depend() {
  need net
}

start() {
  ebegin "Starting terraria via supervisor"
  /usr/bin/supervisorctl start terraria || true
  eend $?
}

stop() {
  ebegin "Stopping terraria via supervisor"
  /usr/bin/supervisorctl stop terraria || true
  eend $?
}

status() {
  /usr/bin/supervisorctl status terraria || true
}
SERVICE
            chmod +x /etc/init.d/terraria || true
            rc-update add terraria default || true
            rc-service terraria restart || rc-service terraria start || true
        else
            cat > /etc/init.d/terraria <<SERVICE
#!/sbin/openrc-run

name="Terraria Server"
description="Terraria Dedicated Server"
command="/opt/terraria/launch.sh"
command_user="terraria:terraria"
pidfile="/run/terraria.pid"
directory="/opt/terraria"
command_background=true

depend() {
  need net
  use dns logger
}
SERVICE
            chmod +x /etc/init.d/terraria
            rc-update add terraria default
            rc-service terraria restart || rc-service terraria start
        fi
    else
        echo "Warning: No known init system (systemd/openrc) found. Server not auto-started."
    fi
    
    echo "Deployment Complete."
EOF

echo "--- Done. Access with: pct enter $CT_ID ---"

# -----------------------------------------------------------------------------
# 5. Host Configuration (Integrations)
# -----------------------------------------------------------------------------
echo "--- Configuring Host Integrations ---"

# Setup Discord
if [ "$ENABLE_DISCORD" -eq 1 ] && [ -n "$DISCORD_URL" ]; then
    echo "Configuring Discord Webhook..."
    CONF_FILE="$PROJECT_DIR/discord.conf"
    if [ ! -f "$CONF_FILE" ]; then
        echo "DISCORD_WEBHOOK_URL=\"$DISCORD_URL\"" > "$CONF_FILE"
        chmod 600 "$CONF_FILE"
        echo "Created discord.conf."
    else
        echo "discord.conf already exists. Not overwriting."
    fi
fi

# Setup Backup Cron
if [ "$ENABLE_BACKUP" -eq 1 ]; then
    BACKUP_SCRIPT="$PROJECT_DIR/scripts/backup_terraria.sh"
    if [ -x "$BACKUP_SCRIPT" ]; then
        echo "Configuring Automated Backup Cron Job..."
        
        # Determine Cron Schedule
        CRON_EXPR=""
        case "$BACKUP_SCHEDULE" in
            "daily")  CRON_EXPR="0 4 * * *" ;;
            "hourly") CRON_EXPR="0 * * * *" ;;
            "6h")     CRON_EXPR="0 */6 * * *" ;;
            "weekly") CRON_EXPR="0 4 * * 0" ;;
            *)        CRON_EXPR="$BACKUP_SCHEDULE" ;; # Custom or passed directly
        esac

        # Command
        CRON_CMD="$BACKUP_SCRIPT $CT_ID >> $PROJECT_DIR/backup.log 2>&1"
        
        # Check if job already exists (idempotency)
        # We search for the script path AND the CT_ID followed by a space or end of line to avoid '100' matching '1000'
        if (crontab -l 2>/dev/null || true) | grep -Eq "$BACKUP_SCRIPT $CT_ID([[:space:]]|$)"; then
            echo "Cron job already exists for CT $CT_ID."
        else
            (crontab -l 2>/dev/null || true; echo "$CRON_EXPR $CRON_CMD") | crontab -
            echo "Added backup job: '$CRON_EXPR'"
        fi
    else
        echo "Warning: Backup script not executable or found at $BACKUP_SCRIPT"
    fi
fi

# Setup Resource Monitor Cron
if [ "$ENABLE_MONITOR" -eq 1 ]; then
    MONITOR_SCRIPT="$PROJECT_DIR/scripts/monitor_health.sh"
    if [ -x "$MONITOR_SCRIPT" ]; then
        echo "Configuring Resource Monitor Cron Job (every 5 mins)..."
        # Cron entry: */5 * * * * /path/to/monitor_health.sh CT_ID --alert >> /dev/null 2>&1
        MONITOR_CMD="$MONITOR_SCRIPT $CT_ID --alert >> /dev/null 2>&1"
        
        if (crontab -l 2>/dev/null || true) | grep -Eq "$MONITOR_SCRIPT $CT_ID([[:space:]]|$)"; then
            echo "Monitor job already exists for CT $CT_ID."
        else
            (crontab -l 2>/dev/null || true; echo "*/5 * * * * $MONITOR_CMD") | crontab -
            echo "Added monitor job (every 5 mins)."
        fi
    else
         echo "Warning: Monitor script not executable or found at $MONITOR_SCRIPT"
    fi
fi

echo "--- All Operations Complete ---"