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
yaml() {
  python3 -c 'import yaml' 2>/dev/null || { echo "   (PyYAML нет — пропуск)"; return 0; }
  python3 -c 'import sys, yaml; [yaml.safe_load(open(f)) for f in sys.argv[1:]]' docker-compose.yml docker-compose.browser.yml
}
# COMPOSE_FILE, который install.sh записал в .env сухого прогона
cfile() { sed -n "s/^COMPOSE_FILE=//p" tests/.tmp/inst/proj/.env | tr -d "'"; }
force_kept() { bash tests/install-dryrun.sh --force >/dev/null 2>&1
  grep -qx "FORCE_RESOURCES='1'" tests/.tmp/inst/proj/.env || { echo "   --force не записан в .env"; return 1; }
  KEEP=1 bash tests/install-dryrun.sh 2>&1 | grep -q "FORCE_RESOURCES=1 в .env" || { echo "   повторный запуск не учёл FORCE_RESOURCES"; return 1; }; }
force_not_default() { bash tests/install-dryrun.sh >/dev/null 2>&1; ! grep -q "^FORCE_RESOURCES='1'" tests/.tmp/inst/proj/.env; }
novnc_only_browser() { ! grep -qE ':6080"' docker-compose.yml && grep -qE ':6080"' docker-compose.browser.yml; }
cf_default()  { bash tests/install-dryrun.sh >/dev/null 2>&1; [ "$(cfile)" = docker-compose.yml ] || { echo "   COMPOSE_FILE=$(cfile)"; return 1; }; }
cf_browser()  { bash tests/install-dryrun.sh --browser --force >/dev/null 2>&1; [ "$(cfile)" = docker-compose.yml:docker-compose.browser.yml ] || { echo "   COMPOSE_FILE=$(cfile)"; return 1; }; }
cf_override() { bash tests/install-dryrun.sh >/dev/null 2>&1; : > tests/.tmp/inst/proj/docker-compose.override.yml
  KEEP=1 bash tests/install-dryrun.sh >/dev/null 2>&1; [ "$(cfile)" = docker-compose.yml:docker-compose.override.yml ] || { echo "   COMPOSE_FILE=$(cfile)"; return 1; }; }
step "синтаксис bash и python" syntax
step "managed-settings.json" json
step "docker-compose*.yml (YAML)" yaml
step "compose: noVNC (6080) публикуется только в docker-compose.browser.yml" novnc_only_browser
step "host-guard" bash tests/host-guard.sh
step "docker-ro" bash tests/docker-ro.sh
step "установщик: обычная установка (сухой прогон)" bash -c 'bash tests/install-dryrun.sh 2>&1 | tail -n1 | grep -q "exit=0"'
step "установщик: предупреждает о CB_TEST_TUN_DEV" bash -c 'bash tests/install-dryrun.sh 2>&1 | grep -q "задана CB_TEST_TUN_DEV=/dev/null"'
step "установщик: без браузера COMPOSE_FILE без noVNC" cf_default
step "установщик: с браузером COMPOSE_FILE с noVNC" cf_browser
step "установщик: override (диск Mac) остаётся в COMPOSE_FILE" cf_override
step "установщик: --force запоминается в .env и учитывается при повторном запуске" force_kept
step "установщик: без --force FORCE_RESOURCES не включается" force_not_default
step "установщик: конфликт имён/подсети останавливает установку" bash -c 'FOREIGN=1 EXTRA_SUBNET=172.29.0.0/16 bash tests/install-dryrun.sh 2>&1 | tail -n1 | grep -q "exit=1"'
echo
[ "$fail" = 0 ] && echo "Все проверки пройдены" || { echo "Есть ошибки"; exit 1; }
