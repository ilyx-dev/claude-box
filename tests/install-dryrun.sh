#!/bin/bash
# Сухой прогон install.sh (профиль server) с заглушками docker/curl/getent/ss/ip и TUN (CB_TEST_TUN_DEV): проверяет логику установщика
# без Docker. Запуск: bash tests/install-dryrun.sh [флаги install.sh]   (KEEP=1 — повторный запуск на той же копии)
# Переменные-сценарии: FOREIGN=1 (чужой claude-agent), EXTRA_SUBNET=172.29.0.0/16 (конфликт подсети), DVER=19.03.1
# KEEP=1 — не пересоздавать копию проекта (проверка повторного запуска).
R=$(cd "$(dirname "$0")/.." && pwd)
T=$R/tests/.tmp/inst
mkdir -p "$T"
if [ -z "$KEEP" ]; then
  rm -rf "${T:?}/proj"
  mkdir -p "$T/proj"
  (cd "$R" && tar --exclude=./.git --exclude=./tests/.tmp --exclude=./.env -cf - .) | (cd "$T/proj" && tar xf -)
  printf "SOCKS_HOST='1.2.3.4'\nSOCKS_PORT='1080'\nSOCKS_USER='user1'\nSOCKS_PASS='s3cr3t\$pw'\n" > $T/proj/.env
fi
rm -rf "${T:?}/bin" "${T:?}/home" "${T:?}/state"
mkdir -p $T/bin $T/home $T/state
cat > $T/bin/docker <<'D'
#!/bin/bash
S=__T__/state
echo "docker $*" >> $S/calls
case "$*" in
  "info --format {{.ServerVersion}}") echo ${DVER:-27.3.1} ;;
  "info --format {{.DockerRootDir}}") echo /var/lib/docker ;;
  "info --format {{.MemTotal}}") echo 8589934592 ;;
  "info --format {{.ServerVersion}} / {{.OperatingSystem}}") echo "27.3.1 / Ubuntu" ;;
  "compose version --short") echo 2.29.1 ;;
  "network ls -q") echo n1 ;;
  "network ls --format {{.Name}}") echo bridge ;;
  "network inspect -f {{.Name}} n1") echo bridge ;;
  "network inspect -f {{range .IPAM.Config}}{{.Subnet}} {{end}} n1") echo "172.17.0.0/16 ${EXTRA_SUBNET:-}" ;;
  "inspect -f {{.State.Health.Status}} claude-gateway") echo healthy ;;
  "inspect -f {{.Id}} claude-gateway") [ -f $S/up ] && echo id-new || exit 1 ;;
  "inspect claude-gateway") [ -f $S/up ] || exit 1 ;;
  "inspect claude-agent") [ -n "$FOREIGN" ] || exit 1 ;;
  "inspect -f {{index .Config.Labels \"com.docker.compose.project\"}} claude-agent") echo other-claude ;;
  inspect\ *) exit 1 ;;
  "compose up -d gateway") touch $S/up; echo " Container claude-gateway Started" ;;
  "compose logs gateway") echo "gateway | geo: ip=1.2.3.4 cc=NL tz=Europe/Amsterdam" ;;
  "compose ps --format {{.Name}}={{.State}}") printf 'claude-gateway=running\nclaude-agent=running\nclaude-docker-ro=running\n' ;;
  "exec claude-agent cat /home/agent/.ssh/id_ed25519.pub") echo "ssh-ed25519 AAAAC3NzaTESTKEY claude-agent@claude-box" ;;
  exec\ -u\ agent\ claude-agent\ ssh*) echo "root@vds-test" ;;
  "exec claude-agent leak-test") echo "  ✔ ... Утечек не найдено. s3cr3t\$pw" ;;
  *) : ;;
esac
exit 0
D
cat > $T/bin/curl <<'C'
#!/bin/bash
echo "curl $*" >> __T__/state/calls
printf '{\n  "ip": "1.2.3.4",\n  "city": "Amsterdam",\n  "country": "NL",\n  "timezone": "Europe/Amsterdam"\n}\n'
C
cat > $T/bin/getent <<G
#!/bin/bash
echo "\$2:x:0:0:root:$T/home:/bin/bash"
G
printf '#!/bin/bash\nexit 0\n' > $T/bin/sleep
# ss/ip и TUN — тоже заглушки: иначе тест читает реальную машину (в контейнере агента порты 7681/6080
# и подсеть claude-box уже заняты, TUN нет) и падает независимо от логики установщика.
cat > $T/bin/ss <<'SS'
#!/bin/bash
# слушает только sshd на 22
case "$*" in *"sport = :22") echo "LISTEN 0 128 0.0.0.0:22 0.0.0.0:*" ;; esac
exit 0
SS
cat > $T/bin/ip <<'IP'
#!/bin/bash
case "$*" in "-4 route show") printf 'default via 10.0.0.1 dev eth0\n10.0.0.0/24 dev eth0 proto kernel scope link src 10.0.0.5\n' ;; esac
exit 0
IP
sed -i.bak "s#__T__#$T#g" "$T/bin/docker" "$T/bin/curl" && rm -f "$T"/bin/*.bak
chmod +x "$T"/bin/*
cd $T/proj && PATH=$T/bin:/usr/bin:/bin HOME=$T/home CB_NOCOLOR=1 CB_TEST_TUN_DEV=/dev/null bash ./install.sh --yes "$@"
echo "=== exit=$?"
