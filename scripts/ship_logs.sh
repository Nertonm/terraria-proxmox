#!/bin/bash
set -euo pipefail

CT_ID=${1:?Usage: $0 CT_ID [dest_dir]}
DEST_DIR=${2:-./logs}

mkdir -p "$DEST_DIR"
TS=$(date +%Y%m%dT%H%M%S)
OUT="$DEST_DIR/terraria-${CT_ID}-${TS}.tar.gz"

echo "Collecting logs from CT $CT_ID -> $OUT"
# pack /var/log/terraria* and /opt/terraria/*.log if present
pct exec "$CT_ID" -- sh -c 'mkdir -p /tmp/terrlogs && cp -a /var/log/terraria* /tmp/terrlogs 2>/dev/null || true; cp -a /opt/terraria/*.log /tmp/terrlogs 2>/dev/null || true; tar -C /tmp -czf - terrlogs' > "$OUT" || true

echo "Logs archived: $OUT"
