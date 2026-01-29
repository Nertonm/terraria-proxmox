#!/bin/bash
set -euo pipefail

# Terraria Discord Bot Setup
# Installs Python environment and Systemd Service

CT_ID=${1:-1550}
ARG_TOKEN=${2:-""}
ARG_USER_ID=${3:-""}

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOT_SCRIPT="$PROJECT_DIR/scripts/discord_bot.py"
VENV_DIR="$PROJECT_DIR/.venv"

echo "--- Setting up Discord Bot for CT $CT_ID ---"

# 1. Install Dependencies
echo "Installing Python dependencies (requires sudo)..."
apt-get update && apt-get install -y python3-venv python3-pip

# 2. Create Virtual Environment
if [ ! -d "$VENV_DIR" ]; then
    echo "Creating Python Virtual Environment..."
    python3 -m venv "$VENV_DIR"
fi

# 3. Install discord.py
echo "Installing discord.py library..."
"$VENV_DIR/bin/pip" install discord.py

# 4. Configure Secrets
echo ""
echo "--- Configuration ---"

if [ -n "$ARG_TOKEN" ]; then
    BOT_TOKEN="$ARG_TOKEN"
else
    echo "You need a Discord Bot Token from: https://discord.com/developers/applications"
    read -rp "Enter Bot Token: " BOT_TOKEN
fi

if [ -n "$ARG_USER_ID" ]; then
    USER_ID="$ARG_USER_ID"
else
    echo "To prevent abuse, only ONE user is allowed to control the bot."
    echo "Right-click your name in Discord -> Copy ID (Enable Developer Mode if missing)"
    read -rp "Enter YOUR User ID: " USER_ID
fi

# 5. Create Systemd Service
SERVICE_FILE="/etc/systemd/system/terraria-bot.service"
echo "Creating systemd service at $SERVICE_FILE..."

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Terraria Discord Commander Bot
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$PROJECT_DIR
Environment="DISCORD_BOT_TOKEN=$BOT_TOKEN"
Environment="DISCORD_USER_ID=$USER_ID"
Environment="CT_ID=$CT_ID"
ExecStart=$VENV_DIR/bin/python $BOT_SCRIPT
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# 6. Enable and Start
systemctl daemon-reload
systemctl enable --now terraria-bot

echo ""
echo "--- Bot Installed & Started! ---"
echo "Check status: systemctl status terraria-bot"
echo "Try typing '!ping' or '!status' in your Discord server."
