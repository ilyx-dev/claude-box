# Фальшивый dockerd на unix-сокете: отвечает эхом метода/пути, /logs отдаёт поток
import asyncio, sys
async def h(r, w):
    data = b""
    while b"\r\n\r\n" not in data:
        c = await r.read(4096)
        if not c: return
        data += c
    first = data.split(b"\r\n")[0].decode()
    conn = [l for l in data.split(b"\r\n") if l.lower().startswith(b"connection:")]
    body = f'{{"echo":"{first}","conn":"{conn[0].decode() if conn else ""}","extra":{len(data.split(chr(13).encode()+chr(10).encode()*1))}}}'
    if "/logs" in first:
        w.write(b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n")
        for i in range(3):
            w.write(f"line{i}\n".encode()); await w.drain(); await asyncio.sleep(0.1)
        w.close(); return
    w.write(f"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {len(body)}\r\n\r\n{body}".encode())
    await w.drain()
    # проверка: не пришло ли что-то ещё по этому соединению
    try:
        extra = await asyncio.wait_for(r.read(4096), 0.5)
        if extra: print("UPSTREAM GOT EXTRA:", extra[:60], flush=True)
    except asyncio.TimeoutError:
        pass
    w.close()
async def main():
    s = await asyncio.start_unix_server(h, sys.argv[1])
    async with s: await s.serve_forever()
asyncio.run(main())
