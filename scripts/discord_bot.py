import discord
import os
import asyncio
import signal
import re
import aiohttp
import datetime
import shutil
import shlex
from discord.ext import commands

# --- CONFIGURATION (INTERNAL) ---
TOKEN = os.getenv('DISCORD_BOT_TOKEN')
try:
    ALLOWED_USER_ID = int(os.getenv('DISCORD_USER_ID', '0'))
except ValueError:
    ALLOWED_USER_ID = 0

# Configuration for Host Mode
CT_ID = os.getenv('CT_ID')
HAS_PCT = shutil.which('pct') is not None
SERVER_DIR = "/opt/terraria"
LOG_FILE = f"{SERVER_DIR}/server_output.log"
CONFIG_FILE = f"{SERVER_DIR}/serverconfig.txt"
CHANNEL_ID_FILE = f"{SERVER_DIR}/.discord_channel_id"

# Detect Service Manager
SERVICE_CMD = "systemctl" # default
if shutil.which('supervisorctl'):
    SERVICE_CMD = "supervisorctl"
elif not shutil.which('systemctl'):
     # Fallback if neither found (unlikely in this setup, but possible in raw docker)
     print("Warning: Neither systemctl nor supervisorctl found.")

# Setup Bot
intents = discord.Intents.default()
intents.message_content = True
bot = commands.Bot(command_prefix='!', intents=intents)
bot.remove_command('help') # Remove default help to use custom one

async def run_shell_async(command):
    try:
        if CT_ID and HAS_PCT:
            full_command = f"pct exec {CT_ID} -- bash -c {shlex.quote(command)}"
        else:
            full_command = command

        process = await asyncio.create_subprocess_shell(
            full_command,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE
        )
        stdout, stderr = await process.communicate()
        stdout_text = stdout.decode(errors='replace').strip()
        stderr_text = stderr.decode(errors='replace').strip()

        if process.returncode != 0:
            return stderr_text or stdout_text or f"Command failed with exit code {process.returncode}"

        return stdout_text
    except Exception as e:
        return f"Error: {str(e)}"


def build_tmux_command(command_text):
    return f"tmux send-keys -t terraria {shlex.quote(command_text)} Enter"


async def get_public_ip():
    try:
        async with aiohttp.ClientSession() as session:
            async with session.get('https://api.ipify.org', timeout=5) as resp:
                IP = await resp.text()
                return IP.strip()
    except Exception as e:
        print(f"Failed to get IP: {e}")
        return "Unknown IP"

async def get_server_info():
    info = {'world': 'Unknown', 'port': '7777'}
    try:
        # Read config via shell (cat) to support both Host and Container modes
        content = await run_shell_async(f"cat {CONFIG_FILE}")
        
        if not content or "No such file" in content:
            return info
            
        for line in content.split('\n'):
            line = line.strip()
            if line.startswith("world="):
                # Format: world=/path/to/WorldName.wld
                path = line.split("=", 1)[1]
                info['world'] = os.path.basename(path).replace(".wld", "")
            elif line.startswith("port="):
                info['port'] = line.split("=", 1)[1]
    except Exception as e:
        print(f"Error parsing serverconfig: {e}")
        
    return info


async def get_player_count(port):
    if not re.fullmatch(r"\d+", str(port or "")):
        port = "7777"

    result = await run_shell_async(
        "if command -v ss >/dev/null 2>&1; then "
        f"ss -tn state established '( sport = :{port} )' | grep -v Recv-Q | wc -l; "
        "elif command -v netstat >/dev/null 2>&1; then "
        f"netstat -tn | grep ':{port}' | grep ESTABLISHED | wc -l; "
        "else echo 0; fi"
    )

    count = result.strip()
    return count if re.fullmatch(r"\d+", count) else "0"



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
            
            # Startup Notification
            channel = bot.get_channel(LOG_CHANNEL_ID)
            if channel:
                embed = discord.Embed(
                    title="\U0001f916 Bot Online", 
                    description="O Gerenciador Terraria est\u00e1 ativo.", 
                    color=discord.Color.blue()
                )
                embed.add_field(name="Ping", value=f"{round(bot.latency * 1000)}ms", inline=True)
                embed.timestamp = datetime.datetime.now()
                await channel.send(embed=embed)
        except Exception as e:
            print(f"Failed to restore channel or send startup msg: {e}")

    if not hasattr(bot, 'status_task'):
        bot.status_task = bot.loop.create_task(update_status_task())
    if not hasattr(bot, 'log_task'):
        bot.log_task = bot.loop.create_task(log_monitor_task())

# Global variable to store the channel receiving updates
LOG_CHANNEL_ID = None

@bot.event
async def on_message(message):
    # Avoid bot self-loops
    if message.author.bot:
        return
    
    # Process Commands first
    await bot.process_commands(message)
    
    # Chat Bridge: Discord -> Terraria
    # Only if channel checks out and it's not a command
    if LOG_CHANNEL_ID and message.channel.id == LOG_CHANNEL_ID:
        if not message.content.startswith(bot.command_prefix):
             clean_msg = message.content.replace("\n", " ").replace("\r", " ").strip()
             if len(clean_msg) > 100:
                 clean_msg = clean_msg[:100] + "..."
             
             user = message.author.display_name
             # Send to Terraria Console via 'say'
             # Format: say [Discord] <User>: Message
             cmd = f"say [Discord] <{user}>: {clean_msg}"
             full_cmd = build_tmux_command(cmd)
             
             # Fire and forget (don't wait for output to keep chat snappy)
             asyncio.create_task(run_shell_async(full_cmd))

@bot.command()
async def monitor(ctx):
    """Sets the current channel to receive Join/Leave notifications."""
    if not await is_authorized(ctx): return
    global LOG_CHANNEL_ID
    LOG_CHANNEL_ID = ctx.channel.id
    
    # Save Persistence
    try:
        # Save locally (bot's environment)
        with open(CHANNEL_ID_FILE, 'w', encoding='utf-8') as f:
            f.write(str(LOG_CHANNEL_ID))
                 
        await ctx.send("\U0001f440 **Monitoramento ativado!** As atualiza\u00e7\u00f5es aparecer\u00e3o aqui.")
    except Exception as e:
        await ctx.send(f"\u26a0\ufe0f Falha ao salvar canal padr\u00e3o: {e}")

async def log_monitor_task():
    """Continuously reads the server log for Join/Leave events."""
    await bot.wait_until_ready()
    
    # Wait for the log file to exist before tailing
    while not os.path.exists(LOG_FILE):
        await asyncio.sleep(10)
    
    # Use tail -F to follow the file (works well with rotation/restarts)
    process = await asyncio.create_subprocess_exec(
        'tail', '-F', '-n', '0', LOG_FILE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE
    )

    print("Log Monitor started.")
    
    while not bot.is_closed():
        try:
            line_bytes = await process.stdout.readline()
            if not line_bytes:
                break 
                
            line = line_bytes.decode('utf-8', errors='ignore').strip()
            
            if LOG_CHANNEL_ID is None: continue
            channel = bot.get_channel(LOG_CHANNEL_ID)
            if not channel: continue

            timestamp = datetime.datetime.now().strftime("%H:%M")
            
            # Logic: Join/Leave detection
            if "has joined." in line:
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
            
            # Chat: <Name> Message
            elif line.startswith("<") and "> " in line:
                 # Standard Terraria Chat: <Name> Message
                 # Exclude [Server] or special tags if needed
                 parts = line.split("> ", 1)
                 if len(parts) == 2:
                     name = parts[0][1:]
                     msg = parts[1]
                     # Don't echo back our own [Discord] messages if they appear in logs
                     if "[Discord]" not in name:
                         await channel.send(f"💬 **{name}**: {msg}")

            # Death Messages (Heuristic)
            elif any(x in line for x in [" was slain by ", " fell ", " drowned ", " burned ", " died "]):
                 await channel.send(f"💀 *{line}*")

            # World Generation Progress (Heuristic: "10.0% - Step Name")
            elif "% - " in line:
                 # Rate limit updates to avoid API spam (Discord limits edits)
                 now = datetime.datetime.now().timestamp()
                 
                 # Initialize state if needed (attach to bot to persist across loop iterations)
                 if not hasattr(bot, 'gen_progress_msg'): bot.gen_progress_msg = None
                 if not hasattr(bot, 'gen_last_update'): bot.gen_last_update = 0
                 
                 # Pattern: 19.3% - Adding more grass
                 # Clean up the line to be a nice status
                 status_text = line.strip()
                 
                 # Update immediately if first time, else check throttle (2.5s)
                 if bot.gen_progress_msg is None:
                     embed = discord.Embed(title="🌍 Generating World - Auto-Repair", description=f"`{status_text}`", color=discord.Color.gold())
                     bot.gen_progress_msg = await channel.send(embed=embed)
                     bot.gen_last_update = now
                 elif now - bot.gen_last_update > 2.5:
                     try:
                         embed = discord.Embed(title="🌍 Generating World - Auto-Repair", description=f"`{status_text}`", color=discord.Color.gold())
                         await bot.gen_progress_msg.edit(embed=embed)
                         bot.gen_last_update = now
                     except discord.NotFound:
                         # Message deleted, recreate
                         bot.gen_progress_msg = await channel.send(embed=embed)
            
            # Detect Generation Complete (or Server Start) to cleanup
            if bot.get_channel(LOG_CHANNEL_ID) and hasattr(bot, 'gen_progress_msg') and bot.gen_progress_msg:
                 if "Listening on port" in line or "Server shut down" in line or "Setting up" in line:
                     try:
                         # clear the progress message
                         await bot.gen_progress_msg.delete()
                     except: pass
                     bot.gen_progress_msg = None
                    
        except Exception as e:
            print(f"Log monitor error: {e}")
            await asyncio.sleep(1)

async def is_authorized(ctx):
    # Public Commands (whitelist)
    if ctx.command and ctx.command.name in ['ping', 'status', 'help']:
        return True

    # 1. Hardcoded Owner
    if ALLOWED_USER_ID != 0 and ctx.author.id == ALLOWED_USER_ID:
        return True
    
    # 2. Server Administrators
    if ctx.guild and ctx.author.guild_permissions.administrator:
        return True
        
    await ctx.send("⛔ **Acesso Negado** (Requer permissão de Administrador)")
    return False

async def update_status_task():
    """Background task to update bot status with player count or server state."""
    await bot.wait_until_ready()
    while not bot.is_closed():
        try:
            # Check if server is actually running
            pgrep = await run_shell_async("pgrep -f TerrariaServer")
            
            if not pgrep or len(pgrep.strip()) == 0:
                # Process not found
                await bot.change_presence(activity=discord.Activity(type=discord.ActivityType.watching, name="Servidor Offline"))
                await asyncio.sleep(30) # Check less frequently if offline
                continue

            server_info = await get_server_info()
            count = await get_player_count(server_info["port"])
            
            activity_text = f"Terraria com {count} jogadores"
            await bot.change_presence(activity=discord.Game(name=activity_text))
            
        except Exception as e:
            print(f"Status update error: {e}")
        
        await asyncio.sleep(30) # Update every 30s


@bot.command()
async def shutdown(ctx):
    """Desliga o bot graciosamente (Apenas Admin)."""
    if not await is_authorized(ctx): return
    await ctx.send("🛑 **Desligando bot...**")
    await bot.close()

@bot.command()
async def kick(ctx, player: str, *, reason: str = "Sem motivo"):
    """Expulsa um jogador: !kick "Nome" Motivo"""
    if not await is_authorized(ctx): return
    await command(ctx, cmd_text=f'kick "{player}" "{reason}"')

@bot.command()
async def ban(ctx, player: str, *, reason: str = "Sem motivo"):
    """Bane um jogador: !ban "Nome" Motivo"""
    if not await is_authorized(ctx): return
    await command(ctx, cmd_text=f'ban "{player}" "{reason}"')

# End of Helpers, Start of Commands

@bot.command(aliases=['exec', 'cmd'])
async def command(ctx, *, cmd_text: str):
    """Sends a raw command to the server console."""
    if not await is_authorized(ctx):
        return
    
    # Sanitize inputs (Basic check to avoid breakout, though tmux send-keys is relatively safe as it types text)
    if any(c in cmd_text for c in [";", "&&", "`", "\n", "\r"]):
        await ctx.send("⚠️ **Unsafe characters detected.** Command blocked.")
        return

    # tmux send-keys logic
    # We send the command + Enter
    full_cmd = build_tmux_command(cmd_text)
    
    async with ctx.typing():
        res = await run_shell_async(full_cmd)
        
        if res:
             await ctx.send(f"⚠️ Erro ao enviar: `{res}`")
             return

        # Wait for execution and read new log lines
        await asyncio.sleep(1.0)
        
        try:
             # tail the bytes added since log_size_before
             # easier method: just tail last 10 lines and try to find relevance, 
             # or just show last few lines. Suffixing command with unique ID is hard in tmux.
             # We will show the last 6 lines.
             logs = await run_shell_async(f"tail -n 6 {LOG_FILE}")
             if not logs:
                 logs = "(No output captured)"
             await ctx.send(f"✅ **Enviado:** `{cmd_text}`\n**Console Output:**\n```bash\n{logs}\n```")
        except Exception:
             await ctx.send(f"✅ **Enviado:** `{cmd_text}` (Logs indisponíveis)")

@bot.command()
async def update(ctx, version: str):
    """Atualiza o servidor: !update 1450"""
    if not await is_authorized(ctx): return
    
    # regex validator for simple version (digits with optional dots)
    if not re.match(r'^\d+$', version):
        await ctx.send("⚠️ Formato de versão inválido. Use apenas números (ex: `1450` para 1.4.5.0).")
        return

    await ctx.send(f"🔄 **Iniciando atualização para v{version}...**\nIsso pode levar alguns minutos. O servidor ficará offline.")
    
    # We are running inside the container or on host.
    # The update_terraria.sh expects CT_ID as argument 1.
    # If we are INSIDE the container, we don't use pct exec.
    # However, existing script uses `pct exec`. This implies the BOT is meant to run on HOST.
    # BUT `setup_bot.sh` installs it inside container? No, `setup_bot.sh` has `CT_ID` var but installs locally?
    # Wait, `setup_bot.sh` installs to `$PROJECT_DIR`.
    # If the bot runs ON HOST, it can use `pct exec`.
    # If the bot runs INSIDE container, `pct` command won't exist.
    
    # Check if we have 'pct'
    check_pct = await run_shell_async("which pct")
    
    cmd = ""
    if "pct" in check_pct and CT_ID:
        # Running on Host
        cmd = f"{os.getcwd()}/scripts/update_terraria.sh {CT_ID} {version}"
    else:
        # Running inside container? 
        # The update script uses `pct exec`. It is NOT designed to run inside container.
        # We must warn user.
        await ctx.send("⚠️ Este bot está rodando dentro do container (provavelmente). O script de atualização requer execução no Host Proxmox.")
        return

    async with ctx.typing():
        res = await run_shell_async(cmd)
        
        if "Update Complete" in res:
             await ctx.send("✅ **Atualização Concluída com Sucesso!**\nVerifique o `!status`.")
        else:
             # Crop long output
             if len(res) > 1800: res = res[-1800:]
             await ctx.send(f"❌ **Erro na Atualização:**\n```bash\n{res}\n```")

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
    # Status is public
    await send_status_embed(ctx)

async def send_status_embed(ctx):
    async with ctx.typing():
        # Parallel Tasks
        ip_task = asyncio.create_task(get_public_ip())
        mem_task = asyncio.create_task(run_shell_async("free -m | grep Mem: | awk '{print $3\"MB / \"$2\"MB\"}'"))
        uptime_task = asyncio.create_task(run_shell_async("uptime -p || uptime"))
        server_info_task = asyncio.create_task(get_server_info())
        
        public_ip, mem, uptime, server_info = await asyncio.gather(
            ip_task, mem_task, uptime_task, server_info_task
        )
        players = await get_player_count(server_info["port"])
        
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
        
        embed.set_footer(text="Terraria Proxmox Manager • Interactive Mode")
        
        view = ServerControlView(ctx)
        await ctx.send(embed=embed, view=view)

class ServerControlView(discord.ui.View):
    def __init__(self, ctx):
        super().__init__(timeout=60)
        self.ctx = ctx

    async def interaction_check(self, interaction):
        if interaction.user.id != self.ctx.author.id:
            await interaction.response.send_message("\u26d4 Estes bot\u00f5es n\u00e3o s\u00e3o para voc\u00ea!", ephemeral=True)
            return False
        return True

    @discord.ui.button(label="Iniciar", style=discord.ButtonStyle.success, emoji="▶️")
    async def start_btn(self, interaction: discord.Interaction, button: discord.ui.Button):
        await interaction.response.send_message("🚀 Iniciando servidor...", ephemeral=True)
        await run_shell_async(f"{SERVICE_CMD} start terraria")
        
    @discord.ui.button(label="Reiniciar", style=discord.ButtonStyle.primary, emoji="🔄")
    async def restart_btn(self, interaction: discord.Interaction, button: discord.ui.Button):
        await interaction.response.send_message("🔄 Reiniciando servidor...", ephemeral=True)
        await run_shell_async(f"{SERVICE_CMD} restart terraria")

    @discord.ui.button(label="Parar", style=discord.ButtonStyle.danger, emoji="🛑")
    async def stop_btn(self, interaction: discord.Interaction, button: discord.ui.Button):
        await interaction.response.send_message("🛑 Parando servidor...", ephemeral=True)
        await run_shell_async(f"{SERVICE_CMD} stop terraria")
        
    @discord.ui.button(label="Status", style=discord.ButtonStyle.secondary, emoji="📊")
    async def status_btn(self, interaction: discord.Interaction, button: discord.ui.Button):
        # Refresh the status view by calling send_status_embed again
        # We can't edit the original easily without passing message ref, so we send a new one.
        # Or ideally, we edit the interaction message.
        await interaction.response.defer()
        await send_status_embed(self.ctx)

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
    await run_shell_async(f"{SERVICE_CMD} start terraria")
    await wait_and_verify(ctx, "Start", verify_running=True)

@bot.command()
async def stop(ctx):
    if not await is_authorized(ctx): return
    await run_shell_async(f"{SERVICE_CMD} stop terraria")
    await wait_and_verify(ctx, "Stop", verify_running=False)

@bot.command()
async def restart(ctx):
    if not await is_authorized(ctx): return
    await run_shell_async(f"{SERVICE_CMD} restart terraria")
    await wait_and_verify(ctx, "Restart", verify_running=True)

# Graceful Shutdown
async def shutdown_bot():
    await bot.close()

def handle_sigterm(*args):
    asyncio.create_task(shutdown_bot())

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
    embed = discord.Embed(title="\U0001f916 Comandos Terraria Bot", description="Controle seu servidor diretamente pelo Discord.", color=discord.Color.blue())
    
    embed.add_field(name="\U0001f3ae **Gerenciamento**", value="`!status` - Info do Servidor & Jogadores\n`!start` - Iniciar Servidor\n`!stop` - Parar Servidor\n`!restart` - Rein\u00edcio Instant\u00e2neo\n`!reboot [min]` - Rein\u00edcio Suave com Aviso", inline=False)
    
    embed.add_field(name="\U0001f6e0\ufe0f **Manuten\u00e7\u00e3o**", value="`!update <ver>` - Atualizar servidor\n`!backup` - Backup Manual do Mundo\n`!storage` - Ver Tamanho de Disco\n`!logs [linhas]` - Ver Logs do Servidor\n`!save` - For\u00e7ar Salvamento", inline=False)
    
    embed.add_field(name="\U0001f46e **Modera\u00e7\u00e3o**", value="`!kick <nome> [motivo]` - Expulsar Jogador\n`!ban <nome> [motivo]` - Banir Jogador", inline=False)

    embed.add_field(name="\U0001f4ac **Console**", value="`!say <msg>` - Enviar Mensagem no Chat\n`!cmd <comando>` - Comando RCON/Console", inline=False)
    
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
    
    await ctx.send(f"\u23f3 **Rein\u00edcio Suave Agendado em {minutes} minutos.**")
    
    # Countdown
    for i in range(minutes, 0, -1):
        # Notify in-game
        msg = f"say [Server] Reiniciando em {i} minuto(s)... Salve seus itens!"
        if i == 1:
             msg = "say [Server] Reiniciando em 60 segundos! AVISO FINAL!"
             
        await run_shell_async(build_tmux_command(msg))
        
        # Wait 60s (unless it's the last minute, handle differently if we wanted seconds logic)
        if i > 0:
             await asyncio.sleep(60)

    # Final Save
    await run_shell_async(build_tmux_command("say [Server] Salvando mundo..."))
    await run_shell_async(build_tmux_command("save"))
    await asyncio.sleep(2)
    
    await ctx.send("🔄 **Reiniciando agora...**")
    await run_shell_async(f"{SERVICE_CMD} restart terraria")
    await wait_and_verify(ctx, "Restart", verify_running=True)

if __name__ == "__main__":
    if not TOKEN:
        raise SystemExit("DISCORD_BOT_TOKEN is not set")
    bot.run(TOKEN)
