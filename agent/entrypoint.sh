#!/usr/bin/env bash
# claude-box / agent entrypoint (root): гео прокси (TZ, локаль), SSH-доступ к хосту (алиас HOST_ALIAS:
# mac на Mac, host на сервере) и к серверам из SSH_HOSTS, правила агента под профиль (/etc/claude-code/CLAUDE.md),
# MCP chrome-devtools (BROWSER=1), docker CLI только для чтения (HOST_DOCKER=ro), sudo по желанию —
# затем supervisord (tmux-сессия с Claude Code + ttyd).
set -Eeuo pipefail

log() { printf '%s [agent] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

AGENT=agent
AGENT_HOME=/home/agent
GEO_FILE=/shared/geo.env
TUN_DNS=172.19.0.2
PROFILE=${BOX_PROFILE:-server}
HOST_ALIAS=${HOST_ALIAS:-host}
BOX_PREFIX=${BOX_PREFIX:-claude}
BOX_PROJECT=${BOX_PROJECT:-claude-box}
for v in HOST_ALIAS BOX_PREFIX BOX_PROJECT; do
  [[ ${!v} =~ ^[A-Za-z0-9._-]+$ ]] || die "$v='${!v}': допустимы только латиница, цифры, точка, дефис, подчёркивание"
done

as_agent() { runuser -u "$AGENT" -- env HOME="$AGENT_HOME" USER="$AGENT" bash -c "$*"; }

[[ -n ${TTYD_PASSWORD:-} && ${TTYD_PASSWORD} != change-me ]] || die "задайте TTYD_PASSWORD в .env"

# ---------------------------------------------------------------- 1. права
PUID=${PUID:-1000}
PGID=${PGID:-1000}
if [[ $(id -u "$AGENT") != "$PUID" || $(id -g "$AGENT") != "$PGID" ]]; then
  log "uid/gid агента -> $PUID:$PGID"
  groupmod -o -g "$PGID" "$AGENT"
  usermod -o -u "$PUID" -g "$PGID" "$AGENT"
  chown -R "$PUID:$PGID" "$AGENT_HOME"
fi
chown "$AGENT:$AGENT" "$AGENT_HOME"
[[ $(stat -c %u /workspace) == 0 ]] && chown "$AGENT:$AGENT" /workspace || true

# sudo выключен по умолчанию: иначе агент мог бы переписать /etc/claude-code (правила подтверждений)
if [[ ${AGENT_SUDO:-0} == 1 ]]; then
  echo 'agent ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/agent && chmod 0440 /etc/sudoers.d/agent
  log "WARNING: AGENT_SUDO=1 — агент root внутри контейнера и может изменить правила подтверждений"
else
  rm -f /etc/sudoers.d/agent
fi

# ---------------------------------------------------------------- 2. гео от шлюза
for _ in $(seq 1 180); do [[ -s $GEO_FILE ]] && break; sleep 1; done
[[ -s $GEO_FILE ]] || die "нет $GEO_FILE — шлюз не поднялся (docker compose logs gateway)"
# shellcheck disable=SC1090
source "$GEO_FILE"

TZ_NAME=${GEO_TZ:-UTC}
if [[ ! -f /usr/share/zoneinfo/$TZ_NAME ]]; then log "неизвестный часовой пояс '$TZ_NAME' -> UTC"; TZ_NAME=UTC; fi
ln -snf "/usr/share/zoneinfo/$TZ_NAME" /etc/localtime
echo "$TZ_NAME" >/etc/timezone

pick_locale() {
  local l
  for l in "$@"; do
    [[ -n $l ]] && grep -qx "$l UTF-8" /usr/share/i18n/SUPPORTED && { echo "$l"; return; }
  done
  echo en_US.UTF-8
}
LOC=$(pick_locale "${GEO_LOCALE:-}" "${GEO_LOCALE_ALT:-}")
for l in "$LOC" en_US.UTF-8; do
  localedef -i "${l%%.*}" -c -f UTF-8 -A /usr/share/locale/locale.alias "$l" >/dev/null 2>&1 || log "localedef $l: ошибка"
done
printf 'LANG=%s\n' "$LOC" >/etc/default/locale
LANGUAGE_VAL="${LOC%%.*}:${LOC%%_*}"

cat >/etc/profile.d/00-geo.sh <<EOF
export TZ='$TZ_NAME'
export LANG='$LOC'
export LANGUAGE='$LANGUAGE_VAL'
EOF
{
  echo 'export PATH="/home/agent/.npm-global/bin:/home/agent/.local/bin:$PATH"'
  # docker CLI смотрит на Docker хоста через docker-ro (только чтение); без HOST_DOCKER=ro — никуда
  if [[ ${HOST_DOCKER:-0} == ro ]]; then echo "export DOCKER_HOST='tcp://${BOX_DOCKER_RO:-172.29.0.3:2375}'"
  else echo "export DOCKER_HOST='unix:///nonexistent/docker-disabled.sock'"; fi
} >/etc/profile.d/10-agent.sh
export TZ="$TZ_NAME" LANG="$LOC" LANGUAGE="$LANGUAGE_VAL"
log "гео прокси: IP ${GEO_IP:-?} (${GEO_COUNTRY:-?}), TZ=$TZ, LANG=$LANG"

printf 'nameserver %s\noptions timeout:2 attempts:3\n' "$TUN_DNS" >/etc/resolv.conf 2>/dev/null || true

# ---------------------------------------------------------------- 3. SSH: ключ агента, алиас хоста, серверы (root-owned конфиги)
as_agent 'install -d -m 700 ~/.ssh; [[ -f ~/.ssh/id_ed25519 ]] || ssh-keygen -q -t ed25519 -N "" -C claude-agent@claude-box -f ~/.ssh/id_ed25519'
install -d -m 755 /etc/ssh/ssh_config.d
rm -f /etc/ssh/ssh_config.d/10-claude-box-mac.conf   # имя файла до v1
if [[ ${HOST_ACCESS:-1} == 1 ]]; then
  [[ -n ${HOST_SSH_USER:-} ]] || log "WARNING: HOST_SSH_USER пуст — задайте пользователя хоста в .env"
  cat >/etc/ssh/ssh_config.d/10-claude-box-host.conf <<EOF
# claude-box: хост, на котором работает контейнер. Каждая команда через этот алиас — с подтверждением.
Host $HOST_ALIAS
  HostName host.docker.internal
  User ${HOST_SSH_USER:-agent}
  Port ${HOST_SSH_PORT:-22}
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  ServerAliveInterval 30
EOF
  chmod 644 /etc/ssh/ssh_config.d/10-claude-box-host.conf
else
  rm -f /etc/ssh/ssh_config.d/10-claude-box-host.conf
fi
# SSH_HOSTS="vds=root@203.0.113.5:22 other=user@host" — другие серверы (трафик идёт через прокси)
: >/etc/ssh/ssh_config.d/20-claude-box-hosts.conf
ssh_hosts=${SSH_HOSTS:-}
for entry in ${ssh_hosts//,/ }; do
  if [[ $entry =~ ^([A-Za-z0-9._-]+)=(([A-Za-z0-9._-]+)@)?([A-Za-z0-9.-]+)(:([0-9]{1,5}))?$ ]]; then
    {
      echo "Host ${BASH_REMATCH[1]}"
      echo "  HostName ${BASH_REMATCH[4]}"
      [[ -n ${BASH_REMATCH[3]} ]] && echo "  User ${BASH_REMATCH[3]}"
      echo "  Port ${BASH_REMATCH[6]:-22}"
      echo "  IdentityFile ~/.ssh/id_ed25519"
      echo "  IdentitiesOnly yes"
      echo "  StrictHostKeyChecking accept-new"
      echo "  ServerAliveInterval 30"
    } >>/etc/ssh/ssh_config.d/20-claude-box-hosts.conf
    log "SSH-алиас ${BASH_REMATCH[1]} -> ${BASH_REMATCH[3]:+${BASH_REMATCH[3]}@}${BASH_REMATCH[4]}:${BASH_REMATCH[6]:-22}"
  else
    log "WARNING: SSH_HOSTS: не понял запись '$entry' (формат: алиас=user@host:порт)"
  fi
done
chmod 644 /etc/ssh/ssh_config.d/20-claude-box-hosts.conf
log "публичный ключ агента: $(cat "$AGENT_HOME/.ssh/id_ed25519.pub")"

# ---------------------------------------------------------------- 4. MCP: Chrome DevTools -> Chrome в контейнере browser
if [[ ${BROWSER:-0} == 1 && ${DEVTOOLS_MCP:-1} == 1 ]]; then
  if timeout 60 runuser -u "$AGENT" -- env HOME="$AGENT_HOME" bash -c \
    'claude mcp get chrome-devtools >/dev/null 2>&1 || claude mcp add --scope user chrome-devtools -- chrome-devtools-mcp --browser-url=http://127.0.0.1:9222' \
    >/dev/null 2>&1; then
    log "MCP chrome-devtools -> http://127.0.0.1:9222"
  else
    log "WARNING: не удалось зарегистрировать MCP chrome-devtools"
  fi
else
  timeout 60 runuser -u "$AGENT" -- env HOME="$AGENT_HOME" bash -c 'claude mcp remove --scope user chrome-devtools' >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------- 4b. структура /workspace (не перезаписывает ваше)
as_agent 'mkdir -p /workspace/_reports /workspace/_tmp; [[ -f /workspace/CLAUDE.md ]] || cp /usr/local/share/claude-box/workspace-CLAUDE.md /workspace/CLAUDE.md' \
  || log "WARNING: не удалось подготовить /workspace"

# ---------------------------------------------------------------- 4c. правила агента под профиль
MD_SRC=/usr/local/share/claude-box/claude-md
parts=("$MD_SRC/00-base.md")
if [[ ${HOST_ACCESS:-1} == 1 ]]; then
  if [[ $PROFILE == mac ]]; then parts+=("$MD_SRC/10-host-mac.md"); else parts+=("$MD_SRC/10-host-server.md"); fi
else
  parts+=("$MD_SRC/15-host-off.md")
fi
[[ ${BROWSER:-0} == 1 ]] && parts+=("$MD_SRC/20-browser.md")
[[ ${HOST_DOCKER:-0} == ro ]] && parts+=("$MD_SRC/30-docker.md")
parts+=("$MD_SRC/90-projects.md")
if [[ $PROFILE == mac ]]; then prof_ru="Mac"; host_ru="MacBook"; else prof_ru="сервер"; host_ru="сервер"; fi
cat "${parts[@]}" | sed -e "s/@HOST@/$HOST_ALIAS/g" -e "s/@PREFIX@/$BOX_PREFIX/g" -e "s/@PROJECT@/$BOX_PROJECT/g" \
  -e "s/@PROFILE_RU@/$prof_ru/g" -e "s/@HOSTNAME_RU@/$host_ru/g" >/etc/claude-code/CLAUDE.md.tmp
mv -f /etc/claude-code/CLAUDE.md.tmp /etc/claude-code/CLAUDE.md
chown root:root /etc/claude-code/CLAUDE.md && chmod 0644 /etc/claude-code/CLAUDE.md
log "правила агента: профиль $PROFILE, хост '$HOST_ALIAS', браузер ${BROWSER:-0}, docker ${HOST_DOCKER:-0}"

# ---------------------------------------------------------------- 5. проверка политики
jq -e '.permissions.disableBypassPermissionsMode == "disable"' /etc/claude-code/managed-settings.json >/dev/null ||
  die "повреждён /etc/claude-code/managed-settings.json"
if [[ $PROFILE == mac ]]; then
  [[ -d /mac/home ]] && log "диск Mac: /mac/home (только чтение)" || log "WARNING: /mac/home не смонтирован (запустите scripts/gen-mac-mounts.sh)"
fi

mkdir -p /var/log/supervisor
log "веб-терминал :7681$([[ ${BROWSER:-0} == 1 ]] && echo ", браузер :6080") (порты опубликованы на шлюзе)"
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
