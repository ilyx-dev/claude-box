# claude-box (Mac) / browser: Google Chrome (или Chromium) на виртуальном дисплее + noVNC.
# Живёт в сети шлюза: весь трафик через прокси. CDP на 127.0.0.1:9222 для агента (chrome-devtools-mcp).
FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg jq procps locales tzdata supervisor \
      xvfb x11vnc x11-utils openbox novnc websockify dbus-x11 \
      fonts-liberation fonts-dejavu-core fonts-noto-core fonts-noto-color-emoji fonts-noto-cjk \
 && rm -rf /var/lib/apt/lists/*

# Google Chrome из официального репозитория (есть сборки amd64 и arm64); если не вышло — Chromium
RUN set -eux; \
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
      >/etc/apt/sources.list.d/google-chrome.list; \
    apt-get update; \
    if apt-get install -y --no-install-recommends google-chrome-stable; then \
      ln -sf /usr/bin/google-chrome-stable /usr/local/bin/agent-browser; \
    else \
      rm -f /etc/apt/sources.list.d/google-chrome.list; apt-get update; \
      apt-get install -y --no-install-recommends chromium; \
      ln -sf /usr/bin/chromium /usr/local/bin/agent-browser; \
    fi; \
    rm -rf /var/lib/apt/lists/*; /usr/local/bin/agent-browser --version

RUN useradd -m -u 1000 -s /bin/bash browser

# noVNC: корень сайта сразу открывает клиент с автоподключением и масштабированием
RUN rm -f /usr/share/novnc/index.html && printf '%s\n' '<!doctype html><meta charset="utf-8"><title>Agent browser</title>' \
    '<meta http-equiv="refresh" content="0; url=vnc.html?autoconnect=true&resize=scale&reconnect=true&show_dot=true">' \
    >/usr/share/novnc/index.html

COPY supervisord.conf /etc/supervisor/supervisord.conf
COPY start-chrome entrypoint.sh /usr/local/bin/
RUN chmod 0755 /usr/local/bin/start-chrome /usr/local/bin/entrypoint.sh && mkdir -p /var/log/supervisor /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
