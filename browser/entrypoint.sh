#!/usr/bin/env bash
# claude-box (Mac) / browser entrypoint (root): гео прокси (TZ, локаль, языки), политики Chrome
# против утечек, пароль VNC — затем supervisord (Xvfb, openbox, x11vnc, noVNC, Chrome).
set -Eeuo pipefail
log() { printf '%s [browser] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

GEO_FILE=/shared/geo.env
[[ -n ${VNC_PASSWORD:-} && ${VNC_PASSWORD} != change-me ]] || die "задайте VNC_PASSWORD в .env"

for _ in $(seq 1 180); do [[ -s $GEO_FILE ]] && break; sleep 1; done
[[ -s $GEO_FILE ]] || die "нет $GEO_FILE — шлюз не поднялся"
# shellcheck disable=SC1090
source "$GEO_FILE"

TZ_NAME=${GEO_TZ:-UTC}
[[ -f /usr/share/zoneinfo/$TZ_NAME ]] || TZ_NAME=UTC
ln -snf "/usr/share/zoneinfo/$TZ_NAME" /etc/localtime
echo "$TZ_NAME" >/etc/timezone

LOC=en_US.UTF-8
for l in "${GEO_LOCALE:-}" "${GEO_LOCALE_ALT:-}"; do
  if [[ -n $l ]] && grep -qx "$l UTF-8" /usr/share/i18n/SUPPORTED; then LOC=$l; break; fi
done
localedef -i "${LOC%%.*}" -c -f UTF-8 -A /usr/share/locale/locale.alias "$LOC" >/dev/null 2>&1 || true

cat >/etc/profile.d/00-geo.sh <<EOF
export TZ='$TZ_NAME'
export LANG='$LOC'
export LANGUAGE='${LOC%%.*}:${LOC%%_*}'
export CHROME_LANG='${GEO_LANG:-en-US}'
export ACCEPT_LANG='${GEO_ACCEPT_LANG:-en-US,en}'
EOF
# shellcheck disable=SC1091
. /etc/profile.d/00-geo.sh
log "гео прокси: ${GEO_IP:-?} (${GEO_COUNTRY:-?}), TZ=$TZ, LANG=$LANG, Accept-Language=$ACCEPT_LANG"

printf 'nameserver 172.19.0.2\noptions timeout:2 attempts:3\n' >/etc/resolv.conf 2>/dev/null || true

# Политики Chrome: WebRTC только через прокси, без QUIC, геолокация запрещена, без телеметрии
POLICY='{
  "WebRtcIPHandling": "disable_non_proxied_udp",
  "QuicAllowed": false,
  "DefaultGeolocationSetting": 2,
  "MetricsReportingEnabled": false,
  "PromotionalTabsEnabled": false,
  "DefaultBrowserSettingEnabled": false,
  "BackgroundModeEnabled": false
}'
for d in /etc/opt/chrome/policies/managed /etc/chromium/policies/managed; do
  mkdir -p "$d" && printf '%s\n' "$POLICY" >"$d/claude-box.json"
done

install -d -o browser -g browser -m 700 /home/browser/.vnc
x11vnc -storepasswd "$VNC_PASSWORD" /home/browser/.vnc/passwd >/dev/null 2>&1 || die "не удалось сохранить пароль VNC"
chown browser:browser /home/browser/.vnc/passwd && chmod 600 /home/browser/.vnc/passwd
unset VNC_PASSWORD
chown browser:browser /home/browser

export DISPLAY=:1 SCREEN="${SCREEN:-1600x900x24}"
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
