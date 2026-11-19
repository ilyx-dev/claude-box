#!/usr/bin/env bash
# Шлюз здоров, только если: tun поднят, гео определено и интернет реально доступен ЧЕРЕЗ прокси.
ip link show tun0 >/dev/null 2>&1 || { echo "tun0 down"; exit 1; }
[[ -s /shared/geo.env ]] || { echo "geo not detected yet"; exit 1; }
curl -fsS -o /dev/null --max-time 10 https://www.gstatic.com/generate_204 ||
  curl -fsS -o /dev/null --max-time 10 https://cp.cloudflare.com/ ||
  { echo "no connectivity through the proxy"; exit 1; }
