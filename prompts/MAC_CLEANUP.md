# Сценарий: очистка Mac от кэшей и мусора

> Запуск в сессии агента: «Прочитай /opt/claude-box/prompts/MAC_CLEANUP.md и выполни».

## Цель
Освободить место на моём Mac, убрав то, что безопасно удалить: кэши, логи, временные файлы,
артефакты разработки и корзину. Ничего ценного не потерять и всё согласовать со мной.

## Правила
- **Никогда не обходи** `~/OrbStack` (файлы контейнеров через NFS — рекурсия, может повесить Docker),
  `~/Library/CloudStorage` и `~/Library/Mobile Documents` (облачные файлы начнут скачиваться).
  В `/mac/home` они уже пустые, а в командах через `ssh mac` исключай их явно
  (`du -x`, `find … -path "$HOME/OrbStack" -prune …`).
- Домашняя папка Mac смонтирована только для чтения в `/mac/home`. **Анализ** делай там: `du`, `find`, `ls`.
  Это быстро и без запросов.
- **Изменения** делай только через `ssh mac '<команда>'`. Каждая такая команда требует моего подтверждения,
  поэтому группируй действия: одна команда на одну категорию.
- Пользовательские файлы (Documents, Desktop, Downloads, Movies, Music, Pictures, iCloud Drive) не удаляй.
  Их только предлагай, и только переносом в корзину: `mv … ~/.Trash/`.
- Не трогай связки ключей, `.ssh`, Фото, Почту, Сообщения, настройки приложений (`~/Library/Preferences`),
  `~/Library/Application Support` (кроме явных кэшей внутри), Time Machine и всё системное.
- Команды, которым нужен `sudo`, не запускай: подготовь их списком, я выполню сам.
- Docker: **не трогай** тома и образы claude-box. Никаких `docker system prune --volumes` и `docker volume prune`.
  Удалять можно только то, что я подтвержу по списку.
- Перед удалением кэшей приложения убедись, что оно закрыто, или предупреди, что кэш пересоздастся.

## Шаг 1. Инвентаризация (только чтение)
1. Сколько места свободно и кто занимает больше всего:
   - `ssh mac 'df -h /'` (это первый запрос подтверждения — объясни, зачем он нужен);
   - `du -sh /mac/home/* /mac/home/.[!.]* 2>/dev/null | sort -h | tail -25`.
2. Пройдись по кандидатам и посчитай размеры (`du -sh`, пропуская отсутствующие):
   - `~/Library/Caches/*` — топ-20 по размеру, с именами приложений;
   - `~/Library/Logs`, `~/Library/Application Support/CrashReporter`, `~/Library/Containers/*/Data/Library/Caches`;
   - корзина `~/.Trash`;
   - разработка:
     - Xcode: `~/Library/Developer/Xcode/DerivedData`, `iOS DeviceSupport`, `Archives`; `~/Library/Developer/CoreSimulator`;
     - `~/.npm/_cacache`, `~/.pnpm-store`, `~/Library/Caches/Yarn`, `~/.cache/*`;
     - `~/Library/Caches/pip`, `~/.cargo/registry`, `~/.gradle/caches`, `~/.m2/repository`, `~/go/pkg/mod`;
     - `~/Library/Caches/Homebrew`, `~/Library/Caches/CocoaPods`;
   - старые бэкапы iPhone: `~/Library/Application Support/MobileSync/Backup` — только показать;
   - большие файлы: `find /mac/home -xdev -type f -size +1G` без Library — только показать;
   - через ssh: `brew cleanup -n` (что удалит brew), `docker system df` (если Docker установлен на Mac),
     `xcrun simctl list devices unavailable` (если есть Xcode), `tmutil listlocalsnapshots /`.
3. Отчёт таблицей: категория | путь | размер | риск (безопасно / по выбору / только показать) | как чистить.
   Внизу — итого, сколько можно освободить безопасно.

## Шаг 2. Согласование
Спроси, какие категории чистить: можно номерами. Безопасные отметь как рекомендуемые.

## Шаг 3. Очистка (только выбранное)
Для каждой выбранной категории — одна команда `ssh mac '…'`. Предпочтительные способы:
- кэши, логи, DerivedData: `rm -rf "<путь>"/*` (саму папку оставляй);
- корзина: `rm -rf ~/.Trash/*` — только после отдельного «да»;
- Homebrew: `brew cleanup --prune=all`; npm: `npm cache clean --force`; pnpm: `pnpm store prune`;
  pip: `pip cache purge`; симуляторы: `xcrun simctl delete unavailable`;
- Docker на Mac: только конкретные объекты, которые я подтвердил по списку.

После каждой категории сверь размер по `/mac/home` и отметь в отчёте.

## Шаг 4. Итог
- Сколько освобождено: `df -h /` до и после.
- Что я должен сделать сам: команды с `sudo` (например, `sudo periodic daily weekly monthly`,
  удаление локальных снимков Time Machine) и большие пользовательские файлы на решение.
- Сохрани отчёт в `/workspace/reports/mac-cleanup-<дата>.md`.
