#!/bin/bash
set -euo pipefail

# Advanced Discord Webhook Script
# Usage: ./discord_webhook.sh --title "..." --desc "..." --status success|error|warn --field "Key:Value"

# Load Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/../discord.conf" ]; then
  source "$SCRIPT_DIR/../discord.conf"
elif [ -f "discord.conf" ]; then
  source "discord.conf"
fi

WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"

# Defaults
TITLE="Notification"
DESCRIPTION=""
COLOR=3447003 # Blue
STATUS="info"
PING=""
FIELDS_JSON=""
FOOTER="Terraria Proxmox Manager"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)

# Icons (Reliable Placeholders)
ICON_SUCCESS="https://placehold.co/64x64/2ecc71/ffffff.png?text=OK"     # Green
ICON_ERROR="https://placehold.co/64x64/e74c3c/ffffff.png?text=ERR"     # Red
ICON_WARN="https://placehold.co/64x64/f1c40f/ffffff.png?text=WARN"     # Yellow
ICON_INFO="https://placehold.co/64x64/3498db/ffffff.png?text=INFO"     # Blue
THUMBNAIL=""

# Escape JSON string function
json_escape() {
  echo "$1" | sed 's/"/\"/g' | sed ':a;N;$!ba;s/\n/\\n/g'
}

# Parse Arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --url) WEBHOOK_URL="$2"; shift 2 ;;
    --title) TITLE="$2"; shift 2 ;;
    --desc|--description|--message) DESCRIPTION="$2"; shift 2 ;;
    --status) STATUS="$2"; shift 2 ;;
    --ping) PING="$2"; shift 2 ;; # e.g., "@here"
    --field) 
      # Expected format: "Name:Value"
      IFS=':' read -r f_name f_value <<< "$2"
      # Append to FIELDS_JSON string (manual JSON construction)
      [ -n "$FIELDS_JSON" ] && FIELDS_JSON="$FIELDS_JSON,"
      FIELDS_JSON="${FIELDS_JSON} { \"name\": \"$(json_escape "$f_name")\", \"value\": \"$(json_escape "$f_value")\", \"inline\": true }"
      shift 2 
      ;; 
    *) echo "Unknown parameter: $1"; exit 1 ;;
  esac
done

if [ -z "$WEBHOOK_URL" ]; then
  # Fail silently if not configured, or log to stderr
  echo "Warning: DISCORD_WEBHOOK_URL not configured. Skipping notification." >&2
  exit 0
fi

# Set Styles based on Status
case "$STATUS" in
  success|ok)
    COLOR=3066993 # Green
    THUMBNAIL="$ICON_SUCCESS"
    ;;
  error|fail|failure)
    COLOR=15158332 # Red
    THUMBNAIL="$ICON_ERROR"
    [ -z "$PING" ] && PING="" # Optional: Auto-ping on error?
    ;;
  warn|warning)
    COLOR=16776960 # Yellow
    THUMBNAIL="$ICON_WARN"
    ;;
  *)
    COLOR=3447003 # Blue
    THUMBNAIL="$ICON_INFO"
    ;;
esac

# Sanitize inputs
TITLE_SAFE=$(json_escape "$TITLE")
DESC_SAFE=$(json_escape "$DESCRIPTION")

# Construct JSON Payload
# Note: We use manual string building to avoid dependencies like 'jq'
PAYLOAD=$(cat <<JSON
{
  "content": "$PING",
  "embeds": [{
    "title": "$TITLE_SAFE",
    "description": "$DESC_SAFE",
    "color": $COLOR,
    "thumbnail": { "url": "$THUMBNAIL" },
    "fields": [ $FIELDS_JSON ],
    "footer": {
      "text": "$FOOTER"
    },
    "timestamp": "$TIMESTAMP"
  }]
}
JSON
)

# Send Request
curl -s -S -H "Content-Type: application/json" \
     -X POST \
     -d "$PAYLOAD" \
     "$WEBHOOK_URL" >/dev/null