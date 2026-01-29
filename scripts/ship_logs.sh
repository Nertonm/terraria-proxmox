#!/bin/bash
set -euo pipefail

CT_ID=${1:?Usage: $0 CT_ID [dest_dir]}
DEST_DIR=${2:-./logs}

mkdir -p "$DEST_DIR"
TS=$(date +%Y%m%dT%H%M%S)
OUT="$DEST_DIR/terraria-logs-${CT_ID}-${TS}.tar.gz"

echo "Collecting logs from CT $CT_ID..."

# Create a temporary directory inside the container
pct exec "$CT_ID" -- mkdir -p /tmp/terrlogs

# 1. Collect File Logs (Supervisor or internal)
pct exec "$CT_ID" -- sh -c 'cp -a /var/log/terraria* /tmp/terrlogs 2>/dev/null || true'
pct exec "$CT_ID" -- sh -c 'cp -a /opt/terraria/*.log /tmp/terrlogs 2>/dev/null || true'

# 2. Collect Systemd Journal
pct exec "$CT_ID" -- sh -c 'journalctl -u terraria --no-pager > /tmp/terrlogs/systemd-terraria.log 2>/dev/null || true'

# 3. Compress and Stream out
pct exec "$CT_ID" -- tar -C /tmp -czf - terrlogs > "$OUT"

# 4. Cleanup
pct exec "$CT_ID" -- rm -rf /tmp/terrlogs

echo "Logs archived: $OUT"