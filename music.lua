local api_base_url = "https://ipod-2to6magyna-uc.a.run.app/"
local version = "2.9"
local arguments = { ... }

-- These settings let several independent music systems share one server.
-- `music setup <group>` is the easy path; the pairing-key and channel
-- settings remain available for advanced manual configuration.
settings.define("music.pairing_key", {
	description = "Shared key used by this music player and its receivers",
	default = "music-room",
	type = "string",
})
settings.define("music.group", {
	description = "Easy speaker-group code; when set it also chooses the wireless channels",
	default = "",
	type = "string",
})
settings.define("music.audio_filter", {
	description = "Apply gentle smoothing to reduce DFPWM grain and hiss",
	default = true,
	type = "boolean",
})
settings.define("music.receiver_channel", {
	description = "Wireless channel listened to by music receivers",
	default = 42420,
	type = "number",
})
settings.define("music.player_channel", {
	description = "Wireless channel listened to by the main music player",
	default = 42421,
	type = "number",
})

local function normaliseGroupCode(code)
	if type(code) ~= "string" then return nil end
	code = code:lower():gsub("^%s+", ""):gsub("%s+$", "")
	if #code < 3 or #code > 24 or not code:match("^[a-z0-9_-]+$") then
		return nil
	end
	return code
end

local function channelsForGroup(code)
	local hash = 5381
	for index = 1, #code do
		hash = (hash * 33 + code:byte(index)) % 15000
	end
	local receiverChannel = 30000 + hash * 2
	return receiverChannel, receiverChannel + 1
end

if arguments[1] == "setup" then
	term.clear()
	term.setCursorPos(1, 1)
	if arguments[2] == "reset" then
		settings.unset("music.group")
		settings.save()
		print("Automatic speaker group cleared.")
		print("Manual pairing-key and channel settings are active again.")
		return
	end
	print("Personal speaker group setup")
	print("Use the same code on your main and receivers.")
	local requestedCode = arguments[2]
	if not requestedCode then
		write("Group code (3-24 letters/numbers): ")
		requestedCode = read()
	end
	local code = normaliseGroupCode(requestedCode)
	if not code then
		error("Invalid group code. Use 3-24 letters, numbers, _ or -", 0)
	end
	settings.set("music.group", code)
	settings.save()
	local receiverChannel, playerChannel = channelsForGroup(code)
	print("Saved group: " .. code)
	print("Channels: " .. receiverChannel .. " / " .. playerChannel)
	print("Run `music` normally when every receiver is configured.")
	return
end

local wireless_group = settings.get("music.group")
if wireless_group ~= "" then
	wireless_group = normaliseGroupCode(wireless_group)
	if not wireless_group then
		error("Invalid saved music.group. Run `music setup` again", 0)
	end
end

local wireless_pairing_key = settings.get("music.pairing_key")
local wireless_receiver_channel = settings.get("music.receiver_channel")
local wireless_player_channel = settings.get("music.player_channel")
if wireless_group ~= "" then
	wireless_pairing_key = "music-group:" .. wireless_group
	wireless_receiver_channel, wireless_player_channel = channelsForGroup(wireless_group)
end

local function validWirelessChannel(channel)
	return type(channel) == "number"
		and channel == math.floor(channel)
		and channel >= 0
		and channel <= 65535
end

if type(wireless_pairing_key) ~= "string" or wireless_pairing_key == "" then
	error("music.pairing_key must be a non-empty string", 0)
elseif not validWirelessChannel(wireless_receiver_channel)
	or not validWirelessChannel(wireless_player_channel)
	or wireless_receiver_channel == wireless_player_channel then
	error("Music wireless channels must be different whole numbers from 0 to 65535", 0)
end

-- Prefer an attached monitor for the player UI. The computer terminal remains
-- the fallback when no monitor is present.
local native_term = term.current()
local display = peripheral.find("monitor")
local display_name = display and peripheral.getName(display) or nil
if display then
	pcall(display.setTextScale, 0.5)
	term.redirect(display)
end
local width, height = term.getSize()
local tab = 1

local waiting_for_input = false
local last_search = nil
local last_search_url = nil
local search_results = nil
local search_error = false
local in_search_result = false
local clicked_result = nil

local playing = false
local queue = {}
local now_playing = nil
local looping = 0
local volume = 1.5

local playing_id = nil
local last_download_url = nil
local playing_status = 0
local is_loading = false
local is_error = false;
local error_message = nil

local player_handle = nil
local start = nil
local pcm = nil
local size = nil
local decoder = require "cc.audio.dfpwm".make_decoder()
local audio_filter_enabled = settings.get("music.audio_filter")
local audio_filter_previous = 0
local needs_next_chunk = 0
local buffer

local function reduceAudioGrain(audioBuffer)
	if not audio_filter_enabled then return audioBuffer end

	-- DFPWM is a one-bit codec. A light one-pole low-pass removes some of its
	-- high-frequency quantisation noise without making music excessively dull.
	-- Keep the previous sample between chunks so chunk boundaries remain clean.
	local previous = audio_filter_previous
	for index = 1, #audioBuffer do
		local filtered = audioBuffer[index] * 0.7 + previous * 0.3
		previous = filtered
		audioBuffer[index] = filtered >= 0
			and math.floor(filtered + 0.5)
			or math.ceil(filtered - 0.5)
	end
	audio_filter_previous = previous
	return audioBuffer
end

-- Wireless speakers use a second ComputerCraft computer running
-- wireless_receiver.lua. The shared settings above isolate systems on a
-- multiplayer server.
local wireless_protocol = "cc-streaming-music-v3"
local wireless_player_id = os.getComputerID()
local wireless_session = nil
local wireless_session_counter = 0
local wireless_sequence = 0
local previous_chunk_duration = 0
local wireless_receivers = {}

local wireless_modem = peripheral.find("modem", function(_, modem)
	return modem.isWireless()
end)

local function wirelessReceiverCount()
	local count = 0
	for _ in pairs(wireless_receivers) do
		count = count + 1
	end
	return count
end

local function wirelessJoiningCount()
	local count = 0
	for _, receiver in pairs(wireless_receivers) do
		if receiver.joining then
			count = count + 1
		end
	end
	return count
end

local function pruneWirelessReceivers()
	local now = os.epoch("utc")
	local changed = false
	for receiverId, receiver in pairs(wireless_receivers) do
		if receiver.lastSeen and now - receiver.lastSeen > 7000 then
			wireless_receivers[receiverId] = nil
			changed = true
		end
	end
	if changed then
		os.queueEvent("redraw_screen")
	end
end

local function sendWirelessDiscovery()
	if wireless_modem then
		wireless_modem.transmit(wireless_receiver_channel, wireless_player_channel, {
			protocol = wireless_protocol,
			key = wireless_pairing_key,
			type = "discover",
			playerId = wireless_player_id,
		})
	end
end

local function registerWirelessMessage(channel, message)
	if channel ~= wireless_player_channel
		or type(message) ~= "table"
		or message.protocol ~= wireless_protocol
		or message.key ~= wireless_pairing_key then
		return
	end
	if message.playerId ~= wireless_player_id or type(message.receiverId) ~= "number" then
		return
	end
	if message.type == "ready" then
		local receiver = wireless_receivers[message.receiverId]
		if not receiver or receiver.bootId ~= message.bootId then
			receiver = {
				bootId = message.bootId,
				joining = playing and wireless_sequence > 0,
			}
			wireless_receivers[message.receiverId] = receiver
		end
		receiver.lastSeen = os.epoch("utc")
		os.queueEvent("redraw_screen")
	elseif message.type == "ack" then
		local receiver = wireless_receivers[message.receiverId]
		if not receiver then
			receiver = { bootId = message.bootId, joining = false }
			wireless_receivers[message.receiverId] = receiver
		end
		receiver.lastSeen = os.epoch("utc")
		if message.session == wireless_session then
			receiver.joining = false
		end
		os.queueEvent("wireless_audio_ack", message.receiverId, message.session, message.sequence)
		os.queueEvent("redraw_screen")
	end
end

local function discoverWirelessReceivers(timeout)
	if not wireless_modem then
		return
	end

	wireless_modem.open(wireless_player_channel)
	sendWirelessDiscovery()
	local timer = os.startTimer(timeout)
	while true do
		local event = { os.pullEvent() }
		if event[1] == "timer" and event[2] == timer then
			return
		elseif event[1] == "modem_message" then
			registerWirelessMessage(event[3], event[5])
		end
	end
end

local speakers = { peripheral.find("speaker") }
local speaker_joining = {}
for _, speaker in ipairs(speakers) do
	speaker_joining[peripheral.getName(speaker)] = false
end

local function refreshSpeakers()
	local refreshed = { peripheral.find("speaker") }
	local present = {}
	for _, speaker in ipairs(refreshed) do
		local name = peripheral.getName(speaker)
		present[name] = true
		if speaker_joining[name] == nil then
			speaker_joining[name] = playing and wireless_sequence > 0
		end
	end
	for name in pairs(speaker_joining) do
		if not present[name] then
			speaker_joining[name] = nil
		end
	end
	speakers = refreshed
end

discoverWirelessReceivers(1)
if #speakers == 0 and wirelessReceiverCount() == 0 then
	error("No speakers found. Attach a speaker or start wireless_receiver.lua on a nearby computer before running music.", 0)
end

local function stopPlaybackOutputs()
	for _, speaker in ipairs(speakers) do
		speaker.stop()
	end
	if wireless_modem then
		wireless_modem.transmit(wireless_receiver_channel, wireless_player_channel, {
			protocol = wireless_protocol,
			key = wireless_pairing_key,
			type = "stop",
			playerId = wireless_player_id,
			session = wireless_session,
		})
	end
	os.queueEvent("playback_stopped")
end

local function waitForPlaybackDelay(delay)
	if type(delay) ~= "number" or delay <= 0 then
		return true
	end
	local timer = os.startTimer(delay)
	while true do
		local event, id = os.pullEvent()
		if event == "timer" and id == timer then
			return true
		elseif event == "playback_stopped" then
			return false
		end
	end
end

local function playSpeakerChunk(speaker, audioBuffer, chunkVolume, expectedPlayingId, sequence, joinDelay)
	local name = peripheral.getName(speaker)
	if speaker_joining[name] and sequence > 1 then
		if not waitForPlaybackDelay(joinDelay) then return end
	end

	while playing and playing_id == expectedPlayingId and peripheral.isPresent(name) do
		if speaker.playAudio(audioBuffer, chunkVolume) then
			speaker_joining[name] = false
			return
		end

		parallel.waitForAny(
			function()
				repeat until select(2, os.pullEvent("speaker_audio_empty")) == name
			end,
			function()
				repeat until select(2, os.pullEvent("peripheral_detach")) == name
			end,
			function()
				os.pullEvent("playback_stopped")
			end
		)
	end
end

local function sendWirelessChunk(chunk, chunkVolume, session, sequence, joinDelay, waitForAcknowledgements)
	local pending = {}
	local joining = {}
	for receiverId, receiver in pairs(wireless_receivers) do
		pending[receiverId] = true
		if receiver.joining and sequence > 1 then
			joining[receiverId] = true
		end
	end

	if next(pending) == nil then
		if #speakers == 0 then
			error("No wireless receivers available", 0)
		end
		return
	end

	local message = {
		protocol = wireless_protocol,
		key = wireless_pairing_key,
		type = "audio",
		playerId = wireless_player_id,
		session = session,
		sequence = sequence,
		volume = chunkVolume,
		chunk = chunk,
		targets = pending,
		joining = joining,
		joinDelay = joinDelay,
	}
	wireless_modem.transmit(wireless_receiver_channel, wireless_player_channel, message)
	if not waitForAcknowledgements then return end

	-- A full chunk is about 2.7 seconds of audio. Receivers acknowledge only
	-- after their speaker accepts it, which provides playback-rate flow control.
	local retries = 0
	local timer = os.startTimer(4)
	while next(pending) do
		local event, receiverId, ackSession, ackSequence = os.pullEvent()
		if event == "wireless_audio_ack" and ackSession == session and ackSequence == sequence then
			pending[receiverId] = nil
		elseif event == "timer" and receiverId == timer then
			if retries == 0 then
				retries = 1
				wireless_modem.transmit(wireless_receiver_channel, wireless_player_channel, message)
				timer = os.startTimer(4)
			else
				for missingId in pairs(pending) do
					wireless_receivers[missingId] = nil
				end
				os.queueEvent("redraw_screen")
				if #speakers == 0 then
					error("Wireless receiver timed out", 0)
				end
				return
			end
		elseif event == "playback_stopped" then
			return
		end
	end
end

local keyboard_visible = false
local keyboard_input = ""
local keyboard_keys = {}

local function clipped(text, available)
	text = tostring(text or "")
	if available <= 0 then return "" end
	if #text <= available then return text end
	if available <= 3 then return text:sub(1, available) end
	return text:sub(1, available - 3) .. "..."
end

local function writeLine(x, y, text, foreground, background)
	if y < 1 or y > height or x > width then return end
	term.setCursorPos(x, y)
	term.setTextColor(foreground or colors.white)
	term.setBackgroundColor(background or colors.black)
	term.write(clipped(text, width - x + 1))
end

local function contentBounds(maximumWidth)
	local contentWidth = math.max(1, math.min(width - 2, maximumWidth or 60))
	local left = math.floor((width - contentWidth) / 2) + 1
	return left, left + contentWidth - 1
end

local function writeCentered(y, text, foreground, background, left, right)
	left, right = left or 1, right or width
	local fitted = clipped(text, right - left + 1)
	local x = left + math.max(0, math.floor((right - left + 1 - #fitted) / 2))
	writeLine(x, y, fitted, foreground, background)
end

local function nowPlayingLayout()
	local left, right = contentBounds(60)
	local roomy = height >= 18
	local gap = 1
	local buttonWidth = math.max(4, math.floor((right - left + 1 - gap * 2) / 3))
	local buttonY1, buttonY2 = roomy and 7 or 6, roomy and 9 or 7
	local play = { x1 = left, x2 = left + buttonWidth - 1 }
	local skip = { x1 = play.x2 + gap + 1, x2 = play.x2 + gap + buttonWidth }
	local loop = { x1 = skip.x2 + gap + 1, x2 = right }
	return {
		left = left,
		right = right,
		play = play,
		skip = skip,
		loop = loop,
		buttonY1 = buttonY1,
		buttonY2 = buttonY2,
		volumeY = roomy and 11 or 9,
		statusY = roomy and 13 or 10,
		queueY = roomy and 15 or 12,
	}
end

local function drawButton(x1, y1, x2, y2, label, background, foreground)
	x1, x2 = math.max(1, x1), math.min(width, x2)
	y1, y2 = math.max(1, y1), math.min(height, y2)
	if x1 > x2 or y1 > y2 then return end
	paintutils.drawFilledBox(x1, y1, x2, y2, background)
	local labelX = x1 + math.max(0, math.floor((x2 - x1 + 1 - #label) / 2))
	local labelY = y1 + math.floor((y2 - y1) / 2)
	writeLine(labelX, labelY, label, foreground, background)
end

local function addKeyboardKey(x1, y1, x2, y2, label, action, background)
	drawButton(x1, y1, x2, y2, label, background or colors.gray, colors.white)
	table.insert(keyboard_keys, { x1 = x1, x2 = x2, y1 = y1, y2 = y2, action = action })
end

local function drawKeyboardRow(characters, y, keyHeight)
	if y > height then return end
	local keyboardLeft, keyboardRight = contentBounds(60)
	local keyWidth = math.max(2, math.min(5, math.floor((keyboardRight - keyboardLeft + 1) / #characters)))
	local totalWidth = keyWidth * #characters
	local startX = math.max(1, math.floor((width - totalWidth) / 2) + 1)
	for index = 1, #characters do
		local character = characters:sub(index, index)
		local x1 = startX + (index - 1) * keyWidth
		addKeyboardKey(x1, y, x1 + keyWidth - 1, y + keyHeight - 1, character:upper(), character)
	end
end

local function drawTouchKeyboard()
	keyboard_keys = {}
	local keyboardLeft, keyboardRight = contentBounds(60)
	writeCentered(6, "Touch to type", colors.lightGray, colors.black, keyboardLeft, keyboardRight)
	local roomy = height >= 18
	local keyHeight = roomy and 2 or 1
	local rowY = roomy and { 7, 9, 11, 13 } or { 7, 8, 9, 10 }
	drawKeyboardRow("1234567890", rowY[1], keyHeight)
	drawKeyboardRow("qwertyuiop", rowY[2], keyHeight)
	drawKeyboardRow("asdfghjkl", rowY[3], keyHeight)
	drawKeyboardRow("zxcvbnm.-_", rowY[4], keyHeight)

	local innerWidth = keyboardRight - keyboardLeft + 1
	local third = math.max(4, math.floor(innerWidth / 3))
	local specialY = roomy and 15 or 11
	local specialHeight = roomy and 2 or 1
	addKeyboardKey(keyboardLeft, specialY, keyboardLeft + third - 1, specialY + specialHeight - 1, "SPACE", "space", colors.blue)
	addKeyboardKey(keyboardLeft + third, specialY, math.min(keyboardRight, keyboardLeft + third * 2 - 1), specialY + specialHeight - 1, "BACK", "back", colors.orange)
	addKeyboardKey(keyboardLeft + third * 2, specialY, keyboardRight, specialY + specialHeight - 1, "CLEAR", "clear", colors.red)
	local actionY = roomy and 18 or 12
	local middle = math.floor((keyboardLeft + keyboardRight) / 2)
	addKeyboardKey(keyboardLeft, actionY, middle - 1, actionY + specialHeight - 1, "CANCEL", "cancel", colors.gray)
	addKeyboardKey(middle + 1, actionY, keyboardRight, actionY + specialHeight - 1, "SEARCH", "submit", colors.green)
end

local function submitSearch(input)
	input = tostring(input or ""):match("^%s*(.-)%s*$")
	if #input > 0 then
		last_search = input
		last_search_url = api_base_url .. "?v=" .. version .. "&search=" .. textutils.urlEncode(input)
		http.request(last_search_url)
		search_results = nil
		search_error = false
	else
		last_search = nil
		last_search_url = nil
		search_results = nil
		search_error = false
	end
end

local function handleKeyboardTouch(x, y)
	for _, key in ipairs(keyboard_keys) do
		if y >= key.y1 and y <= key.y2 and x >= key.x1 and x <= key.x2 then
			if key.action == "space" then
				keyboard_input = keyboard_input .. " "
			elseif key.action == "back" then
				keyboard_input = keyboard_input:sub(1, math.max(0, #keyboard_input - 1))
			elseif key.action == "clear" then
				keyboard_input = ""
			elseif key.action == "cancel" then
				keyboard_visible = false
			elseif key.action == "submit" then
				submitSearch(keyboard_input)
				keyboard_visible = false
			else
				keyboard_input = keyboard_input .. key.action
			end
			return true
		end
	end
	return false
end

function redrawScreen()
	if waiting_for_input then return end
	term.setCursorBlink(false)
	term.setBackgroundColor(colors.black)
	term.clear()

	local middle = math.floor(width / 2)
	drawButton(1, 1, middle, 1, "NOW PLAYING", tab == 1 and colors.white or colors.gray, tab == 1 and colors.black or colors.white)
	drawButton(middle + 1, 1, width, 1, "SEARCH", tab == 2 and colors.white or colors.gray, tab == 2 and colors.black or colors.white)

	if tab == 1 then drawNowPlaying() else drawSearch() end
end

function drawNowPlaying()
	local layout = nowPlayingLayout()
	if now_playing then
		writeCentered(3, now_playing.name, colors.white, colors.black, layout.left, layout.right)
		writeCentered(4, now_playing.artist, colors.lightGray, colors.black, layout.left, layout.right)
	else
		writeCentered(3, "Nothing playing", colors.lightGray, colors.black, layout.left, layout.right)
		writeCentered(4, "Open Search to choose music", colors.gray, colors.black, layout.left, layout.right)
	end

	if is_loading then
		writeCentered(5, "Loading audio...", colors.yellow, colors.black, layout.left, layout.right)
	elseif is_error then
		writeCentered(5, error_message or "Playback/network error", colors.red, colors.black, layout.left, layout.right)
	elseif playing then
		writeCentered(5, "Playing", colors.lime, colors.black, layout.left, layout.right)
	else
		writeCentered(5, "Stopped", colors.gray, colors.black, layout.left, layout.right)
	end

	drawButton(layout.play.x1, layout.buttonY1, layout.play.x2, layout.buttonY2, playing and "STOP" or "PLAY", playing and colors.red or colors.green, colors.white)
	drawButton(layout.skip.x1, layout.buttonY1, layout.skip.x2, layout.buttonY2, "SKIP", colors.orange, colors.white)
	local loopLabel = looping == 0 and "LOOP OFF" or (looping == 1 and "LOOP QUEUE" or "LOOP SONG")
	drawButton(layout.loop.x1, layout.buttonY1, layout.loop.x2, layout.buttonY2, loopLabel, looping == 0 and colors.gray or colors.blue, colors.white)

	local barStart, barEnd = layout.left, layout.right
	paintutils.drawFilledBox(barStart, layout.volumeY, barEnd, layout.volumeY, colors.gray)
	local filled = math.floor((barEnd - barStart + 1) * volume / 3 + 0.5)
	if filled > 0 then paintutils.drawFilledBox(barStart, layout.volumeY, barStart + filled - 1, layout.volumeY, colors.lightBlue) end
	local volumeLabel = "VOL " .. math.floor(100 * volume / 3 + 0.5) .. "%"
	writeCentered(layout.volumeY, volumeLabel, colors.white, filled > 0 and colors.lightBlue or colors.gray, barStart, barEnd)

	local outputStatus = #speakers .. " attached | " .. wirelessReceiverCount() .. " wireless"
	local syncing = wirelessJoiningCount()
	if syncing > 0 then outputStatus = outputStatus .. " | " .. syncing .. " syncing" end
	local defaultKeyWarning = wireless_modem and wireless_pairing_key == "music-room"
	if defaultKeyWarning then outputStatus = outputStatus .. " | default key" end
	if wireless_group ~= "" then outputStatus = outputStatus .. " | " .. wireless_group end
	writeCentered(layout.statusY, outputStatus,
		(syncing > 0 or defaultKeyWarning) and colors.yellow or colors.lightGray,
		colors.black, layout.left, layout.right)

	if #queue > 0 then
		writeCentered(layout.queueY, "UP NEXT (" .. #queue .. ")", colors.cyan, colors.black, layout.left, layout.right)
		for index = 1, #queue do
			local titleY = layout.queueY + 1 + (index - 1) * 2
			if titleY > height then break end
			writeCentered(titleY, queue[index].name, colors.white, colors.black, layout.left, layout.right)
			writeCentered(titleY + 1, queue[index].artist, colors.lightGray, colors.black, layout.left, layout.right)
		end
	end
end

function drawSearch()
	local searchLeft, searchRight = contentBounds(70)
	if in_search_result then
		term.setBackgroundColor(colors.black)
		term.clear()
		local result = search_results[clicked_result]
		writeCentered(2, result.name, colors.white, colors.black, searchLeft, searchRight)
		writeCentered(3, result.artist, colors.lightGray, colors.black, searchLeft, searchRight)
		drawButton(searchLeft, 5, searchRight, 5, "PLAY NOW", colors.green, colors.white)
		drawButton(searchLeft, 7, searchRight, 7, "PLAY NEXT", colors.blue, colors.white)
		drawButton(searchLeft, 9, searchRight, 9, "ADD TO QUEUE", colors.orange, colors.white)
		drawButton(searchLeft, 11, searchRight, 11, "CANCEL", colors.gray, colors.white)
		return
	end

	paintutils.drawFilledBox(searchLeft, 3, searchRight, 5, keyboard_visible and colors.white or colors.lightGray)
	local inputText = keyboard_visible and keyboard_input or (last_search or "Touch to search...")
	local inputWidth = searchRight - searchLeft - 3
	if keyboard_visible and #inputText > inputWidth then inputText = "..." .. inputText:sub(-math.max(1, inputWidth - 3)) end
	writeLine(searchLeft + 1, 4, inputText, colors.black, keyboard_visible and colors.white or colors.lightGray)

	if keyboard_visible then
		drawTouchKeyboard()
		return
	end

	if search_results then
		for index = 1, #search_results do
			local titleY = 7 + (index - 1) * 2
			if titleY > height then break end
			writeLine(searchLeft, titleY, search_results[index].name, colors.white)
			writeLine(searchLeft, titleY + 1, search_results[index].artist, colors.lightGray)
		end
	elseif search_error then
		writeCentered(7, "Search failed - try again", colors.red, colors.black, searchLeft, searchRight)
	elseif last_search_url then
		writeCentered(7, "Searching...", colors.yellow, colors.black, searchLeft, searchRight)
	else
		writeCentered(7, display_name and "Touch the box to open the keyboard" or "Click the box, then type your search", colors.lightGray, colors.black, searchLeft, searchRight)
		writeCentered(8, "YouTube links also work", colors.gray, colors.black, searchLeft, searchRight)
	end
end

local function pullPointerClick()
	while true do
		local event, first, second, third = os.pullEvent()
		if event == "monitor_touch" and display_name and first == display_name then
			return event, 1, second, third
		elseif event == "mouse_click" and not display_name then
			return event, first, second, third
		end
	end
end

function uiLoop()
	redrawScreen()

	while true do
		if waiting_for_input then
			parallel.waitForAny(
				function()
					term.setCursorPos(3,4)
					term.setBackgroundColor(colors.white)
					term.setTextColor(colors.black)
					local input = read()
					submitSearch(input)
					waiting_for_input = false
					os.queueEvent("redraw_screen")
				end,
				function()
					while waiting_for_input do
						local event, button, x, y = pullPointerClick()
						if y < 3 or y > 5 or x < 2 or x > width-1 then
							waiting_for_input = false
							os.queueEvent("redraw_screen")
							break
						end
					end
				end
			)
		else
			parallel.waitForAny(
				function()
					local event, button, x, y = pullPointerClick()

					if button == 1 then
						if keyboard_visible then
							if y == 1 then
								keyboard_visible = false
								tab = x <= math.floor(width / 2) and 1 or 2
							else
								handleKeyboardTouch(x, y)
							end
							redrawScreen()
							return
						end

						-- Tabs
						if in_search_result == false then
							if y == 1 then
								if x < width/2 then
									tab = 1
								else
									tab = 2
								end
								redrawScreen()
							end
						end
						
						if tab == 2 and in_search_result == false then
							local searchLeft, searchRight = contentBounds(70)
							-- Search box click
							if y >= 3 and y <= 5 and x >= searchLeft and x <= searchRight then
								if display_name then
									keyboard_input = last_search or ""
									keyboard_visible = true
									redrawScreen()
								else
									paintutils.drawFilledBox(2,3,width-1,5,colors.white)
									term.setBackgroundColor(colors.white)
									waiting_for_input = true
								end
							end
		
							-- Search result click
							if search_results then
								for i=1,#search_results do
									if y == 7 + (i-1)*2 or y == 8 + (i-1)*2 then
										term.setBackgroundColor(colors.white)
										term.setTextColor(colors.black)
										term.setCursorPos(2,7 + (i-1)*2)
										term.clearLine()
										term.write(search_results[i].name)
										term.setTextColor(colors.gray)
										term.setCursorPos(2,8 + (i-1)*2)
										term.clearLine()
										term.write(search_results[i].artist)
										sleep(0.2)
										in_search_result = true
										clicked_result = i
										redrawScreen()
									end
								end
							end
						elseif tab == 2 and in_search_result == true then
							-- Search result menu clicks
		
							term.setBackgroundColor(colors.white)
							term.setTextColor(colors.black)
		
							if y == 5 then
								term.setCursorPos(2,5)
								term.clearLine()
								term.write("Play now")
								sleep(0.2)
								in_search_result = false
								stopPlaybackOutputs()
								playing = true
								is_error = false
								playing_id = nil
								if search_results[clicked_result].type == "playlist" then
									now_playing = search_results[clicked_result].playlist_items[1]
									queue = {}
									if #search_results[clicked_result].playlist_items > 1 then
										for i=2, #search_results[clicked_result].playlist_items do
											table.insert(queue, search_results[clicked_result].playlist_items[i])
										end
									end
								else
									now_playing = search_results[clicked_result]
								end
								os.queueEvent("audio_update")
							end
		
							if y == 7 then
								term.setCursorPos(2,7)
								term.clearLine()
								term.write("Play next")
								sleep(0.2)
								in_search_result = false
								if search_results[clicked_result].type == "playlist" then
									for i = #search_results[clicked_result].playlist_items, 1, -1 do
										table.insert(queue, 1, search_results[clicked_result].playlist_items[i])
									end
								else
									table.insert(queue, 1, search_results[clicked_result])
								end
								os.queueEvent("audio_update")
							end
		
							if y == 9 then
								term.setCursorPos(2,9)
								term.clearLine()
								term.write("Add to queue")
								sleep(0.2)
								in_search_result = false
								if search_results[clicked_result].type == "playlist" then
									for i = 1, #search_results[clicked_result].playlist_items do
										table.insert(queue, search_results[clicked_result].playlist_items[i])
									end
								else
									table.insert(queue, search_results[clicked_result])
								end
								os.queueEvent("audio_update")
							end
		
							if y == 11 then
								term.setCursorPos(2,11)
								term.clearLine()
								term.write("Cancel")
								sleep(0.2)
								in_search_result = false
							end
		
							redrawScreen()
						elseif tab == 1 and in_search_result == false then
							-- Now playing tab clicks
							local layout = nowPlayingLayout()

							if y >= layout.buttonY1 and y <= layout.buttonY2 then
								-- Play/stop button
								if x >= layout.play.x1 and x <= layout.play.x2 then
									if playing then
										playing = false
										stopPlaybackOutputs()
										playing_id = nil
										is_loading = false
										is_error = false
										os.queueEvent("audio_update")
									elseif now_playing ~= nil then
										playing_id = nil
										playing = true
										is_error = false
										os.queueEvent("audio_update")
									elseif #queue > 0 then
										now_playing = queue[1]
										table.remove(queue, 1)
										playing_id = nil
										playing = true
										is_error = false
										os.queueEvent("audio_update")
									end
								end
		
								-- Skip button
								if x >= layout.skip.x1 and x <= layout.skip.x2 then
									if now_playing ~= nil or #queue > 0 then
										is_error = false
										if playing then
											stopPlaybackOutputs()
										end
										if #queue > 0 then
											if looping == 1 then
												table.insert(queue, now_playing)
											end
											now_playing = queue[1]
											table.remove(queue, 1)
											playing_id = nil
										else
											now_playing = nil
											playing = false
											is_loading = false
											is_error = false
											playing_id = nil
										end
										os.queueEvent("audio_update")
									end
								end
		
								-- Loop button
								if x >= layout.loop.x1 and x <= layout.loop.x2 then
									if looping == 0 then
										looping = 1
									elseif looping == 1 then
										looping = 2
									else
										looping = 0
									end
								end
							end

							if y == layout.volumeY then
								-- Volume slider
								if x >= layout.left and x <= layout.right then
									volume = math.max(0, math.min(3, (x - layout.left) / math.max(1, layout.right - layout.left) * 3))

									-- for _, speaker in ipairs(speakers) do
									-- 	speaker.stop()
									-- 	os.queueEvent("playback_stopped")
									-- end
									-- playing_id = nil
									-- os.queueEvent("audio_update")
								end
							end

							redrawScreen()
						end
					end
				end,
				function()
					local event, button, x, y = os.pullEvent("mouse_drag")

					if button == 1 then

						if tab == 1 and in_search_result == false then
							local layout = nowPlayingLayout()
							if y >= layout.volumeY - 1 and y <= layout.volumeY + 1 then
								-- Volume slider
								if x >= layout.left and x <= layout.right then
									volume = math.max(0, math.min(3, (x - layout.left) / math.max(1, layout.right - layout.left) * 3))

									-- for _, speaker in ipairs(speakers) do
									-- 	speaker.stop()
									-- 	os.queueEvent("playback_stopped")
									-- end
									-- playing_id = nil
									-- os.queueEvent("audio_update")
								end
							end

							redrawScreen()
						end
					end
				end,
				function()
					local event = os.pullEvent("redraw_screen")

					redrawScreen()
				end
			)
		end
	end
end

function audioLoop()
	while true do

		-- AUDIO
		if playing and now_playing then
			local thisnowplayingid = now_playing.id
			if playing_id ~= thisnowplayingid then
				playing_id = thisnowplayingid
				wireless_session_counter = wireless_session_counter + 1
				wireless_session = tostring(wireless_player_id) .. ":" .. tostring(os.epoch("utc")) .. ":" .. tostring(wireless_session_counter)
				wireless_sequence = 0
				previous_chunk_duration = 0
				error_message = nil
				decoder = require "cc.audio.dfpwm".make_decoder()
				audio_filter_previous = 0
				last_download_url = api_base_url .. "?v=" .. version .. "&id=" .. textutils.urlEncode(playing_id)
				playing_status = 0
				needs_next_chunk = 1

				http.request({url = last_download_url, binary = true})
				is_loading = true

				os.queueEvent("redraw_screen")
				os.queueEvent("audio_update")
			elseif playing_status == 1 and needs_next_chunk == 1 then

				while true do
					local chunk = player_handle.read(size)
					if not chunk then
						if looping == 2 or (looping == 1 and #queue == 0) then
							playing_id = nil
						elseif looping == 1 and #queue > 0 then
							table.insert(queue, now_playing)
							now_playing = queue[1]
							table.remove(queue, 1)
							playing_id = nil
						else
							if #queue > 0 then
								now_playing = queue[1]
								table.remove(queue, 1)
								playing_id = nil
							else
								now_playing = nil
								playing = false
								playing_id = nil
								is_loading = false
								is_error = false
							end
						end

						os.queueEvent("redraw_screen")

						player_handle.close()
						needs_next_chunk = 0
						break
					else
						if start then
							chunk, start = start .. chunk, nil
							size = size + 4
						end
						if #speakers == 0 and wirelessReceiverCount() == 0 then
							needs_next_chunk = 2
							is_error = true
							error_message = "All audio outputs disconnected"
							break
						end

						wireless_sequence = wireless_sequence + 1
						local thisSequence = wireless_sequence
						local joinDelay = previous_chunk_duration
						local thisChunkDuration = #chunk * 8 / 48000

						buffer = reduceAudioGrain(decoder(chunk))
						
						local fn = {}
						for _, speaker in ipairs(speakers) do
							local thisSpeaker = speaker
							table.insert(fn, function()
								playSpeakerChunk(thisSpeaker, buffer, volume, thisnowplayingid, thisSequence, joinDelay)
							end)
						end

						if wireless_modem and wirelessReceiverCount() > 0 then
							local waitForWireless = #speakers == 0
							table.insert(fn, function()
								sendWirelessChunk(chunk, volume, wireless_session, thisSequence, joinDelay, waitForWireless)
							end)
						end
						
						local ok, err = pcall(parallel.waitForAll, table.unpack(fn))
						if not ok then
							needs_next_chunk = 2
							is_error = true
							error_message = tostring(err)
							break
						end
						
						-- If we're not playing anymore, exit the chunk processing loop
						if not playing or playing_id ~= thisnowplayingid then
							break
						end
						previous_chunk_duration = thisChunkDuration
					end
				end
				os.queueEvent("audio_update")
			end
		end

		os.pullEvent("audio_update")
	end
end

function httpLoop()
	while true do
		parallel.waitForAny(
			function()
				local event, url, handle = os.pullEvent("http_success")

				if url == last_search_url then
					search_results = textutils.unserialiseJSON(handle.readAll())
					os.queueEvent("redraw_screen")
				end
				if url == last_download_url then
					is_loading = false
					player_handle = handle
					start = handle.read(4)
					size = 16 * 1024 - 4
					playing_status = 1
					os.queueEvent("redraw_screen")
					os.queueEvent("audio_update")
				end
			end,
			function()
				local event, url = os.pullEvent("http_failure")	

				if url == last_search_url then
					search_error = true
					os.queueEvent("redraw_screen")
				end
				if url == last_download_url then
					is_loading = false
					is_error = true
					error_message = "Audio download failed"
					playing = false
					playing_id = nil
					os.queueEvent("redraw_screen")
					os.queueEvent("audio_update")
				end
			end
		)
	end
end

function wirelessLoop()
	if not wireless_modem then
		while true do
			os.pullEvent()
		end
	end

	local discoveryTimer = os.startTimer(3)
	while true do
		local event = { os.pullEvent() }
		if event[1] == "modem_message" then
			registerWirelessMessage(event[3], event[5])
		elseif event[1] == "timer" and event[2] == discoveryTimer then
			pruneWirelessReceivers()
			sendWirelessDiscovery()
			discoveryTimer = os.startTimer(3)
		end
	end
end

function displayLoop()
	while true do
		local event, side = os.pullEvent()
		local changed = false
		if event == "monitor_resize" and side == display_name then
			changed = true
		elseif event == "term_resize" and not display_name then
			changed = true
		elseif event == "peripheral_detach" and side == display_name then
			term.redirect(native_term)
			display = nil
			display_name = nil
			changed = true
		elseif event == "peripheral" and not display_name and peripheral.getType(side) == "monitor" then
			display = peripheral.wrap(side)
			display_name = side
			pcall(display.setTextScale, 0.5)
			term.redirect(display)
			changed = true
		end
		if event == "peripheral" or event == "peripheral_detach" then
			refreshSpeakers()
			changed = true
		end

		if changed then
			width, height = term.getSize()
			os.queueEvent("redraw_screen")
		end
	end
end

local ok, runtimeError = pcall(function()
	parallel.waitForAny(uiLoop, audioLoop, httpLoop, wirelessLoop, displayLoop)
end)

-- Always release speakers, the modem channel and the redirected monitor when
-- the user terminates the program or an unexpected error occurs.
pcall(stopPlaybackOutputs)
if wireless_modem then
	pcall(wireless_modem.close, wireless_player_channel)
end
term.redirect(native_term)
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)

if not ok and tostring(runtimeError) ~= "Terminated" then
	error(runtimeError, 0)
end
