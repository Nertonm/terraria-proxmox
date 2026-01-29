#!/bin/bash
set -euo pipefail

CT_ID=${1:?Usage: $0 CT_ID}
CONF=/etc/pve/lxc/${CT_ID}.conf

if [ ! -f "$CONF" ]; then
  echo "LXC config $CONF not found. Is CT $CT_ID created?" >&2
  exit 1
fi

BACKUP=${CONF}.bak.$(date +%Y%m%dT%H%M%S)
cp "$CONF" "$BACKUP"
echo "Backed up $CONF -> $BACKUP"

# recommended capabilities to drop
DROP_LIST=(CAP_SYS_ADMIN CAP_SYS_MODULE CAP_SYS_BOOT CAP_SYS_TIME CAP_AUDIT_CONTROL CAP_AUDIT_WRITE CAP_NET_RAW CAP_NET_ADMIN CAP_SYS_PTRACE)
LINE="lxc.cap.drop = ${DROP_LIST[*]}"

# append if not present
if ! grep -q "lxc.cap.drop" "$CONF"; then
  echo "$LINE" >> "$CONF"
  echo "Appended lxc.cap.drop to $CONF"
else
  echo "lxc.cap.drop already present in $CONF; not modifying."
fi

echo "Please stop and start the container to apply: pct stop $CT_ID && pct start $CT_ID"
