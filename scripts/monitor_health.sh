#!/bin/bash
set -euo pipefail

# Terraria Advanced Health & Status Monitor
# Usage: 
#   ./monitor_health.sh <CT_ID> --alert [THRESHOLD]  (Checks health, alerts only on issues)
#   ./monitor_health.sh <CT_ID> --report             (Sends full status report)

CT_ID=${1:?Usage: $0 CT_ID [--alert THRESHOLD | --report]}
MODE=${2:-"--alert"}
THRESHOLD=${3:-90}

# Load Notification Helper
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

send_discord() {
  local args=("$@")
  if [ -x "$SCRIPT_DIR/discord_webhook.sh" ]; then
    "$SCRIPT_DIR/discord_webhook.sh" "${args[@]}" || true
  fi
}

# 1. Check Container State
STATUS=$(pct status "$CT_ID" 2>/dev/null || echo "stopped")
if [[ "$STATUS" != *"running"* ]]; then
  if [ "$MODE" == "--report" ]; then
    send_discord --title "Server Status" --desc "Container $CT_ID is offline." --status error
  fi
  exit 0
fi

# 2. Collect Metrics via pct exec

# RAM
MEM_INFO=$(pct exec "$CT_ID" -- free -m | grep Mem:)
MEM_TOTAL=$(echo "$MEM_INFO" | awk '{print $2}')
MEM_USED=$(echo "$MEM_INFO" | awk '{print $3}')
MEM_PERCENT=0
[ "$MEM_TOTAL" -gt 0 ] && MEM_PERCENT=$(( 100 * MEM_USED / MEM_TOTAL ))

# CPU Load (1 min avg)
LOAD_AVG=$(pct exec "$CT_ID" -- cat /proc/loadavg | awk '{print $1}')

# Disk Usage (RootFS)
# Use df -P to ensure portability and one line per entry
DISK_INFO=$(pct exec "$CT_ID" -- df -Ph / | tail -n1)
DISK_USED=$(echo "$DISK_INFO" | awk '{print $5}') # e.g. 15%
DISK_FREE=$(echo "$DISK_INFO" | awk '{print $4}')

# Uptime
UPTIME_PRETTY=$(pct exec "$CT_ID" -- uptime -p | sed 's/up //')

# Active Players
# Read the configured port from serverconfig when possible, then count ESTABLISHED
# connections on that port.
SERVER_PORT=$(pct exec "$CT_ID" -- awk -F= "\$1==\"port\" {print \$2; exit}" /opt/terraria/serverconfig.txt 2>/dev/null | tr -d '\r')
if [[ ! "$SERVER_PORT" =~ ^[0-9]+$ ]]; then
  SERVER_PORT=7777
fi

PLAYER_COUNT=$(pct exec "$CT_ID" -- sh -c "if command -v ss >/dev/null 2>&1; then ss -tn state established '( sport = :$SERVER_PORT )' | grep -v Recv-Q | wc -l; elif command -v netstat >/dev/null 2>&1; then netstat -tn | grep ':$SERVER_PORT' | grep ESTABLISHED | wc -l; else echo 0; fi")
PLAYER_COUNT=$((PLAYER_COUNT)) # force integer

# 3. Logic: Alert Mode
if [ "$MODE" == "--alert" ]; then
  # Check RAM Threshold
  if [ "$MEM_PERCENT" -ge "$THRESHOLD" ]; then
    LOCKFILE="/tmp/terraria_ram_${CT_ID}.lock"
    # Anti-spam: 1 hour cooldown
    if [ ! -f "$LOCKFILE" ] || [ $(($(date +%s) - $(stat -c %Y "$LOCKFILE"))) -gt 3600 ]; then
      touch "$LOCKFILE"
      send_discord --title "⚠️ High Resource Usage" \
        --status warn \
        --desc "Terraria Server is under heavy load." \
        --field "RAM:${MEM_PERCENT}% (${MEM_USED}MB)" \
        --field "CPU Load:${LOAD_AVG}" \
        --field "Players:${PLAYER_COUNT}"
    fi
  else
    rm -f "/tmp/terraria_ram_${CT_ID}.lock" 2>/dev/null
  fi
  
  # Check Disk Threshold (Simpler check > 90%)
  DISK_INT=${DISK_USED%\%}
  if [ "$DISK_INT" -ge 90 ]; then
    LOCKFILE="/tmp/terraria_disk_${CT_ID}.lock"
    if [ ! -f "$LOCKFILE" ] || [ $(($(date +%s) - $(stat -c %Y "$LOCKFILE"))) -gt 3600 ]; then
      touch "$LOCKFILE"
      send_discord --title "💾 Low Disk Space" \
        --status error \
        --desc "Container disk is almost full!" \
        --field "Usage:${DISK_USED}" \
        --field "Free:${DISK_FREE}"
    fi
  fi

# 4. Logic: Report Mode
elif [ "$MODE" == "--report" ]; then
  send_discord --title "📊 Server Status Report" \
    --status info \
    --desc "Current performance metrics for Terraria CT $CT_ID" \
    --field "Players Online:${PLAYER_COUNT}" \
    --field "Uptime:${UPTIME_PRETTY}" \
    --field "RAM Usage:${MEM_PERCENT}% (${MEM_USED}MB)" \
    --field "CPU Load:${LOAD_AVG}" \
    --field "Disk Usage:${DISK_USED} (Free: ${DISK_FREE})"
fi
