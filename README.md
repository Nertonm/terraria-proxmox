# Terraria Proxmox LXC Manager 🚀

Solução completa "Enterprise-Grade" para implantar, gerenciar e monitorar servidores de Terraria (v1.4.5.0+) em Proxmox VE.

## ✨ Funcionalidades

- **Instalação Inteligente:** Deploy automatizado com Wizard interativo ou CLI completa.
- **Geração Automática de Mundo:** Setup compliance com v1.4.5.0 (Tamanho, Dificuldade, Evil, Seed).
- **Notificações Discord:** Alertas ricos via Webhook para Backups, Updates, Crash e Status.
- **Bot de Comando:** Controle total via chat (`!start`, `!stop`, `!backup`, `!status`).
- **Monitoramento de Saúde:** Alertas automáticos de RAM (>90%) e Disco cheio.
- **Backups Flexíveis:** Agendamento diário, horário, semanal ou Cron customizado.

---

## ⚡ Quick Install (Full Template)

Copie e edite este bloco para instalar tudo de uma vez (sem perguntas):

```bash
git clone https://github.com/Nertonm/terraria-proxmox
cd terraria-proxmox
chmod +x install.sh scripts/*.sh

./install.sh 1550 \
  --version 1450 \
  --port 7777 \
  --maxplayers 8 \
  --world-name "TerrariaWorld" \
  --evil 1 \
  --seed "MySuperSeed" \
  --secret-seed "not the bees" \
  --enable-backup \
  --backup-schedule "daily" \
  --enable-monitor \
  --discord-url "https://discord.com/api/webhooks/SEU_WEBHOOK_AQUI" \
  --enable-bot \
  --bot-token "SEU_BOT_TOKEN_AQUI" \
  --bot-userid "SEU_DISCORD_USER_ID"
```

### 📝 Legenda das Flags

| Flag | Descrição | Exemplo |
| :--- | :--- | :--- |
| `1550` | ID do Container (Posicional) | `100` |
| `--version` | Versão do Terraria | `1450` |
| `--evil` | Bioma do Mundo (1=Random, 2=Corrupt, 3=Crimson) | `2` |
| `--seed` | Seed do Mapa | `"Abacaxi"` |
| `--secret-seed` | Seed Especial (Easter Eggs) | `"not the bees"` |
| `--enable-backup` | Ativa backups automáticos | - |
| `--backup-schedule` | Frequência (`daily`, `hourly`, `6h`, `weekly`) | `6h` |
| `--enable-monitor` | Ativa alertas de RAM/Disco | - |
| `--discord-url` | URL do Webhook para notificações | `"https://..."` |
| `--enable-bot` | Instala o Bot de comando (Python) | - |
| `--bot-token` | Token do Bot (Developer Portal) | `"MTA..."` |
| `--bot-userid` | Seu ID de usuário (para segurança) | `12345678` |

---

## 🤖 Controle via Bot do Discord

Se você ativou o `--enable-bot`, o serviço `terraria-bot` já está rodando no host.

### Comandos Disponíveis:
- `!ping` - Testa a conexão.
- `!status` - Relatório detalhado (Jogadores, RAM, CPU, Disco).
- `!start` / `!stop` / `!restart` - Controle de energia do container.
- `!backup` - Dispara backup manual imediato.

---

## 🛠️ Scripts de Administração (`scripts/`)

Todos os scripts devem ser executados no **Host Proxmox**.

- **Backup:** `./scripts/backup_terraria.sh <CT_ID>`
- **Restore:** `./scripts/restore_terraria.sh <CT_ID> <arquivo.tar.gz>`
- **Update:** `./scripts/update_terraria.sh <CT_ID> <VERSÃO>`
- **Health Report:** `./scripts/monitor_health.sh <CT_ID> --report`
- **Security:** `./scripts/harden_lxc.sh <CT_ID>`

---

## 📋 Monitoramento Manual

- **Logs do Bot:** `journalctl -u terraria-bot -f`
- **Logs do Jogo:** `pct exec 1550 -- journalctl -u terraria -f`

---
Desenvolvido para transformar seu Proxmox em um host de games profissional. 🎮