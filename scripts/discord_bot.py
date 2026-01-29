import discord
import os
import subprocess
import asyncio
from discord.ext import commands

# --- CONFIGURATION ---
# Load config from environment variables (set by systemd or manually)
TOKEN = os.getenv('DISCORD_BOT_TOKEN')
try:
    ALLOWED_USER_ID = int(os.getenv('DISCORD_USER_ID', '0'))
except ValueError:
    print("Error: DISCORD_USER_ID must be an integer.")
    exit(1)

CT_ID = os.getenv('CT_ID', '1550')
SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))

# Check config
if not TOKEN:
    print("Error: DISCORD_BOT_TOKEN not found.")
    exit(1)

# Setup Bot
intents = discord.Intents.default()
intents.message_content = True
bot = commands.Bot(command_prefix='!', intents=intents)

def run_shell(command):
    """Runs a shell command and returns output."""
    try:
        result = subprocess.run(command, shell=True, capture_output=True, text=True, timeout=120)
        return result.stdout + result.stderr
    except subprocess.TimeoutExpired:
        return "Error: Command timed out."
    except Exception as e:
        return str(e)

@bot.event
async def on_ready():
    print(f'Logged in as {bot.user} (ID: {bot.user.id})')
    print('------')

async def is_authorized(ctx):
    if ctx.author.id != ALLOWED_USER_ID:
        await ctx.send("⛔ You are not authorized to control this server.")
        return False
    return True

# --- COMMANDS ---

@bot.command()
async def ping(ctx):
    await ctx.send('Pong! 🏓')

@bot.command()
async def status(ctx):
    """Shows full server status report."""
    msg = await ctx.send("🔍 Checking status...")
    # Calls our existing monitor script in report mode
    # Note: The script sends a webhook, but we also want to see output here if needed.
    # However, since the script uses the webhook logic, calling it directly is cleaner.
    cmd = f"{SCRIPTS_DIR}/monitor_health.sh {CT_ID} --report"
    run_shell(cmd)
    await msg.edit(content="✅ Status report sent via Webhook!")

@bot.command()
async def start(ctx):
    """Starts the Terraria Server Container."""
    if not await is_authorized(ctx): return
    await ctx.send(f"🚀 Starting Container {CT_ID}...")
    output = run_shell(f"pct start {CT_ID}")
    if "is already running" in output:
        await ctx.send("⚠️ Server is already running.")
    else:
        await ctx.send("✅ Start command issued. Watch for the 'Server Starting' notification.")

@bot.command()
async def stop(ctx):
    """Stops the Terraria Server."""
    if not await is_authorized(ctx): return
    await ctx.send(f"🛑 Stopping Terraria Service on {CT_ID}...")
    # Use systemctl inside CT to stop cleanly
    output = run_shell(f"pct exec {CT_ID} -- systemctl stop terraria")
    await ctx.send(f"✅ Stop command sent.")

@bot.command()
async def restart(ctx):
    """Restarts the Terraria Server."""
    if not await is_authorized(ctx): return
    await ctx.send(f"🔄 Restarting Terraria Service on {CT_ID}...")
    run_shell(f"pct exec {CT_ID} -- systemctl restart terraria")
    await ctx.send("✅ Restart command sent.")

@bot.command()
async def backup(ctx):
    """Triggers a manual backup."""
    if not await is_authorized(ctx): return
    await ctx.send("💾 Starting manual backup... this may take a moment.")
    # Run the backup script
    cmd = f"{SCRIPTS_DIR}/backup_terraria.sh {CT_ID}"
    # We run this non-blocking in a real scenario, but for simplicity here we wait
    # Using run_in_executor to not block the bot heartbeat
    await bot.loop.run_in_executor(None, lambda: run_shell(cmd))
    await ctx.send("✅ Backup process finished (check Webhook for details).")

@bot.command()
async def cmd(ctx, *, command):
    """Runs a raw command inside the server console (Advanced)."""
    if not await is_authorized(ctx): return
    # This requires attaching to screen/tmux or using a pipe. 
    # Since we use simple systemd service, input injection is hard without TShock.
    # For Vanilla, we can't easily inject commands unless we used tmux/screen in the service file.
    # This is a placeholder.
    await ctx.send("⚠️ Console command injection is not supported in Vanilla Systemd mode yet.")

# Run
bot.run(TOKEN)
