import discord
import os
import asyncio
import signal
import re
import aiohttp
import datetime
from discord.ext import commands

# --- CONFIGURATION (INTERNAL) ---
TOKEN = os.getenv('DISCORD_BOT_TOKEN')
try:
    ALLOWED_USER_ID = int(os.getenv('DISCORD_USER_ID', '0'))
except ValueError:
    ALLOWED_USER_ID = 0

# Configuration for Host Mode
CT_ID = os.getenv('CT_ID')
SERVER_DIR = "/opt/terraria"
LOG_FILE = f"{SERVER_DIR}/server_output.log"
CONFIG_FILE = f"{SERVER_DIR}/serverconfig.txt"
CHANNEL_ID_FILE = f"{SERVER_DIR}/.discord_channel_id"

# Setup Bot
intents = discord.Intents.default()
intents.message_content = True
bot = commands.Bot(command_prefix='!', intents=intents)
bot.remove_command('help') # Remove default help to use custom one

async def run_shell_async(command):
    # ... (unchanged) ...
    try:
        if CT_ID:
            safe_command = command.replace("'", "'\\''")
            full_command = f"pct exec {CT_ID} -- bash -c '{safe_command}'"
        else:
            full_command = command

        process = await asyncio.create_subprocess_shell(
            full_command,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE
        )
        stdout, stderr = await process.communicate()
        return stdout.decode().strip()
    except Exception as e:
        return f"Error: {str(e)}"

# ... (Helpers unchanged) ...

@bot.event
async def on_ready():
    print(f'Bot internal log: Logged in as {bot.user}')
    
    # Restore Monitor Channel
    global LOG_CHANNEL_ID
    if os.path.exists(CHANNEL_ID_FILE):
        try:
            with open(CHANNEL_ID_FILE, 'r') as f:
                LOG_CHANNEL_ID = int(f.read().strip())
            print(f"Restored Monitor Channel ID: {LOG_CHANNEL_ID}")
        except:
            print("Failed to restore channel ID.")

    if not hasattr(bot, 'status_task'):
        bot.status_task = bot.loop.create_task(update_status_task())
    if not hasattr(bot, 'log_task'):
        bot.log_task = bot.loop.create_task(log_monitor_task())

# Global variable to store the channel receiving updates
LOG_CHANNEL_ID = None

@bot.command()
async def monitor(ctx):
    """Sets the current channel to receive Join/Leave notifications."""
    if not await is_authorized(ctx): return
    global LOG_CHANNEL_ID
    LOG_CHANNEL_ID = ctx.channel.id
    
    # Save Persistence
    try:
        # If Host Mode, we need to write inside container paths appropriately or just use shell
        # Since this bot runs INSIDE container usually (via install.sh setup), direct write is fine.
        # But if running in Host Mode, we must use `run_shell_async` to write echo.
        # Let's use generic run_shell_async for safety if CT_ID is set.
        if CT_ID:
             # Host mode write
             await run_shell_async(f"echo {LOG_CHANNEL_ID} > {CHANNEL_ID_FILE}")
        else:
             # Direct write
             with open(CHANNEL_ID_FILE, 'w') as f:
                 f.write(str(LOG_CHANNEL_ID))
                 
        await ctx.send("👀 **Monitoring activated!** Channel saved as default.")
    except Exception as e:
        await ctx.send(f"⚠️ Monitoring active but failed to save default: {e}")

async def log_monitor_task():
    """Continuously reads the server log for Join/Leave events."""
    await bot.wait_until_ready()
    
    # Wait for the log file to exist before tailing
    while not os.path.exists(LOG_FILE):
        await asyncio.sleep(10)
    
    # Use tail -F to follow the file (works well with rotation/restarts)
    # We use -n 0 to start reading only NEW lines
    process = await asyncio.create_subprocess_exec(
        'tail', '-F', '-n', '0', LOG_FILE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE
    )

    print("Log Monitor started.")
    
    while not bot.is_closed():
        line_bytes = await process.stdout.readline()
        if not line_bytes:
            break # Process died?
            
        line = line_bytes.decode('utf-8', errors='ignore').strip()
        
        # Check if we have a destination channel
        if LOG_CHANNEL_ID is None:
            continue
            
        channel = bot.get_channel(LOG_CHANNEL_ID)
        if not channel:
            continue

        # --- PARSING LOGIC ---
        # Format: "Name has joined." or "IP:Port Name has joined."
        
        try:
            timestamp = datetime.datetime.now().strftime("%H:%M")
            
            if "has joined." in line:
                # Extract Name: Clean up IP if present
                # Regex matches: (IP:Port )? (Name) has joined.
                match = re.search(r'(?:\d+\.\d+\.\d+\.\d+:\d+\s+)?(.+) has joined\.', line)
                if match:
                    player_name = match.group(1).strip()
                    embed = discord.Embed(description=f"**{player_name}** entrou no mundo! 🌍", color=discord.Color.green())
                    embed.set_footer(text=f"At {timestamp}")
                    await channel.send(embed=embed)
                    
            elif "has left." in line:
                match = re.search(r'(?:\d+\.\d+\.\d+\.\d+:\d+\s+)?(.+) has left\.', line)
                if match:
                    player_name = match.group(1).strip()
                    embed = discord.Embed(description=f"**{player_name}** saiu do mundo. 👋", color=discord.Color.red())
                    embed.set_footer(text=f"At {timestamp}")
                    await channel.send(embed=embed)
                    
        except Exception as e:
            print(f"Log Parse Error: {e}")

async def is_authorized(ctx):
    if ALLOWED_USER_ID != 0 and ctx.author.id != ALLOWED_USER_ID:
        await ctx.send("⛔ **Unauthorized Access**")
        return False
    return True

async def update_status_task():
    """Background task to update bot status with player count."""
    await bot.wait_until_ready()
    while not bot.is_closed():
        try:
            # Get Player Count
            res = await run_shell_async("ss -tn state established '( sport = :7777 )' | grep -v Recv-Q | wc -l")
            count = res.strip() or "0"
            
            # Show current count
            activity_text = f"Terraria with {count} players"
            
            await bot.change_presence(activity=discord.Game(name=activity_text))
        except Exception as e:
            print(f"Status update error: {e}")
        
        await asyncio.sleep(60) # Update every minute

@bot.command(aliases=['exec', 'cmd'])
async def command(ctx, *, cmd_text: str):
    """Sends a raw command to the server console."""
    if not await is_authorized(ctx): return
    
    # Sanitize inputs (Basic check to avoid breakout, though tmux send-keys is relatively safe as it types text)
    if any(c in cmd_text for c in [';', '&&', '`']):
        await ctx.send("⚠️ **Unsafe characters detected.** Command blocked.")
        return

    # tmux send-keys logic
    # We send the command + Enter
    full_cmd = f"tmux send-keys -t terraria '{cmd_text}' Enter"
    
    async with ctx.typing():
        res = await run_shell_async(full_cmd)
        if not res:
            await ctx.send(f"Evocado ao console: `/{cmd_text}`")
        else:
            await ctx.send(f"⚠️ Erro ao enviar: `{res}`")

@bot.command()
async def say(ctx, *, msg: str):
    """Broadcasts a message to the server chat."""
    if not await is_authorized(ctx): return
    # Terraria 'say' command format
    await command(ctx, cmd_text=f"say [Discord] {msg}")

@bot.command()
async def save(ctx):
    """Triggers a world save."""
    if not await is_authorized(ctx): return
    await command(ctx, cmd_text="save")
    await ctx.send("💾 **World Save triggered.**")

# --- COMMANDS ---

@bot.command()
async def ping(ctx):
    latency = round(bot.latency * 1000)
    await ctx.send(f'🏓 Pong! `{latency}ms`')

@bot.command()
async def status(ctx):
    """Shows comprehensive server status."""
    await send_status_embed(ctx)

async def send_status_embed(ctx):
    async with ctx.typing():
        # Parallel Tasks
        ip_task = asyncio.create_task(get_public_ip())
        mem_task = asyncio.create_task(run_shell_async("free -m | grep Mem: | awk '{print $3\"MB / \"$2\"MB\"}'"))
        uptime_task = asyncio.create_task(run_shell_async("uptime -p"))
        players_task = asyncio.create_task(run_shell_async("ss -tn state established '( sport = :7777 )' | grep -v Recv-Q | wc -l"))
        
        public_ip, mem, uptime, players = await asyncio.gather(ip_task, mem_task, uptime_task, players_task)
        server_info = await get_server_info()
        
        # Determine Status
        status_color = discord.Color.green()
        try:
            pgrep = await run_shell_async("pgrep -f TerrariaServer")
            if not pgrep:
                 status_title = "🔴 Server Offline"
                 status_color = discord.Color.red()
            else:
                 status_title = "🟢 Server Online"
        except:
             status_title = "❓ Status Unknown"
             status_color = discord.Color.orange()

        embed = discord.Embed(title=status_title, color=status_color)
        embed.set_thumbnail(url="https://terraria.org/assets/terraria-logo.png")
        
        embed.add_field(name="🌍 World", value=server_info['world'], inline=True)
        embed.add_field(name="👥 Players", value=f"{players.strip() or '0'}", inline=True)
        embed.add_field(name="📡 Address", value=f"`{public_ip}:{server_info['port']}`", inline=False)
        
        embed.add_field(name="💾 RAM Usage", value=mem.strip(), inline=True)
        embed.add_field(name="⏱️ Uptime", value=uptime.strip().replace("up ", ""), inline=True)
        
        embed.set_footer(text="Terraria Proxmox Manager")
        await ctx.send(embed=embed)

@bot.command(aliases=['log'])
async def logs(ctx, lines: int = 15):
    """Fetch the latest server logs."""
    if not await is_authorized(ctx): return
    if lines > 50: lines = 50 
    
    async with ctx.typing():
        log_content = await run_shell_async(f"tail -n {lines} {LOG_FILE}")
        
        # Clean up log content
        if not log_content or "No such file" in log_content:
            await ctx.send("⚠️ Log file not found or empty.")
            return

        # Format blocks to avoid Discord char limits
        if len(log_content) > 1900:
            log_content = log_content[-1900:]
            
        await ctx.send(f"**📜 Last {lines} lines of Server Log:**\n```bash\n{log_content}\n```")

async def wait_and_verify(ctx, action, verify_running=True):
    """Wait for an action to complete and verify status."""
    embed = discord.Embed(title=f"⏳ {action} in progress...", color=discord.Color.gold())
    status_msg = await ctx.send(embed=embed)
    
    # Wait a bit for service to change state
    await asyncio.sleep(5)
    
    # Check Verification
    pgrep = await run_shell_async("pgrep -f TerrariaServer")
    is_running = bool(pgrep)
    
    success = False
    if verify_running and is_running:
        success = True
        title = f"✅ Server {action} Successful"
        desc = "The Terraria process is running."
        color = discord.Color.green()
    elif not verify_running and not is_running:
        success = True
        title = f"✅ Server {action} Successful"
        desc = "The Terraria process has stopped."
        color = discord.Color.red() # Red here means stopped (success for stop)
    else:
        title = f"❌ Server {action} Failed" # Or taking too long
        desc = f"Expected running={verify_running}, but found running={is_running}. Check `!logs`."
        color = discord.Color.red()
        
    result_embed = discord.Embed(title=title, description=desc, color=color)
    await status_msg.edit(embed=result_embed)
    
    # If starting was verification, show status card too
    if verify_running and success:
        await asyncio.sleep(1)
        await send_status_embed(ctx)

@bot.command()
async def start(ctx):
    if not await is_authorized(ctx): return
    await run_shell_async("systemctl start terraria")
    await wait_and_verify(ctx, "Start", verify_running=True)

@bot.command()
async def stop(ctx):
    if not await is_authorized(ctx): return
    await run_shell_async("systemctl stop terraria")
    await wait_and_verify(ctx, "Stop", verify_running=False)

@bot.command()
async def restart(ctx):
    if not await is_authorized(ctx): return
    await run_shell_async("systemctl restart terraria")
    await wait_and_verify(ctx, "Restart", verify_running=True)

# Graceful Shutdown
async def shutdown():
    await bot.close()

def handle_sigterm(*args):
    asyncio.create_task(shutdown())

signal.signal(signal.SIGTERM, handle_sigterm)

# Duplicate runner removed properly
@bot.command()
async def backup(ctx):
    """Triggers a manual backup."""
    if not await is_authorized(ctx): return
    
    await ctx.send("📦 **Starting Manual Backup...**")
    
    async with ctx.typing():
        timestamp = await run_shell_async("date +%Y%m%d_%H%M%S")
        filename = f"world_backup_{timestamp}.tar.gz"
        dest = f"/tmp/{filename}"
        
        # Determine source path with a safe default
        # Note: Standard path for this project is /home/terraria/.local/share/Terraria/Worlds
        src = "/home/terraria/.local/share/Terraria/Worlds"
        
        # Verify source exists
        check = await run_shell_async(f"ls -d {src}")
        if "No such file" in check:
             await ctx.send(f"⚠️ Source directory not found: `{src}`. Backup skipped.")
             return

        res = await run_shell_async(f"tar -czf {dest} -C {src} .")
        
        if "Error" in res:
             await ctx.send(f"❌ Backup failed: {res}")
        else:
             file_size = await run_shell_async(f"du -h {dest} | cut -f1")
             await ctx.send(f"✅ **Backup Created!**\n📁 Path: `{dest}`\n📦 Size: `{file_size}`\n\n*(Save this file if you plan to destroy the container)*")

@bot.command(name="help")
async def help_command(ctx):
    """Shows this help message."""
    embed = discord.Embed(title="🤖 Terraria Bot Commands", description="Control your server directly from Discord.", color=discord.Color.blue())
    
    embed.add_field(name="🎮 **Management**", value="`!status` - Server Info & Players\n`!start` - Start Server\n`!stop` - Stop Server\n`!restart` - Instant Reboot\n`!reboot [min]` - Graceful Restart", inline=False)
    
    embed.add_field(name="🛠️ **Maintenance**", value="`!backup` - Manual World Backup\n`!storage` - Check Backup/World Sizes\n`!logs [lines]` - View Server Logs\n`!save` - Force Save World", inline=False)
    
    embed.add_field(name="💬 **Console**", value="`!say <msg>` - Message Players\n`!cmd <command>` - RCON/Console Command", inline=False)
    
    embed.set_thumbnail(url="https://terraria.org/assets/terraria-logo.png")
    embed.set_footer(text="Terraria Proxmox Manager")
    
    await ctx.send(embed=embed)

@bot.command(aliases=['backups', 'usage'])
async def storage(ctx):
    """Checks the size of Worlds and Backup files."""
    if not await is_authorized(ctx): return
    
    async with ctx.typing():
        # World Folder Size
        world_dir = "/home/terraria/.local/share/Terraria/Worlds"
        world_size = await run_shell_async(f"du -sh {world_dir} 2>/dev/null | cut -f1")
        if not world_size or "No such file" in world_size: world_size = "0B"
        
        # Manual Backups Size (/tmp/world_backup_*.tar.gz)
        # We check /tmp inside container where !backup saves
        backup_size = await run_shell_async("du -ch /tmp/world_backup_*.tar.gz 2>/dev/null | grep total | cut -f1")
        if not backup_size: backup_size = "0B"
        
        # Count of backups
        backup_count = await run_shell_async("ls -1 /tmp/world_backup_*.tar.gz 2>/dev/null | wc -l")
        
        embed = discord.Embed(title="💾 Storage Usage", color=discord.Color.teal())
        embed.add_field(name="🌍 Active World Data", value=f"`{world_size.strip()}`", inline=True)
        embed.add_field(name="📦 Tmp Backups", value=f"`{backup_size.strip()}`\n({backup_count.strip()} files)", inline=True)
        
        embed.set_footer(text="Note: !backup stores files in /tmp (ephemeral)")
        
        await ctx.send(embed=embed)


@bot.command()
async def reboot(ctx, minutes: int = 5):
    """Restarts the server gracefully with a countdown."""
    if not await is_authorized(ctx): return
    
    if minutes < 1: minutes = 1
    
    await ctx.send(f"⏳ **Scheduled Graceful Restart in {minutes} minutes.**")
    
    # Countdown
    for i in range(minutes, 0, -1):
        # Notify in-game
        msg = f"say [Server] Restarting in {i} minute(s)... Save your items!"
        if i == 1:
             msg = f"say [Server] Restarting in 60 seconds! FINAL WARNING!"
             
        await run_shell_async(f"tmux send-keys -t terraria '{msg}' Enter")
        
        # Wait 60s (unless it's the last minute, handle differently if we wanted seconds logic)
        if i > 0:
             await asyncio.sleep(60)

    # Final Save
    await run_shell_async("tmux send-keys -t terraria 'say [Server] Saving world...' Enter")
    await run_shell_async("tmux send-keys -t terraria 'save' Enter")
    await asyncio.sleep(2)
    
    await ctx.send("🔄 **Restarting now...**")
    await run_shell_async("systemctl restart terraria")
    await wait_and_verify(ctx, "Restart", verify_running=True)

if __name__ == "__main__":
    bot.run(TOKEN)
