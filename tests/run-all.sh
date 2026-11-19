#!/bin/bash
# Все проверки, которые не требуют Docker: синтаксис скриптов, JSON, хук, docker-ro, сухой прогон установщика.
# Запуск из корня репозитория: bash tests/run-all.sh
set -u
R=$(cd "$(dirname "$0")/.." && pwd); cd "$R" || exit 1
fail=0
step() { printf '\n== %s\n' "$1"; shift; if "$@"; then echo "   OK"; else echo "   FAIL"; fail=1; fi; }
syntax() {
  local f rc=0
  for f in install.sh scripts/*.sh gateway/*.sh agent/entrypoint.sh agent/claude/host-guard.sh agent/bin/* browser/entrypoint.sh browser/start-chrome tests/*.sh; do
    [ -f "$f" ] || continue
    head -n1 "$f" | grep -q 'bash' || continue
    bash -n "$f" || { echo "   синтаксис: $f"; rc=1; }
  done
  python3 -m py_compile docker-ro/docker-ro.py || rc=1
  return $rc
}
json() { jq -e . agent/claude/managed-settings.json >/dev/null; }
yaml() { python3 -c 'import sys, yaml; yaml.safe_load(open("docker-compose.yml"))' 2>/dev/null || { echo "   (PyYAML нет — пропуск)"; return 0; }; }
step "синтаксис bash и python" syntax
step "managed-settings.json" json
step "docker-compose.yml (YAML)" yaml
step "host-guard" bash tests/host-guard.sh
step "docker-ro" bash tests/docker-ro.sh
step "установщик: обычная установка (сухой прогон)" bash -c 'bash tests/install-dryrun.sh 2>&1 | tail -n1 | grep -q "exit=0"'
step "установщик: предупреждает о CB_TEST_TUN_DEV" bash -c 'bash tests/install-dryrun.sh 2>&1 | grep -q "задана CB_TEST_TUN_DEV=/dev/null"'
step "установщик: конфликт имён/подсети останавливает установку" bash -c 'FOREIGN=1 EXTRA_SUBNET=172.29.0.0/16 bash tests/install-dryrun.sh 2>&1 | tail -n1 | grep -q "exit=1"'
echo
[ "$fail" = 0 ] && echo "Все проверки пройдены" || { echo "Есть ошибки"; exit 1; }
