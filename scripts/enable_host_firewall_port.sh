#!/bin/bash
set -euo pipefail

# One-liner example (non-interactive):
# sudo ./scripts/enable_host_firewall_port.sh 7777 0.0.0.0/0 --yes

PORT=${1:-7777}
SOURCE=${2:-0.0.0.0/0}
AUTO=${3:-no}

if [ "${AUTO}" = "-y" ] || [ "${AUTO}" = "--yes" ] || [ "${AUTO}" = "yes" ] || [ "${AUTO}" = "y" ]; then
  SKIP_PROMPT=yes
else
  SKIP_PROMPT=no
fi

if [ "$SKIP_PROMPT" != "yes" ]; then
  echo "This will add an iptables rule allowing TCP port $PORT from $SOURCE."
  read -rp "Proceed? (y/N): " ans
  if [[ ! "$ans" =~ ^[Yy] ]]; then
    echo "Aborted."
    exit 0
  fi
fi

# idempotent: check
if iptables -C INPUT -p tcp -s "$SOURCE" --dport "$PORT" -j ACCEPT >/dev/null 2>&1; then
  echo "Rule already present."
else
  iptables -I INPUT -p tcp -s "$SOURCE" --dport "$PORT" -j ACCEPT
  echo "Rule added. Consider saving with:"
  echo "  sudo iptables-save > /etc/iptables.rules"
fi

