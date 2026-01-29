# Terraria Proxmox LXC Manager 🚀

Solução "Enterprise-Grade" completa para implantar, gerenciar e monitorar servidores de Terraria (v1.4.5.0+) em **Proxmox VE**.

Agora com suporte **Multi-Distro** (Debian, Ubuntu, Alpine, Fedora) e resiliência a falhas de boot.

## ✨ Funcionalidades Principais

- **🛡️ Instalação Resiliente:** Suporte nativo a containers privilegiados e não-privilegiados, com detecção automática de init system (`systemd`, `openrc`, `supervisor`).
- **🔧 Auto-Repair de Mundo:** O servidor detecta se o mundo sumiu ou corrompeu e tenta regenerá-lo automaticamente na inicialização, prevenindo "Crash Loops".
- **⚙️ Configuração Granular:** Controle total via flags: Senha, MOTD, Prioridade, UPnP, Idioma, Banlist, NPC Streaming e Permissões Journey.
- **💬 Integração Rica com Discord:**
    - **Webhooks:** Notificações coloridas para Status (ON/OFF), Crash, Backups e Updates.
    - **Bot Bidirecional:** Controle o servidor via chat (`!start`, `!stop`, `!restart`, `!status`).
- **📦 Manutenção Automatizada:**
    - **Updates Seguros:** Verifica espaço em disco (>500MB) e limpa versões antigas.
    - **Backups Inteligentes:** Rotação automática e suporte a snapshot "frio" (para serviços).
- **📊 Monitoramento Proativo:** Alertas de RAM (>90%) e Disco Cheio com cooldown para evitar spam.

---

## ⚡ Instalação Rápida (Full Template)

Copie e edite este comando para uma instalação completa e monitorada:

```bash
git clone https://github.com/Nertonm/terraria-proxmox
cd terraria-proxmox
chmod +x install.sh scripts/*.sh

./install.sh 1550 \
  --template alpine \
  --version 1450 \
  --port 7777 \
  --maxplayers 8 \
  --world-name "TerrariaWorld" \
  --size 2 \
  --difficulty 1 \
  --password "mypassword" \
  --motd "Welcome to my Server" \
  --secure \
  --upnp \
  --priority 1 \
  --language "en-US" \
  --journey-permission 2 \
  --enable-backup \
  --backup-schedule "6h" \
  --enable-monitor \
  --discord-url "https://discord.com/api/webhooks/SEU_WEBHOOK_AQUI" \
  --enable-bot \
  --bot-token "SEU_BOT_TOKEN_AQUI" \
  --bot-userid "SEU_ID_NUMERICO"
```

### 📝 Legenda das Flags

| Flag | Descrição | Exemplo |
| :--- | :--- | :--- |
| `1550` | ID do Container (Posicional - Obrigatório) | `100` |
| `-t, --template` | Família do OS (`alpine`, `ubuntu`, `debian`, `fedora`) | `alpine` |
| `--version` | Versão do Servidor Terraria | `1450` |
| `--size` | Tamanho do Mundo (1=Small, 2=Medium, 3=Large) | `2` |
| `--difficulty` | Dificuldade (0=Classic, 1=Expert, 2=Master) | `1` |
| `--evil` | Bioma (1=Random, 2=Corrupt, 3=Crimson) | `2` |
| `--password` | Senha do servidor | `s3cr3t` |
| `--motd` | Mensagem do dia | `"Hello World"` |
| `--secure` | Ativa proteção anti-cheat | - |
| `--priority` | Prioridade do Processo (0-5, 0=Realtime, 1=High) | `1` |
| `--upnp` | Ativa redirecionamento de porta automático | - |
| `--language` | Idioma do servidor (ex: `en-US`, `pt-BR`) | `en-US` |
| `--banlist` | Nome do arquivo de banimentos | `banlist.txt` |
| `--npcstream` | Reduz skipping de inimigos (0: Off, 60: Default) | `60` |
| `--journey-permission` | Permissões Journey (0: Locked, 1: Host, 2: Todos) | `2` |
| `--autocreate` | Cria o mundo automaticamente (usa `--size`) | - |
| `--enable-backup` | Ativa a rotina de backups automáticos | - |
| `--backup-schedule` | Frequência (`daily`, `hourly`, `6h`, `weekly`) | `6h` |
| `--enable-monitor` | Ativa alertas de saúde (RAM/Disco) | - |
| `--discord-url` | Webhook URL para logs e notificações | `"https://..."` |
| `--enable-bot` | Instala o Bot de controle remoto | - |

---

## 🤖 Controle via Bot do Discord

Se ativado, o bot responde a comandos no canal onde ele tem permissão. Somente o usuário definido em `--bot-userid` pode executar comandos administrativos.

### Comandos:
- `!ping` - Verifica se o bot interno está vivo.
- `!status` - Relatório ao vivo (RAM, Uptime, Jogadores Online).
- `!start` / `!stop` / `!restart` - Controla o **serviço** do jogo (o container permanece ligado).

---

## 🛠️ Scripts de Manutenção (Host)

Execute estes scripts no host Proxmox para gerenciar o servidor:

### 🔄 Atualizar Server
Baixa a nova versão, verifica espaço em disco, faz backup do binário antigo e atualiza atomicamente.
```bash
./scripts/update_terraria.sh <CT_ID> <VERSAO>
# Exemplo: ./scripts/update_terraria.sh 1550 1451
```

### 💾 Backup & Restore
O sistema de backup é compatível com qualquer init system (para o serviço corretamente antes de copiar os dados).
```bash
# Backup Manual
./scripts/backup_terraria.sh <CT_ID>

# Restaurar Backup (Isso sobrescreve o mundo atual!)
./scripts/restore_terraria.sh <CT_ID> ./backups/terraria-1550-DATA.tar.gz
```

### 🏥 Health Check
Gera um relatório instantâneo de saúde.
```bash
./scripts/monitor_health.sh <CT_ID> --report
```

---

## 🐛 Troubleshooting

### Boot Loop Detectado?
Se o servidor notificar "Boot Loop Detected" no Discord:
1. Isso geralmente significa que o arquivo de mundo corrompeu ou sumiu, e o servidor está travado no menu "Choose World".
2. O sistema **Auto-Repair** tentará gerar um novo mundo automaticamente na próxima tentativa.
3. Se persistir, use o `restore_terraria.sh` para recuperar um backup anterior.

### Onde estão os logs?
Dependendo do OS escolhido, os logs podem estar em lugares diferentes. O script unifica isso em `/var/log/terraria.log` na maioria dos casos.

```bash
# Ver logs em tempo real (Funciona para Systemd e Supervisor)
pct exec 1550 -- tail -f /var/log/terraria.log
```

---
Desenvolvido com ❤️ para a comunidade Terraria & Proxmox.