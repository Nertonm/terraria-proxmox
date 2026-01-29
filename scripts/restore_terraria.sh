#!/bin/bash
set -euo pipefail

# Enhanced Restore Script for Terraria Proxmox LXC

CT_ID=${1:?Usage: $0 CT_ID backup-file.tar.gz}
BACKUP_FILE=${2:?Usage: $0 CT_ID backup-file.tar.gz}

# Helper for notifications
notify_restore() {
  local status="$1"
  local title="$2"
  local msg="$3"
  
  local script_dir="$(dirname "$0")"
  if [ -x "$script_dir/discord_webhook.sh" ]; then
    "$script_dir/discord_webhook.sh" \
      --title "$title" \
      --desc "$msg" \
      --status "$status" \
      --field "Container:$CT_ID" \
      --field "Backup File:$(basename "$BACKUP_FILE")" || true
  fi
}

trap 'notify_restore "error" "Restore Failed" "Restore procedure for CT $CT_ID failed unexpectedly."; exit 1' ERR

if ! command -v pct >/dev/null 2>&1; then
  echo "pct not found; run this on the Proxmox host" >&2
  exit 1
fi

if [ ! -f "$BACKUP_FILE" ]; then
  echo "Backup file not found: $BACKUP_FILE" >&2
  exit 1
fi

echo "--- Restoring Backup to Container $CT_ID ---"
echo "Backup File: $BACKUP_FILE"

# 1. Stop Service
echo "Stopping service..."
pct exec "$CT_ID" -- bash -c "systemctl stop terraria || supervisorctl stop terraria || rc-service terraria stop || true"

# 2. Extract Archive
# The backup now contains absolute paths /opt/terraria and /home/terraria.
# We extract them to root /.
echo "Extracting files..."
cat "$BACKUP_FILE" | pct exec "$CT_ID" -- tar -xzf - -C /

# 3. Fix Permissions
# Ensure user terraria owns everything restored
echo "Fixing permissions..."
pct exec "$CT_ID" -- chown -R terraria:terraria /opt/terraria /home/terraria

# 4. Start Service
echo "Starting service..."
pct exec "$CT_ID" -- bash -c "systemctl start terraria || supervisorctl start terraria || rc-service terraria start || true"

notify_restore "success" "Restore Complete" "Backup successfully restored to CT $CT_ID."

echo "--- Restore Complete ---"
echo "Check status with: pct exec $CT_ID -- systemctl status terraria"