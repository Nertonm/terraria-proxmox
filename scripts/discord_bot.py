import discord
import os
import subprocess
import asyncio
from discord.ext import commands

# --- CONFIGURATION (INTERNAL) ---
TOKEN = os.getenv('DISCORD_BOT_TOKEN')
try:
    ALLOWED_USER_ID = int(os.getenv('DISCORD_USER_ID', '0'))
except ValueError:
    ALLOWED_USER_ID = 0

# Configuration for Host Mode
CT_ID = os.getenv('CT_ID')

# Paths inside the container
SCRIPTS_DIR = "/opt/terraria"

# Setup Bot
intents = discord.Intents.default()
intents.message_content = True
bot = commands.Bot(command_prefix='!', intents=intents)

def run_shell(command):
    """Runs a shell command. Adapts to Container or Host mode."""
    try:
        if CT_ID:
            # Host Mode: Wrap command in pct exec
            # Escape single quotes for bash -c
            safe_command = command.replace("'", "'\\''")
            full_command = f"pct exec {CT_ID} -- bash -c '{safe_command}'"
        else:
            # Container Mode: Run directly
            full_command = command
            
        result = subprocess.run(full_command, shell=True, capture_output=True, text=True, timeout=60)
        return result.stdout + result.stderr
    except Exception as e:
        return str(e)

@bot.event
async def on_ready():
    print(f'Bot internal log: Logged in as {bot.user}')

async def is_authorized(ctx):
    if ALLOWED_USER_ID != 0 and ctx.author.id != ALLOWED_USER_ID:
        await ctx.send("⛔ Unauthorized.")
        return False
    return True

# --- COMMANDS ---

@bot.command()
async def ping(ctx):
    await ctx.send('Internal Bot is online! 🏓')

@bot.command()
async def status(ctx):
    """Shows server metrics from inside the container."""
    # We can use simple local commands here
    mem = run_shell("free -m | grep Mem: | awk '{print $3\"MB / \"$2\"MB\"}'")
    uptime = run_shell("uptime -p")
    players = run_shell("ss -tn state established '( sport = :7777 )' | grep -v Recv-Q | wc -l")
    
    embed = discord.Embed(title="🎮 Terraria Server Status", color=discord.Color.blue())
    embed.add_field(name="Players Online", value=players.strip(), inline=True)
    embed.add_field(name="RAM Usage", value=mem.strip(), inline=True)
    embed.add_field(name="Uptime", value=uptime.strip(), inline=False)
    await ctx.send(embed=embed)

@bot.command()
async def start(ctx):
    """Starts the Terraria Service (if container is running)."""
    if not await is_authorized(ctx): return
    await ctx.send("🚀 Starting Terraria Service...")
    # Try systemd, then supervisor, then openrc
    run_shell("systemctl start terraria || supervisorctl start terraria || rc-service terraria start")
    await ctx.send("✅ Start command sent.")

@bot.command()
async def stop(ctx):
    """Stops the Terraria Service (Container stays up)."""
    if not await is_authorized(ctx): return
    await ctx.send("🛑 Stopping Terraria Service...")
    run_shell("systemctl stop terraria || supervisorctl stop terraria || rc-service terraria stop")
    await ctx.send("✅ Stop command sent.")

@bot.command()
async def restart(ctx):
    """Restarts the Terraria service."""
    if not await is_authorized(ctx): return
    await ctx.send("🔄 Restarting Terraria service...")
    # Attempt to restart via systemctl or supervisor
    run_shell("systemctl restart terraria || supervisorctl restart terraria || rc-service terraria restart")
    await ctx.send("✅ Restart command sent.")

bot.run(TOKEN)