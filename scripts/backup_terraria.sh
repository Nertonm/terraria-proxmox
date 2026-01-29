#!/bin/bash
set -euo pipefail

# Enhanced Backup Script for Terraria Proxmox LXC
# Backs up configuration, binaries, AND world files.

CT_ID=${1:?Usage: $0 CT_ID [dest_dir]}
DEST_DIR=${2:-./backups}
KEEP=${3:-7}

START_TIME=$(date +%s)

# Helper for notifications
notify_backup() {
  local status="$1"
  local title="$2"
  local msg="$3"
  local file_path="${4:-}"
  
  local script_dir="$(dirname "$0")"
  if [ -x "$script_dir/discord_webhook.sh" ]; then
    local args=(--title "$title" --desc "$msg" --status "$status")
    
    if [ "$status" == "success" ] && [ -n "$file_path" ]; then
      local size=$(du -h "$file_path" | cut -f1)
      local filename=$(basename "$file_path")
      local end_time=$(date +%s)
      local duration=$((end_time - START_TIME))
      
      args+=(--field "File:$filename")
      args+=(--field "Size:$size")
      args+=(--field "Duration:${duration}s")
    fi
    
    "$script_dir/discord_webhook.sh" "${args[@]}" || true
  fi
}

# Trap errors for failure notification
trap 'notify_backup "error" "Backup Failed" "Backup for CT $CT_ID encountered an unexpected error."; exit 1' ERR

mkdir -p "$DEST_DIR"
TIMESTAMP=$(date +%Y%m%dT%H%M%S)
OUT="$DEST_DIR/terraria-${CT_ID}-${TIMESTAMP}.tar.gz"

if ! command -v pct >/dev/null 2>&1; then
  echo "pct not found; run this on the Proxmox host" >&2
  exit 1
fi

echo "--- Starting Backup for Container $CT_ID ---"
# notify_backup "info" "Backup Started" "Initiating backup process for CT $CT_ID..."

# 1. Stop Service (to ensure world consistency)
echo "Stopping Terraria service..."
pct exec "$CT_ID" -- systemctl stop terraria || echo "Service stop failed or service not running (ignoring)..."

# 2. Create Archive
# We backup /opt/terraria (binaries/config) and /home/terraria (worlds/saves)
echo "Archiving /opt/terraria and /home/terraria..."
pct exec "$CT_ID" -- tar -czf - /opt/terraria /home/terraria > "$OUT"

# 3. Start Service
echo "Restarting Terraria service..."
pct exec "$CT_ID" -- systemctl start terraria || echo "Service start warning."

echo "Backup saved to: $OUT"

# 4. Rotate Backups
COUNT=$(ls -1 "$DEST_DIR"/terraria-${CT_ID}-*.tar.gz 2>/dev/null | wc -l)
if [ "$COUNT" -gt "$KEEP" ]; then
  echo "Rotating backups (keeping $KEEP)..."
  ls -1t "$DEST_DIR"/terraria-${CT_ID}-*.tar.gz | tail -n +$((KEEP+1)) | xargs -r rm -f --
fi

notify_backup "success" "Backup Complete" "The world backup was successfully completed and rotated." "$OUT"

echo "--- Backup Complete ---"