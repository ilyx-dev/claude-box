#!/usr/bin/env bash
# Доступ к веб-терминалу через Tailscale без открытия портов в интернет.
# Запускать на СЕРВЕРЕ, где установлен и залогинен Tailscale:
#   https://<имя-сервера>.<tailnet>.ts.net/  -> веб-терминал (tmux + Claude Code)
# Отключить: tailscale serve reset
set -euo pipefail
cd "$(dirname "$0")/.."
TTYD_PORT=$(sed -n 's/^TTYD_PORT=//p' .env 2>/dev/null | tail -n1)
tailscale serve --bg --https=443 "${TTYD_PORT:-7681}"
tailscale serve status
