import discord
import os
import asyncio
import signal
from discord.ext import commands

# --- CONFIGURATION (INTERNAL) ---
TOKEN = os.getenv('DISCORD_BOT_TOKEN')
try:
    ALLOWED_USER_ID = int(os.getenv('DISCORD_USER_ID', '0'))
except ValueError:
    ALLOWED_USER_ID = 0

# Configuration for Host Mode
CT_ID = os.getenv('CT_ID')

# Setup Bot
intents = discord.Intents.default()
intents.message_content = True
bot = commands.Bot(command_prefix='!', intents=intents)

async def run_shell_async(command):
    """Async wrapper for shell commands to prevent blocking the event loop."""
    try:
        if CT_ID:
            # Host Mode: Wrap command in pct exec
            # Escape single quotes for bash -c safety
            safe_command = command.replace("'", "'\\''")
            full_command = f"pct exec {CT_ID} -- bash -c '{safe_command}'"
        else:
            # Container Mode: Run directly
            full_command = command

        process = await asyncio.create_subprocess_shell(
            full_command,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE
        )
        stdout, stderr = await process.communicate()
        
        output = stdout.decode().strip()
        if stderr:
             output += "\n[STDERR]: " + stderr.decode().strip()
        return output

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
    """Shows server metrics from inside the container asynchronously."""
    async with ctx.typing():
        # Run commands in parallel for speed
        mem_task = asyncio.create_task(run_shell_async("free -m | grep Mem: | awk '{print $3\"MB / \"$2\"MB\"}'"))
        uptime_task = asyncio.create_task(run_shell_async("uptime -p"))
        players_task = asyncio.create_task(run_shell_async("ss -tn state established '( sport = :7777 )' | grep -v Recv-Q | wc -l"))
        
        mem, uptime, players = await asyncio.gather(mem_task, uptime_task, players_task)
        
        embed = discord.Embed(title="🎮 Terraria Server Status", color=discord.Color.blue())
        embed.add_field(name="Players Online", value=players.strip() or "0", inline=True)
        embed.add_field(name="RAM Usage", value=mem.strip(), inline=True)
        embed.add_field(name="Uptime", value=uptime.strip(), inline=False)
        await ctx.send(embed=embed)

@bot.command()
async def start(ctx):
    if not await is_authorized(ctx): return
    await ctx.send("🚀 Starting Terraria Service...")
    await run_shell_async("systemctl start terraria || supervisorctl start terraria || rc-service terraria start")
    await ctx.send("✅ Start command sent.")

@bot.command()
async def stop(ctx):
    if not await is_authorized(ctx): return
    await ctx.send("🛑 Stopping Terraria Service...")
    await run_shell_async("systemctl stop terraria || supervisorctl stop terraria || rc-service terraria stop")
    await ctx.send("✅ Stop command sent.")

@bot.command()
async def restart(ctx):
    if not await is_authorized(ctx): return
    await ctx.send("🔄 Restarting Terraria service...")
    await run_shell_async("systemctl restart terraria || supervisorctl restart terraria || rc-service terraria restart")
    await ctx.send("✅ Restart command sent.")

@bot.command()
async def backup(ctx):
    """Triggers a manual backup (Host Mode required for full backup script)."""
    if not await is_authorized(ctx): return
    
    # If we are inside the container, we might not have access to the host backup script easily unless mounted.
    # But usually this bot runs on host if --enable-bot was used in Host Mode? 
    # Actually install.sh installs this INSIDE the container usually.
    # Inside container backup focuses on world files only.
    
    await ctx.send("📦 Starting Backup process...")
    async with ctx.typing():
        # Simple internal backup logic: tar the Worlds folder
        res = await run_shell_async("tar -czf /tmp/world_backup_bot.tar.gz /home/terraria/.local/share/Terraria/Worlds")
        if "Error" in res:
             await ctx.send(f"❌ Backup failed: {res}")
        else:
             await ctx.send("✅ Backup created at `/tmp/world_backup_bot.tar.gz` (Internal Container Storage)")

# Graceful Shutdown Handler
async def shutdown():
    print("Shutting down bot...")
    await bot.close()

def handle_sigterm(*args):
    asyncio.create_task(shutdown())

signal.signal(signal.SIGTERM, handle_sigterm)

if __name__ == "__main__":
    try:
        bot.run(TOKEN)
    except Exception as e:
        print(f"Bot execution error: {e}")