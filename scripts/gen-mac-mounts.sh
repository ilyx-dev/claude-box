#!/bin/bash
# Генерирует docker-compose.override.yml: домашняя папка Mac -> /mac/home в контейнере agent,
# ТОЛЬКО ДЛЯ ЧТЕНИЯ, а секреты (ключи, токены, связки ключей, cookies, профили браузеров, история shell)
# закрыты пустыми tmpfs/файлами. Изменения на Mac агент делает только через `ssh mac` с вашего подтверждения.
# Совместим с bash 3.2 (системный bash macOS). Перезапускайте после установки новых программ с секретами.
set -eu
cd "$(dirname "$0")/.."
PROJECT=$(pwd -P)
H="${MAC_HOME:-$HOME}"
OUT=docker-compose.override.yml

yq() { # YAML-строка в двойных кавычках
  printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
}

mkdir -p masks
: > masks/empty

# Каталоги, которые закрываются пустыми tmpfs (только если существуют):
#  - ~/OrbStack: файлы самих контейнеров/томов OrbStack (NFS из VM). Обход этой папки из контейнера
#    уходит в рекурсию (контейнер видит сам себя) и может повесить OrbStack.
#  - облачные папки (iCloud Drive, Dropbox, Google Drive…): чтение «облачных» файлов запускает их скачивание.
#  - секреты; ~/.orbstack/ssh — закрытый ключ OrbStack (root в его Linux-машинах);
#    ~/.Trash — удалённые файлы, среди них бывают и старые .env (логи ~/.orbstack/log остаются видны).
DIRS="OrbStack
Library/CloudStorage
Library/Mobile Documents
.Trash
.ssh
.orbstack/ssh
.gnupg
.aws
.azure
.kube
.docker
.config/gh
.config/gcloud
.config/op
.password-store
.vault-token
Library/Keychains
Library/Cookies
Library/Mail
Library/Messages
Library/Safari
Library/Accounts
Library/Application Support/Google/Chrome
Library/Application Support/Chromium
Library/Application Support/Firefox
Library/Application Support/BraveSoftware
Library/Application Support/Microsoft Edge
Library/Application Support/Arc
Library/Application Support/1Password
Library/Application Support/Bitwarden
Library/Application Support/Telegram Desktop
Library/Group Containers/2BUA8C4S2C.com.1password
Library/Containers/com.apple.mail"

# Отдельные файлы с секретами/историей (закрываются пустым файлом)
FILES=".netrc
.npmrc
.pypirc
.git-credentials
.zsh_history
.bash_history
.python_history
.psql_history
.mysql_history
.node_repl_history
.vault-token"

{
  echo "# Сгенерировано scripts/gen-mac-mounts.sh $(date '+%Y-%m-%d %H:%M'). Не редактируйте — перезапустите скрипт."
  echo "services:"
  echo "  agent:"
  echo "    volumes:"
  echo "      - type: bind"
  echo "        source: $(yq "$H")"
  echo "        target: /mac/home"
  echo "        read_only: true"

  echo "$DIRS" | while IFS= read -r d; do
    [ -n "$d" ] || continue
    if [ -d "$H/$d" ] && [ ! -L "$H/$d" ]; then
      echo "      - type: tmpfs"
      echo "        target: $(yq "/mac/home/$d")"
      echo "        tmpfs:"
      echo "          size: 1m"
    fi
  done

  echo "$FILES" | while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -f "$H/$f" ] && [ ! -L "$H/$f" ]; then
      echo "      - type: bind"
      echo "        source: $(yq "$PROJECT/masks/empty")"
      echo "        target: $(yq "/mac/home/$f")"
      echo "        read_only: true"
    fi
  done

  # .env этого проекта (пароли прокси и веб-интерфейсов) и его копии, которые install.sh кладёт при каждом
  # запуске в .backup/<время>/.env, — если проект лежит внутри домашней папки
  case "$PROJECT/" in
    "$H"/*)
      rel=${PROJECT#"$H"/}
      if [ -f "$PROJECT/.env" ]; then
        echo "      - type: bind"
        echo "        source: $(yq "$PROJECT/masks/empty")"
        echo "        target: $(yq "/mac/home/$rel/.env")"
        echo "        read_only: true"
      fi
      # каталог нужен заранее: точку монтирования внутри /mac/home (только чтение) Docker создать не сможет
      mkdir -p "$PROJECT/.backup"
      echo "      - type: tmpfs"
      echo "        target: $(yq "/mac/home/$rel/.backup")"
      echo "        tmpfs:"
      echo "          size: 1m"
      ;;
  esac
} > "$OUT"

n_masks=$(grep -c 'target: "/mac/home/' "$OUT" || true)
echo "OK: $OUT — /mac/home (только чтение), скрыто путей с секретами: $n_masks"
