#!/bin/bash
# scripts/gen-mac-mounts.sh на поддельной домашней папке: какие пути закрываются масками.
# Запуск из корня репозитория: bash tests/gen-mac-mounts.sh
set -u
R=$(cd "$(dirname "$0")/.." && pwd)
T="$R/tests/.tmp/macmounts"; rm -rf "$T"
mkdir -p "$T/home"; H=$(cd "$T/home" && pwd -P); P="$H/claude-box"
mkdir -p "$P/scripts" "$H/.ssh" "$H/.orbstack/ssh" "$H/.orbstack/log" "$H/.Trash" "$H/Library/Keychains" "$H/Documents"
cp "$R/scripts/gen-mac-mounts.sh" "$P/scripts/"
: > "$P/.env"; : > "$H/.zsh_history"

MAC_HOME="$H" bash "$P/scripts/gen-mac-mounts.sh" >/dev/null || { echo "   gen-mac-mounts.sh завершился с ошибкой"; exit 1; }
out="$P/docker-compose.override.yml"; fail=0
has()  { grep -qxF "        target: \"/mac/home/$1\"" "$out"; }
want() { has "$1" || { echo "   нет маски: ~/$1"; fail=1; }; }
dont() { ! has "$1" || { echo "   лишняя маска: ~/$1"; fail=1; }; }

want .ssh; want .orbstack/ssh; want .Trash; want Library/Keychains; want .zsh_history
want claude-box/.env; want claude-box/.backup
dont .orbstack/log; dont Documents
[ -d "$P/.backup" ] || { echo "   .backup не создан заранее (Docker не создаст точку монтирования в /mac/home)"; fail=1; }
grep -q 'read_only: true' "$out" || { echo "   /mac/home не только для чтения"; fail=1; }
exit $fail
