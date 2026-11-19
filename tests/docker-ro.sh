#!/bin/bash
# Тесты docker-ro (фильтр Docker API) против фальшивого dockerd на unix-сокете.
# Запуск: bash tests/docker-ro.sh   (нужны python3, curl; Docker не нужен)
R=$(cd "$(dirname "$0")/.." && pwd)
D=$R/tests/.tmp/dro; mkdir -p "$D"; S=$D/docker.sock; rm -f "$S"
python3 "$R/tests/fake_dockerd.py" "$S" > $D/fake.log 2>&1 & F=$!
sleep 0.5
DOCKER_SOCK=$S DOCKER_RO_PORT=23750 python3 -u "$R/docker-ro/docker-ro.py" > $D/ro.log 2>&1 & R=$!
sleep 0.7
pass=0; fail=0
t() { # expected-code method path
  code=$(curl -s -o $D/out -w '%{http_code}' -X "$2" "http://127.0.0.1:23750$3" --max-time 5)
  [[ $code == "$1" ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL want=$1 got=$code $2 $3"; }
}
t 200 GET  "/_ping"
t 200 GET  "/v1.45/containers/json?all=1&filters=%7B%7D"
t 200 GET  "/v1.45/containers/abc123/json"
t 200 GET  "/v1.45/containers/my_app-1/logs?stdout=1&follow=1"
t 200 GET  "/v1.45/images/ghcr.io/sagernet/sing-box:latest/json"
t 200 GET  "/networks"
t 200 GET  "/v1.45/info"
t 403 POST "/v1.45/containers/create"
t 403 POST "/v1.45/containers/abc/restart"
t 403 POST "/v1.45/containers/abc/exec"
t 403 DELETE "/v1.45/containers/abc"
t 403 GET  "/v1.45/containers/abc/archive?path=/etc"
t 403 GET  "/v1.45/containers/abc/export"
t 403 GET  "/v1.45/containers/abc/attach/ws"
t 403 GET  "/v1.45/containers/../containers/create"
t 403 GET  "/v1.45/containers/abc%2F..%2Fcreate/json"
t 403 GET  "/v1.45/secrets"
t 403 PUT  "/v1.45/containers/abc/archive"
# тело в GET
code=$(curl -s -o /dev/null -w '%{http_code}' -X GET -d 'x=1' http://127.0.0.1:23750/_ping); [[ $code == 403 ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL GET with body -> $code"; }
# Connection: close уходит в Docker
grep -q '"conn":"Connection: close"' <(curl -s -H 'Connection: keep-alive' http://127.0.0.1:23750/version) && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL connection close not forced"; }
# поток logs доходит целиком
n=$(curl -s http://127.0.0.1:23750/containers/x/logs?follow=1 | grep -c line); [[ $n == 3 ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL logs stream lines=$n"; }
# протаскивание второго запроса в одном соединении
python3 - <<'PY'
import socket,time
s=socket.create_connection(("127.0.0.1",23750))
s.sendall(b"GET /version HTTP/1.1\r\nHost: x\r\n\r\nPOST /containers/create HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\n{}")
time.sleep(1); print("smuggle-resp:", s.recv(4096)[:40]); s.close()
PY
sleep 1
grep -q "UPSTREAM GOT EXTRA" $D/fake.log && { fail=$((fail+1)); echo "FAIL smuggled request reached docker"; cat $D/fake.log; } || pass=$((pass+1))
echo "passed=$pass failed=$fail"; echo "--- ro.log:"; tail -5 $D/ro.log
kill $R $F 2>/dev/null
[ "$fail" = 0 ]
