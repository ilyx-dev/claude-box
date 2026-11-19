#!/usr/bin/env python3
"""claude-box docker-ro — Docker Engine API хоста только для чтения.

Слушает TCP :2375 (доступен только агенту: адрес разрешён в kill-switch шлюза) и пересылает в
/var/run/docker.sock лишь GET/HEAD-запросы из белого списка: список и inspect контейнеров, образов,
сетей и томов, логи, stats, top, events, version/info. Всё остальное — 403 с подсказкой.

Не пропускаются, в частности: любые POST/PUT/DELETE (create/start/stop/exec/build/pull…),
GET /containers/<id>/archive и /export (чтение файлов контейнеров), attach и websocket.

Каждое соединение обслуживает ровно один запрос: в Docker уходит «Connection: close», а всё,
что клиент пришлёт после первого запроса, отбрасывается — второй запрос нельзя «протащить»
в уже проверенном соединении.
"""
import asyncio
import os
import re
import sys

SOCK = os.environ.get("DOCKER_SOCK", "/var/run/docker.sock")
PORT = int(os.environ.get("DOCKER_RO_PORT", "2375"))
MAX_HEAD = 64 * 1024

V = r"(?:/v[0-9]{1,2}\.[0-9]{1,3})?"
ID = r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}"
IMG = r"[A-Za-z0-9][A-Za-z0-9_.:@/-]{0,255}"
ALLOW = [
    re.compile("^" + V + p + "$")
    for p in (
        r"/_ping",
        r"/version",
        r"/info",
        r"/events",
        r"/system/df",
        r"/containers/json",
        rf"/containers/{ID}/(?:json|logs|stats|top|changes)",
        r"/images/json",
        rf"/images/{IMG}/(?:json|history)",
        r"/networks",
        rf"/networks/{ID}",
        r"/volumes",
        rf"/volumes/{ID}",
    )
]
DROP_HEADERS = {b"connection", b"keep-alive", b"upgrade", b"proxy-connection", b"te", b"trailer"}

DENY_MSG = (
    '{"message":"claude-box docker-ro: этот Docker только для чтения (ps, logs, inspect, stats, events). '
    "Изменения (run, compose up, restart, exec, build, rm…) выполняй на хосте: "
    "ssh <хост> 'docker …' — с подтверждением пользователя.\"}"
)


def log(*a):
    print(*a, file=sys.stdout, flush=True)


def allowed(method: str, target: str) -> bool:
    if method not in ("GET", "HEAD"):
        return False
    path = target.split("?", 1)[0]
    if not path.startswith("/") or ".." in path or "//" in path or "%" in path or "\\" in path:
        return False
    return any(r.match(path) for r in ALLOW)


async def reply(writer, status: str, body: str):
    data = body.encode()
    writer.write(
        f"HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {len(data)}\r\n"
        f"Connection: close\r\n\r\n".encode() + data
    )
    try:
        await writer.drain()
    finally:
        writer.close()


async def pipe_up_to_client(ur, cw):
    try:
        while True:
            chunk = await ur.read(65536)
            if not chunk:
                break
            cw.write(chunk)
            await cw.drain()
    except (ConnectionError, asyncio.CancelledError):
        pass


async def drain_client(cr):
    """Читает и выбрасывает всё, что клиент шлёт после первого запроса; возвращается при закрытии."""
    try:
        while await cr.read(65536):
            pass
    except (ConnectionError, asyncio.CancelledError):
        pass


async def handle(cr, cw):
    peer = cw.get_extra_info("peername")
    try:
        head = await asyncio.wait_for(cr.readuntil(b"\r\n\r\n"), timeout=30)
    except (asyncio.IncompleteReadError, asyncio.LimitOverrunError, asyncio.TimeoutError, ConnectionError):
        cw.close()
        return
    lines = head[:-4].split(b"\r\n")
    try:
        method, target, version = lines[0].decode("latin-1").split(" ", 2)
    except ValueError:
        await reply(cw, "400 Bad Request", '{"message":"bad request"}')
        return

    headers = []
    for raw in lines[1:]:
        name, sep, value = raw.partition(b":")
        if not sep:
            await reply(cw, "400 Bad Request", '{"message":"bad header"}')
            return
        lname = name.strip().lower()
        if lname in (b"content-length", b"transfer-encoding") and value.strip() not in (b"0", b""):
            # у разрешённых GET/HEAD тела нет; тело — признак попытки обмана
            await reply(cw, "403 Forbidden", DENY_MSG)
            log(f"DENY body {method} {target.split('?', 1)[0]} from {peer}")
            return
        if lname in DROP_HEADERS or lname == b"content-length" or lname == b"transfer-encoding":
            continue
        headers.append(raw)

    if not version.startswith("HTTP/1.") or not allowed(method, target):
        log(f"DENY {method} {target.split('?', 1)[0]} from {peer}")
        await reply(cw, "403 Forbidden", DENY_MSG)
        return

    try:
        ur, uw = await asyncio.open_unix_connection(SOCK)
    except OSError as e:
        await reply(cw, "502 Bad Gateway", '{"message":"docker socket unavailable"}')
        log(f"ERROR socket: {e}")
        return

    log(f"ALLOW {method} {target.split('?', 1)[0]}")
    out = [f"{method} {target} {version}".encode("latin-1")] + headers + [b"Connection: close", b"", b""]
    uw.write(b"\r\n".join(out))
    await uw.drain()

    up = asyncio.create_task(pipe_up_to_client(ur, cw))
    down = asyncio.create_task(drain_client(cr))
    done, _ = await asyncio.wait({up, down}, return_when=asyncio.FIRST_COMPLETED)
    if down in done and not up.done():
        # клиент закрыл свою сторону: обычный ответ ещё может дойти, поток (logs -f) — нет, ждём недолго
        await asyncio.wait({up}, timeout=30)
    for t in (up, down):
        t.cancel()
    for w in (uw, cw):
        try:
            w.close()
        except Exception:
            pass


async def main():
    server = await asyncio.start_server(handle, "0.0.0.0", PORT, limit=MAX_HEAD)
    log(f"docker-ro: :{PORT} -> {SOCK} (только чтение)")
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
