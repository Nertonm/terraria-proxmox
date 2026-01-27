#!/bin/bash
set -euo pipefail

CT_ID=${1:?Usage: $0 CT_ID [dest_dir]}
DEST_DIR=${2:-./backups}
KEEP=${3:-7}

mkdir -p "$DEST_DIR"
TIMESTAMP=$(date +%Y%m%dT%H%M%S)
OUT="$DEST_DIR/terraria-${CT_ID}-${TIMESTAMP}.tar.gz"

if ! command -v pct >/dev/null 2>&1; then
  echo "pct not found; run this on the Proxmox host" >&2
  exit 1
fi

echo "Creating backup for CT $CT_ID -> $OUT"
# stream a tar from inside the container to the host
pct exec "$CT_ID" -- tar -C /opt/terraria -czf - . > "$OUT"

echo "Backup completed: $OUT"
# rotate backups: keep $KEEP most recent
ls -1t "$DEST_DIR"/terraria-${CT_ID}-*.tar.gz 2>/dev/null | tail -n +$((KEEP+1)) | xargs -r rm -f --
echo "Rotated backups, kept $KEEP latest files."
