# claude-box / agent: Claude Code + tmux + ttyd (+ Chrome DevTools MCP, + docker CLI для чтения Docker хоста).
# Браузер (если BROWSER=1) живёт в отдельном контейнере `browser` в той же сети шлюза (CDP на 127.0.0.1:9222).
FROM node:22-bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive
ARG TTYD_VERSION=1.7.7
ARG DOCKER_CLI_VERSION=27.5.1

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget gnupg git openssh-client rsync sudo jq less nano unzip xz-utils \
      tmux procps psmisc iproute2 dnsutils netcat-openbsd ripgrep python3 python3-venv \
      locales tzdata supervisor \
 && rm -rf /var/lib/apt/lists/*

# ---- ttyd (статический бинарник с GitHub)
RUN set -eux; case "$(dpkg --print-architecture)" in \
      amd64) a=x86_64 ;; arm64) a=aarch64 ;; *) echo "unsupported arch"; exit 1 ;; esac; \
    curl -fsSLo /usr/local/bin/ttyd "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.${a}"; \
    chmod 0755 /usr/local/bin/ttyd; /usr/local/bin/ttyd --version

# ---- docker CLI (только клиент): при HOST_DOCKER=ro смотрит на Docker хоста через docker-ro (только чтение)
RUN set -eux; case "$(dpkg --print-architecture)" in \
      amd64) a=x86_64 ;; arm64) a=aarch64 ;; *) echo "unsupported arch"; exit 1 ;; esac; \
    curl -fsSL "https://download.docker.com/linux/static/stable/${a}/docker-${DOCKER_CLI_VERSION}.tgz" \
      | tar -xz -C /usr/local/bin --strip-components=1 docker/docker; \
    /usr/local/bin/docker --version

# ---- Chrome DevTools MCP (подключается к Chrome в контейнере browser по CDP)
RUN PUPPETEER_SKIP_DOWNLOAD=1 npm install -g chrome-devtools-mcp@latest && npm cache clean --force

# ---- пользователь agent (uid/gid 1000). sudo включается только через AGENT_SUDO=1 (см. entrypoint).
RUN groupmod -n agent node && usermod -l agent -d /home/agent -m -s /bin/bash node

# ---- политика Claude Code, которую агент не может изменить: подтверждение действий на Mac
COPY claude/managed-settings.json /etc/claude-code/managed-settings.json
COPY claude/md/ /usr/local/share/claude-box/claude-md/
COPY claude/host-guard.sh /usr/local/lib/claude-box/host-guard.sh
RUN chown -R root:root /etc/claude-code /usr/local/lib/claude-box /usr/local/share/claude-box \
 && chmod 0644 /etc/claude-code/managed-settings.json /usr/local/share/claude-box/claude-md/* \
 && chmod 0755 /usr/local/lib/claude-box/host-guard.sh \
 && jq -e . /etc/claude-code/managed-settings.json >/dev/null

# ---- Claude Code (npm-пакет ставит нативный бинарник; префикс в $HOME — для автообновлений)
ENV NPM_CONFIG_PREFIX=/home/agent/.npm-global \
    PATH=/home/agent/.npm-global/bin:/home/agent/.local/bin:$PATH
USER agent
WORKDIR /home/agent
RUN npm install -g @anthropic-ai/claude-code@latest && npm cache clean --force && claude --version
USER root

COPY supervisord.conf /etc/supervisor/supervisord.conf
COPY tmux.conf /etc/tmux.conf
COPY bin/ /usr/local/bin/
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY workspace-CLAUDE.md /usr/local/share/claude-box/workspace-CLAUDE.md
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/start-ttyd /usr/local/bin/start-claude-tmux \
      /usr/local/bin/claude-session /usr/local/bin/leak-test \
      /usr/local/bin/new-project /usr/local/bin/rc-sync /usr/local/bin/rc-serve /usr/local/bin/box-info \
 && mkdir -p /workspace /var/log/supervisor /mac && chown agent:agent /workspace

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
