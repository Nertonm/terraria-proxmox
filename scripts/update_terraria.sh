#!/bin/bash
set -euo pipefail

# Terraria Server Update Script
# Usage: ./update_terraria.sh <CT_ID> <NEW_VERSION>

CT_ID=${1:?Usage: $0 CT_ID NEW_VERSION (e.g., 1450)}
NEW_VERSION=${2:?Usage: $0 CT_ID NEW_VERSION (e.g., 1450)}

# Helper for notifications
notify_update() {
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
      --field "Target Version:$NEW_VERSION" || true
  fi
}

trap 'notify_update "error" "Update Failed" "Update procedure failed unexpectedly."; exit 1' ERR

echo "--- Updating Terraria Server on CT $CT_ID to version $NEW_VERSION ---"

# 1. Stop Service
echo "Stopping Terraria service..."
pct exec "$CT_ID" -- systemctl stop terraria || true

# 2. Backup current binary
echo "Backing up current binary..."
pct exec "$CT_ID" -- mv /opt/terraria/TerrariaServer.bin.x86_64 /opt/terraria/TerrariaServer.bin.x86_64.bak || true

# 3. Download and Install New Version
echo "Downloading version $NEW_VERSION..."
ZIP_FILE="terraria-server-$NEW_VERSION.zip"
URL="https://terraria.org/api/download/pc-dedicated-server/$ZIP_FILE"

# We execute a script inside to handle download and unzip to avoid transferring files back and forth
pct exec "$CT_ID" -- /bin/bash -s <<EOF
  set -e
  cd /tmp
  
  # Download
  if command -v wget >/dev/null; then
    wget -q "$URL"
  else
    curl -L -O "$URL"
  fi
  
  echo "Extracting..."
  unzip -q -o "$ZIP_FILE"
  
  # Find new binary
  BIN_PATH=\$(find . -type f -name "TerrariaServer.bin.x86_64" | head -n1)
  if [ -z "\$BIN_PATH" ]; then
    echo "Error: New binary not found in zip."
    exit 1
  fi
  
  echo "Installing new binary..."
  cp "\$BIN_PATH" /opt/terraria/
  chmod +x /opt/terraria/TerrariaServer.bin.x86_64
  
  # Cleanup
  rm -rf "$ZIP_FILE" "\$(dirname "\$BIN_PATH")"
  
  # Restore permissions
  chown terraria:terraria /opt/terraria/TerrariaServer.bin.x86_64
EOF

# 4. Start Service
echo "Starting Terraria service..."
pct exec "$CT_ID" -- systemctl start terraria

notify_update "success" "Update Complete" "Terraria Server was successfully updated."

echo "--- Update Complete ---"
echo "Binary updated. Check status: pct exec $CT_ID -- systemctl status terraria"
