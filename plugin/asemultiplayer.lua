-- Multiplayer sync plugin for Aseprite
-- Uses native WebSocket to connect to a relay server.
-- Sends cel-level pixel diffs; supports N users per room.

local json -- forward declaration; Aseprite bundles json support via the websocket layer

-- Minimal JSON encoder/decoder for Aseprite (which has no built-in json module).
-- Handles the flat tables and simple types this plugin needs.
local JSON = {}

function JSON.encode(val)
    if val == nil then return "null" end
    local t = type(val)
    if t == "boolean" then return tostring(val) end
    if t == "number" then
        if val ~= val then return "null" end
        if val == math.huge or val == -math.huge then return "null" end
        if val == math.floor(val) then return string.format("%d", val) end
        return tostring(val)
    end
    if t == "string" then
        local s = val:gsub('\\', '\\\\'):gsub('"', '\\"')
            :gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
        return '"' .. s .. '"'
    end
    if t == "table" then
        -- array check: sequential integer keys starting at 1
        local is_array = #val > 0
        if is_array then
            local parts = {}
            for i = 1, #val do
                parts[i] = JSON.encode(val[i])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            for k, v in pairs(val) do
                parts[#parts + 1] = JSON.encode(tostring(k)) .. ":" .. JSON.encode(v)
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return "null"
end

function JSON.decode(str)
    -- Use Lua pattern matching for the simple JSON this plugin receives.
    -- Supports: objects (non-nested for our protocol), arrays of strings, strings, numbers, booleans, null.
    if str == nil then return nil end
    str = str:match("^%s*(.-)%s*$")
    if str == "null" then return nil end
    if str == "true" then return true end
    if str == "false" then return false end

    local num = tonumber(str)
    if num then return num end

    if str:sub(1, 1) == '"' then
        return str:sub(2, -2):gsub('\\n', '\n'):gsub('\\r', '\r')
            :gsub('\\t', '\t'):gsub('\\"', '"'):gsub('\\\\', '\\')
    end

    if str:sub(1, 1) == '[' then
        local arr = {}
        for item in str:sub(2, -2):gmatch('[^,]+') do
            arr[#arr + 1] = JSON.decode(item)
        end
        return arr
    end

    if str:sub(1, 1) == '{' then
        local obj = {}
        local inner = str:sub(2, -2)
        -- Parse key:value pairs handling nested arrays/objects
        local pos = 1
        while pos <= #inner do
            -- skip whitespace and commas
            local ws_end = inner:match("^[%s,]*()", pos)
            if ws_end then pos = ws_end end
            if pos > #inner then break end

            -- read key (quoted string)
            local key_start, key_end, key = inner:find('"([^"]*)"', pos)
            if not key then break end
            pos = key_end + 1

            -- skip colon
            pos = inner:match("^%s*:%s*()", pos) or pos

            -- read value
            local ch = inner:sub(pos, pos)
            local val
            if ch == '"' then
                local ve = inner:find('"', pos + 1)
                val = JSON.decode(inner:sub(pos, ve))
                pos = ve + 1
            elseif ch == '[' then
                local depth, ve = 1, pos + 1
                while depth > 0 and ve <= #inner do
                    local c = inner:sub(ve, ve)
                    if c == '[' then depth = depth + 1
                    elseif c == ']' then depth = depth - 1 end
                    ve = ve + 1
                end
                val = JSON.decode(inner:sub(pos, ve - 1))
                pos = ve
            elseif ch == '{' then
                local depth, ve = 1, pos + 1
                while depth > 0 and ve <= #inner do
                    local c = inner:sub(ve, ve)
                    if c == '{' then depth = depth + 1
                    elseif c == '}' then depth = depth - 1 end
                    ve = ve + 1
                end
                val = JSON.decode(inner:sub(pos, ve - 1))
                pos = ve
            else
                local raw = inner:match("([^,}%]]+)", pos)
                val = JSON.decode(raw)
                pos = pos + #raw
            end
            obj[key] = val
        end
        return obj
    end

    return nil
end

-- ─── Plugin ─────────────────────────────────────────────────────────

function init(plugin)
    print("multiplayer plugin v2 initializing")

    -- Preferences with defaults
    if plugin.preferences.serverURL == nil then
        plugin.preferences.serverURL = "ws://localhost:5000"
    end
    if plugin.preferences.room == nil then
        plugin.preferences.room = "default"
    end
    if plugin.preferences.userName == nil then
        plugin.preferences.userName = "user-" .. tostring(os.time()):sub(-4)
    end
    if plugin.preferences.syncInterval == nil then
        plugin.preferences.syncInterval = "1"
    end
    if plugin.preferences.isSyncOn == nil then
        plugin.preferences.isSyncOn = false
    end

    local ws = nil
    local syncTimer = nil
    local connected = false
    local applyingRemote = false -- guard against feedback loops

    local myLayerName = nil
    local myFrameNumber = nil

    -- Snapshots of cel image bytes, keyed by "layer\0frame"
    local snapshots = {}
    -- Peer cursors: { name = { layer, frame, x, y } }
    local peerCursors = {}
    -- Peer list
    local peers = {}
    -- Last sent layer order (list of names, bottom to top)
    local lastLayerOrder = {}

    local statusDialog = nil

    -- ─── Helpers ────────────────────────────────────────────────────

    local function celKey(layer, frame)
        return layer .. "\0" .. tostring(frame)
    end

    local function findLayerByName(name, sprite)
        for _, layer in ipairs(sprite.layers) do
            if layer.name == name then return layer end
        end
        return nil
    end

    local function getOpenTabs()
        local tabs = {}
        for _, sprite in ipairs(app.sprites) do
            tabs[#tabs + 1] = sprite.filename
        end
        return tabs
    end

    local function findSpriteByName(name)
        for _, sprite in ipairs(app.sprites) do
            if sprite.filename == name then return sprite end
        end
        return nil
    end

    -- ─── Diff computation ───────────────────────────────────────────

    -- Returns the raw image bytes and dimensions for a cel, or nil
    local function getCelData(sprite, layerName, frameNum)
        local layer = findLayerByName(layerName, sprite)
        if not layer then return nil end
        local cel = layer:cel(frameNum)
        if not cel then return nil end
        local img = cel.image
        return img.bytes, img.width, img.height, cel.position, img.colorMode
    end

    -- Compute bounding box of changed pixels between two byte strings of equal length.
    -- Returns nil if identical. For RGBA (4 bpp); adapts stride from width.
    local function computeDirtyRect(oldBytes, newBytes, w, h, bpp)
        if oldBytes == newBytes then return nil end
        local minX, minY, maxX, maxY = w, h, -1, -1
        local stride = w * bpp
        for y = 0, h - 1 do
            local rowOff = y * stride
            for x = 0, w - 1 do
                local off = rowOff + x * bpp + 1  -- Lua strings are 1-indexed
                local changed = false
                for b = 0, bpp - 1 do
                    if oldBytes:byte(off + b) ~= newBytes:byte(off + b) then
                        changed = true
                        break
                    end
                end
                if changed then
                    if x < minX then minX = x end
                    if x > maxX then maxX = x end
                    if y < minY then minY = y end
                    if y > maxY then maxY = y end
                end
            end
        end
        if maxX < 0 then return nil end
        return { x = minX, y = minY, w = maxX - minX + 1, h = maxY - minY + 1 }
    end

    -- Extract a rectangle of pixel bytes from a full image byte string
    local function extractRect(bytes, imgW, rect, bpp)
        local parts = {}
        local stride = imgW * bpp
        for y = rect.y, rect.y + rect.h - 1 do
            local start = y * stride + rect.x * bpp + 1
            parts[#parts + 1] = bytes:sub(start, start + rect.w * bpp - 1)
        end
        return table.concat(parts)
    end

    -- Apply a rectangle of pixel bytes into an image byte string
    local function applyRect(bytes, imgW, rect, bpp, rectBytes)
        local result = { bytes }
        -- Build a new string with the rect patched in
        local buf = {}
        local stride = imgW * bpp
        local src = bytes
        local prevEnd = 0
        for y = rect.y, rect.y + rect.h - 1 do
            local start = y * stride + rect.x * bpp  -- 0-indexed byte offset
            -- copy everything before this row's rect
            if start > prevEnd then
                buf[#buf + 1] = src:sub(prevEnd + 1, start)
            end
            -- insert rect row
            local rowIdx = (y - rect.y) * rect.w * bpp
            buf[#buf + 1] = rectBytes:sub(rowIdx + 1, rowIdx + rect.w * bpp)
            prevEnd = start + rect.w * bpp
        end
        -- copy remainder
        if prevEnd < #src then
            buf[#buf + 1] = src:sub(prevEnd + 1)
        end
        return table.concat(buf)
    end

    local function bppForMode(colorMode)
        if colorMode == ColorMode.RGB then return 4 end
        if colorMode == ColorMode.GRAY or colorMode == ColorMode.GRAYSCALE then return 2 end
        if colorMode == ColorMode.INDEXED then return 1 end
        return 4 -- default to RGBA
    end

    -- ─── Send helpers ───────────────────────────────────────────────

    local function sendJSON(tbl)
        if ws and connected then
            ws:sendText(JSON.encode(tbl))
        end
    end

    local function sendBinary(header, pixelBytes)
        if ws and connected then
            ws:sendBinary(JSON.encode(header) .. "\0" .. pixelBytes)
        end
    end

    local function sendCursor()
        if not myLayerName or not myFrameNumber then return end
        sendJSON({
            type = "cursor",
            layer = myLayerName,
            frame = myFrameNumber,
        })
    end

    -- Send a diff or full cel for the given layer/frame
    local function pushCel(sprite, layerName, frameNum, force)
        local bytes, w, h, pos, colorMode = getCelData(sprite, layerName, frameNum)
        if not bytes then return end

        local bpp = bppForMode(colorMode)
        local key = celKey(layerName, frameNum)
        local old = snapshots[key]

        if not force and old and #old == #bytes then
            local rect = computeDirtyRect(old, bytes, w, h, bpp)
            if not rect then return end -- no change

            -- If dirty rect is >50% of image, send full
            if rect.w * rect.h > w * h * 0.5 then
                force = true
            else
                local rectPixels = extractRect(bytes, w, rect, bpp)
                -- Pack rect coords as binary prefix: count (1 byte) + per rect x,y,w,h (4x uint16 LE)
                local prefix = string.pack("<B I2I2I2I2", 1, rect.x, rect.y, rect.w, rect.h)
                sendBinary({
                    type = "cel_diff",
                    layer = layerName,
                    frame = frameNum,
                    img_w = w,
                    img_h = h,
                    pos_x = pos.x,
                    pos_y = pos.y,
                    bpp = bpp,
                }, prefix .. rectPixels)
                snapshots[key] = bytes
                return
            end
        end

        -- Full send
        sendBinary({
            type = "cel_full",
            layer = layerName,
            frame = frameNum,
            img_w = w,
            img_h = h,
            pos_x = pos.x,
            pos_y = pos.y,
            bpp = bpp,
        }, bytes)
        snapshots[key] = bytes
    end

    -- ─── Receive handlers ───────────────────────────────────────────

    local function handleCelFull(header, pixelBytes)
        local sprite = findSpriteByName(plugin.preferences.syncTab)
        if not sprite then return end

        local layerName = header.layer
        local frameNum = header.frame
        local w = header.img_w
        local h = header.img_h
        if not layerName or not frameNum or not w or not h then return end
        local bpp = header.bpp or 4

        local layer = findLayerByName(layerName, sprite)
        if not layer then
            layer = sprite:newLayer()
            layer.name = layerName
        end

        while #sprite.frames < frameNum do
            sprite:newFrame()
        end

        applyingRemote = true
        app.transaction("remote cel", function()
            local img = Image(w, h, layer.sprite.colorMode)
            if #pixelBytes == img.rowStride * h then
                img.bytes = pixelBytes
            end
            local cel = layer:cel(frameNum)
            if cel then
                cel.image = img
                cel.position = Point(header.pos_x or 0, header.pos_y or 0)
            else
                sprite:newCel(layer, frameNum, img, Point(header.pos_x or 0, header.pos_y or 0))
            end
        end)
        applyingRemote = false

        snapshots[celKey(layerName, frameNum)] = pixelBytes
    end

    local function handleCelDiff(header, payload)
        local sprite = findSpriteByName(plugin.preferences.syncTab)
        if not sprite then return end

        local layerName = header.layer
        local frameNum = header.frame
        local w = header.img_w
        local h = header.img_h
        if not layerName or not frameNum or not w or not h then return end
        local bpp = header.bpp or 4

        local layer = findLayerByName(layerName, sprite)
        if not layer then return end

        local cel = layer:cel(frameNum)
        if not cel then return end

        -- Unpack rect coords from binary prefix
        local numRects = string.unpack("<B", payload)
        local pos = 2
        local rects = {}
        for i = 1, numRects do
            local x, y, rw, rh
            x, y, rw, rh, pos = string.unpack("<I2I2I2I2", payload, pos)
            rects[i] = { x = x, y = y, w = rw, h = rh }
        end

        applyingRemote = true
        app.transaction("remote diff", function()
            local img = cel.image:clone()
            local currentBytes = img.bytes

            for _, rect in ipairs(rects) do
                local rectSize = rect.w * rect.h * bpp
                local chunk = payload:sub(pos, pos + rectSize - 1)
                currentBytes = applyRect(currentBytes, w, rect, bpp, chunk)
                pos = pos + rectSize
            end

            img.bytes = currentBytes
            cel.image = img
            cel.position = Point(header.pos_x or 0, header.pos_y or 0)
        end)
        applyingRemote = false

        snapshots[celKey(layerName, frameNum)] = getCelData(sprite, layerName, frameNum)
    end

    -- ─── Layer name dedup ─────────────────────────────────────────────

    local function deduplicateLayerNames(sprite)
        local seen = {}
        local renamed = false
        for _, layer in ipairs(sprite.layers) do
            if seen[layer.name] then
                local base = layer.name
                local n = 2
                while seen[base .. " (" .. n .. ")"] do n = n + 1 end
                layer.name = base .. " (" .. n .. ")"
                print("renamed duplicate layer to: " .. layer.name)
                renamed = true
            end
            seen[layer.name] = true
        end
        return renamed
    end

    -- ─── Layer order sync ────────────────────────────────────────────

    local function getLayerOrder(sprite)
        local order = {}
        for _, layer in ipairs(sprite.layers) do
            order[#order + 1] = layer.name
        end
        return order
    end

    local function layerOrderChanged(a, b)
        if #a ~= #b then return true end
        for i = 1, #a do
            if a[i] ~= b[i] then return true end
        end
        return false
    end

    local function pushLayerOrder(sprite)
        local order = getLayerOrder(sprite)
        if not layerOrderChanged(order, lastLayerOrder) then return end
        lastLayerOrder = order
        sendJSON({
            type = "layer_op",
            op = "reorder",
            order = order,
        })
    end

    local function handleLayerOrder(msg)
        local sprite = findSpriteByName(plugin.preferences.syncTab)
        if not sprite then return end
        local order = msg.order
        if not order or #order == 0 then return end

        applyingRemote = true
        app.transaction("remote layer order", function()
            -- Create missing layers
            for _, name in ipairs(order) do
                if not findLayerByName(name, sprite) then
                    local newLayer = sprite:newLayer()
                    newLayer.name = name
                end
            end

            -- Reorder: set stackIndex bottom-to-top (1 = bottom)
            for i, name in ipairs(order) do
                local layer = findLayerByName(name, sprite)
                if layer and layer.stackIndex ~= i then
                    layer.stackIndex = i
                end
            end
        end)
        lastLayerOrder = order
        applyingRemote = false
    end

    -- ─── Message handlers ───────────────────────────────────────────

    local function handleTextMessage(raw)
        local msg = JSON.decode(raw)
        if not msg then return end
        local kind = msg.type

        if kind == "welcome" then
            peers = msg.users or {}
            print("connected to room " .. (msg.room or "?") .. " with " .. #peers .. " users")

        elseif kind == "user_join" then
            peers[#peers + 1] = msg.user
            print(msg.user .. " joined")
            -- Send our current state so they can catch up
            local sprite = findSpriteByName(plugin.preferences.syncTab)
            if sprite then
                lastLayerOrder = {}
                pushLayerOrder(sprite)
                if myLayerName then
                    pushCel(sprite, myLayerName, myFrameNumber, true)
                end
            end

        elseif kind == "user_leave" then
            for i, name in ipairs(peers) do
                if name == msg.user then
                    table.remove(peers, i)
                    break
                end
            end
            peerCursors[msg.user] = nil
            print(msg.user .. " left")

        elseif kind == "cursor" then
            peerCursors[msg.user] = {
                layer = msg.layer,
                frame = msg.frame,
            }

        elseif kind == "layer_op" and msg.op == "reorder" then
            handleLayerOrder(msg)
        end

        updateStatusDialog()
    end

    local function handleBinaryMessage(data)
        local sep = data:find("\0")
        if not sep then return end
        local header = JSON.decode(data:sub(1, sep - 1))
        if not header then return end
        local pixels = data:sub(sep + 1)

        if header.type == "cel_full" then
            handleCelFull(header, pixels)
        elseif header.type == "cel_diff" then
            handleCelDiff(header, pixels)
        end
    end

    -- ─── Status dialog ──────────────────────────────────────────────

    function updateStatusDialog()
        if not statusDialog then return end

        local peerText = ""
        for name, cur in pairs(peerCursors) do
            peerText = peerText .. name .. ": " .. (cur.layer or "?") .. " f" .. (cur.frame or "?") .. "\n"
        end
        if peerText == "" then peerText = "(none)" end

        pcall(function()
            statusDialog:modify{ id = "statusPeers", text = peerText }
            statusDialog:modify{ id = "statusConnected", text = connected and "YES" or "NO" }
            statusDialog:modify{ id = "statusRoom", text = plugin.preferences.room }
        end)
    end

    -- ─── Connect / disconnect ───────────────────────────────────────

    local function connect()
        if ws then
            pcall(function() ws:close() end)
        end

        ws = WebSocket{
            url = plugin.preferences.serverURL,
            onreceive = function(message, data)
                if message == WebSocketMessageType.OPEN then
                    connected = true
                    sendJSON({
                        type = "join",
                        room = plugin.preferences.room,
                        user = plugin.preferences.userName,
                    })
                    print("websocket connected")

                elseif message == WebSocketMessageType.TEXT then
                    handleTextMessage(data)

                elseif message == WebSocketMessageType.BINARY then
                    handleBinaryMessage(data)

                elseif message == WebSocketMessageType.CLOSE or message == WebSocketMessageType.ERROR then
                    connected = false
                    print("websocket disconnected")
                    updateStatusDialog()
                end
            end,
            deflate = true,
        }
        ws:connect()
    end

    local function disconnect()
        if ws then
            pcall(function() ws:close() end)
            ws = nil
        end
        connected = false
        peerCursors = {}
        peers = {}
        snapshots = {}
    end

    -- ─── Sync loop ──────────────────────────────────────────────────

    local function startSync(dialog)
        plugin.preferences.isSyncOn = true

        connect()

        local sprite = findSpriteByName(plugin.preferences.syncTab)
        if sprite then
            myLayerName = app.layer and app.layer.name or nil
            myFrameNumber = app.frame and app.frame.frameNumber or nil

            sprite.events:on("change", function(ev)
                if not plugin.preferences.isSyncOn then return end
                if applyingRemote then return end
                if not app.sprite or app.sprite.filename ~= plugin.preferences.syncTab then return end
                if not myLayerName or not myFrameNumber then return end
                -- Defer actual push to the timer to batch rapid edits
            end)
        end

        if syncTimer then syncTimer:stop() end
        syncTimer = Timer{
            interval = tonumber(plugin.preferences.syncInterval) or 1,
            ontick = function()
                if not plugin.preferences.isSyncOn then return end
                if not connected then return end

                local spr = findSpriteByName(plugin.preferences.syncTab)
                if not spr then return end
                if not app.sprite or app.sprite.filename ~= plugin.preferences.syncTab then return end

                deduplicateLayerNames(spr)

                local curLayer = app.layer and app.layer.name or nil
                local curFrame = app.frame and app.frame.frameNumber or nil

                if curLayer ~= myLayerName or curFrame ~= myFrameNumber then
                    -- Push old cel before moving away
                    if myLayerName and myFrameNumber then
                        pushCel(spr, myLayerName, myFrameNumber, false)
                    end
                    myLayerName = curLayer
                    myFrameNumber = curFrame
                    sendCursor()
                end

                -- Push current cel
                if myLayerName and myFrameNumber then
                    pushCel(spr, myLayerName, myFrameNumber, false)
                end

                -- Sync layer order
                pushLayerOrder(spr)

                updateStatusDialog()
            end,
        }
        syncTimer:start()
    end

    local function stopSync()
        plugin.preferences.isSyncOn = false
        if syncTimer then
            syncTimer:stop()
            syncTimer = nil
        end
        disconnect()
    end

    -- ─── UI ─────────────────────────────────────────────────────────

    local function showMultiplayerDialog()
        local openTabs = getOpenTabs()

        if plugin.preferences.syncTab == nil and #openTabs > 0 then
            plugin.preferences.syncTab = openTabs[1]
        end

        statusDialog = Dialog{
            title = "Multiplayer (closing stops sync)",
            onclose = function()
                stopSync()
            end,
        }
        statusDialog:label{ id = "statusConnected", label = "Connected:", text = "NO" }
        statusDialog:label{ id = "statusRoom", label = "Room:", text = plugin.preferences.room }
        statusDialog:label{ id = "statusPeers", label = "Peers:", text = "(none)" }
        statusDialog:separator()
        statusDialog:button{
            id = "pushBtn",
            text = "Force Push Cel",
            onclick = function()
                local spr = findSpriteByName(plugin.preferences.syncTab)
                if spr and myLayerName and myFrameNumber then
                    pushCel(spr, myLayerName, myFrameNumber, true)
                end
            end,
        }

        local mainDialog = Dialog{ title = "Multiplayer Sync" }

        mainDialog:entry{
            id = "serverURL",
            label = "Server",
            text = plugin.preferences.serverURL,
            onchange = function()
                plugin.preferences.serverURL = mainDialog.data.serverURL
            end,
        }
        mainDialog:entry{
            id = "room",
            label = "Room",
            text = plugin.preferences.room,
            onchange = function()
                plugin.preferences.room = mainDialog.data.room
            end,
        }
        mainDialog:entry{
            id = "userName",
            label = "Name",
            text = plugin.preferences.userName,
            onchange = function()
                plugin.preferences.userName = mainDialog.data.userName
            end,
        }
        mainDialog:entry{
            id = "interval",
            label = "Sync interval (s)",
            text = plugin.preferences.syncInterval,
            onchange = function()
                plugin.preferences.syncInterval = mainDialog.data.interval
            end,
        }
        mainDialog:combobox{
            id = "syncTab",
            label = "Sync Tab",
            options = openTabs,
            onchange = function()
                plugin.preferences.syncTab = mainDialog.data.syncTab
            end,
        }
        mainDialog:button{
            id = "syncBtn",
            text = "Connect & Sync",
            onclick = function()
                if plugin.preferences.isSyncOn then
                    stopSync()
                    mainDialog:modify{ id = "syncBtn", text = "Connect & Sync" }
                    if statusDialog then
                        pcall(function() statusDialog:close() end)
                    end
                else
                    startSync()
                    mainDialog:modify{ id = "syncBtn", text = "Disconnect" }
                    statusDialog:show{ wait = false }
                end
            end,
        }

        mainDialog:show{ wait = false }
    end

    plugin:newCommand{
        id = "syncID",
        title = "Multiplayer",
        group = "file_app",
        onclick = function()
            showMultiplayerDialog()
        end,
        onenabled = function()
            return true
        end,
    }

    -- Handle sitechange for layer/frame tracking
    app.events:on("sitechange", function()
        if not plugin.preferences.isSyncOn then return end
        if not connected then return end
        if not app.sprite or app.sprite.filename ~= plugin.preferences.syncTab then return end

        local curLayer = app.layer and app.layer.name or nil
        local curFrame = app.frame and app.frame.frameNumber or nil

        if curLayer ~= myLayerName or curFrame ~= myFrameNumber then
            -- Push current cel before switching
            if myLayerName and myFrameNumber then
                local spr = findSpriteByName(plugin.preferences.syncTab)
                if spr then pushCel(spr, myLayerName, myFrameNumber, false) end
            end
            myLayerName = curLayer
            myFrameNumber = curFrame
            sendCursor()
        end
    end)
end

function exit(plugin)
    print("multiplayer plugin shutting down")
end
