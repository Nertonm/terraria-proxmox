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
PRIORITY=${PRIORITY:-1}
UPNP=${UPNP:-0}
LANGUAGE=${LANGUAGE:-"en-US"}
BANLIST=${BANLIST:-"banlist.txt"}
NPCSTREAM=${NPCSTREAM:-""}
JOURNEY_PERM=${JOURNEY_PERM:-2} # 0=Locked, 1=Host, 2=Everyone

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
  --local-zip FILE         Use local server zip instead of downloading
  --static                 Use static IP (requires --ip and --gw)
  --ip CIDR                Static IP (e.g. 10.1.15.50/24)
  --gw IP                  Gateway (e.g. 10.1.15.1)
  -p, --port PORT          Server port
  -m, --maxplayers N       Max players
  --world-name NAME        World Name (default: Terraria)
  --size N                 World Size (1=small, 2=medium, 3=large) (default: 2)
  --difficulty N           Difficulty (0=classic, 1=expert, 2=master, 3=journey) (default: 1)
  --evil TYPE              World Evil (1=Random, 2=Corrupt, 3=Crimson)
  --seed TEXT              World Seed
  --secret-seed TEXT       Enable Secret Seed (e.g. 'not the bees')
  --password PASS          Server password
  --motd "MSG"             Message of the Day
  --secure                 Enable Cheat Protection (default: off)
  --priority N             Process Priority 0-5 (default: 1)
  --upnp                   Enable UPnP (default: off)
  --language LANG          Language (default: en-US)
  --banlist FILE           Banlist filename (default: banlist.txt)
  --npcstream N            Reduce enemy skipping (default: 60)
  --journey-permission N   Journey Mode Defaults (0=Locked, 1=Host, 2=All)
  --autocreate             Enable auto-creation of world if missing
  --world-file FILE        Import an existing .wld file
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
    --local-zip) LOCAL_ZIP_PATH="$2"; shift 2 ;;
    --static) NET_DHCP="no"; shift ;;
    --dhcp) NET_DHCP="yes"; shift ;;
    --ip) NET_IP="$2"; NET_DHCP="no"; shift 2 ;;
    --gw) NET_GW="$2"; shift 2 ;;
    -p|--port) SERVER_PORT="$2"; shift 2 ;;
    -m|--maxplayers) MAX_PLAYERS="$2"; shift 2 ;;
    --world-name) WORLD_NAME="$2"; shift 2 ;;
    --size) WORLD_SIZE="$2"; shift 2 ;;
    --difficulty) DIFFICULTY="$2"; shift 2 ;;
    --evil) WORLD_EVIL="$2"; shift 2 ;;
    --seed) SEED="$2"; shift 2 ;;
    --secret-seed) SECRET_SEED="$2"; shift 2 ;;
    --password) PASSWORD="$2"; shift 2 ;;
    --motd) MOTD="$2"; shift 2 ;;
    --secure) SECURE=1; shift ;;
    --priority) PRIORITY="$2"; shift 2 ;;
    --upnp) UPNP=1; shift ;;
    --language) LANGUAGE="$2"; shift 2 ;;
    --banlist) BANLIST="$2"; shift 2 ;;
    --npcstream) NPCSTREAM="$2"; shift 2 ;;
    --journey-permission) JOURNEY_PERM="$2"; shift 2 ;;
    --autocreate) AUTOCREATE_FLAG=1; shift ;;
    --enable-backup) ENABLE_BACKUP=1; shift ;;
    --backup-schedule) ENABLE_BACKUP=1; BACKUP_SCHEDULE="$2"; shift 2 ;;
    --enable-monitor) ENABLE_MONITOR=1; shift ;;
    --world-file) LOCAL_WORLD_PATH="$2"; shift 2 ;;
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

  read -rp "Import an existing world file (.wld)? (y/N) [N]: " input_import
  if [[ "$input_import" =~ ^[Yy] ]]; then
      read -rp "Path to .wld file: " input_path
      if [ -f "$input_path" ]; then
          LOCAL_WORLD_PATH="$input_path"
          # Extract name without extension for config consistency
          WORLD_NAME=$(basename "$input_path" .wld)
          echo "Using imported world: $WORLD_NAME"
          # Skip generation questions
          SKIP_GEN_OPTS=1
      else
          echo "File not found. Proceeding with standard setup."
          SKIP_GEN_OPTS=0
      fi
  else
      SKIP_GEN_OPTS=0
  fi

  if [ "$SKIP_GEN_OPTS" -eq 0 ]; then
      read -rp "World Name [$WORLD_NAME]: " input_wname
      WORLD_NAME=${input_wname:-$WORLD_NAME}
      
      read -rp "World Size (1=small, 2=medium, 3=large) [$WORLD_SIZE]: " input_size
      WORLD_SIZE=${input_size:-$WORLD_SIZE}

      read -rp "Difficulty (0=classic, 1=expert, 2=master, 3=journey) [$DIFFICULTY]: " input_diff
      DIFFICULTY=${input_diff:-$DIFFICULTY}

      read -rp "Seed (optional): " input_seed
      SEED=${input_seed:-$SEED}
      
      read -rp "Secret Seed (optional, e.g. 'not the bees'): " input_secret
      if [ -n "$input_secret" ]; then
        SEED="$input_secret"
      fi
  fi

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

# Validation & Normalization
if [[ ! "$WORLD_SIZE" =~ ^[1-3]$ ]]; then
    echo "Error: World size must be 1 (small), 2 (medium), or 3 (large)." >&2
    exit 1
fi
if [[ ! "$DIFFICULTY" =~ ^[0-3]$ ]]; then
    echo "Error: Difficulty must be 0 (classic), 1 (expert), 2 (master), or 3 (journey)." >&2
    exit 1
fi


# If --autocreate flag was used, set AUTOCREATE to the chosen WORLD_SIZE
if [ "${AUTOCREATE_FLAG:-0}" -eq 1 ]; then
    AUTOCREATE=$WORLD_SIZE
fi

# Merge Secret Seed if provided
if [ -n "$SECRET_SEED" ]; then
    SEED="$SECRET_SEED"
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
        TEMPLATE_FILE=$(pveam available | awk '{print $1}' | grep -iE "^${TEMPLATE_FAMILY}" | sort -V | tail -n1 || true)
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

# --- SERVER BINARY CACHING SYSTEM ---
# Determine local cache filename
CACHE_FILE="$PROJECT_DIR/terraria-server-$TERRARIA_VERSION.zip"
TARGET_URL="https://terraria.org/api/download/pc-dedicated-server/terraria-server-$TERRARIA_VERSION.zip"

echo "Checking for Terraria Server package..."

# 1. Check if user provided a custom zip path
if [ -n "${LOCAL_ZIP_PATH:-}" ]; then
    if [ ! -f "$LOCAL_ZIP_PATH" ]; then
        echo "Error: Custom zip file '$LOCAL_ZIP_PATH' not found."
        exit 1
    fi
    SOURCE_ZIP="$LOCAL_ZIP_PATH"
    echo "Using custom local package: $SOURCE_ZIP"

# 2. Check if we already have it cached in project dir
elif [ -f "$CACHE_FILE" ]; then
    SOURCE_ZIP="$CACHE_FILE"
    echo "Using cached package: $SOURCE_ZIP"

# 3. Not found locally, download to Host Cache
else
    echo "Package not found locally. Downloading to cache..."
    if command -v wget >/dev/null 2>&1; then
        wget -q --show-progress -O "$CACHE_FILE" "$TARGET_URL" || rm -f "$CACHE_FILE"
    else
        curl -L -o "$CACHE_FILE" "$TARGET_URL" || rm -f "$CACHE_FILE"
    fi
    
    if [ ! -f "$CACHE_FILE" ]; then
        echo "Error: Failed to download Terraria server. Check internet connection."
        exit 1
    fi
    SOURCE_ZIP="$CACHE_FILE"
    echo "Download complete. Cached as: $CACHE_FILE"
fi

# 4. Push to Container
echo "Pushing game files to container..."
pct push "$CT_ID" "$SOURCE_ZIP" "/tmp/terraria_installer.zip"

UPLOADED_WORLD_NAME=""
if [ -n "${LOCAL_WORLD_PATH:-}" ]; then
    if [ ! -f "$LOCAL_WORLD_PATH" ]; then
        echo "Error: World file '$LOCAL_WORLD_PATH' not found."
        exit 1
    fi
    UPLOADED_WORLD_NAME=$(basename "$LOCAL_WORLD_PATH")
    echo "Pushing world file '$UPLOADED_WORLD_NAME'..."
    pct push "$CT_ID" "$LOCAL_WORLD_PATH" "/tmp/$UPLOADED_WORLD_NAME"
fi

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
  UPLOADED_WORLD_NAME="$UPLOADED_WORLD_NAME" \
  DISCORD_URL="$DISCORD_URL" \
  BOT_TOKEN="$BOT_TOKEN" \
  BOT_USER_ID="$BOT_USER_ID" \
  BOT_CODE="$BOT_CODE" \
  PRIORITY="$PRIORITY" \
  UPNP="$UPNP" \
  LANGUAGE="$LANGUAGE" \
  BANLIST="$BANLIST" \
  NPCSTREAM="$NPCSTREAM" \
  JOURNEY_PERM="$JOURNEY_PERM" \
  LC_ALL=C \
  /bin/sh -s <<'EOF'
    set -e
    
    # Ensure DNS resolution via fallback if DHCP failed to provide it
    if ! ping -c 1 google.com >/dev/null 2>&1; then
        echo "Network check failed. Forcing DNS 8.8.8.8 in /etc/resolv.conf..."
        echo "nameserver 8.8.8.8" > /etc/resolv.conf
    fi

    echo "Detecting Package Manager..."
    if command -v apk >/dev/null 2>&1; then
        echo "Alpine detected."
        apk update
        apk add --no-cache bash findutils icu-libs wget unzip tmux curl ca-certificates iproute2 python3 py3-pip procps
        # Alpine uses musl, locales are different, usually handled by 'musl-locales' if needed, but often C.UTF-8 works.
    elif command -v apt-get >/dev/null 2>&1; then
      echo "Debian/Ubuntu detected."
      apt-get update
      apt-get install -y wget unzip tmux libicu-dev supervisor curl ca-certificates iproute2 python3 python3-venv python3-pip findutils locales procps

      # Fix Locales
      if [ -f /etc/locale.gen ]; then
         sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
         locale-gen
         update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
      fi
    elif command -v dnf >/dev/null 2>&1; then
        echo "Fedora/RHEL detected."
        dnf install -y wget unzip tmux libicu curl ca-certificates iproute python3 python3-pip findutils procps
    else
        echo "Error: No supported package manager found (apk, apt, dnf)."
        exit 1
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

    # Save Bot Credentials
    if [ -n "$BOT_TOKEN" ]; then
       echo "export DISCORD_BOT_TOKEN='$BOT_TOKEN'" > /opt/terraria/.bot_env
       echo "export DISCORD_USER_ID='$BOT_USER_ID'" >> /opt/terraria/.bot_env
       chmod 600 /opt/terraria/.bot_env
       chown terraria:terraria /opt/terraria/.bot_env
    fi

    # Create the Launch Wrapper (handles notifications)
    cat > /opt/terraria/launch.sh <<'LAUNCH'
#!/bin/bash
# Wrapper to run Terraria and handle Start/Stop notifications
DIR="/opt/terraria"
BIN="$DIR/TerrariaServer.bin.x86_64"
CONF="$DIR/serverconfig.txt"
URL_FILE="$DIR/.discord_url"
LOG_FILE="$DIR/server_output.log"

# Escape JSON strings
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/ }"
    s="${s//$'\r'/}"
    echo "$s"
}

# Simple Notification Function
notify() {
    [ ! -f "$URL_FILE" ] && return
    local title="$(json_escape "$1")"
    local color="$2" # integer
    local desc="$(json_escape "$3")"
    local url=$(cat "$URL_FILE")
    [ -z "$url" ] && return
    
    # Try to get local IP
    local ip=$(ip -4 a s eth0 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -n1 || echo "Unknown")
    
    # Extract World Name and Port for the embed
    local wname=$(grep "worldname=" "$CONF" | cut -d= -f2 | tr -d '\r')
    local port=$(grep "port=" "$CONF" | cut -d= -f2 | tr -d '\r')
    [ -z "$wname" ] && wname="Unknown"
    [ -z "$port" ] && port="7777"

    # JSON Payload (Rich Embed)
    local json=$(cat <<J
{
  "embeds": [{
    "title": "$title",
    "description": "$desc",
    "color": $color,
    "thumbnail": { "url": "https://terraria.org/assets/terraria-logo.png" },
    "fields": [
      { "name": "Server IP", "value": "$ip", "inline": true },
      { "name": "Port", "value": "$port", "inline": true },
      { "name": "World", "value": "$wname", "inline": true }
    ],
    "footer": { "text": "Terraria Server Status • Proxmox" },
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  }]
}
J
)
    curl -s -H "Content-Type: application/json" -d "$json" "$url" >/dev/null || true
}

# Sanity Check: World Existence
# Read world path, handling potential whitespace around '='
WORLD_PATH=$(grep "^world=" "$CONF" | cut -d= -f2 | tr -d '\r' | xargs | head -n1)
WORLD_DIR=$(dirname "$WORLD_PATH")
mkdir -p "$WORLD_DIR"

    # 1. Check for 0-byte corrupted worlds
    if [ -f "$WORLD_PATH" ] && [ ! -s "$WORLD_PATH" ]; then
        echo "Warning: World file exists but is empty (corrupted). Deleting to allow regen."
        rm -f "$WORLD_PATH"
    fi

    # Native Auto-Create Handling
    # The server handles generation automatically via 'autocreate=' in config.
    # We just ensure the directory exists and permissions are right.
    if [ ! -f "$WORLD_PATH" ]; then
         notify "First Run" 3447003 "World file not found. Server will generate it automatically (this may take a minute)..."
    fi

# Ensure Permissions (Critical fix for access denied errors)
chown -R terraria:terraria "$DIR" "$(dirname "$WORLD_PATH")" 2>/dev/null || true

# CRITICAL: Ensure 'world=' config exists to prevent interactive menu loop
if ! grep -qE "^world=" "$CONF"; then
    echo "Config Warning: 'world=' directive missing in $CONF. Injecting default..."
    if [ -n "$WORLD_PATH" ]; then
        echo "world=$WORLD_PATH" >> "$CONF"
    else
        # Fallback if variable somehow empty
        echo "world=$DIR/Worlds/Terraria.wld" >> "$CONF"
    fi
    chown terraria:terraria "$CONF"
fi

notify "Server Starting" 3447003 "Terraria Server is booting up..."

# Run the Server
# Pipe output to capture start errors (like 'Choose World' menu)
# Run the Server in Tmux for Input Injection Capability
# We use a unique session name based on the folder hash or fixed name 'terraria'
TMUX_SESSION="terraria"

# Ensure no stale session exists
tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true


    echo "Launching Server..."
    # Start Tmux Detached
    tmux new-session -d -s "$TMUX_SESSION" "$BIN -config $CONF"

    # Start Discord Bot (Background)
    BOT_PID=""
    if [ -f "$DIR/.bot_env" ] && [ -f "$DIR/discord_bot.py" ]; then
        echo "Starting Discord Bot..."
        # Load env vars in current shell (wrapper)
        set -a
        . "$DIR/.bot_env"
        set +a
        
        # Run in background directly
        "$DIR/.bot_venv/bin/python3" "$DIR/discord_bot.py" > "$DIR/bot_output.log" 2>&1 &
        BOT_PID=$!
        echo "$BOT_PID" > "$DIR/bot.pid"
    fi

# Setup Logging: Pipe the tmux output to the log file immediately
tmux pipe-pane -o -t "$TMUX_SESSION" "cat >> $LOG_FILE"

# Wait Loop: Monitor tmux session existence
# We use a loop here because launch.sh must remain running for systemd/supervisor to track it.
while tmux has-session -t "$TMUX_SESSION" 2>/dev/null; do
    sleep 3
done

# Cleanup Bot
if [ -n "$BOT_PID" ]; then
    echo "Stopping Bot (PID $BOT_PID)..."
    kill "$BOT_PID" 2>/dev/null || true
fi

# When loop ends (server shutdown), capture exit code logic if possible
# (Tmux masks the internal exit code, but we assume clean exit if session ends)
EXIT_CODE=0

# Capture last lines for diagnosis
LAST_LOGS=$(tail -n 10 "$DIR/server_output.log" | sed 's/^[[:space:]]*//' | cut -c 1-200)

# Diagnosis Logic
if [ $EXIT_CODE -eq 0 ]; then
    # If exit 0, check if it was a "Menu Exit" (Failure to load)
    if echo "$LAST_LOGS" | grep -qiE "(choose world|select world|enter world name)"; then
        notify "Boot Error: Missing World" 15158332 "Server dropped to menu. It cannot find the configured world file.\n\n**Action:** Check paths in 'serverconfig.txt' or run restore."
        exit 1
    else
        notify "Server Stopped" 15158332 "Server shut down normally."
    fi
else
    # Analyze Crash Reason
    ERROR_TITLE="Server Crashed"
    ERROR_DESC="Exit Code: $EXIT_CODE.\n\n**Logs:**\n\`\`\`$LAST_LOGS\`\`\`"
    
    # 1. Port In Use
    if echo "$LAST_LOGS" | grep -q "Address already in use"; then
        ERROR_TITLE="Network Error"
        ERROR_DESC="Port 7777 is already in use.\n\n**Hint:** Is another instance running? Check 'pct exec $CT_ID -- ss -lptn'."
    
    # 2. Corrupted World / Read Error
    elif echo "$LAST_LOGS" | grep -qiE "(LoadWorld|ReadAllBytes|System.IO.IOException)"; then
        ERROR_TITLE="World Corruption Detected"
        ERROR_DESC="Failed to load world file. It may be corrupted or have wrong permissions.\n\n**Action:** Restore from backup immediately."
        
    # 3. Out of Memory
    elif echo "$LAST_LOGS" | grep -qi "OutOfMemory"; then
        ERROR_TITLE="Out of Memory"
        ERROR_DESC="Server ran out of RAM.\n\n**Action:** Increase container memory via Proxmox UI."
        
    # 4. Bad Config
    elif echo "$LAST_LOGS" | grep -qi "serverconfig.txt"; then
        ERROR_TITLE="Configuration Error"
        ERROR_DESC="Error reading 'serverconfig.txt'. Check for typos or invalid parameters."
    fi

    notify "$ERROR_TITLE" 15158332 "$ERROR_DESC"
fi

sleep 2
exit $EXIT_CODE
LAUNCH
    chmod +x /opt/terraria/launch.sh
    chown terraria:terraria /opt/terraria/launch.sh

    # --- DISCORD COMMANDER BOT SETUP (INTERNAL) ---
    if [ -n "$BOT_CODE" ]; then
        echo "Setting up Internal Discord Bot..."
        # Dump the env var directly to file to avoid heredoc expansion issues
        printenv BOT_CODE > /opt/terraria/discord_bot.py
    fi
    
    # Finalize Bot Installation (Inside Container)
    if [ -n "$BOT_TOKEN" ]; then
        echo "Finalizing Bot Python Environment..."
        python3 -m venv /opt/terraria/.bot_venv
        /opt/terraria/.bot_venv/bin/pip install discord.py --quiet
        chown -R terraria:terraria /opt/terraria/.bot_venv /opt/terraria/discord_bot.py
    fi
    
    
    # Download
    ZIP_FILE="terraria-server.zip"
    URL="https://terraria.org/api/download/pc-dedicated-server/terraria-server-$TERRARIA_VERSION.zip"
    
    # Install from Pushed Zip
    ZIP_FILE="terraria-server.zip"
    
    if [ -f "/tmp/terraria_installer.zip" ]; then
        echo "Installer package found. Extracting..."
        mv /tmp/terraria_installer.zip "$ZIP_FILE"
    else
        # Fallback (should not happen with new logic, but safe to keep)
        echo "Error: Installer package /tmp/terraria_installer.zip missing!"
        exit 1
    fi
    
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
    
    chown -R terraria:terraria /opt/terraria
    
    # --- Prepare World Paths ---
    TERRARIA_HOME=${TERRARIA_HOME:-/home/terraria}
    
    # Handle Uploaded World
    if [ -n "$UPLOADED_WORLD_NAME" ] && [ -f "/tmp/$UPLOADED_WORLD_NAME" ]; then
         echo "Installing uploaded world: $UPLOADED_WORLD_NAME"
         TARGET_DIR="$TERRARIA_HOME/.local/share/Terraria/Worlds"
         mkdir -p "$TARGET_DIR"
         mv "/tmp/$UPLOADED_WORLD_NAME" "$TARGET_DIR/$UPLOADED_WORLD_NAME"
         chown terraria:terraria "$TARGET_DIR/$UPLOADED_WORLD_NAME"
         
         # Update identifiers
         WORLD_FILE="$TARGET_DIR/$UPLOADED_WORLD_NAME"
         WORLD_NAME=$(basename "$UPLOADED_WORLD_NAME" .wld)
         
         # Disable auto-create in config logic as we have a world
         AUTOCREATE="" 
    else
         WORLD_FILE="$TERRARIA_HOME/.local/share/Terraria/Worlds/${WORLD_NAME}.wld"
    fi
    
    WORLD_DIR="$(dirname "$WORLD_FILE")"

    # Ensure directories exist
    mkdir -p "$WORLD_DIR" /opt/terraria/Worlds 2>/dev/null || true
    chown -R terraria:terraria "$WORLD_DIR" /opt/terraria/Worlds || true
    
    # Compatibility link for some setups
    mkdir -p /root/.local/share/Terraria/Worlds 2>/dev/null || true

    # Generate Config (Standardized)
    echo "Generating serverconfig.txt..."
    
    # Backup existing config if present
    if [ -f "serverconfig.txt" ]; then
        cp serverconfig.txt serverconfig.txt.bak
        chown terraria:terraria serverconfig.txt.bak
    fi

    # Prepare Config Lines
    NPCSTREAM_LINE=""
    if [ -n "$NPCSTREAM" ]; then
        NPCSTREAM_LINE="npcstream=$NPCSTREAM"
    fi
    
    AUTOCREATE_LINE=""
    # Always include autocreate derived from WORLD_SIZE to ensure:
    # 1. launch.sh Auto-Repair knows the intended size if the world is missing.
    # 2. Server binary has a fallback auto-create configuration.
    if [[ "$WORLD_SIZE" =~ ^[1-3]$ ]]; then
        AUTOCREATE_LINE="autocreate=$WORLD_SIZE"
    fi

cat > serverconfig.txt <<CONFIG
#this is an example config file for TerrariaServer.exe
#use the command 'TerrariaServer.exe -config serverconfig.txt' to use this configuration or run start-server.bat
#please report crashes by emailing crashlog.txt to support@terraria.org

#the following is a list of available command line parameters:

#-config <config file>				            Specifies the configuration file to use.
#-port <port number>				              Specifies the port to listen on.
#-players <number> / -maxplayers <number>	Sets the max number of players
#-pass <password> / -password <password>		Sets the server password
#-world <world file>					Load a world and automatically start the server.
#-autocreate <#>					Creates a world if none is found in the path specified by -world. World size is specified by: 1(small), 2(medium), and 3(large).
#-banlist <path>					Specifies the location of the banlist. Defaults to "banlist.txt" in the working directory.
#-worldname <world name>             			Sets the name of the world when using -autocreate.
#-secure						Adds addition cheat protection to the server.
#-noupnp						Disables automatic port forwarding
#-steam							Enables Steam Support
#-lobby <friends> or <private>				Allows friends to join the server or sets it to private if Steam is enabled
#-ip <ip address>					Sets the IP address for the server to listen on
#-forcepriority <priority>				Sets the process priority for this task. If this is used the "priority" setting below will be ignored.
#-disableannouncementbox				Disables the text announcements Announcement Box makes when pulsed from wire.
#-announcementboxrange <number>				Sets the announcement box text messaging range in pixels, -1 for serverwide announcements.
#-seed <seed>						Specifies the world seed when using -autocreate

#remove the # in front of commands to enable them.

#Load a world and automatically start the server.
world=$WORLD_FILE

#Creates a new world if none is found. World size is specified by: 1(small), 2(medium), and 3(large).
$AUTOCREATE_LINE

#Sets the world seed when using autocreate
seed=$SEED

#Sets the name of the world when using autocreate
worldname=$WORLD_NAME

#Sets the difficulty of the world when using autocreate 0(classic), 1(expert), 2(master), 3(journey)
difficulty=$DIFFICULTY

#Sets the max number of players allowed on a server.  Value must be between 1 and 255
maxplayers=$MAX_PLAYERS

#Set the port number
port=$SERVER_PORT

#Set the server password
password=$PASSWORD

#Set the message of the day
motd=${MOTD:-"Welcome to Terraria Server!"}

#Sets the folder where world files will be stored
worldpath=$WORLD_DIR

#The location of the banlist. Defaults to "banlist.txt" in the working directory.
banlist=$BANLIST

#Adds addition cheat protection.
secure=$SECURE

#Sets the server language from its language code.
#English = en-US, German = de-DE, Italian = it-IT, French = fr-FR, Spanish = es-ES, Russian = ru-RU, Chinese = zh-Hans, Portuguese = pt-BR, Polish = pl-PL,
language=en-US

#Automatically forward ports with uPNP
upnp=$UPNP

#Reduces enemy skipping but increases bandwidth usage. The lower the number the less skipping will happen, but more data is sent. 0 is off.
$NPCSTREAM_LINE

#Default system priority 0:Realtime, 1:High, 2:AboveNormal, 3:Normal, 4:BelowNormal, 5:Idle
priority=$PRIORITY

#Journey mode power permissions for every individual power. 0: Locked for everyone, 1: Can only be changed by host, 2: Can be changed by everyone
journeypermission_time_setfrozen=$JOURNEY_PERM
journeypermission_time_setdawn=$JOURNEY_PERM
journeypermission_time_setnoon=$JOURNEY_PERM
journeypermission_time_setdusk=$JOURNEY_PERM
journeypermission_time_setmidnight=$JOURNEY_PERM
journeypermission_godmode=$JOURNEY_PERM
journeypermission_wind_setstrength=$JOURNEY_PERM
journeypermission_rain_setstrength=$JOURNEY_PERM
journeypermission_time_setspeed=$JOURNEY_PERM
journeypermission_rain_setfrozen=$JOURNEY_PERM
journeypermission_wind_setfrozen=$JOURNEY_PERM
journeypermission_increaseplacementrange=$JOURNEY_PERM
journeypermission_setdifficulty=$JOURNEY_PERM
journeypermission_biomespread_setfrozen=$JOURNEY_PERM
journeypermission_setspawnrate=$JOURNEY_PERM
CONFIG
    
    chown terraria:terraria serverconfig.txt

    # Cleanup redundant actions (paths are already handled above)
    echo "Configuration written to serverconfig.txt"

    # If no worlds exist, FORCE a generation run to prevent service crash on first boot.
    # We use input injection to answer the "Choose World" prompt that appears when the configured world is missing.
    # World generation is now handled by the launch.sh Auto-Repair logic on first boot.
    # This prevents silent failures during installation and ensures the server environment is fully ready.
    echo "World generation will be handled by the service on first start if needed."


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
      if ! command -v systemctl >/dev/null 2>&1 && [ -d /etc/init.d ] && [ ! -f /etc/init.d/supervisord ]; then
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
Environment="LANG=C.UTF-8"
Environment="LC_ALL=C.UTF-8"
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
Environment="LANG=C.UTF-8"
Environment="LC_ALL=C.UTF-8"
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
environment=DISCORD_BOT_TOKEN="$BOT_TOKEN",DISCORD_USER_ID="$BOT_USER_ID",LANG="C.UTF-8",LC_ALL="C.UTF-8"
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