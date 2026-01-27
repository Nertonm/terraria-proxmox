#!/bin/bash
set -euo pipefail

CT_ID=${1:?Usage: $0 CT_ID backup-file.tar.gz}
BACKUP_FILE=${2:?Usage: $0 CT_ID backup-file.tar.gz}

if ! command -v pct >/dev/null 2>&1; then
  echo "pct not found; run this on the Proxmox host" >&2
  exit 1
fi

if [ ! -f "$BACKUP_FILE" ]; then
  echo "Backup file not found: $BACKUP_FILE" >&2
  exit 1
fi

echo "Restoring $BACKUP_FILE to container $CT_ID (/opt/terraria)"
pct exec "$CT_ID" -- sh -c 'mkdir -p /opt/terraria && chown terraria:terraria /opt/terraria || true'
tar -C - -xzf "$BACKUP_FILE" | pct exec "$CT_ID" -- tar -C /opt/terraria -xzf - || true

echo "Restore complete. Ensure permissions:"
pct exec "$CT_ID" -- chown -R terraria:terraria /opt/terraria || true

echo "If the server is running under systemd/supervisor it should auto-restart."
