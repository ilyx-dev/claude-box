# claude-box

Claude Code в Docker-контейнере, весь трафик которого (агента и его браузера) идёт **только** через ваш
SOCKS5-прокси: kill-switch, без утечек DNS, IPv6, UDP и WebRTC. Часовой пояс, локаль и языки браузера —
по стране прокси. Управлять агентом можно из браузера, приложения Claude и с телефона (Remote Control).

Один код для Mac и Linux-сервера. Возможности включаются флагами:

| | `mac` (по умолчанию на macOS) | `server` (по умолчанию на Linux) |
|---|---|---|
| Браузер агента (Chrome + noVNC + DevTools MCP) | вкл | выкл, `--browser` |
| Команды на хосте `ssh <хост> '…'` (каждая — с вашего подтверждения) | `ssh mac` | `ssh host` |
| Docker хоста только для чтения (ps, logs, inspect, stats) | выкл | вкл |
| Диск хоста для агента | `~` Mac только для чтения, секреты скрыты | — |

```
 Mac / сервер ──────────────────────────────────────────────────────────────────┐
 │  gateway: sing-box TUN → SOCKS5, nftables kill-switch, DoH через прокси       │
 │    ├── agent: Claude Code + tmux + ttyd, Remote Control, правила и хук         │
 │    ├── browser (опц.): Chrome, noVNC, CDP 127.0.0.1:9222                       │
 │    └── docker-ro (опц.): Docker API хоста только для чтения                    │
 │  ssh <хост> '…' — всё, что меняет хост; каждая команда с вашего подтверждения  │
 └───────────────────────────────────────────────────────────────────────────────┘
```

## Установка
Нужны Docker (на Mac — OrbStack или Docker Desktop; на Linux — Docker Engine + compose v2) и SOCKS5-прокси.
Папка claude-box не должна лежать внутри рабочей папки агента (`~/claude-workspace`).
```bash
git clone https://github.com/ilyx-dev/claude-box.git ~/claude-box && cd ~/claude-box
./install.sh --check      # проверка системы: ничего не меняет
./install.sh              # установка (спросит данные прокси)
```
Требования: без браузера — от 1 ГБ RAM (рекомендуется 2) и 5 ГБ диска; с браузером — от 3 ГБ (рекомендуется 4)
и 10 ГБ. На сервере нужен `/dev/net/tun` (на OpenVZ/LXC его часто нет).

Флаги: `--profile mac|server`, `--browser` / `--no-browser`, `--docker ro|0`, `--host-access 1|0`,
`--yes` (без вопросов, для запуска по SSH), `--force` (игнорировать нехватку ресурсов).

## После установки
- **Вход**: откройте терминал агента и в окне `claude` выполните `/login`; в окне `rc` (сервер Remote Control)
  один раз ответьте `y`. Дальше агент доступен в приложении Claude и на claude.ai/code.
  - Mac: http://localhost:7681 (пароль `TTYD_PASSWORD` в `.env`), браузер агента — http://localhost:6080.
  - Сервер: `ssh -N -L 17681:127.0.0.1:7681 <сервер>` → http://localhost:17681.
  - Без браузера: `docker exec -it -u agent claude-agent tmux attach -t main`.
- **Проекты**: папки `/workspace/<имя>`; новый — `new-project <имя> "описание"`. В новом чате называйте
  проект словами: «проект site: …».
- **Агент знает окружение**: в начале каждой сессии получает сводку (команда `box-info`) и правила
  `/etc/claude-code/CLAUDE.md` под ваш профиль.

## Обслуживание
```bash
./install.sh --update        # git pull, новые ключи .env, пересборка, проверка утечек
./install.sh --report        # диагностика одним блоком (пароли замаскированы) — для чата с Claude
docker exec claude-agent leak-test
```
Смена прокси: поправьте `SOCKS_*` в `.env` и выполните `./install.sh --update --no-pull`.

## Безопасность (кратко)
- Наружу из контейнеров — только прокси. Упал туннель — нет сети, а не прямой выход.
- Всё за пределами контейнера (SSH на хост и другие серверы, прямые адреса из `DIRECT_CIDRS`) — только
  с вашим подтверждением; это задаёт managed-политика Claude Code и хук `host-guard`, агент их не изменит.
- Локальная сеть из контейнера закрыта; к роутеру и другим устройствам агент ходит через хост (`ssh mac '…'`).
- Docker хоста агенту доступен только на чтение (`docker-ro`); изменения — `ssh host 'docker …'` с подтверждением.
- На Linux-хосте дополнительно: правило DOCKER-USER (юнит `claude-box-firewall`) — из сети claude-box наружу
  только на прокси.

## Если что-то не так
| Симптом | Что делать |
|---|---|
| шлюз не `healthy` | `docker compose logs gateway`; чаще всего неверные `SOCKS_*` |
| в приложении «offline» | обрыв прокси — сервер вернётся сам за 1–2 мин; дольше — `./install.sh --report` |
| `ssh mac` не работает | включите «Удалённый вход» на Mac и запустите `./install.sh` ещё раз |
| веб-терминал «Reconnecting» в Chrome | расширения Chrome; используйте Safari или `tmux attach` |
| порт или имя контейнера заняты | `./install.sh --check` подскажет: `TTYD_PORT`, `BOX_PREFIX`, `DOCKER_SUBNET` в `.env` |

Изменения: `CHANGELOG.md`. Проверки без Docker: `bash tests/run-all.sh`.
