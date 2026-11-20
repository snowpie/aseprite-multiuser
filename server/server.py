import asyncio
import json
import logging
import os
import time
from collections import defaultdict

import websockets

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("relay")

PORT = int(os.environ.get("PORT", "5000"))
# Max binary message size: 4 MB (generous for pixel art)
MAX_MSG = 4 * 1024 * 1024

rooms: dict[str, dict[str, "Client"]] = defaultdict(dict)
# Latest full cel state per room, keyed by "layer\0frame"
cel_cache: dict[str, dict[str, bytes]] = defaultdict(dict)


class Client:
    __slots__ = ("ws", "room", "name")

    def __init__(self, ws, room: str, name: str):
        self.ws = ws
        self.room = room
        self.name = name


async def broadcast(room: str, msg, *, sender: str):
    peers = rooms.get(room)
    if not peers:
        return
    targets = [c.ws for name, c in peers.items() if name != sender]
    if targets:
        await asyncio.gather(
            *(t.send(msg) for t in targets), return_exceptions=True
        )


async def handle_text(client: Client, raw: str):
    try:
        msg = json.loads(raw)
    except json.JSONDecodeError:
        return

    kind = msg.get("type")

    if kind == "cursor" or kind == "layer_op":
        msg["user"] = client.name
        await broadcast(client.room, json.dumps(msg), sender=client.name)

    elif kind == "sync_request":
        # Late joiner asks for full state; relay to whoever has it
        msg["user"] = client.name
        await broadcast(client.room, json.dumps(msg), sender=client.name)


async def handle_binary(client: Client, data: bytes):
    # Binary format: JSON header (utf-8) + \x00 + pixel bytes
    sep = data.find(b"\x00")
    if sep < 0:
        return
    try:
        header = json.loads(data[:sep])
    except json.JSONDecodeError:
        return

    kind = header.get("type")
    layer = header.get("layer", "")
    frame = header.get("frame", 0)
    cache_key = f"{layer}\x00{frame}"

    if kind in ("cel_diff", "cel_full"):
        header["user"] = client.name
        # Re-encode header in case we added user
        new_header = json.dumps(header).encode("utf-8")
        out = new_header + b"\x00" + data[sep + 1 :]
        await broadcast(client.room, out, sender=client.name)

        if kind == "cel_full":
            cel_cache[client.room][cache_key] = out
            log.info(
                "cached full cel %s/%s frame %s (%d bytes)",
                client.room, layer, frame, len(data) - sep - 1,
            )


async def send_cached_state(client: Client):
    cached = cel_cache.get(client.room, {})
    for cache_key, msg in cached.items():
        try:
            await client.ws.send(msg)
        except websockets.ConnectionClosed:
            break


async def handler(ws):
    client = None
    try:
        # First message must be a JSON JOIN
        raw = await asyncio.wait_for(ws.recv(), timeout=10)
        if isinstance(raw, bytes):
            await ws.close(1002, "expected text JOIN")
            return
        msg = json.loads(raw)
        if msg.get("type") != "join":
            await ws.close(1002, "first message must be join")
            return

        room = msg.get("room", "default")
        name = msg.get("user", f"anon-{id(ws)}")

        # Reject duplicate names in the same room
        if name in rooms[room]:
            await ws.close(1008, "name already taken in room")
            return

        client = Client(ws, room, name)
        rooms[room][name] = client

        users = list(rooms[room].keys())
        log.info("join: %s -> room %s (%d users)", name, room, len(users))

        await ws.send(json.dumps({
            "type": "welcome",
            "users": users,
            "room": room,
        }))

        await broadcast(room, json.dumps({
            "type": "user_join",
            "user": name,
        }), sender=name)

        # Send cached cel state to late joiner
        await send_cached_state(client)

        async for raw in ws:
            if isinstance(raw, str):
                await handle_text(client, raw)
            elif isinstance(raw, bytes):
                if len(raw) <= MAX_MSG:
                    await handle_binary(client, raw)
                else:
                    log.warning("dropped oversized binary from %s (%d bytes)", name, len(raw))

    except (websockets.ConnectionClosed, asyncio.TimeoutError):
        pass
    except Exception:
        log.exception("handler error")
    finally:
        if client:
            rooms[client.room].pop(client.name, None)
            if not rooms[client.room]:
                del rooms[client.room]
                cel_cache.pop(client.room, None)
                log.info("room %s empty, cleaned up", client.room)
            else:
                await broadcast(client.room, json.dumps({
                    "type": "user_leave",
                    "user": client.name,
                }), sender=client.name)
                log.info("leave: %s from room %s", client.name, client.room)


async def main():
    async with websockets.serve(
        handler,
        "0.0.0.0",
        PORT,
        max_size=MAX_MSG,
        ping_interval=20,
        ping_timeout=10,
    ):
        log.info("relay server listening on 0.0.0.0:%d", PORT)
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
