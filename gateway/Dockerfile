# Официальный образ sing-box (alpine, бинарник в /usr/local/bin/sing-box).
# Версию можно закрепить в .env: SINGBOX_IMAGE=ghcr.io/sagernet/sing-box:<тег>
ARG SINGBOX_IMAGE=ghcr.io/sagernet/sing-box:latest
FROM ${SINGBOX_IMAGE}

RUN apk add --no-cache bash coreutils curl jq iproute2 nftables ca-certificates

COPY entrypoint.sh healthcheck.sh /usr/local/bin/
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
