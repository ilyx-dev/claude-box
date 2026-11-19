#!/usr/bin/env bash
# claude-box: PreToolUse-хук (из managed settings — агент не может его отключить).
# Любая Bash-команда, которая выходит за пределы контейнера, требует вашего явного подтверждения:
#   • любые SSH-команды (ssh, scp, rsync host:, sftp …) — к хосту (алиас HOST_ALIAS) и к другим серверам;
#   • прямые обращения к хосту (host.docker.internal / IP хоста), перенастройка SSH, SSH-ключи;
#   • запуск скрипта (bash x.sh, ./x.sh, python x.py …), внутри которого есть SSH или обращение к хосту;
#   • ввод в окно tmux (send-keys / paste-buffer), где открыто SSH-подключение;
#   • адреса из DIRECT_CIDRS (подсети, которые вы сами открыли мимо прокси).
# Сразу блокируются (с подсказкой правильного пути), потому что из контейнера всё равно не работают:
#   • обращения к локальной сети (192.168.*, 10.* …) — «открытые» порты здесь эффект TUN;
#   • изменения Docker через docker CLI контейнера (он только для чтения) — нужно `ssh <хост> 'docker …'`.
#  - режимы default / acceptEdits / plan  -> "ask" (появится запрос подтверждения)
#  - режимы auto / dontAsk               -> канонические `ssh <алиас> …` / `scp|rsync … <алиас>:` пропускаем
#    к managed-правилам ask (они спрашивают во всех режимах), всё остальное — "deny" с подсказкой.
set -u

emit() { # $1 = ask|deny, $2 = reason
  local reason
  reason=$(printf '%s' "$2" | jq -Rs . 2>/dev/null) || reason='"claude-box host guard"'
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":%s}}\n' "$1" "$reason"
  exit 0
}

input=$(cat 2>/dev/null) || input=""
command -v jq >/dev/null 2>&1 || emit ask "claude-box: проверка недоступна (нет jq) — подтвердите команду вручную"

tool=$(jq -r '.tool_name // empty' <<<"$input" 2>/dev/null) || emit ask "claude-box: не удалось разобрать вызов — подтвердите вручную"
[[ $tool == Bash ]] || exit 0
cmd=$(jq -r '.tool_input.command // empty' <<<"$input" 2>/dev/null) || emit ask "claude-box: не удалось разобрать команду — подтвердите вручную"
mode=$(jq -r '.permission_mode // "default"' <<<"$input" 2>/dev/null) || mode=default
cwd=$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null) || cwd=""
[[ -n $cwd ]] || cwd=$PWD
[[ -n $cmd ]] || exit 0

H=${HOST_ALIAS:-host}
host_ip=$(awk '$1 ~ /^[0-9.]+$/ { for (i = 2; i <= NF; i++) if ($i == "host.docker.internal") { print $1; exit } }' /etc/hosts 2>/dev/null)

ssh_tools='(^|[^[:alnum:]_./-])(ssh|scp|sftp|sshfs|autossh|mosh|sshpass)([^[:alnum:]_-]|$)|(^|[^[:alnum:]_./-])rsync([^[:alnum:]_-].*[[:alnum:]_.@-]:|[[:space:]]+-e)'
host_ref='host\.docker\.internal'
[[ -n $host_ip ]] && host_ref+="|(^|[^0-9.])${host_ip//./\\.}([^0-9]|$)"
ssh_reconf='(ssh_config|[[:space:]]-F[[:space:]]|[[:space:]]-o[[:space:]]*(HostName|ProxyCommand|ProxyJump|Hostname|LocalCommand|PermitLocalCommand)|[[:space:]]-J[[:space:]]|[[:space:]]-[LRDW][[:space:]]*[0-9])'
ssh_keys='(\.ssh/|/etc/ssh/)'
net_tools='(^|[^[:alnum:]_./-])(ssh|scp|sftp|rsync|sshfs|sshpass|autossh|mosh|nc|ncat|netcat|telnet|curl|wget|aria2c|nmap|ping|arping|traceroute|mtr|socat|websocat|ftp|lftp|tftp|smbclient|snmpwalk|snmpget|mysql|psql|redis-cli|mongosh|http|https|xh|socket|requests|urllib|httpx|aiohttp|fetch)([^[:alnum:]_-]|$)|/dev/(tcp|udp)/'
priv_ip='(^|[^0-9.])(10(\.[0-9]{1,3}){3}|192\.168(\.[0-9]{1,3}){2}|172\.(1[6-9]|2[0-9]|3[01])(\.[0-9]{1,3}){2}|169\.254(\.[0-9]{1,3}){2}|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])(\.[0-9]{1,3}){2})([^0-9.]|$)'
remote_procs='^(ssh|scp|sftp|mosh|mosh-client|autossh|sshpass|telnet|nc|ncat|netcat|socat|expect)$'
cmd_pos='(^|[;&|(]|\$\(|`)[[:space:]]*((sudo|env|time|nohup|command|exec)[[:space:]]+)*'
docker_write='docker[[:space:]]+(compose[[:space:]]+(up|down|build|restart|stop|start|rm|pull|push|run|exec|create|kill|pause|unpause|cp|watch)|(container|image|network|volume|system|builder|buildx|plugin|context)[[:space:]]+(rm|prune|create|run|start|stop|restart|kill|update|rename|pause|unpause|exec|cp|commit|connect|disconnect|load|import|push|pull|tag|build|use)|run|create|start|stop|restart|kill|rm|rmi|exec|build|buildx|pull|push|cp|commit|tag|load|import|update|rename|pause|unpause|attach|login|logout|swarm|service|stack|secret|config|trust)([[:space:]]|$)'

ip2int() { local IFS=.; set -- $1; echo $(( ($1 << 24) + ($2 << 16) + ($3 << 8) + $4 )); }
in_cidrs() { # $1 = ip, $2 = список CIDR через пробел/запятую
  local ip=$1 c net bits n m
  n=$(ip2int "$ip" 2>/dev/null) || return 1
  for c in ${2//,/ }; do
    [[ $c == */* ]] || c="$c/32"
    net=${c%/*} bits=${c#*/}
    [[ $net =~ ^[0-9]+(\.[0-9]+){3}$ && $bits =~ ^[0-9]+$ ]] && ((bits <= 32)) || continue
    ((bits == 0)) && return 0
    m=$(( (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
    (( (n & m) == ($(ip2int "$net") & m) )) && return 0
  done
  return 1
}
unq() { local s=$1; s=${s#[\"\']}; s=${s%[\"\']}; printf '%s' "$s"; }

# ---------------------------------------------------------------- 1. SSH и хост напрямую
ssh_reason="" ssh_canonical=0
if grep -Eq "$ssh_tools" <<<"$cmd"; then
  if grep -Eq "$ssh_reconf" <<<"$cmd"; then
    ssh_reason="SSH-команда с нестандартными параметрами (-o/-F/-J/проброс портов)"
  else
    ssh_reason="команда выполняется на другой машине по SSH"
    grep -Eq "(^|[[:space:]@=;&|('\"])$H([[:space:]:;&|)'\"]|$)" <<<"$cmd" && ssh_reason="команда выполняется на хосте ($H) по SSH"
    # каноническая форма: одна команда ssh/scp/rsync/sftp в начале строки — её поймают managed-правила ask
    grep -Eq '^[[:space:]]*(ssh[[:space:]]|scp[[:space:]]|sftp[[:space:]]|rsync[[:space:]].*[[:alnum:]_.@-]:)' <<<"$cmd" && ssh_canonical=1
  fi
fi
host_reason=""
if grep -Eq "$host_ref" <<<"$cmd"; then
  host_reason="команда обращается к хосту напрямую (host.docker.internal / IP хоста)"
elif grep -Eq "$ssh_keys" <<<"$cmd"; then
  host_reason="команда трогает SSH-ключи или конфигурацию SSH"
fi

# ---------------------------------------------------------------- 2. скрипты с SSH внутри
wrap_reason=""
while IFS= read -r seg; do
  read -r -a w <<<"$seg" || true
  i=0
  while ((i < ${#w[@]})); do
    case ${w[i]} in
      sudo|env|exec|nohup|time|nice|command|builtin|stdbuf|setsid|xargs) ((i++)); continue ;;
      timeout) ((i += 2)); continue ;;
    esac
    [[ ${w[i]} =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && { ((i++)); continue; }
    break
  done
  ((i < ${#w[@]})) || continue
  w0=$(unq "${w[i]}") target=""
  case ${w0##*/} in
    bash|sh|zsh|dash|ksh|source|.|python|python3|node|perl|ruby|php|deno|bun|tsx|ts-node)
      for ((j = i + 1; j < ${#w[@]}; j++)); do
        a=$(unq "${w[j]}")
        [[ $a == -c || $a == -e || $a == --eval ]] && break   # код прямо в команде — уже проверен выше
        [[ $a == -* ]] && continue
        target=$a; break
      done ;;
    *) [[ $w0 == */* ]] && target=$w0 ;;
  esac
  [[ -n $target ]] || continue
  [[ $target == /* ]] || target="$cwd/$target"
  # файлы образа (их агент менять не может) не проверяем — только то, что агент мог написать сам
  [[ -f $target && -r $target && -w $target ]] || continue
  (( $(stat -c %s "$target" 2>/dev/null || echo 0) < 1048576 )) || continue
  grep -Iq . "$target" 2>/dev/null || continue   # бинарники пропускаем
  if grep -Eq "$ssh_tools" "$target" 2>/dev/null || grep -Eq "$host_ref" "$target" 2>/dev/null; then
    wrap_reason="скрипт ${target#"$cwd"/} выходит за пределы контейнера (внутри есть ssh/scp/rsync или обращение к хосту)"
    break
  fi
done < <(sed -E 's/(\|\||&&|[;&|()]|\$\()/\n/g' <<<"$cmd")

# ---------------------------------------------------------------- 3. ввод в tmux-окно с SSH
if [[ -z $wrap_reason ]] && grep -Eq '(^|[^[:alnum:]_-])tmux[[:space:]]' <<<"$cmd" &&
  grep -Eq '(^|[[:space:];&|])(send-keys|send|paste-buffer|pasteb)([[:space:]]|$)' <<<"$cmd"; then
  t=$(grep -Eo -- '(^|[[:space:]])-t[[:space:]]*[^[:space:];&|]+' <<<"$cmd" | head -n1 | sed -E 's/^[[:space:]]*-t[[:space:]]*//')
  t=$(unq "$t")
  targs=(display-message -p); [[ -n $t ]] && targs+=(-t "$t")
  if pinfo=$(tmux "${targs[@]}" '#{pane_pid} #{pane_current_command}' 2>/dev/null); then
    ppid0=${pinfo%% *} pcmd=${pinfo#* }
    hit=""
    if [[ $pcmd =~ $remote_procs ]]; then
      hit=$pcmd
    elif [[ $ppid0 =~ ^[0-9]+$ ]]; then
      # потомки процесса окна (ssh, запущенный из shell или скрипта)
      hit=$(ps -eo pid=,ppid=,comm= 2>/dev/null | awk -v root="$ppid0" -v re="$remote_procs" '
        { p[$1] = $2; c[$1] = $3 }
        END { for (x in p) { y = x; while (y in p && y != root && y > 1) y = p[y]
                             if (y == root && c[x] ~ re) { print c[x]; exit } } }')
    fi
    [[ -n $hit ]] && wrap_reason="ввод в окно tmux ${t:-(текущее)}, где работает $hit: команда выполнится вне контейнера"
  fi
fi

# ---------------------------------------------------------------- 4. изменения Docker через CLI контейнера
if [[ -z $ssh_reason ]] && grep -Eq "$cmd_pos$docker_write" <<<"$cmd"; then
  emit deny "claude-box: docker в контейнере только для чтения (ps, logs, inspect, stats, events) — изменения через него не пройдут. Выполни это на хосте: ssh $H 'docker …' (с подтверждением пользователя). Для своих проектов: ssh $H 'cd <папка проекта на хосте> && docker compose up -d --build' — путь к /workspace на хосте покажет box-info."
fi

# ---------------------------------------------------------------- 5. локальная сеть
direct_reason=""
# у SSH-команды смотрим только адреса вне кавычек (цель подключения), а не удалённую команду в '…'
scan=$cmd
[[ -n $ssh_reason ]] && scan=$(sed -E "s/'[^']*'//g; s/\"[^\"]*\"//g" <<<"$cmd")
if [[ -z $host_reason ]] && grep -Eq "$net_tools" <<<"$scan"; then
  blocked=() allowed=()
  while IFS= read -r ip; do
    [[ -n $ip ]] || continue
    in_cidrs "$ip" "172.19.0.0/30 ${BOX_DOCKER_SUBNET:-172.29.0.0/24}" && continue   # туннель и сеть самого claude-box
    [[ $ip == "$host_ip" ]] && continue
    if in_cidrs "$ip" "${BOX_DIRECT_CIDRS:-}"; then allowed+=("$ip"); else blocked+=("$ip"); fi
  done < <(grep -Eo "$priv_ip" <<<"$scan" | grep -Eo '[0-9]+(\.[0-9]+){3}' | sort -u)
  if ((${#blocked[@]})); then
    b=${blocked[0]}
    emit deny "claude-box: из контейнера локальная сеть недоступна (${blocked[*]}). Kill-switch пропускает наружу только прокси, а «открытые» порты частных адресов здесь — эффект TUN, проверять их отсюда бессмысленно. Устройства локальной сети доступны только через хост, с подтверждением пользователя: ssh $H 'curl -s http://$b/' или ssh $H 'ssh <user>@$b \"<команда>\"'. Пароли не подбирай: если нужен доступ, спроси пользователя."
  fi
  ((${#allowed[@]})) && direct_reason="команда обращается к устройству вне контейнера (${allowed[*]}, открыто в DIRECT_CIDRS)"
fi

# ---------------------------------------------------------------- решение
auto_mode=0
case "$mode" in auto|dontAsk|bypassPermissions) auto_mode=1 ;; esac
hint="Обращения за пределы контейнера допускаются только прямой командой \`ssh <алиас> '<команда>'\` (или scp/rsync) с подтверждением пользователя — не через скрипты, tmux и нестандартные параметры SSH."

if [[ -n $wrap_reason ]]; then
  ((auto_mode)) && emit deny "claude-box: $wrap_reason. $hint"
  emit ask "claude-box: $wrap_reason — нужно ваше подтверждение"
fi
if [[ -n $host_reason ]]; then
  ((auto_mode)) && emit deny "claude-box: $host_reason. В режиме $mode это не подтверждается автоматически. $hint"
  emit ask "claude-box: $host_reason — нужно ваше подтверждение"
fi
if [[ -n $ssh_reason ]]; then
  if ((auto_mode)); then
    ((ssh_canonical)) && exit 0   # managed-правила ask спросят пользователя и в этом режиме
    emit deny "claude-box: $ssh_reason. В режиме $mode $hint"
  fi
  emit ask "claude-box: $ssh_reason — нужно ваше подтверждение"
fi
if [[ -n $direct_reason ]]; then
  ((auto_mode)) && emit deny "claude-box: $direct_reason. В режиме $mode такие обращения не подтверждаются автоматически: попроси пользователя переключить режим (Shift+Tab) или сделай это через ssh $H."
  emit ask "claude-box: $direct_reason — нужно ваше подтверждение"
fi
exit 0
