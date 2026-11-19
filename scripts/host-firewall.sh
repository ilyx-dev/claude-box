#!/usr/bin/env bash
# ОПЦИОНАЛЬНО, только Linux-хост. Второй, независимый слой kill-switch на самом хосте:
# всё, что контейнеры claude-box пытаются отправить наружу НЕ на SOCKS5-сервер, отбрасывается
# в цепочке DOCKER-USER — даже если namespace контейнера будет скомпрометирован.
#   sudo ./scripts/host-firewall.sh          # применить
#   sudo ./scripts/host-firewall.sh remove   # убрать
# Чтобы правила переживали перезагрузку и рестарт Docker — systemd-юнит scripts/claude-box-firewall.service.
set -euo pipefail
cd "$(dirname "$0")/.."

env_get() { sed -n "s/^$1=//p" .env | tail -n1 | sed -e "s/^'//" -e "s/'$//" -e 's/^"//' -e 's/"$//'; }

SUBNET=$(env_get DOCKER_SUBNET); SUBNET=${SUBNET:-172.29.0.0/24}
HOST=$(env_get SOCKS_HOST); PORT=$(env_get SOCKS_PORT)
UDP=$(env_get ALLOW_UDP); DIRECT=$(env_get DIRECT_CIDRS)
CHAIN=CLAUDE-BOX

if [[ ${1:-} == remove ]]; then
  iptables -D DOCKER-USER -s "$SUBNET" -j "$CHAIN" 2>/dev/null || true
  iptables -F "$CHAIN" 2>/dev/null || true
  iptables -X "$CHAIN" 2>/dev/null || true
  echo "removed"; exit 0
fi

[[ -n $HOST && -n $PORT ]] || { echo "SOCKS_HOST/SOCKS_PORT не заданы в .env"; exit 1; }
if [[ $HOST =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then IP=$HOST; else IP=$(getent ahostsv4 "$HOST" | awk 'NR==1{print $1}'); fi
[[ -n $IP ]] || { echo "не удалось разрезолвить $HOST"; exit 1; }

iptables -N DOCKER-USER 2>/dev/null || true
iptables -N "$CHAIN" 2>/dev/null || iptables -F "$CHAIN"
iptables -A "$CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
iptables -A "$CHAIN" -d "$IP" -p tcp --dport "$PORT" -j RETURN
iptables -A "$CHAIN" -d "$SUBNET" -j RETURN   # внутри сети claude-box (шлюз <-> docker-ro)
[[ $UDP == 1 ]] && iptables -A "$CHAIN" -d "$IP" -p udp -j RETURN
for c in ${DIRECT//,/ }; do iptables -A "$CHAIN" -d "$c" -j RETURN; done
iptables -A "$CHAIN" -j LOG --log-prefix "claude-box-drop: " --log-level 4 -m limit --limit 6/min
iptables -A "$CHAIN" -j DROP
iptables -C DOCKER-USER -s "$SUBNET" -j "$CHAIN" 2>/dev/null || iptables -I DOCKER-USER 1 -s "$SUBNET" -j "$CHAIN"
echo "OK: из $SUBNET наружу разрешено только на $IP:$PORT${DIRECT:+ и $DIRECT}"
