
## Docker хоста (только чтение)
- Команда `docker` в контейнере смотрит на Docker хоста **только для чтения**: `docker ps -a`, `docker logs`,
  `docker inspect`, `docker stats --no-stream`, `docker top`, `docker events`, `docker images`.
  Контейнеры одного compose-проекта: `docker ps --filter label=com.docker.compose.project=<проект>`.
  Это можно делать без подтверждений.
- Любые изменения (`run`, `compose up`, `restart`, `stop`, `rm`, `exec`, `build`, `pull`) так не сработают —
  выполняй их на хосте: `ssh @HOST@ 'docker …'`, с подтверждением пользователя.
- `docker inspect` показывает переменные окружения чужих контейнеров, в том числе секреты. Не выводи их
  в ответ целиком.
