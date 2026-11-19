#!/bin/bash
# Тесты PreToolUse-хука host-guard: команда + режим -> ожидаемое решение (allow = хук молчит).
# Запуск: bash tests/host-guard.sh   (нужны bash, jq; Docker не нужен)
R=$(cd "$(dirname "$0")/.." && pwd)
H=$R/agent/claude/host-guard.sh
W=$R/tests/.tmp/hg; mkdir -p "$W"
printf '#!/bin/bash\necho hi\nssh host "docker restart x"\n' > "$W/deploy.sh"
printf '#!/bin/bash\nrsync -a ./dist/ vds:/srv/app/\n' > "$W/sync.sh"
printf '#!/bin/bash\nrsync -a ./a/ ./b/\n' > "$W/local.sh"
printf 'import os\nos.system("ls")\n' > "$W/ok.py"
export BOX_DIRECT_CIDRS="192.168.50.0/24" BOX_DOCKER_SUBNET="172.29.0.0/24" HOST_ALIAS=host
pass=0 fail=0
t() { local out dec
  out=$(jq -n --arg c "$3" --arg m "$2" --arg cwd "$W" '{tool_name:"Bash",tool_input:{command:$c},permission_mode:$m,cwd:$cwd}' | bash "$H")
  dec=$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"$out" 2>/dev/null); dec=${dec:-allow}
  if [[ $dec == "$1" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL [$2] want=$1 got=$dec :: $3"; echo "     $(jq -r '.hookSpecificOutput.permissionDecisionReason // empty' <<<"$out" | head -c 220)"; fi; }
# SSH к хосту и серверам
t ask   default "ssh host 'docker ps'"
t allow auto    "ssh host 'docker compose up -d'"
t ask   default "ssh vds 'uname -a'"
t allow auto    "ssh -t vds 'htop'"
t ask   default "scp build.tgz vds:/tmp/"
t ask   default "rsync -az ./dist/ vds:/srv/app/"
t allow default "rsync -a ./a/ ./b/"
t deny  auto    "cd /tmp && ssh vds ls"
t ask   default "ssh -o ProxyCommand='nc x 22' vds"
t deny  auto    "ssh -o ProxyCommand='nc x 22' vds"
t deny  auto    "ssh -L 8080:localhost:80 vds"
t ask   default "cat ~/.ssh/config"
t allow default "ssh-keygen -lf /tmp/k.pub"
t allow default "git push origin main"
# хост напрямую
t ask   default "curl -s http://host.docker.internal:8080/"
t deny  auto    "curl -s http://host.docker.internal:8080/"
# скрипты
t ask   default "bash deploy.sh"
t ask   default "./sync.sh"
t allow default "bash local.sh"
t deny  auto    "bash $W/deploy.sh"
t allow default "python3 ok.py"
# docker
t allow default "docker ps -a"
t allow default "docker logs --tail 50 vpn"
t allow default "docker inspect vpn | jq '.[0].State'"
t deny  default "docker restart vpn"
t deny  default "docker compose up -d --build"
t deny  default "cd app && docker build -t x ."
t deny  default "sudo docker rm -f x"
t deny  default "docker container stop x"
t allow default "grep 'docker run' README.md"
t allow default "docker images"
t ask   default "ssh host 'docker restart vpn'"
# локальная сеть
t deny  default "ssh -p 222 root@192.168.1.1"
t deny  default "nc -zv 192.168.1.1 54321"
t ask   default "ssh host 'ssh -p 222 root@192.168.1.1 opkg list-installed'"
t ask   default "curl -s http://192.168.50.10/"
t allow default "curl -s http://172.29.0.3:2375/version"
t allow default "grep 10.0.0.5 notes.txt"
# прочее
t allow default "ls -la /workspace && npm test"
t deny  default "ssh root@10.0.0.7 'uptime'"
t ask   default "ssh host \"ping -c1 192.168.1.1\""
t deny  default "curl \"http://192.168.1.1/api\""
t deny  default "scp file root@192.168.1.1:/tmp/"
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
