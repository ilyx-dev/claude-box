#!/bin/bash
# claude-box — единый установщик: Mac (OrbStack/Docker Desktop) и Linux-сервер (VDS).
#
#   ./install.sh                 установка или повторная настройка (профиль — по ОС: macOS -> mac, Linux -> server)
#   ./install.sh --check         только проверка системы, ничего не меняет
#   ./install.sh --update        обновить установленное: код (git pull), .env, пересборка, тест утечек
#   ./install.sh --update --detach   то же в фоне (агент так обновляет сам себя; итог — в install.log)
#   ./install.sh --report        диагностика одним блоком (секреты замаскированы) — для чата с Claude
#
# Флаги: --profile mac|server  --browser|--no-browser  --docker ro|0  --host-access 1|0
#        -y|--yes (без вопросов, для запуска по SSH)  --force (игнорировать нехватку ресурсов)  --no-pull
# Повторный запуск безопасен: существующий .env не перезаписывается, а дополняется.
# Совместим с системным bash 3.2 macOS.
set -eu
cd "$(dirname "$0")"
DIR=$(pwd -P)
VERSION=$(cat VERSION 2>/dev/null || echo dev)
LOG="$DIR/install.log"
ORIG_ARGS=("$@")

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; }

ACTION=install PROFILE_ARG="" YES=0 FORCE=0 DETACH=0 PULL=1 SET_BROWSER="" SET_DOCKER="" SET_HOSTACC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE_ARG=${2:-}; shift ;;
    --profile=*) PROFILE_ARG=${1#*=} ;;
    --browser) SET_BROWSER=1 ;;
    --no-browser) SET_BROWSER=0 ;;
    --docker) SET_DOCKER=${2:-}; shift ;;
    --docker=*) SET_DOCKER=${1#*=} ;;
    --host-access) SET_HOSTACC=${2:-}; shift ;;
    --host-access=*) SET_HOSTACC=${1#*=} ;;
    --update) ACTION=update ;;
    --check) ACTION=check ;;
    --report) ACTION=report ;;
    --detach) DETACH=1 ;;
    --no-pull) PULL=0 ;;
    -y|--yes) YES=1 ;;
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "неизвестный аргумент: $1"; echo; usage; exit 1 ;;
  esac
  shift
done
case "$PROFILE_ARG" in ""|mac|server) ;; *) echo "--profile: mac или server"; exit 1 ;; esac
case "$SET_DOCKER" in ""|ro|0) ;; off) SET_DOCKER=0 ;; *) echo "--docker: ro или 0"; exit 1 ;; esac
case "$SET_HOSTACC" in ""|0|1) ;; *) echo "--host-access: 1 или 0"; exit 1 ;; esac

# ─────────────────────────────────────────────── фоновый запуск (обновление самого себя)
if [ "$DETACH" = 1 ]; then
  args=()
  for a in ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}; do [ "$a" = --detach ] || args+=("$a"); done
  if command -v setsid >/dev/null 2>&1; then runner="setsid nohup"; else runner="nohup"; fi
  # shellcheck disable=SC2086
  CB_TEED=1 CB_NOCOLOR=1 $runner bash "$DIR/install.sh" ${args[@]+"${args[@]}"} --yes >>"$LOG" 2>&1 </dev/null &
  echo "claude-box: запущено в фоне (pid $!). Ход и итог: $LOG"
  echo "Контейнер агента будет пересоздан: сессия Claude Code оборвётся и вернётся сама через 1–3 минуты."
  exit 0
fi

# ─────────────────────────────────────────────── вывод и журнал
if [ -t 1 ] && [ -z "${CB_NOCOLOR:-}" ]; then B=$'\033[1m'; G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; N=$'\033[0m'; else B="" G="" R="" Y="" N=""; fi
if [ "$ACTION" != report ] && [ -z "${CB_TEED:-}" ]; then
  export CB_TEED=1
  exec > >(tee -a "$LOG") 2>&1
fi
[ "$ACTION" != report ] && printf '\n######## %s  install.sh %s  (v%s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${ORIG_ARGS[*]-}" "$VERSION"
say()  { printf '\n%s==> %s%s\n' "$B" "$*" "$N"; }
ok()   { printf '  %s✔%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; WARNS=$((WARNS + 1)); }
err()  { printf '  %s✘%s %s\n' "$R" "$N" "$*"; ERRS=$((ERRS + 1)); }
die()  { printf '  %s✘ %s%s\n' "$R" "$*" "$N"; exit 1; }
WARNS=0 ERRS=0
TTY=0; [ -t 0 ] && TTY=1
ask_yn() { # ask_yn "Вопрос" -> 0 = да
  if [ "$YES" = 1 ]; then echo "  $1 -> да (--yes)"; return 0; fi
  if [ "$TTY" != 1 ]; then echo "  $1 -> пропущено (нет терминала; запустите с --yes, чтобы согласиться)"; return 1; fi
  local a; read -r -p "  $1 [y/N] " a
  case "$a" in y|Y|yes|д|Д|да) return 0 ;; *) return 1 ;; esac
}
ask() { # ask "Вопрос" "умолчание" -> печатает ответ
  if [ "$TTY" != 1 ] || [ "$YES" = 1 ]; then printf '%s' "${2:-}"; return; fi
  local a; read -r -p "  $1${2:+ [$2]}: " a; printf '%s' "${a:-${2:-}}"
}

# ─────────────────────────────────────────────── .env
env_get() { [ -f .env ] || return 0; sed -n "s/^$1=//p" .env | tail -n1 | sed -e "s/^'//" -e "s/'\$//" -e 's/^"//' -e 's/"$//'; }
env_set() { # KEY VALUE — пишет KEY='VALUE' без интерпретации спецсимволов
  local tmp
  case "$2" in *"'"*) die "значение $1 содержит одинарную кавычку — впишите его в .env вручную" ;; esac
  tmp=$(mktemp)
  K="$1" L="$1='$2'" awk 'BEGIN { d = 0 }
    index($0, ENVIRON["K"] "=") == 1 { if (!d) print ENVIRON["L"]; d = 1; next }
    { print }
    END { if (!d) print ENVIRON["L"] }' .env >"$tmp"
  cat "$tmp" >.env; rm -f "$tmp"
}
env_default() { [ -n "$(env_get "$1")" ] || env_set "$1" "$2"; } # задать, только если пусто
prof_get() { sed -n "s/^$2=//p" "profiles/$1.env" 2>/dev/null | tail -n1; }
gen_pass() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$1"; }
expand_path() { case "$1" in "~") printf '%s' "$HOME" ;; "~/"*) printf '%s/%s' "$HOME" "${1#\~/}" ;; ./*) printf '%s/%s' "$DIR" "${1#./}" ;; *) printf '%s' "$1" ;; esac; }

# ─────────────────────────────────────────────── IPv4/CIDR
ip2int() { local IFS=.; set -- $1; echo $(( ($1 << 24) + ($2 << 16) + ($3 << 8) + $4 )); }
int2ip() { echo "$(( ($1 >> 24) & 255 )).$(( ($1 >> 16) & 255 )).$(( ($1 >> 8) & 255 )).$(( $1 & 255 ))"; }
cidr_bounds() { # a.b.c.d/n -> "start end"
  local ip=${1%/*} bits=${1#*/} n m
  case "$1" in */*) ;; *) bits=32 ;; esac
  n=$(ip2int "$ip"); m=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
  echo "$(( n & m )) $(( (n & m) | (~m & 0xFFFFFFFF) ))"
}
cidr_overlap() { local a b; a=$(cidr_bounds "$1"); b=$(cidr_bounds "$2"); set -- $a $b; [ "$1" -le "$4" ] && [ "$3" -le "$2" ]; }
is_cidr() { echo "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$'; }

# ─────────────────────────────────────────────── система
OS=$(uname -s)
ARCH=$(uname -m)
SUDO=""
[ "$(id -u)" = 0 ] || { command -v sudo >/dev/null 2>&1 && SUDO="sudo"; }
port_busy() { # 0 = порт кем-то слушается
  if [ "$OS" = Darwin ]; then lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
  elif command -v ss >/dev/null 2>&1; then [ -n "$(ss -Hltn "sport = :$1" 2>/dev/null)" ]
  else netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$1\$"; fi
}
mem_mb() {
  if [ "$OS" = Darwin ]; then echo $(( $(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0) / 1048576 ))
  else awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo; fi
}
swap_mb() { [ "$OS" = Linux ] && awk '/^SwapTotal:/ { print int($2 / 1024) }' /proc/meminfo || echo 0; }
disk_free_gb() {
  local d
  if [ "$OS" = Linux ]; then d=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker); [ -d "$d" ] || d=/
  else d=$HOME; fi
  df -Pk "$d" 2>/dev/null | awk 'NR == 2 { print int($4 / 1048576) }'
}
ver_ge() { # ver_ge 2.21.0 2.20 -> 0 если первая >= второй
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -n1)" = "$2" ]
}
gw() { local p; p=$(env_get BOX_PREFIX); echo "${p:-claude}-gateway"; }
ag() { local p; p=$(env_get BOX_PREFIX); echo "${p:-claude}-agent"; }

# ═══════════════════════════════════════════════ 1. профиль и .env
setup_env() {
  say "Настройки (.env)"
  if [ ! -f .env ]; then cp .env.example .env; ok "создан .env из шаблона"; fi
  chmod 600 .env

  local p; p=$PROFILE_ARG
  [ -n "$p" ] || p=$(env_get PROFILE)
  if [ -z "$p" ]; then case "$OS" in Darwin) p=mac ;; *) p=server ;; esac; fi
  [ -f "profiles/$p.env" ] || die "нет профиля profiles/$p.env"
  env_set PROFILE "$p"
  PROFILE=$p
  # умолчания профиля — только для пустых ключей
  while IFS='=' read -r k v; do
    case "$k" in ''|'#'*) continue ;; esac
    env_default "$k" "$v"
  done <"profiles/$p.env"
  # ключи, которых нет в .env (появились в новой версии), — из шаблона
  while IFS='=' read -r k v; do
    case "$k" in ''|'#'*) continue ;; esac
    grep -q "^$k=" .env || printf '%s=%s\n' "$k" "$v" >>.env
  done <.env.example
  [ -n "$SET_BROWSER" ] && env_set BROWSER "$SET_BROWSER"
  [ -n "$SET_DOCKER" ] && env_set HOST_DOCKER "$SET_DOCKER"
  [ -n "$SET_HOSTACC" ] && env_set HOST_ACCESS "$SET_HOSTACC"

  # прокси
  if [ -z "$(env_get SOCKS_HOST)" ] || [ "$(env_get SOCKS_HOST)" = 203.0.113.10 ]; then
    if [ "$TTY" = 1 ] && [ "$YES" != 1 ]; then
      echo "  Данные SOCKS5-прокси (лучше IP, а не доменное имя):"
      env_set SOCKS_HOST "$(ask 'Адрес прокси' '')"
      env_set SOCKS_PORT "$(ask 'Порт' "$(env_get SOCKS_PORT)")"
      env_set SOCKS_USER "$(ask 'Логин (пусто, если нет)' '')"
      if [ -n "$(env_get SOCKS_USER)" ]; then
        local pw; read -r -s -p "  Пароль: " pw; echo; env_set SOCKS_PASS "$pw"; unset pw
      fi
      if ask_yn "Прокси поддерживает UDP (UDP ASSOCIATE)? Если не знаете — N"; then env_set ALLOW_UDP 1; else env_set ALLOW_UDP 0; fi
    else
      die "в $DIR/.env не заданы SOCKS_HOST/SOCKS_PORT (и SOCKS_USER/SOCKS_PASS). Впишите их и запустите снова."
    fi
  fi
  [ -n "$(env_get SOCKS_PORT)" ] || die "SOCKS_PORT пуст"
  ok "прокси: $(env_get SOCKS_HOST):$(env_get SOCKS_PORT)"

  # пароли веб-интерфейсов
  case "$(env_get TTYD_PASSWORD)" in ''|change-me) env_set TTYD_PASSWORD "$(gen_pass 20)"; ok "сгенерирован пароль веб-терминала" ;; esac
  case "$(env_get VNC_PASSWORD)" in ''|change-me) env_set VNC_PASSWORD "$(gen_pass 8)" ;; esac

  # пользователь хоста, uid/gid агента
  local hu; hu=$(env_get HOST_SSH_USER)
  if [ -z "$hu" ]; then hu=${SUDO_USER:-$(id -un)}; env_set HOST_SSH_USER "$hu"; fi
  if [ -z "$(env_get PUID)" ]; then
    local u g
    if [ "$OS" = Linux ]; then u=$(id -u "$hu" 2>/dev/null || echo 1000); g=$(id -g "$hu" 2>/dev/null || echo 1000)
    else u=1000; g=1000; fi
    # агент никогда не должен быть root внутри контейнера (иначе перепишет свои правила)
    [ "$u" = 0 ] && u=1000 && g=1000
    env_set PUID "$u"; env_set PGID "$g"
  fi
  [ "$(env_get PUID)" != 0 ] || die "PUID=0 недопустим: агент стал бы root в контейнере"

  # рабочая папка
  local ws; ws=$(env_get WORKSPACE_DIR)
  if [ "$PROFILE" = server ] && [ "$ws" = /srv/claude-workspace ] && [ "$(id -u)" != 0 ] && [ ! -d /srv/claude-workspace ]; then
    ws="$HOME/claude-workspace"
  fi
  if [ "$ACTION" = install ] && [ ! -d "$(expand_path "$ws")" ]; then ws=$(ask "Рабочая папка агента на этой машине" "$(expand_path "$ws")"); fi
  ws=$(expand_path "$ws"); env_set WORKSPACE_DIR "$ws"
  # установленная копия (с .env и паролями) не должна быть видна агенту через /workspace
  case "$DIR/" in "${ws%/}/"*) die "claude-box установлен внутри рабочей папки агента ($ws): агент увидел бы .env с паролями и мог бы менять свои настройки. Перенесите папку claude-box за пределы $ws (например ~/claude-box) и запустите снова." ;; esac
  if [ "$ACTION" != check ]; then
    mkdir -p "$ws" 2>/dev/null || $SUDO mkdir -p "$ws" || die "не удалось создать $ws"
    if [ "$OS" = Linux ] && [ "$(stat -c %u "$ws")" != "$(env_get PUID)" ]; then
      $SUDO chown "$(env_get PUID):$(env_get PGID)" "$ws" 2>/dev/null || warn "не удалось сменить владельца $ws на $(env_get PUID)"
    fi
  fi

  # сеть: адреса docker-ro и диапазон динамических адресов из подсети
  local sub; sub=$(env_get DOCKER_SUBNET)
  is_cidr "$sub" || die "DOCKER_SUBNET='$sub' — нужен формат a.b.c.d/n"
  local bits=${sub#*/}; [ "$bits" -le 28 ] || die "DOCKER_SUBNET слишком мала (нужно /28 или больше)"
  local b; b=$(cidr_bounds "$sub"); set -- $b
  local want_ro want_range; want_ro=$(int2ip $(( $1 + 3 ))); want_range="$(int2ip $(( $1 + ($2 - $1 + 1) / 2 )))/$(( bits + 1 ))"
  if [ "$sub" != 172.29.0.0/24 ] && { [ "$(env_get DOCKER_RO_IP)" = 172.29.0.3 ] || [ "$(env_get DOCKER_IP_RANGE)" = 172.29.0.128/25 ]; }; then
    env_set DOCKER_RO_IP "$want_ro"; env_set DOCKER_IP_RANGE "$want_range"
  fi

  # какие сервисы включены
  local profs=""
  [ "$(env_get BROWSER)" = 1 ] && profs="browser"
  [ "$(env_get HOST_DOCKER)" = ro ] && profs="${profs:+$profs,}docker"
  env_set COMPOSE_PROFILES "$profs"
  set_compose_files
  ok "профиль $PROFILE: браузер=$(env_get BROWSER), docker хоста=$(env_get HOST_DOCKER), доступ к хосту=$(env_get HOST_ACCESS) (ssh $(env_get HOST_ALIAS)), рабочая папка $ws"
}

# ═══════════════════════════════════════════════ 2. проверка системы
preflight() {
  say "Проверка системы"
  # --force запоминается в .env (FORCE_RESOURCES=1): иначе --update и самообновление из агента падали бы
  # на той же нехватке ресурсов, которую пользователь уже принял. Отменить — убрать ключ из .env.
  if [ "$FORCE" != 1 ] && [ "$(env_get FORCE_RESOURCES)" = 1 ]; then
    FORCE=1; echo "  (FORCE_RESOURCES=1 в .env: нехватка RAM/диска — предупреждение, а не ошибка)"
  fi
  if [ "$FORCE" = 1 ] && [ "$ACTION" != check ] && [ -f .env ] && [ "$(env_get FORCE_RESOURCES)" != 1 ]; then
    env_set FORCE_RESOURCES 1
  fi
  local br; br=$(env_get BROWSER); [ -n "$br" ] || br=$( [ -n "$SET_BROWSER" ] && echo "$SET_BROWSER" || echo 0 )
  case "$OS" in
    Darwin) ok "macOS $(sw_vers -productVersion 2>/dev/null || echo ?) ($ARCH)" ;;
    Linux) ok "Linux: $( . /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-?}" || echo ?), ядро $(uname -r) ($ARCH)" ;;
    *) err "неподдерживаемая ОС: $OS" ;;
  esac
  case "$ARCH" in x86_64|amd64|arm64|aarch64) ;; *) err "архитектура $ARCH не поддерживается (нужна amd64 или arm64)" ;; esac

  # CB_TEST_TUN_DEV — только для tests/install-dryrun.sh (в контейнере агента TUN нет); в реальной установке не задавать
  local tun_dev=/dev/net/tun
  if [ -n "${CB_TEST_TUN_DEV:-}" ]; then
    tun_dev=$CB_TEST_TUN_DEV
    warn "задана CB_TEST_TUN_DEV=$tun_dev — только для тестов: проверка TUN смотрит её вместо /dev/net/tun. Для реальной установки уберите"
  fi
  if [ "$OS" = Linux ]; then
    local virt; virt=$(systemd-detect-virt 2>/dev/null || echo unknown)
    case "$virt" in openvz|lxc|lxc-libvirt) warn "виртуализация $virt: TUN и nftables в контейнерах часто недоступны" ;; *) ok "виртуализация: $virt" ;; esac
    if [ -c "$tun_dev" ]; then ok "$tun_dev есть"
    elif $SUDO modprobe tun 2>/dev/null && [ -c "$tun_dev" ]; then ok "$tun_dev: модуль tun загружен"
      echo tun | $SUDO tee /etc/modules-load.d/tun.conf >/dev/null 2>&1 || true
    else err "нет /dev/net/tun и не удалось загрузить модуль tun — без TUN kill-switch невозможен"; fi
  fi

  # Docker
  if ! command -v docker >/dev/null 2>&1; then
    if [ "$OS" = Darwin ]; then err "Docker не найден: установите OrbStack (brew install --cask orbstack) или Docker Desktop"
    else err "Docker не найден: установите Docker Engine из официального репозитория (https://docs.docker.com/engine/install/)"; fi
    return
  fi
  local dout
  if ! dout=$(docker info --format '{{.ServerVersion}}' 2>&1); then
    case "$dout" in *ermission*) err "нет прав на Docker: добавьте пользователя в группу docker (sudo usermod -aG docker $(id -un), перелогиньтесь) или запустите через sudo" ;;
      *) err "Docker не запущен: $( [ "$OS" = Darwin ] && echo 'откройте OrbStack или Docker Desktop' || echo 'sudo systemctl start docker')" ;; esac
    return
  fi
  local dv cv; dv=$dout; cv=$(docker compose version --short 2>/dev/null | sed 's/^v//' || true)
  if ver_ge "$dv" 20.10; then ok "Docker $dv"; else err "Docker $dv слишком старый (нужен 20.10+)"; fi
  if [ -z "$cv" ]; then err "нет docker compose v2 (плагин docker-compose-plugin)"
  elif ver_ge "$cv" 2.20; then ok "docker compose $cv"; else err "docker compose $cv слишком старый (нужен 2.20+)"; fi

  # ресурсы
  local mem swp disk need_mem rec_mem need_disk
  mem=$(mem_mb); swp=$(swap_mb); disk=$(disk_free_gb)
  if [ "$br" = 1 ]; then need_mem=3000 rec_mem=4000 need_disk=10; else need_mem=1000 rec_mem=2000 need_disk=5; fi
  local what="без браузера"; [ "$br" = 1 ] && what="с браузером"
  if [ "${mem:-0}" -lt "$need_mem" ]; then
    if [ "$FORCE" = 1 ]; then warn "RAM ${mem} МБ меньше минимума $need_mem МБ для установки $what (--force)"
    else err "RAM ${mem} МБ меньше минимума $need_mem МБ для установки $what$( [ "$br" = 1 ] && echo ' — уберите браузер (--no-browser)' ) или добавьте --force"; fi
  # машина «на 4 ГБ» показывает чуть меньше 4000 МБ (часть забирает ядро/VM) — рекомендацию сверяем с допуском 5%;
  # swap на Mac не измеряется (он внутри VM Docker), поэтому и не показывается
  elif [ "$mem" -lt $((rec_mem * 95 / 100)) ]; then warn "RAM ${mem} МБ$( [ "$OS" = Linux ] && echo " (+swap ${swp} МБ)" ): работать будет, рекомендуется $rec_mem МБ$( [ "$OS" = Linux ] && [ "${swp:-0}" -lt 2000 ] && echo ' или swap 2–4 ГБ' )"
  else ok "RAM ${mem} МБ$( [ "$OS" = Linux ] && echo " (+swap ${swp} МБ)" )"; fi
  if [ "${disk:-0}" -lt "$need_disk" ]; then
    if [ "$FORCE" = 1 ]; then warn "свободно ${disk} ГБ, нужно от $need_disk ГБ (--force)"; else err "свободно ${disk} ГБ на диске Docker, нужно от $need_disk ГБ"; fi
  else ok "диск: свободно ${disk} ГБ"; fi

  # имена контейнеров и порты
  local pfx proj n name lbl
  pfx=$(env_get BOX_PREFIX); [ -n "$pfx" ] || pfx=claude
  proj=$(env_get COMPOSE_PROJECT_NAME); [ -n "$proj" ] || proj=$(prof_get "${PROFILE:-server}" COMPOSE_PROJECT_NAME)
  for n in gateway agent browser docker-ro; do
    name="$pfx-$n"
    if docker inspect "$name" >/dev/null 2>&1; then
      lbl=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$name" 2>/dev/null || true)
      if [ "$lbl" != "$proj" ]; then err "контейнер $name уже есть и принадлежит «${lbl:-не compose}» — задайте другой BOX_PREFIX в .env (например cbox)"; fi
    fi
  done
  local mine=0 e0=$ERRS port pname
  docker inspect "$pfx-gateway" >/dev/null 2>&1 && mine=1
  for pname in TTYD_PORT NOVNC_PORT; do
    [ "$pname" = NOVNC_PORT ] && [ "$br" != 1 ] && continue   # без браузера noVNC не публикуется
    port=$(env_get "$pname")
    [ -n "$port" ] || { [ "$pname" = TTYD_PORT ] && port=7681 || port=6080; }
    # свой работающий шлюз — не конфликт
    if [ "$mine" = 0 ] && port_busy "$port"; then err "порт $port занят — поменяйте $pname в .env"; fi
  done
  [ "$ERRS" -gt "$e0" ] || ok "имена контейнеров ($pfx-*) и порты свободны"

  # подсеть Docker
  local sub net subs s
  sub=$(env_get DOCKER_SUBNET); [ -n "$sub" ] || sub=172.29.0.0/24
  for net in $(docker network ls -q 2>/dev/null); do
    n=$(docker network inspect -f '{{.Name}}' "$net" 2>/dev/null) || continue
    [ "$n" = "${proj}_egress" ] && continue
    subs=$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "$net" 2>/dev/null || true)
    for s in $subs; do
      is_cidr "$s" || continue
      if cidr_overlap "$sub" "$s"; then err "подсеть $sub пересекается с сетью Docker «$n» ($s) — задайте другую DOCKER_SUBNET в .env (например 172.30.0.0/24)"; fi
    done
  done
  if [ "$OS" = Linux ] && command -v ip >/dev/null 2>&1; then
    for s in $(ip -4 route show 2>/dev/null | awk '$1 ~ /\// { print $1 }'); do
      is_cidr "$s" || continue
      case "$s" in 172.17.0.0/16) continue ;; esac
      cidr_overlap "$sub" "$s" && ! docker network ls --format '{{.Name}}' 2>/dev/null | grep -qx "${proj}_egress" && warn "подсеть $sub пересекается с маршрутом хоста $s (VPN?) — лучше другая DOCKER_SUBNET"
    done
  fi
  [ "$ERRS" -gt "$e0" ] || ok "подсеть claude-box: $sub"

  # SSH на хосте
  if [ "$(env_get HOST_ACCESS)" != 0 ]; then
    local sp; sp=$(env_get HOST_SSH_PORT); [ -n "$sp" ] || sp=22
    if [ "$OS" = Darwin ]; then
      (exec 3<>/dev/tcp/127.0.0.1/"$sp") 2>/dev/null && ok "SSH на Mac включён" || warn "«Удалённый вход» (SSH) на Mac выключен — включу подсказку позже"
    else
      port_busy "$sp" && ok "sshd слушает порт $sp" || warn "sshd не слушает порт $sp — агент не сможет выполнять команды на хосте"
    fi
  fi
}

# ═══════════════════════════════════════════════ 3. прокси
check_proxy() {
  say "Проверяю прокси с этой машины"
  local cfg info
  cfg=$(mktemp); chmod 600 "$cfg"
  cesc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
  printf 'socks5-hostname = "%s:%s"\n' "$(cesc "$(env_get SOCKS_HOST)")" "$(env_get SOCKS_PORT)" >"$cfg"
  [ -n "$(env_get SOCKS_USER)" ] && printf 'proxy-user = "%s:%s"\n' "$(cesc "$(env_get SOCKS_USER)")" "$(cesc "$(env_get SOCKS_PASS)")" >>"$cfg"
  if info=$(curl -sS --max-time 20 -K "$cfg" https://ipinfo.io/json 2>&1); then
    rm -f "$cfg"
    echo "$info" | grep -E '"(ip|country|city|timezone)"' | sed 's/^ */    /'
    ok "прокси отвечает"
  else
    rm -f "$cfg"
    echo "    $info"
    die "прокси не отвечает — проверьте SOCKS_* в .env и повторите"
  fi
}

# ═══════════════════════════════════════════════ 4. код (обновление)
pull_code() {
  [ "$PULL" = 1 ] || return 0
  [ -d .git ] && command -v git >/dev/null 2>&1 || { echo "  (не git-репозиторий — использую файлы как есть)"; return 0; }
  say "Обновляю код"
  if [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    warn "в коде есть локальные изменения — git pull пропущен (git status)"; return 0
  fi
  local before; before=$(git rev-parse --short HEAD 2>/dev/null || echo ?)
  if git pull --ff-only -q 2>&1; then ok "код: $before -> $(git rev-parse --short HEAD) (v$(cat VERSION 2>/dev/null || echo ?))"
    [ "$before" != "$(git rev-parse --short HEAD)" ] && exec bash "$DIR/install.sh" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"} --no-pull
  else warn "git pull не удался — продолжаю с текущим кодом ($before)"; fi
}

# ═══════════════════════════════════════════════ 5. сборка и запуск
# COMPOSE_FILE в .env: порт noVNC публикуется только с браузером (docker-compose.browser.yml).
# Раз COMPOSE_FILE задан, compose сам override не подхватит — добавляем его явно (диск Mac, ваши правки).
set_compose_files() {
  local f="docker-compose.yml"
  [ "$(env_get BROWSER)" = 1 ] && f="$f:docker-compose.browser.yml"
  [ -f docker-compose.override.yml ] && f="$f:docker-compose.override.yml"
  env_set COMPOSE_FILE "$f"
}
compose_up() { # с одной попыткой пересоздать сеть, если изменилась её конфигурация
  local out
  if out=$(docker compose up -d ${1+"$@"} 2>&1); then echo "$out" | tail -n 20; return 0; fi
  echo "$out" | tail -n 20
  case "$out" in
    *network*) warn "конфигурация сети изменилась — пересоздаю сеть (тома и данные сохраняются)"
      docker compose down --remove-orphans && docker compose up -d ${1+"$@"} ;;
    *) return 1 ;;
  esac
}
build_and_start() {
  local GWN; GWN=$(gw)
  if [ "$(env_get PROFILE)" = mac ]; then
    say "Домашняя папка Mac для агента (только чтение, секреты скрыты)"
    bash scripts/gen-mac-mounts.sh
  fi
  set_compose_files   # override мог только что появиться

  say "Сборка образов (первый раз — 5–15 минут)"
  docker compose build --pull

  # выключенные сервисы — остановить, если работали
  [ "$(env_get BROWSER)" = 1 ] || { docker inspect "$(env_get BOX_PREFIX)-browser" >/dev/null 2>&1 && docker compose --profile browser rm -sf browser; } || true
  [ "$(env_get HOST_DOCKER)" = ro ] || { docker inspect "$(env_get BOX_PREFIX)-docker-ro" >/dev/null 2>&1 && docker compose --profile docker rm -sf docker-ro; } || true

  local before after st i
  before=$(docker inspect -f '{{.Id}}' "$GWN" 2>/dev/null || echo none)
  say "Запускаю шлюз (туннель + kill-switch)"
  compose_up gateway || die "шлюз не запустился (docker compose logs gateway)"
  st=starting; i=0
  while [ $i -lt 60 ]; do
    st=$(docker inspect -f '{{.State.Health.Status}}' "$GWN" 2>/dev/null || echo missing)
    [ "$st" = healthy ] && break
    i=$((i + 1)); sleep 5
  done
  if [ "$st" != healthy ]; then
    docker compose logs --tail 40 gateway
    die "шлюз не поднялся (статус: $st). Частая причина — неверные SOCKS_* в .env"
  fi
  docker compose logs gateway 2>/dev/null | grep 'geo:' | tail -n1 | sed 's/^/    /' || true
  ok "туннель и kill-switch работают"

  say "Запускаю агента$( [ "$(env_get BROWSER)" = 1 ] && echo ' и браузер' )$( [ "$(env_get HOST_DOCKER)" = ro ] && echo ' и docker-ro' )"
  compose_up || die "не удалось запустить сервисы (docker compose logs)"
  after=$(docker inspect -f '{{.Id}}' "$GWN" 2>/dev/null || echo none)
  if [ "$before" != none ] && [ "$before" != "$after" ]; then
    # Обычно compose сам пересоздаёт агента и браузер под новый шлюз. Добиваем только тех, кто остался в сети
    # старого: лишнее пересоздание — ещё один перезапуск агента, Remote Control и чатов.
    local deps="" s c
    for s in agent $( [ "$(env_get BROWSER)" = 1 ] && echo browser ); do
      c=$(docker compose ps -q "$s" 2>/dev/null | head -n1)
      if [ -z "$c" ] || [ "$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$c" 2>/dev/null)" != "container:$after" ]; then
        deps="$deps $s"
      fi
    done
    if [ -n "$deps" ]; then
      echo "  шлюз пересоздан — переподключаю к его новой сети:$deps"
      # shellcheck disable=SC2086
      docker compose up -d --force-recreate $deps
    fi
  fi
  sleep 10
  ok "контейнеры: $(docker compose ps --format '{{.Name}}={{.State}}' 2>/dev/null | tr '\n' ' ')"
}

# ═══════════════════════════════════════════════ 6. доступ агента к хосту
host_access() {
  [ "$(env_get HOST_ACCESS)" = 1 ] || return 0
  local A user home ak pub keybody sp alias
  A=$(ag); user=$(env_get HOST_SSH_USER); sp=$(env_get HOST_SSH_PORT); [ -n "$sp" ] || sp=22; alias=$(env_get HOST_ALIAS)
  say "Доступ агента к хосту по SSH (ssh $alias — каждая команда с вашего подтверждения)"
  if [ "$OS" = Darwin ] && ! (exec 3<>/dev/tcp/127.0.0.1/"$sp") 2>/dev/null; then
    warn "«Удалённый вход» (SSH) на Mac выключен. Включите:"
    echo "      Системные настройки → Основные → Общий доступ → Удалённый вход: ВКЛ"
    echo "      ⓘ рядом: «Разрешить доступ: Только эти пользователи» → только вы,"
    echo "        и «Полный доступ к диску для удалённых пользователей» (нужно для очистки ~/Library)"
    if [ "$TTY" = 1 ] && [ "$YES" != 1 ]; then read -r -p "  Нажмите Enter, когда включите (или Ctrl+C, чтобы пропустить)… " _; fi
  fi
  pub=$(docker exec "$A" cat /home/agent/.ssh/id_ed25519.pub 2>/dev/null || true)
  [ -n "$pub" ] || { warn "не удалось получить ключ агента (docker compose logs agent)"; return 0; }
  if [ "$OS" = Darwin ]; then home=$HOME
  else home=$(getent passwd "$user" 2>/dev/null | cut -d: -f6); [ -n "$home" ] || home=$(eval echo "~$user"); fi
  ak="$home/.ssh/authorized_keys"
  keybody=$(echo "$pub" | awk '{print $2}')
  if [ "$user" != "$(id -un)" ] && [ "$(id -u)" != 0 ]; then
    warn "ключ нужно добавить пользователю $user, а установщик запущен от $(id -un). Добавьте сами в $ak:"
    echo "      restrict,pty $pub"
  elif [ -f "$ak" ] && grep -q "$keybody" "$ak"; then
    ok "ключ агента уже в $ak"
  elif ask_yn "Добавить ключ агента в $ak (с ограничениями: без проброса портов и агента)?"; then
    mkdir -p "$home/.ssh"; chmod 700 "$home/.ssh"; touch "$ak"; chmod 600 "$ak"
    echo "restrict,pty $pub" >>"$ak"
    [ "$(id -u)" = 0 ] && [ "$user" != root ] && chown -R "$user" "$home/.ssh"
    ok "ключ добавлен"
  fi
  if [ "$OS" = Linux ] && command -v ufw >/dev/null 2>&1 && $SUDO ufw status 2>/dev/null | grep -q "Status: active"; then
    local sub; sub=$(env_get DOCKER_SUBNET)
    if ! $SUDO ufw status 2>/dev/null | grep -q "$sub"; then
      ask_yn "ufw активен: разрешить SSH (порт $sp) из сети claude-box $sub?" && $SUDO ufw allow from "$sub" to any port "$sp" proto tcp && ok "ufw: правило добавлено"
    fi
  fi
  local out
  if out=$(docker exec -u agent "$A" ssh -o BatchMode=yes -o ConnectTimeout=8 "$alias" 'echo "$(whoami)@$(hostname)"' 2>&1); then
    ok "агент подключается к хосту: $out"
  else
    warn "агент пока не может подключиться к хосту: $(echo "$out" | tail -n1)"
  fi
  [ "$OS" = Darwin ] && echo "  Чтобы агент видел ~/Library целиком: «Конфиденциальность и безопасность → Полный доступ к диску» → OrbStack/Docker."
  return 0
}

# ═══════════════════════════════════════════════ 7. второй слой kill-switch на Linux-хосте
host_firewall() {
  [ "$OS" = Linux ] || return 0
  command -v systemctl >/dev/null 2>&1 && command -v iptables >/dev/null 2>&1 || return 0
  [ "$(id -u)" = 0 ] || [ -n "$SUDO" ] || return 0
  say "Второй слой защиты на хосте (DOCKER-USER: из сети claude-box наружу — только на прокси)"
  local unit=/etc/systemd/system/claude-box-firewall.service
  if [ -f "$unit" ] && grep -q "$DIR" "$unit"; then
    $SUDO systemctl restart claude-box-firewall && ok "юнит claude-box-firewall обновлён и перезапущен"
  elif ask_yn "Установить systemd-юнит claude-box-firewall (iptables DOCKER-USER, переживает перезагрузку)?"; then
    sed "s#@DIR@#$DIR#g" scripts/claude-box-firewall.service | $SUDO tee "$unit" >/dev/null
    chmod +x scripts/host-firewall.sh
    $SUDO systemctl daemon-reload && $SUDO systemctl enable --now claude-box-firewall && ok "юнит включён"
  fi
}

# ═══════════════════════════════════════════════ 8. итог
leak_test() {
  say "Проверка изоляции (leak-test)"
  docker exec "$(ag)" leak-test || warn "есть замечания — см. вывод выше (сразу после старта TZ=? бывает — повторите: docker exec $(ag) leak-test)"
}
summary() {
  local A tp np
  A=$(ag); tp=$(env_get TTYD_PORT); np=$(env_get NOVNC_PORT)
  say "Готово (claude-box v$VERSION, профиль $(env_get PROFILE))"
  if [ "$(env_get PROFILE)" = mac ]; then
    echo "  Веб-терминал (Claude Code):  http://localhost:$tp   логин: $(env_get TTYD_USER)   пароль: в .env (TTYD_PASSWORD)"
    [ "$(env_get BROWSER)" = 1 ] && echo "  Браузер агента (noVNC):      http://localhost:$np   пароль: в .env (VNC_PASSWORD)"
  else
    echo "  Веб-терминал — через SSH-туннель с вашего компьютера:"
    echo "      ssh -N -L 17681:127.0.0.1:$tp$( [ "$(env_get BROWSER)" = 1 ] && echo " -L 16080:127.0.0.1:$np" ) <пользователь>@<сервер>"
    echo "      затем http://localhost:17681$( [ "$(env_get BROWSER)" = 1 ] && echo "  (браузер агента: http://localhost:16080)" ); пароли — в $DIR/.env"
  fi
  echo "  Терминал без браузера:       docker exec -it -u agent $A tmux attach -t main"
  echo "  Remote Control:              «$(env_get RC_NAME)» в приложении Claude и на claude.ai/code"
  echo
  echo "  Если это первая установка: подключитесь к терминалу, в окне claude выполните /login"
  echo "  (ссылку откройте в браузере, код вставьте обратно). Окно rc — сервер Remote Control,"
  echo "  на его вопросы (доверие к папке, Enable Remote Control?) один раз ответьте y."
  echo "  Обновление:  ./install.sh --update     Диагностика:  ./install.sh --report"
  [ "$WARNS" -gt 0 ] && echo "  Замечаний: $WARNS (см. «!» выше и $LOG)"
  return 0
}

# ═══════════════════════════════════════════════ отчёт
report() {
  local out="$DIR/report-$(date +%Y%m%d-%H%M%S).txt"
  ( umask 077
    {
      echo "claude-box report $(date '+%Y-%m-%d %H:%M:%S %z'), v$VERSION, git $(git rev-parse --short HEAD 2>/dev/null || echo -)"
      echo "OS: $OS $(uname -r) $ARCH"; [ "$OS" = Darwin ] && sw_vers 2>/dev/null | tr '\n' ' ' && echo
      echo "Docker: $(docker info --format '{{.ServerVersion}} / {{.OperatingSystem}}' 2>&1 | head -n1); compose $(docker compose version --short 2>&1)"
      echo "RAM: $(mem_mb) MB, swap $(swap_mb) MB, диск свободно $(disk_free_gb) GB"
      echo; echo "== .env (секреты скрыты)"
      sed -E -e "s/^((SOCKS_PASS|TTYD_PASSWORD|VNC_PASSWORD|[A-Z_]*TOKEN[A-Z_]*|[A-Z_]*SECRET[A-Z_]*)=).+/\1***/" \
             -e "s/^(SOCKS_USER=['\"]?)(..)[^'\"]*/\1\2***/" .env 2>/dev/null | grep -v '^#' | grep -v '^$'
      echo; echo "== docker compose ps"; docker compose ps 2>&1
      echo; echo "== gateway (последние 60 строк)"; docker compose logs --tail 60 gateway 2>&1
      echo; echo "== agent (последние 40 строк)"; docker compose logs --tail 40 agent 2>&1
      if [ "$(env_get HOST_DOCKER)" = ro ]; then echo; echo "== docker-ro (последние 20 строк)"; docker compose logs --tail 20 docker-ro 2>&1; fi
      echo; echo "== leak-test"; docker exec "$(ag)" leak-test 2>&1
      echo; echo "== окно rc (Remote Control)"; docker exec -u agent "$(ag)" tmux capture-pane -p -t main:rc 2>&1 | grep -v '^[[:space:]]*$' | tail -n 8
      echo; echo "== install.log (последние 40 строк)"; tail -n 40 "$LOG" 2>/dev/null
    } 2>&1 | P1="$(env_get SOCKS_PASS)" P2="$(env_get TTYD_PASSWORD)" P3="$(env_get VNC_PASSWORD)" awk '
      function m(s, p,   i) { if (p == "") return s; while ((i = index(s, p)) > 0) s = substr(s, 1, i - 1) "***" substr(s, i + length(p)); return s }
      { print m(m(m($0, ENVIRON["P1"]), ENVIRON["P2"]), ENVIRON["P3"]) }' >"$out"
  )
  cat "$out"
  echo
  echo "Отчёт сохранён: $out (права 600). Пришлите его целиком — пароли в нём замаскированы."
}

# ═══════════════════════════════════════════════ main
case "$ACTION" in
  report)
    report ;;
  check)
    [ -f .env ] || { echo "(нет .env — проверяю с умолчаниями профиля)"; }
    PROFILE=${PROFILE_ARG:-$(env_get PROFILE)}; [ -n "$PROFILE" ] || { [ "$OS" = Darwin ] && PROFILE=mac || PROFILE=server; }
    preflight
    echo; [ "$ERRS" -eq 0 ] && echo "${G}Система подходит${N} (замечаний: $WARNS)" || { echo "${R}Ошибок: $ERRS${N} — исправьте и повторите"; exit 1; } ;;
  install|update)
    [ "$ACTION" = update ] && pull_code
    if [ -f .env ]; then bk=".backup/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$bk" && cp .env "$bk/.env" && chmod 600 "$bk/.env"; fi
    setup_env
    preflight
    if [ "$ERRS" -gt 0 ]; then echo; die "проверка системы: ошибок $ERRS — установка остановлена, ничего не изменено (кроме .env)"; fi
    check_proxy
    build_and_start
    host_access
    [ "$(env_get PROFILE)" = server ] && host_firewall
    leak_test
    summary ;;
esac
