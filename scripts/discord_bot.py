import discord
import os
import asyncio
import signal
import re
import aiohttp
import datetime
import shutil
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

# Setup Bot
intents = discord.Intents.default()
intents.message_content = True
bot = commands.Bot(command_prefix='!', intents=intents)
bot.remove_command('help') # Remove default help to use custom one

async def run_shell_async(command):
    # ... (unchanged) ...
    try:
        if CT_ID and HAS_PCT:
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
                    title="🤖 Bot Online", 
                    description="O Gerenciador Terraria está ativo.", 
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
    if message.author.bot: return
    
    # Process Commands first
    await bot.process_commands(message)
    
    # Chat Bridge: Discord -> Terraria
    # Only if channel checks out and it's not a command
    if LOG_CHANNEL_ID and message.channel.id == LOG_CHANNEL_ID:
        if not message.content.startswith(bot.command_prefix):
             # Sanitize message to prevent shell/tmux injection
             clean_msg = message.content.replace("'", "").replace('"', "")
             # Limit length
             if len(clean_msg) > 100: clean_msg = clean_msg[:100] + "..."
             
             user = message.author.display_name
             # Send to Terraria Console via 'say'
             # Format: say [Discord] <User>: Message
             cmd = f"say [Discord] <{user}>: {clean_msg}"
             full_cmd = f"tmux send-keys -t terraria '{cmd}' Enter"
             
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
        with open(CHANNEL_ID_FILE, 'w') as f:
            f.write(str(LOG_CHANNEL_ID))
                 
        await ctx.send("👀 **Monitoramento ativado!** As atualizações aparecerão aqui.")
    except Exception as e:
        await ctx.send(f"⚠️ Falha ao salvar canal padrão: {e}")

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
            # "Name was slain by...", "Name fell...", "Name drowned..."
            elif any(x in line for x in [" was slain by ", " fell ", " drowned ", " burned ", " died "]):
                 # Basic filter to ensure it's a player death event
                 # Usually starts with PlayerName ...
                 # We avoid lines starting with IP like "192.168... was slain" (unlikely)
                 await channel.send(f"💀 *{line}*")
                    
        except Exception as e:
            print(f"Log monitor error: {e}")
            await asyncio.sleep(1)

async def is_authorized(ctx):
    if ALLOWED_USER_ID != 0 and ctx.author.id != ALLOWED_USER_ID:
        await ctx.send("⛔ **Unauthorized Access**")
        return False
    return True

async def update_status_task():
    """Background task to update bot status with player count or server state."""
    await bot.wait_until_ready()
    while not bot.is_closed():
        try:
            # Check if server is actually running
            pgrep = await run_shell_async("pgrep -f TerrariaServer")
            
            if not pgrep or "1" not in str(pgrep) and len(str(pgrep)) < 2: # Basic check
                # Process not found
                await bot.change_presence(activity=discord.Activity(type=discord.ActivityType.watching, name="Servidor Offline"))
                await asyncio.sleep(30) # Check less frequently if offline
                continue

            # Get Player Count
            res = await run_shell_async("ss -tn state established '( sport = :7777 )' | grep -v Recv-Q | wc -l")
            count = res.strip() or "0"
            
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
    if not await is_authorized(ctx): return
    
    # Sanitize inputs (Basic check to avoid breakout, though tmux send-keys is relatively safe as it types text)
    if any(c in cmd_text for c in [';', '&&', '`']):
        await ctx.send("⚠️ **Unsafe characters detected.** Command blocked.")
        return

    # tmux send-keys logic
    # We send the command + Enter
    full_cmd = f"tmux send-keys -t terraria '{cmd_text}' Enter"
    
    async with ctx.typing():
        # Capture current log size
        log_size_before = 0
        if os.path.exists(LOG_FILE):
             try:
                 log_size_before = os.path.getsize(LOG_FILE)
             except: pass

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
             await ctx.send(f"✅ **Enviado:** `{cmd_text}`\n**Console Output:**\n```bash\n{logs}\n```")
        except:
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
        
        embed.set_footer(text="Terraria Proxmox Manager • Interactive Mode")
        
        view = ServerControlView(ctx)
        await ctx.send(embed=embed, view=view)

class ServerControlView(discord.ui.View):
    def __init__(self, ctx):
        super().__init__(timeout=60)
        self.ctx = ctx

    async def interaction_check(self, interaction):
        if interaction.user.id != self.ctx.author.id:
            await interaction.response.send_message("⛔ Estes botões não são para você!", ephemeral=True)
            return False
        return True

    @discord.ui.button(label="Iniciar", style=discord.ButtonStyle.success, emoji="▶️")
    async def start_btn(self, interaction: discord.Interaction, button: discord.ui.Button):
        await interaction.response.send_message("🚀 Iniciando servidor...", ephemeral=True)
        await run_shell_async("systemctl start terraria")
        
    @discord.ui.button(label="Reiniciar", style=discord.ButtonStyle.primary, emoji="🔄")
    async def restart_btn(self, interaction: discord.Interaction, button: discord.ui.Button):
        await interaction.response.send_message("🔄 Reiniciando servidor...", ephemeral=True)
        await run_shell_async("systemctl restart terraria")

    @discord.ui.button(label="Parar", style=discord.ButtonStyle.danger, emoji="🛑")
    async def stop_btn(self, interaction: discord.Interaction, button: discord.ui.Button):
        await interaction.response.send_message("🛑 Parando servidor...", ephemeral=True)
        await run_shell_async("systemctl stop terraria")
        
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
    embed = discord.Embed(title="🤖 Comandos Terraria Bot", description="Controle seu servidor diretamente pelo Discord.", color=discord.Color.blue())
    
    embed.add_field(name="🎮 **Gerenciamento**", value="`!status` - Info do Servidor & Jogadores\n`!start` - Iniciar Servidor\n`!stop` - Parar Servidor\n`!restart` - Reinício Instantâneo\n`!reboot [min]` - Reinício Suave com Aviso", inline=False)
    
    embed.add_field(name="🛠️ **Manutenção**", value="`!update <ver>` - Atualizar servidor\n`!backup` - Backup Manual do Mundo\n`!storage` - Ver Tamanho de Disco\n`!logs [linhas]` - Ver Logs do Servidor\n`!save` - Forçar Salvamento", inline=False)
    
    embed.add_field(name="👮 **Moderação**", value="`!kick <nome> [motivo]` - Expulsar Jogador\n`!ban <nome> [motivo]` - Banir Jogador", inline=False)

    embed.add_field(name="💬 **Console**", value="`!say <msg>` - Enviar Mensagem no Chat\n`!cmd <comando>` - Comando RCON/Console", inline=False)
    
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
    
    await ctx.send(f"⏳ **Reinício Suave Agendado em {minutes} minutos.**")
    
    # Countdown
    for i in range(minutes, 0, -1):
        # Notify in-game
        msg = f"say [Server] Reiniciando em {i} minuto(s)... Salve seus itens!"
        if i == 1:
             msg = f"say [Server] Reiniciando em 60 segundos! AVISO FINAL!"
             
        await run_shell_async(f"tmux send-keys -t terraria '{msg}' Enter")
        
        # Wait 60s (unless it's the last minute, handle differently if we wanted seconds logic)
        if i > 0:
             await asyncio.sleep(60)

    # Final Save
    await run_shell_async("tmux send-keys -t terraria 'say [Server] Salvando mundo...' Enter")
    await run_shell_async("tmux send-keys -t terraria 'save' Enter")
    await asyncio.sleep(2)
    
    await ctx.send("🔄 **Reiniciando agora...**")
    await run_shell_async("systemctl restart terraria")
    await wait_and_verify(ctx, "Restart", verify_running=True)

if __name__ == "__main__":
    bot.run(TOKEN)
