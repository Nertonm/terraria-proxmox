# Terraria Proxmox LXC Manager

Scripts para instalar, operar e manter um servidor dedicado de Terraria em um container LXC no Proxmox VE.

O repositório cobre quatro áreas:

- criação e provisionamento do container
- configuração do serviço do Terraria dentro do container
- automação no host Proxmox, como backup, update e monitoramento
- integrações opcionais com Discord

## Escopo

O instalador principal cria ou reaproveita um container LXC, instala dependências, extrai o servidor do Terraria, gera o `serverconfig.txt` e registra o serviço de acordo com o init system disponível no container.

Hoje o fluxo suporta templates baseados em:

- Debian
- Ubuntu
- Alpine
- Fedora

Os scripts da pasta `scripts/` devem ser executados no host Proxmox, não dentro do container, exceto quando a documentação indicar o contrário.

## Requisitos

- host com Proxmox VE e utilitários `pct`, `pveam` e `pvesm`
- acesso root no host
- acesso à internet para baixar template LXC e pacote do servidor do Terraria
- `bash`, `curl`, `tar`, `find`, `awk` e `python3` no host

## Instalação rápida

Clone o repositório e deixe os scripts executáveis:

```bash
git clone https://github.com/Nertonm/terraria-proxmox
cd terraria-proxmox
chmod +x install.sh scripts/*.sh
```

Exemplo mínimo:

```bash
./install.sh 1550 --template debian
```

Exemplo com opções comuns:

```bash
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
  --language "pt-BR" \
  --secure \
  --enable-backup \
  --backup-schedule "6h" \
  --enable-monitor \
  --discord-url "https://discord.com/api/webhooks/SEU_WEBHOOK_AQUI" \
  --enable-bot \
  --bot-token "SEU_BOT_TOKEN_AQUI" \
  --bot-userid "SEU_ID_NUMERICO"
```

Sem argumentos, `install.sh` entra em modo interativo.

## Flags principais

Use `./install.sh --help` para a lista completa. As opções abaixo cobrem o fluxo mais comum.

| Flag | Uso |
| --- | --- |
| `CT_ID` | ID do container LXC. Argumento posicional. |
| `-t, --template` | Família do template. Ex.: `debian`, `ubuntu`, `alpine`, `fedora`. |
| `-v, --version` | Versão do servidor do Terraria. Ex.: `1450`. |
| `--local-zip` | Usa um pacote `.zip` local em vez de baixar do site oficial. |
| `--static --ip --gw` | Configura IP fixo no container. |
| `-p, --port` | Porta do servidor. |
| `-m, --maxplayers` | Limite de jogadores. |
| `--world-name` | Nome do mundo quando o instalador cria o mundo. |
| `--world-file` | Importa um arquivo `.wld` existente. |
| `--size` | Tamanho do mundo: `1`, `2` ou `3`. |
| `--difficulty` | Dificuldade: `0`, `1`, `2` ou `3`. |
| `--evil` | Bioma inicial: `1`, `2` ou `3`. |
| `--seed` | Seed normal do mundo. |
| `--secret-seed` | Seed especial. Ex.: `not the bees`. |
| `--password` | Senha do servidor. |
| `--motd` | Mensagem do servidor. |
| `--secure` | Ativa proteção extra do servidor. |
| `--priority` | Prioridade do processo de `0` a `5`. |
| `--upnp` | Habilita UPnP. |
| `--language` | Idioma do servidor. Ex.: `en-US`, `pt-BR`. |
| `--banlist` | Nome do arquivo de banlist. |
| `--npcstream` | Ajuste de `npcstream`. |
| `--journey-permission` | Permissões padrão do modo Journey. |
| `--enable-backup` | Agenda backups no host. |
| `--backup-schedule` | Frequência: `daily`, `hourly`, `6h`, `weekly` ou expressão cron. |
| `--enable-monitor` | Agenda checagem periódica de saúde no host. |
| `--discord-url` | Ativa notificações por webhook. |
| `--enable-bot` | Instala o bot de controle no Discord. |
| `--bot-token` | Token do bot do Discord. |
| `--bot-userid` | ID numérico do usuário autorizado a controlar o bot. |

## Comportamento do mundo

O projeto mantém `autocreate` no `serverconfig.txt` para cobrir dois cenários:

- primeiro boot, quando o mundo ainda não existe
- recuperação automática, se o arquivo do mundo sumir ou ficar vazio

Se você precisa de um mundo específico, use `--world-file` para importar o `.wld` já pronto.

## O que o instalador configura

Dentro do container:

- usuário `terraria`
- diretório `/opt/terraria`
- arquivo `/opt/terraria/serverconfig.txt`
- wrapper `/opt/terraria/launch.sh`
- serviço `terraria` em `systemd`, `supervisor` ou `openrc`, conforme disponível
- bot interno do Discord, se habilitado

No host:

- `discord.conf`, se `--discord-url` for informado
- entrada de cron para backup, se `--enable-backup` for usado
- entrada de cron para monitoramento, se `--enable-monitor` for usado

## Scripts de manutenção

Todos os comandos abaixo devem ser executados no host Proxmox.

| Script | Uso |
| --- | --- |
| `./scripts/backup_terraria.sh <CT_ID> [dest_dir] [keep]` | Para o serviço, gera backup compactado e aplica rotação. |
| `./scripts/restore_terraria.sh <CT_ID> <backup.tar.gz>` | Restaura um backup sobre o estado atual. |
| `./scripts/update_terraria.sh <CT_ID> <VERSAO>` | Baixa e troca o binário do servidor. |
| `./scripts/monitor_health.sh <CT_ID> --report` | Gera um relatório imediato de uso de RAM, disco, uptime e jogadores. |
| `./scripts/monitor_health.sh <CT_ID> --alert [limite]` | Envia alerta só quando detectar problema. |
| `./scripts/ship_logs.sh <CT_ID> [dest_dir]` | Coleta logs do container e gera um arquivo compactado no host. |
| `./scripts/harden_lxc.sh <CT_ID>` | Adiciona um conjunto conservador de `lxc.cap.drop` ao container. |
| `./scripts/enable_host_firewall_port.sh <porta> [origem] [--yes]` | Abre a porta TCP no firewall do host. |

Exemplos:

```bash
./scripts/backup_terraria.sh 1550
./scripts/restore_terraria.sh 1550 ./backups/terraria-1550-20260401T120000.tar.gz
./scripts/update_terraria.sh 1550 1451
./scripts/monitor_health.sh 1550 --report
```

## Discord

Há duas integrações separadas:

- webhook para notificações
- bot para controle do servidor

### Webhook

Se `--discord-url` for usado no instalador, o projeto cria `discord.conf` no diretório raiz do repositório.

Formato esperado:

```bash
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/SEU_ID/SEU_TOKEN"
```

O arquivo de exemplo é `discord.conf.example`.

### Bot

Se `--enable-bot` for usado, o bot é instalado no container e pode responder a comandos como:

- `!ping`
- `!status`
- `!start`
- `!stop`
- `!restart`
- `!logs`
- `!save`
- `!backup`
- `!monitor`
- `!reboot`
- `!kick`
- `!ban`

O bot também atualiza o status com base na porta configurada no `serverconfig.txt`.

## Arquivos importantes

| Caminho | Finalidade |
| --- | --- |
| `/opt/terraria/serverconfig.txt` | Configuração principal do servidor. |
| `/opt/terraria/launch.sh` | Wrapper que sobe o servidor, registra logs e envia notificações. |
| `/opt/terraria/server_output.log` | Saída principal do processo do Terraria. |
| `/var/log/terraria.log` | Log usado nos cenários com `supervisor` ou wrappers de serviço. |
| `/home/terraria/.local/share/Terraria/Worlds` | Diretório de mundos do usuário `terraria`. |

## Troubleshooting

### Ver logs

```bash
pct exec 1550 -- tail -f /opt/terraria/server_output.log
pct exec 1550 -- tail -f /var/log/terraria.log
```

### Confirmar status do serviço

```bash
pct exec 1550 -- systemctl status terraria
```

Se o container não usa `systemd`, teste:

```bash
pct exec 1550 -- supervisorctl status terraria
pct exec 1550 -- rc-service terraria status
```

### Conferir configuração aplicada

```bash
pct exec 1550 -- sed -n '1,220p' /opt/terraria/serverconfig.txt
```

### Mundo não sobe

Verifique primeiro:

- se o caminho em `world=` existe
- se o arquivo `.wld` não está vazio
- se o diretório pertence ao usuário `terraria`

Se necessário, restaure um backup e reinicie o serviço.
