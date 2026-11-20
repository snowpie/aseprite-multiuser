# Multiplayer Plugin for Aseprite

Real-time collaborative sprite editing. Multiple users connect to a shared relay server via WebSocket and sync cel-level pixel diffs.

## Architecture

```
┌──────────┐  ┌──────────┐  ┌──────────┐
│ Aseprite │  │ Aseprite │  │ Aseprite │
│  Plugin  │  │  Plugin  │  │  Plugin  │
└────┬─────┘  └────┬─────┘  └────┬─────┘
     │ WebSocket    │             │
     └──────┬───────┘─────────────┘
            │
     ┌──────┴──────┐
     │ Relay Server│
     │  (Docker)   │
     └─────────────┘
```

- **Server**: WebSocket relay that broadcasts pixel diffs between clients in a room. No Aseprite knowledge needed — it just forwards messages.
- **Plugin**: Lua script using Aseprite's native WebSocket API. Computes dirty-rect diffs on cel images and sends only changed pixels.

## Setup

### 1. Start the server

```bash
cd server
docker compose up -d
```

The server listens on port 5000 by default. Override with:

```bash
PORT=8080 docker compose up -d
```

### 2. Install the plugin

Zip the contents of `plugin/` and install in Aseprite:

```bash
cd plugin
zip -r asemultiplayer-plugin.zip package.json asemultiplayer.lua
```

In Aseprite: **Edit → Preferences → Extensions → Add Extension** and select the zip.

### 3. Connect

1. Open a sprite in Aseprite
2. **File → Multiplayer**
3. Set the server URL (e.g. `ws://192.168.1.100:5000`)
4. Choose a room name (all users in the same room sync together)
5. Pick a username
6. Select the sprite tab to sync
7. Click **Connect & Sync**

All users in the room see each other's edits in near-real-time.

## How sync works

- Each client tracks which cel (layer + frame) the user is on
- On each sync interval, the plugin compares the current cel's pixels against the last-sent snapshot
- If pixels changed, it computes a dirty bounding rectangle and sends only those pixels
- If >50% of the image changed, it sends the full cel instead
- Other clients apply incoming diffs to their local sprite as undoable transactions
- Cursor positions (which layer/frame each user is on) are shared for awareness

## Same-layer editing

Two users can edit the same layer, even the same cel. Diffs are at pixel granularity — edits in different areas of the same cel merge cleanly. For true same-pixel conflicts, last-write-wins applies (natural for pixel art).

## Differences from v1

| | v1 | v2 |
|---|---|---|
| Peers | 2 (hardcoded) | N (room-based) |
| Transport | Raw TCP + file IPC | WebSocket (native API) |
| Data sent | Entire .ase file | Pixel diffs or raw image bytes |
| Server | Spawned per-client | Standalone Docker container |
| Conflict handling | Warns, blocks same-cel | Pixel-level merge |
