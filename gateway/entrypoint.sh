#!/usr/bin/env bash
# claude-box / gateway
#
#  1. nftables kill-switch — ставится ДО туннеля и живёт независимо от sing-box:
#     наружу через eth0 можно только на IP:порт SOCKS5 (+ опционально хост:22 и явно
#     разрешённые подсети). Всё остальное — только через tun0.
#  2. sing-box: TUN -> SOCKS5. Весь TCP идёт в прокси, DNS (порт 53, любой сервер)
#     перехватывается и резолвится через DoH ВНУТРИ прокси, UDP по умолчанию блокируется,
#     IPv6 выключен.
#  3. Определяет гео (IP, страна, часовой пояс, язык) выходного IP прокси и пишет
#     /shared/geo.env — контейнер agent настраивает по нему часовой пояс и локаль.
set -Eeuo pipefail

log() { printf '%s [gateway] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

# ---------------------------------------------------------------- settings
: "${SOCKS_HOST:?SOCKS_HOST не задан (см. .env)}"
: "${SOCKS_PORT:?SOCKS_PORT не задан (см. .env)}"
SOCKS_USER="${SOCKS_USER:-}"
SOCKS_PASS="${SOCKS_PASS:-}"
ALLOW_UDP="${ALLOW_UDP:-0}"
DOH_SERVER="${DOH_SERVER:-1.1.1.1}"
DOCKER_SUBNET="${DOCKER_SUBNET:-172.29.0.0/24}"
LAN_CIDRS="${LAN_CIDRS:-}"
DIRECT_CIDRS="${DIRECT_CIDRS:-}"
HOST_ACCESS="${HOST_ACCESS:-0}"
HOST_PORTS="${HOST_PORTS:-22}"
HOST_DOCKER="${HOST_DOCKER:-0}"            # ro -> разрешить агенту docker-ro (Docker API только чтение)
DOCKER_RO_IP="${DOCKER_RO_IP:-172.29.0.3}"
SERVICE_PORTS="${SERVICE_PORTS:-7681}"
SB_LOG_LEVEL="${SB_LOG_LEVEL:-warn}"
# TCP keepalive до прокси: мёртвое соединение закрывается примерно за SB_KEEPALIVE + 9 × SB_KEEPALIVE_INTERVAL
# (по умолчанию ~1 мин вместо ~16 мин у sing-box). Пустое SB_KEEPALIVE — оставить умолчания sing-box.
SB_KEEPALIVE="${SB_KEEPALIVE-15s}"
SB_KEEPALIVE_INTERVAL="${SB_KEEPALIVE_INTERVAL:-5s}"

TUN_IF=tun0
TUN_ADDR=172.19.0.1/30
TUN_DNS=172.19.0.2          # любой DNS-запрос в tun перехватывается sing-box
SB_CONF=/etc/sing-box/config.json
SHARED=/shared
GEO_FILE="$SHARED/geo.env"

# ---------------------------------------------------------------- helpers
is_ipv4() { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

# "a, b,c" -> массив
split_csv() { local -n _out=$1; IFS=', ' read -r -a _out <<<"${2:-}"; }

join_csv() { local IFS=,; printf '%s' "$*"; }

# IPv4 по имени: /etc/hosts -> getent -> nslookup (используется ТОЛЬКО до поднятия kill-switch)
resolve4() {
  local name=$1 ip=""
  ip=$(awk -v n="$name" '$1 ~ /^[0-9.]+$/ { for (i = 2; i <= NF; i++) if ($i == n) { print $1; exit } }' /etc/hosts)
  [[ -z $ip ]] && ip=$(getent hosts "$name" 2>/dev/null | awk '$1 ~ /^[0-9.]+$/ { print $1; exit }')
  [[ -z $ip ]] && ip=$(nslookup -type=a "$name" 2>/dev/null | awk '/^Address: / && $2 ~ /^[0-9.]+$/ { print $2; exit }')
  printf '%s' "$ip"
}

# Страна -> локаль glibc (запасной вариант, если гео-сервис не отдал языки)
country_locale() {
  case "${1^^}" in
    US) echo en_US ;; GB|UK) echo en_GB ;; CA) echo en_CA ;; AU) echo en_AU ;; NZ) echo en_NZ ;;
    IE) echo en_IE ;; IN) echo en_IN ;; SG) echo en_SG ;; ZA) echo en_ZA ;; PH) echo en_PH ;;
    NG) echo en_NG ;; HK) echo zh_HK ;;
    DE) echo de_DE ;; AT) echo de_AT ;; CH) echo de_CH ;; LI) echo de_LI ;; LU) echo fr_LU ;;
    FR|MC) echo fr_FR ;; BE) echo nl_BE ;; NL) echo nl_NL ;;
    ES) echo es_ES ;; MX) echo es_MX ;; AR) echo es_AR ;; CL) echo es_CL ;; CO) echo es_CO ;;
    PE) echo es_PE ;; VE) echo es_VE ;; UY) echo es_UY ;; EC) echo es_EC ;; CR) echo es_CR ;;
    PT) echo pt_PT ;; BR) echo pt_BR ;;
    IT|SM|VA) echo it_IT ;; MT) echo mt_MT ;;
    PL) echo pl_PL ;; CZ) echo cs_CZ ;; SK) echo sk_SK ;; HU) echo hu_HU ;; RO) echo ro_RO ;;
    MD) echo ro_MD ;; BG) echo bg_BG ;; GR) echo el_GR ;; CY) echo el_CY ;; TR) echo tr_TR ;;
    SE) echo sv_SE ;; NO) echo nb_NO ;; DK) echo da_DK ;; FI) echo fi_FI ;; IS) echo is_IS ;;
    EE) echo et_EE ;; LV) echo lv_LV ;; LT) echo lt_LT ;;
    UA) echo uk_UA ;; RU) echo ru_RU ;; BY) echo be_BY ;; KZ) echo kk_KZ ;; UZ) echo uz_UZ ;;
    KG) echo ky_KG ;; GE) echo ka_GE ;; AM) echo hy_AM ;; AZ) echo az_AZ ;;
    RS) echo sr_RS ;; HR) echo hr_HR ;; SI) echo sl_SI ;; BA) echo bs_BA ;; ME) echo sr_ME ;;
    MK) echo mk_MK ;; AL) echo sq_AL ;;
    IL) echo he_IL ;; AE) echo ar_AE ;; SA) echo ar_SA ;; EG) echo ar_EG ;; QA) echo ar_QA ;;
    KW) echo ar_KW ;; JO) echo ar_JO ;; MA) echo ar_MA ;;
    IR) echo fa_IR ;; PK) echo ur_PK ;; BD) echo bn_BD ;;
    JP) echo ja_JP ;; KR) echo ko_KR ;; CN) echo zh_CN ;; TW) echo zh_TW ;;
    TH) echo th_TH ;; VN) echo vi_VN ;; ID) echo id_ID ;; MY) echo ms_MY ;;
    *) echo en_US ;;
  esac
}

# Один гео-сервис -> "ip|CC|timezone|languages" (запрос идёт через tun -> прокси)
geo_query() {
  local j
  case $1 in
    ipwho.is)
      j=$(curl -fsS --max-time 8 https://ipwho.is/) || return 1
      jq -e '.success == true and (.country_code // "") != ""' >/dev/null 2>&1 <<<"$j" || return 1
      jq -r '[.ip, (.country_code | ascii_upcase), (.timezone.id // ""), ""] | map(. // "" | tostring) | join("|")' <<<"$j" ;;
    ipapi.is)
      j=$(curl -fsS --max-time 8 https://api.ipapi.is/) || return 1
      jq -e '(.location.country_code // "") != ""' >/dev/null 2>&1 <<<"$j" || return 1
      jq -r '[.ip, (.location.country_code | ascii_upcase), (.location.timezone // ""), ""] | map(. // "" | tostring) | join("|")' <<<"$j" ;;
    ipapi.co)
      j=$(curl -fsS --max-time 8 https://ipapi.co/json/) || return 1
      jq -e '(.error // false) == false and (.country_code // "") != ""' >/dev/null 2>&1 <<<"$j" || return 1
      jq -r '[.ip, (.country_code | ascii_upcase), (.timezone // ""), (.languages // "")] | map(. // "" | tostring) | join("|")' <<<"$j" ;;
    ipinfo.io)
      j=$(curl -fsS --max-time 8 https://ipinfo.io/json) || return 1
      jq -e '(.country // "") != ""' >/dev/null 2>&1 <<<"$j" || return 1
      jq -r '[.ip, (.country | ascii_upcase), (.timezone // ""), ""] | map(. // "" | tostring) | join("|")' <<<"$j" ;;
    ifconfig.co)
      j=$(curl -fsS --max-time 8 -H 'Accept: application/json' https://ifconfig.co/json) || return 1
      jq -e '(.country_iso // "") != ""' >/dev/null 2>&1 <<<"$j" || return 1
      jq -r '[.ip, (.country_iso | ascii_upcase), (.time_zone // ""), ""] | map(. // "" | tostring) | join("|")' <<<"$j" ;;
    *) return 1 ;;
  esac
}

# Базы геолокации часто расходятся (особенно для недавно переназначенных/арендованных подсетей),
# поэтому спрашиваем несколько сервисов и берём страну большинства.
# Печатает "ip|CC|timezone|languages|источник"
GEO_PROVIDERS="${GEO_PROVIDERS:-ipwho.is ipapi.is ipapi.co ipinfo.io ifconfig.co}"
geo_lookup() {
  local p line results="" best votes
  for p in $GEO_PROVIDERS; do
    line=$(geo_query "$p" 2>/dev/null) || continue
    results+="$p|$line"$'\n'
  done
  [[ -n $results ]] || return 1
  # страна большинства (при равенстве — по порядку сервисов)
  best=$(awk -F'|' 'NF > 2 && $3 != "" { if (!($3 in c)) o[++n] = $3; c[$3]++ }
    END { b = ""; m = 0; for (i = 1; i <= n; i++) if (c[o[i]] > m) { m = c[o[i]]; b = o[i] } print b }' <<<"$results")
  votes=$(awk -F'|' 'NF > 2 { printf "%s%s=%s", (NR > 1 ? ", " : ""), $1, $3 }' <<<"$results")
  if [[ $(awk -F'|' 'NF > 2 { print $3 }' <<<"$results" | sort -u | wc -l) -gt 1 ]]; then
    log "WARNING: базы геолокации расходятся: $votes — беру большинство: $best"
  fi
  awk -F'|' -v b="$best" -v v="$votes" '
    $3 == b { if (ip == "") ip = $2; if (tz == "" && $4 != "") tz = $4; if (lg == "" && $5 != "") lg = $5 }
    END { printf "%s|%s|%s|%s|%s\n", ip, b, tz, lg, v }' <<<"$results"
}

write_geo() {
  local ip=$1 cc=$2 tz=$3 langs=$4 src=$5 first loc alt lang region primary accept tmp

  # локаль: явная из .env -> первый язык страны из гео-сервиса -> таблица по стране
  alt=$(country_locale "$cc")
  loc=""
  first=${langs%%,*}
  if [[ $first =~ ^([a-z]{2,3})-([A-Za-z]{2})$ ]]; then
    loc="${BASH_REMATCH[1]}_${BASH_REMATCH[2]^^}"
  elif [[ $first =~ ^([a-z]{2,3})$ && -n $cc ]]; then
    loc="${first}_${cc^^}"
  fi
  [[ -z $loc ]] && loc=$alt
  if [[ -n ${GEO_LOCALE:-} ]]; then loc=${GEO_LOCALE%%.*}; alt=$loc; fi

  [[ -n ${GEO_TZ:-} ]] && tz=$GEO_TZ
  if [[ -z $tz ]]; then log "WARNING: часовой пояс не определён, ставлю UTC (задайте GEO_TZ в .env)"; tz=UTC; fi

  lang=${loc%%_*}; region=${loc#*_}
  primary="$lang-$region"
  accept="$primary,$lang"
  [[ $lang != en ]] && accept+=",en-US,en"
  [[ -n ${GEO_ACCEPT_LANG:-} ]] && accept=$GEO_ACCEPT_LANG

  tmp=$(mktemp "$SHARED/.geo.XXXXXX")
  {
    printf 'GEO_IP=%q\n' "$ip"
    printf 'GEO_COUNTRY=%q\n' "$cc"
    printf 'GEO_TZ=%q\n' "$tz"
    printf 'GEO_LOCALE=%q\n' "$loc.UTF-8"
    printf 'GEO_LOCALE_ALT=%q\n' "$alt.UTF-8"
    printf 'GEO_LANG=%q\n' "$primary"
    printf 'GEO_ACCEPT_LANG=%q\n' "$accept"
    printf 'GEO_SOURCE=%q\n' "$src"
    printf 'GEO_UPDATED=%q\n' "$(date -u +%FT%TZ)"
  } >"$tmp"
  chmod 644 "$tmp"
  mv -f "$tmp" "$GEO_FILE"
  log "geo: ip=$ip country=$cc tz=$tz locale=$loc.UTF-8 accept-language=$accept (источник: $src)"
}

# ---------------------------------------------------------------- 0. prep
mkdir -p /etc/sing-box /var/lib/sing-box "$SHARED"
rm -f "$GEO_FILE"
[[ $SOCKS_PORT =~ ^[0-9]+$ ]] || die "SOCKS_PORT должен быть числом"
[[ -c /dev/net/tun ]] || die "нет /dev/net/tun — проверьте 'devices' и 'cap_add: NET_ADMIN' в docker-compose.yml"

# ---------------------------------------------------------------- 1. resolve endpoints
# Это ЕДИНСТВЕННЫЕ запросы через локальный DNS Docker/хоста — до включения kill-switch.
if is_ipv4 "$SOCKS_HOST"; then
  SOCKS_IP=$SOCKS_HOST
else
  SOCKS_IP=$(resolve4 "$SOCKS_HOST")
  [[ -n $SOCKS_IP ]] || die "не удалось разрезолвить SOCKS_HOST=$SOCKS_HOST"
  log "SOCKS_HOST $SOCKS_HOST -> $SOCKS_IP (имя прокси один раз ушло в локальный DNS; укажите IP, чтобы исключить и это)"
fi

HOST_IP=""
if [[ $HOST_ACCESS == 1 ]]; then
  HOST_IP=$(resolve4 host.docker.internal)
  [[ -n $HOST_IP ]] || die "HOST_ACCESS=1, но host.docker.internal не резолвится"
  log "доступ к хосту: $HOST_IP tcp/{${HOST_PORTS}}"
fi

WAN_IF=$(ip -4 route show default | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
[[ -n $WAN_IF ]] || die "нет маршрута по умолчанию"

if [[ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1) != 1 ]]; then
  log "WARNING: IPv6 включён в namespace (sysctl не применился) — nftables всё равно режет весь IPv6"
fi

split_csv LAN "$LAN_CIDRS"
split_csv DIRECT "$DIRECT_CIDRS"

# ---------------------------------------------------------------- 2. kill-switch (nftables)
NFT_UDP=""
[[ $ALLOW_UDP == 1 ]] && NFT_UDP="oifname \"$WAN_IF\" ip daddr $SOCKS_IP meta l4proto udp accept"
NFT_HOST=""
[[ -n $HOST_IP ]] && NFT_HOST="oifname \"$WAN_IF\" ip daddr $HOST_IP tcp dport { ${HOST_PORTS// /} } accept"
NFT_DOCKER=""
[[ $HOST_DOCKER == ro ]] && NFT_DOCKER="oifname \"$WAN_IF\" ip daddr $DOCKER_RO_IP tcp dport 2375 accept"
NFT_DIRECT=""
((${#DIRECT[@]})) && NFT_DIRECT="oifname \"$WAN_IF\" ip daddr { $(join_csv "${DIRECT[@]}") } accept"
SRC_SET=$(join_csv "$DOCKER_SUBNET" "${LAN[@]}")

cat >/etc/killswitch.nft <<EOF
table inet killswitch
delete table inet killswitch
table inet killswitch {
  chain output {
    type filter hook output priority filter; policy drop;
    ip daddr 127.0.0.11 counter reject comment "docker-embedded-dns-resolves-via-host"
    oifname "lo" accept
    oifname "$TUN_IF" accept
    meta nfproto ipv6 counter drop
    ct state established,related accept
    oifname "$WAN_IF" ip daddr $SOCKS_IP tcp dport $SOCKS_PORT accept
    $NFT_UDP
    $NFT_HOST
    $NFT_DOCKER
    $NFT_DIRECT
    counter reject with icmpx type admin-prohibited
  }
  chain input {
    type filter hook input priority filter; policy drop;
    iifname "lo" accept
    iifname "$TUN_IF" accept
    meta nfproto ipv6 drop
    ct state established,related accept
    iifname "$WAN_IF" ip saddr { $SRC_SET } tcp dport { ${SERVICE_PORTS// /} } accept
  }
  chain forward {
    type filter hook forward priority filter; policy drop;
  }
}
EOF
nft -f /etc/killswitch.nft || die "не удалось применить nftables kill-switch"
log "kill-switch активен: наружу только $SOCKS_IP:$SOCKS_PORT через $WAN_IF${NFT_DOCKER:+ (+ docker-ro $DOCKER_RO_IP:2375)}"

# DNS всех процессов namespace (файл общий с agent) -> адрес внутри tun, где его перехватывает sing-box
printf 'nameserver %s\noptions timeout:2 attempts:3\n' "$TUN_DNS" >/etc/resolv.conf

# ---------------------------------------------------------------- 3. sing-box config
EXCLUDES=("$DOCKER_SUBNET" "$SOCKS_IP/32")
[[ -n $HOST_IP ]] && EXCLUDES+=("$HOST_IP/32")
EXCLUDES+=("${LAN[@]}" "${DIRECT[@]}")
EXCL_JSON=$(printf '%s\n' "${EXCLUDES[@]}" | jq -R 'select(length > 0)' | jq -s .)

gen_sb_conf() { # $1 — keepalive ("" — умолчания sing-box)
  jq -n \
  --arg loglevel "$SB_LOG_LEVEL" \
  --arg tun "$TUN_IF" --arg tunaddr "$TUN_ADDR" \
  --arg sip "$SOCKS_IP" --argjson sport "$SOCKS_PORT" \
  --arg user "$SOCKS_USER" --arg pass "$SOCKS_PASS" \
  --arg doh "$DOH_SERVER" \
  --argjson excl "$EXCL_JSON" \
  --arg ka "$1" --arg kai "$SB_KEEPALIVE_INTERVAL" \
  --argjson udp "$([[ $ALLOW_UDP == 1 ]] && echo true || echo false)" \
  '{
    log: { level: $loglevel, timestamp: true },
    dns: {
      servers: [ { type: "https", tag: "doh", server: $doh, detour: "proxy" } ],
      final: "doh",
      strategy: "ipv4_only"
    },
    inbounds: [ {
      type: "tun", tag: "tun-in",
      interface_name: $tun,
      address: [ $tunaddr ],
      mtu: 9000,
      auto_route: true,
      strict_route: true,
      route_exclude_address: $excl
    } ],
    outbounds: [
      ( { type: "socks", tag: "proxy", server: $sip, server_port: $sport, version: "5" }
        + (if $user != "" then { username: $user, password: $pass } else {} end)
        + (if $udp then {} else { network: "tcp" } end)
        + (if $ka != "" then { tcp_keep_alive: $ka, tcp_keep_alive_interval: $kai } else {} end) )
    ],
    route: {
      rules: ( [
        { action: "sniff" },
        { protocol: "dns", action: "hijack-dns" },
        { port: 53, action: "hijack-dns" },
        { ip_is_private: true, action: "reject" }
      ] + (if $udp then [] else [ { network: "udp", action: "reject" } ] end) ),
      final: "proxy",
      auto_detect_interface: true
    }
  }' >"$SB_CONF"
}
gen_sb_conf "$SB_KEEPALIVE"
chmod 600 "$SB_CONF"
if ! sing-box check -c "$SB_CONF"; then
  [[ -n $SB_KEEPALIVE ]] || die "sing-box отверг конфиг $SB_CONF"
  log "WARNING: эта версия sing-box не знает tcp_keep_alive — запускаю без него (обрывы прокси будут замечаться дольше)"
  gen_sb_conf ""
  sing-box check -c "$SB_CONF" || die "sing-box отверг конфиг $SB_CONF"
fi
log "sing-box $(sing-box version 2>/dev/null | head -n1 | awk '{print $NF}'): TUN -> socks5://$SOCKS_IP:$SOCKS_PORT, DoH $DOH_SERVER через прокси, UDP: $([[ $ALLOW_UDP == 1 ]] && echo через прокси || echo заблокирован)"

# ---------------------------------------------------------------- 4. run sing-box (с авто-перезапуском)
(
  while :; do
    sing-box run -c "$SB_CONF" -D /var/lib/sing-box || log "sing-box завершился с кодом $?"
    log "перезапуск sing-box через 2 с (kill-switch всё это время блокирует трафик)"
    sleep 2
  done
) &
SB_LOOP=$!
trap 'log "остановка"; kill "$SB_LOOP" 2>/dev/null; pkill -x sing-box 2>/dev/null; exit 0' TERM INT

for _ in $(seq 1 30); do ip link show "$TUN_IF" >/dev/null 2>&1 && break; sleep 1; done
ip link show "$TUN_IF" >/dev/null 2>&1 || die "$TUN_IF не поднялся"
log "$TUN_IF поднят"

# ---------------------------------------------------------------- 5. geo
attempt=0
while :; do
  attempt=$((attempt + 1))
  if line=$(geo_lookup); then
    IFS='|' read -r g_ip g_cc g_tz g_langs g_src <<<"$line"
    write_geo "$g_ip" "$g_cc" "$g_tz" "$g_langs" "$g_src"
    break
  fi
  if [[ -n ${GEO_TZ:-} && -n ${GEO_LOCALE:-} && $attempt -ge 3 ]]; then
    log "гео-сервисы недоступны, использую GEO_TZ/GEO_LOCALE из .env"
    write_geo "unknown" "" "$GEO_TZ" "" "env"
    break
  fi
  log "не удалось определить гео через прокси (попытка $attempt) — проверьте SOCKS_* в .env; повтор через 5 с"
  sleep 5
done

wait "$SB_LOOP"
