function init(plugin)
	print("Aseprite is initializing local multiplayer plugin")

	local pluginFolder = app.fs.joinPath(app.fs.userConfigPath, "extensions/asemultiplayer-plugin")
	local commandFile = app.fs.joinPath(app.fs.userConfigPath, "extensions/asemultiplayer-plugin/command.txt")
	local positionFile = app.fs.joinPath(app.fs.userConfigPath, "extensions/asemultiplayer-plugin/position.txt")

	local myLayerName = nil
	local myFrameNumber = nil

	local peerLayerName = nil
	local peerFrameNumber = nil
	
	local push = false
	local pull = false

	local isDirty = {}

	local openTabs = nil

	local syncTimer = nil


	if plugin.preferences.peerIP == nil then
    	plugin.preferences.peerIP = "192.168.0.1"
	end

	if plugin.preferences.serverPort == nil then
		plugin.preferences.serverPort = "5000"
	end

	if plugin.preferences.autoPushInterval == nil then
		plugin.preferences.autoPushInterval = "5"
	end

	if plugin.preferences.isSyncOn == nil then
		plugin.preferences.isSyncOn = false
	end

	-- local function getMyLocalIP()
		-- local handle = io.popen("ipconfig")
		-- local result = handle:read("*all")
		-- handle:close()

		-- for line in result:gmatch("[^\r\n]+") do
		--	if line:match("IPv4") then
		--		local ip = line:match("(%d+%.%d+%.%d+%.%d+)")
		--		if ip then
		--			return ip
		--		end
		--	end
		-- end

		-- return "IP not found try ipconfig in cmd and find IPv4"
	-- end

local function getMyLocalIP()
		local is_windows = package.config:sub(1, 1) == "\\"
		local cmd

		if is_windows then
			cmd = "ipconfig"
		else
			cmd = "ip route get 1.1.1.1 2>/dev/null || ipconfig getifaddr $(route -n get default 2>/dev/null | awk '/interface:/{print $2}') 2>/dev/null || hostname -I 2>/dev/null"
		end

		local handle = io.popen(cmd)
		if not handle then
			return nil, "Failed to run network command"
		end

		local output = handle:read("*a")
		handle:close()

		if is_windows then
			for ip in output:gmatch("IPv4 Address[^:]+:%s*(%d+%.%d+%.%d+%.%d+)") do
				if ip ~= "127.0.0.1" then
					return ip
				end
			end
		else
			local route_ip = output:match("src%s+(%d+%.%d+%.%d+%.%d+)")
			if route_ip and route_ip ~= "127.0.0.1" then
				return route_ip
			end

			local mac_ip = output:match("^%s*(%d+%.%d+%.%d+%.%d+)%s*$")
			if mac_ip and mac_ip ~= "127.0.0.1" then
				return mac_ip
			end

			for ip in output:gmatch("inet%s+(%d+%.%d+%.%d+%.%d+)") do
				if ip ~= "127.0.0.1" then
					return ip
				end
			end
		end

		return nil, "No active local IPv4 address found"
	end



	local function findSpriteByName(spriteName)
		for _, sprite in ipairs(app.sprites) do
			if sprite.filename == spriteName then
				return sprite
			end
		end
		return nil
	end

	local function findLayerByName(layerName, sprite)
		for _, layer in ipairs(sprite.layers) do
			if layer.name == layerName then
				return layer
			end
		end
		return nil
	end

	local function clearFiles()
		for _, file in ipairs(app.fs.listFiles(pluginFolder)) do
			local extension = app.fs.fileExtension(file)
			if extension == "ase" or extension == "txt" then
				os.remove(pluginFolder .. "/" .. file)
			end
		end
	end

	local function serverCommand(command, data)
		data = data or ""
		local file = io.open(commandFile, "a")
		if not file then return end
		file:write(command .. data .. "\n")
		file:flush()
		file:close()
	end

	local function getOpenTabs()
		local tabs = {}
		for _, sprite in ipairs(app.sprites) do
			table.insert(tabs, sprite.filename)
		end
		return tabs
	end

	local function updateDetector(dialogDetector)
		if not dialogDetector then return end
		local text="not sync tab"

		if app.sprite.filename == plugin.preferences.syncTab then
			text="SYNC TAB"
		end

		dialogDetector:modify
		{
			id="dialogDetectorID",
			text=text
		}

		dialogDetector:modify 
		{
			id="dialogDetectorMyLayerID",
			text=myLayerName
		}

		dialogDetector:modify 
		{
			id="dialogDetectorMyFrameID",
			text=myFrameNumber
		}

		dialogDetector:modify 
		{
			id="dialogDetectorPeerLayerID",
			text=peerLayerName
		}

		dialogDetector:modify 
		{
			id="dialogDetectorPeerFrameID",
			text=peerFrameNumber
		}

		local warningText = ""

		if myFrameNumber == peerFrameNumber then
			warningText = "You and your peer are on the same frame"
		end

		if myLayerName == peerLayerName then
			warningText = "You and your peer are on the same layer"
		end

		if myLayerName == peerLayerName then
			if myFrameNumber == peerFrameNumber then
				warningText = "!!! You and your peer are on the same cel !!!"
			end
		end

		dialogDetector:modify 
		{
			id="dialogDetectorWarningID",
			text=warningText
		}

		dialogDetector.bounds = Rectangle(
		dialogDetector.bounds.x,
		dialogDetector.bounds.y,
		400 / 2,
		260 / 2
		)
	end

	local function isItDirty()

		local isCelDirty = false

		if isDirty[myLayerName] then
			if isDirty[myLayerName][myFrameNumber] then
				if isDirty[myLayerName][myFrameNumber] == true then 
					isCelDirty = true
				end
			end
		end

		return isCelDirty
	end

	local function dialogsUpdate(dialog, dialogDetector)
		updateDetector(dialogDetector)
		local newText = "Turn sync ON"
		if plugin.preferences.isSyncOn then
			newText = "Turn sync OFF"
		end
		dialog:modify{id="dialogSyncOnOffID", text=newText}
		openTabs = getOpenTabs()
		dialog:modify{id="dialogSyncTabID", options=openTabs}
	end

	local function pushSprite(force)
		force = force or false
	
		push = true

		local isCelDirty = true
		if force == false then
			isCelDirty = isItDirty()
		end

		if isCelDirty == false then return end

		if force == false then
			if myLayerName == peerLayerName and myFrameNumber == peerFrameNumber then return end
		end

		local sprite = findSpriteByName(plugin.preferences.syncTab)
		if not sprite then return end

		local layer = findLayerByName(myLayerName, sprite)
		if not layer then return end

		local cel = layer:cel(myFrameNumber)
		if not cel then return end

		local spriteFile = app.fs.joinPath(app.fs.userConfigPath, "extensions/asemultiplayer-plugin/cel_" .. myLayerName .. "_" .. myFrameNumber .. ".ase")
		sprite:saveCopyAs(spriteFile)
		serverCommand("SENDCEL:", spriteFile)

		isDirty[myLayerName] = isDirty[myLayerName] or {}
		isDirty[myLayerName][myFrameNumber] = false
	end

	local function sendPosition()
		serverCommand("POSITION:", myLayerName .. "|" .. myFrameNumber)
	end

	local function pullSprite()
		pull = true

		for _, file in ipairs(app.fs.listFiles(pluginFolder)) do
  			local fileName = app.fs.fileName(file)
			local extension = app.fs.fileExtension(file)
  			if extension == "ase" and fileName:sub(1, 5) == "celIn" then
				local _, layerName, frameString = file:match("(.+)_(.+)_(%d+)")
				local frameNumber = tonumber(frameString)

				local sprite = app.sprite
				if not sprite then return end
				
				if sprite.filename ~= plugin.preferences.syncTab then return end
				local incoming = Sprite{fromFile=pluginFolder .. "/" .. file}

				if incoming == nil then return end

				local inLayer = findLayerByName(layerName, incoming)
				if not inLayer then incoming:close() return end

				local inCel = inLayer:cel(frameNumber)
				if not inCel then incoming:close() return end

				local localLayer = findLayerByName(layerName, sprite)
				if not localLayer then
					localLayer = sprite:newLayer()
					localLayer.name = layerName
				end

				while #sprite.frames < frameNumber do
					sprite:newFrame()
				end

				local cel = localLayer:cel(frameNumber)
				if cel then
					cel.image = inCel.image
					cel.position = inCel.position
				else
					sprite:newCel(localLayer, frameNumber, inCel.image, inCel.position)
				end

				incoming:close()
			end	
			
			if extension == "ase" and fileName:sub(1, 5) == "celIn" then
				os.remove(pluginFolder .. "/" .. file)
			end
		end
	end

	local function checkPeerPosition()
		local file = io.open(positionFile, "r")
		if not file then return end
		
		peerLayerName, peerFrameNumber = file:read():match("([^|]+)|([^|]+)")
		peerFrameNumber = tonumber(peerFrameNumber)
		file:close()
		
		os.remove(positionFile)
	end

	local function startTimer(dialogDetector)
		if syncTimer then
			syncTimer:stop()
		end

		syncTimer = Timer
		{
			interval = tonumber(plugin.preferences.autoPushInterval) or 1,
			ontick = function()
				if plugin.preferences.isSyncOn then
					if push == false then
						pushSprite()
						push = false
					end
					if pull == false then
						pullSprite()
						pull = false
					end

					checkPeerPosition()

					updateDetector(dialogDetector)
				end
			end
		}
		syncTimer:start()
	end

	local function stopTimer()
		if syncTimer then
			syncTimer:stop()
			syncTimer = nil
		end
	end

	local function startSync(dialogDetector)
		plugin.preferences.isSyncOn = true
		if dialogDetector == nil then return end
		dialogDetector:show { wait = false }
		dialogDetector.bounds = Rectangle(
		dialogDetector.bounds.x,
		dialogDetector.bounds.y,
		400 / 2,
		310 / 2
		)

		os.remove(commandFile)
		
		local port = plugin.preferences.serverPort
		local ip = plugin.preferences.peerIP
		
		
		local is_windows = package.config:sub(1, 1) == "\\"
		local cmd
		if is_windows then
			cmd = string.format('start "" python3 "%s/server.py" %s %s', plugin.path, port, ip)
		else
			cmd = string.format('python3 "%s/server.py" %s %s &', plugin.path, port, ip)
		end
		os.execute(cmd)

		
		myLayerName = app.layer and app.layer.name or nil
		myFrameNumber = app.frame and app.frame.frameNumber or nil

		findSpriteByName(plugin.preferences.syncTab).events:on("change", function(ev)
			if not plugin.preferences.isSyncOn then return end
			if not app.sprite then return end
			if app.sprite.filename ~= plugin.preferences.syncTab then return end

			isDirty[myLayerName] = isDirty[myLayerName] or {}
			isDirty[myLayerName][myFrameNumber] = true
		end)

		startTimer(dialogDetector)
	end

	local function stopSync(dialogDetector)
		plugin.preferences.isSyncOn = false
		
		serverCommand("SHUTDOWN")
		
		if dialogDetector then
			dialogDetector:close()
		end

		stopTimer()
	end

	function multiplayer()
		openTabs = getOpenTabs()

		local dialog = Dialog { title = "Multiplayer Sync" }

		if plugin.preferences.autoPushInterval == nil then
			plugin.preferences.syncTab = openTabs[1]
		end

		local dialogDetector = Dialog 
		{ 
			title = "SYNC (closing me will stop sync)",
			onclose=function() 
				stopSync()
				dialogsUpdate(dialog, dialogDetector)
			end

		}

		dialogDetector:label 
		{
			id="dialogDetectorID",
			label="Tab:",
			text="SYNC TAB"
		}

		dialogDetector:label 
		{
			id="dialogDetectorMyLayerID",
			label="My Layer:",
			text=myLayerName
		}

		dialogDetector:label 
		{
			id="dialogDetectorMyFrameID",
			label="My Frame:",
			text=myFrameNumber
		}

		dialogDetector:label 
		{
			id="dialogDetectorPeerLayerID",
			label="Peer Layer:",
			text=peerLayerName
		}

		dialogDetector:label 
		{
			id="dialogDetectorPeerFrameID",
			label="Peer Frame:",
			text=peerFrameNumber
		}

		dialogDetector:button 
		{ 
			id="dialogDetectorPushID", 
			text="^ Push ^", 
			onclick=function() 
				if push == false then
					pushSprite(true)
					push = false
				end
			end
		}

		dialogDetector:button 
		{ 
			id="dialogDetectorPullID", 
			text="v Pull v", 
			onclick=function() 
				if pull == false then
					pullSprite()
					pull = false
				end
			end
		}

		dialogDetector:separator 
		{
			id="dialogDetectorWarningID",
			text=""
		}

		app.events:on("sitechange", function()

			if not plugin.preferences.isSyncOn then return end

			local stillOpen = false
			for _, sprite in ipairs(app.sprites) do
				if sprite.filename == plugin.preferences.syncTab then
					stillOpen = true
					break
				end
			end

			dialogsUpdate(dialog, dialogDetector)

			if not app.sprite or app.sprite.filename ~= plugin.preferences.syncTab then return end

			if push == false then
				pushSprite()
				push = false
			end
			if pull == false then
				pullSprite()
				pull = false
			end

			myLayerName = app.layer.name
			myFrameNumber = app.frame.frameNumber

			sendPosition()

			dialogsUpdate(dialog, dialogDetector)
		end)

		dialog:label 
		{
			id="dialogMyIPID",
			label="My ip:",
			text=getMyLocalIP()
		}

		dialog:entry 
		{
			id="dialogIPToSyncID",
			label="IP to sync",
			text=plugin.preferences.peerIP,
			onchange=function()
				plugin.preferences.peerIP = dialog.data.dialogIPToSyncID
			end
		}

		dialog:entry 
		{
			id="dialogPortToSyncID",
			label="PORT to sync",
			text=plugin.preferences.serverPort,
			onchange=function(value)
				plugin.preferences.serverPort = dialog.data.dialogPortToSyncID
			end
		}

		dialog:entry 
		{
			id="dialogIntervalID",
			label="Interval of sync",
			text=plugin.preferences.autoPushInterval,
			onchange=function(value)
				plugin.preferences.autoPushInterval = dialog.data.dialogIntervalID
			end
		}

		dialog:combobox 
		{
			id = "dialogSyncTabID",
			label = "Sync Tab",
			options = openTabs,
			onchange = function()
				plugin.preferences.syncTab = dialog.data.dialogSyncTabID
			end
		}

		local syncButton = dialog:button 
		{ 
			id="dialogSyncOnOffID", 
			text="Turn sync ON", 
			onclick=function() 
				plugin.preferences.isSyncOn = not plugin.preferences.isSyncOn
				if plugin.preferences.isSyncOn then
					startSync(dialogDetector)
				else
					stopSync(dialogDetector)
				end

				dialogsUpdate(dialog, dialogDetector)
			end
		}

		local clearButton = dialog:button 
		{ 
			id="dialogClearFilesID", 
			text="Clear server files", 
			onclick=function() 
				clearFiles()
			end
		}

		dialog:show { wait = false }
	end

	plugin:newCommand 
	{
		id = "syncID",
		title = "Multiplayer",
		group = "file_app",
		onclick=function()
			multiplayer()
		end,
		onenabled=function()
			return true
		end
	}
end

function exit(plugin)
	stopSync(dialogDetector)
	print("Aseprite is closing local multiplayer plugin")
end
