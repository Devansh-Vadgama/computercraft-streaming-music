-- Wireless receiver for music.lua
-- Attach a wireless modem and one or more speakers, then run this program
-- before starting music.lua on the main computer.

local arguments = { ... }

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
	print("Now run `wireless_receiver` normally.")
	return
end

local protocol = "cc-streaming-music-v3"
local wireless_group = settings.get("music.group")
if wireless_group ~= "" then
	wireless_group = normaliseGroupCode(wireless_group)
	if not wireless_group then
		error("Invalid saved music.group. Run `wireless_receiver setup` again", 0)
	end
end

local pairing_key = settings.get("music.pairing_key")
local receiver_channel = settings.get("music.receiver_channel")
local player_channel = settings.get("music.player_channel")
if wireless_group ~= "" then
	pairing_key = "music-group:" .. wireless_group
	receiver_channel, player_channel = channelsForGroup(wireless_group)
end

local function validChannel(channel)
	return type(channel) == "number"
		and channel == math.floor(channel)
		and channel >= 0
		and channel <= 65535
end

if type(pairing_key) ~= "string" or pairing_key == "" then
	error("music.pairing_key must be a non-empty string", 0)
elseif not validChannel(receiver_channel)
	or not validChannel(player_channel)
	or receiver_channel == player_channel then
	error("Music wireless channels must be different whole numbers from 0 to 65535", 0)
end

local modem = peripheral.find("modem", function(_, wrapped)
	return wrapped.isWireless()
end)
if not modem then
	error("No wireless modem attached", 0)
end

local speakers = { peripheral.find("speaker") }
if #speakers == 0 then
	error("No speakers attached", 0)
end

modem.open(receiver_channel)

local receiver_id = os.getComputerID()
local receiver_boot_id = tostring(receiver_id) .. ":" .. tostring(os.epoch("utc"))
local decoder = require("cc.audio.dfpwm").make_decoder()
local audio_filter_enabled = settings.get("music.audio_filter")
local audio_filter_previous = 0
local active_player_id = nil
local active_session = nil
local last_sequence = nil
local last_player_activity = 0
local deferred_messages = {}

local function writeStatus(message, colour)
	local width = select(1, term.getSize())
	term.setCursorPos(1, 5)
	term.setBackgroundColor(colors.black)
	term.setTextColor(colour or colors.lightGray)
	term.clearLine()
	term.write(tostring(message):sub(1, width))
	term.setTextColor(colors.white)
end

local function stopSpeakers()
	for _, speaker in ipairs(speakers) do
		speaker.stop()
	end
end

local function reduceAudioGrain(audioBuffer)
	if not audio_filter_enabled then return audioBuffer end

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

local function resetPlayback(playerId, session)
	stopSpeakers()
	decoder = require("cc.audio.dfpwm").make_decoder()
	audio_filter_previous = 0
	active_player_id = playerId
	active_session = session
	last_sequence = nil
	last_player_activity = playerId and os.epoch("utc") or 0
	if playerId == nil then
		deferred_messages = {}
	end
end

local function reply(_, message)
	message.protocol = protocol
	message.key = pairing_key
	message.receiverId = receiver_id
	message.bootId = receiver_boot_id
	-- Always answer on the configured channel. Do not trust a channel supplied
	-- by another computer on a multiplayer server.
	modem.transmit(player_channel, receiver_channel, message)
end

local function isMessage(message)
	return type(message) == "table"
		and message.protocol == protocol
		and message.key == pairing_key
end

local function handleControlMessage(channel, replyChannel, message)
	if channel ~= receiver_channel or not isMessage(message) then
		return false
	end

	if message.type == "discover" and type(message.playerId) == "number" then
		reply(replyChannel, {
			type = "ready",
			playerId = message.playerId,
		})
		return false
	elseif message.type == "stop"
		and message.playerId == active_player_id
		and (message.session == nil or message.session == active_session) then
		resetPlayback(nil, nil)
		writeStatus("Stopped - waiting for music", colors.orange)
		return true
	end

	return false
end

local function handleMessageWhileWaiting(event)
	if handleControlMessage(event[3], event[4], event[5]) then
		return false
	end

	-- With attached and wireless speakers mixed together, the main computer
	-- keeps its local outputs moving without waiting for a wireless ACK. Keep a
	-- few early audio packets instead of accidentally consuming and losing them
	-- while this receiver waits for its own speaker buffer.
	local message = event[5]
	if event[3] == receiver_channel
		and isMessage(message)
		and message.type == "audio"
		and #deferred_messages < 8 then
		table.insert(deferred_messages, { event[2], event[3], event[4], message })
	end
	return true
end

local function waitUntilAccepted(speaker, buffer, volume)
	while not speaker.playAudio(buffer, volume) do
		local event = { os.pullEvent() }
		if event[1] == "modem_message" then
			if not handleMessageWhileWaiting(event) then
				return false
			end
		end
	end
	return true
end

local function waitForJoinDelay(delay)
	if type(delay) ~= "number" or delay <= 0 then
		return true
	end

	local timer = os.startTimer(delay)
	while true do
		local event = { os.pullEvent() }
		if event[1] == "timer" and event[2] == timer then
			return true
		elseif event[1] == "modem_message" then
			if not handleMessageWhileWaiting(event) then
				return false
			end
		end
	end
end

term.clear()
term.setCursorPos(1, 1)
print("Wireless music receiver")
print("Computer #" .. receiver_id)
print("Speakers: " .. #speakers)
print("Group: " .. (wireless_group ~= "" and wireless_group or "manual") .. " (" .. receiver_channel .. ")")
writeStatus(pairing_key == "music-room" and "Waiting (default key)" or "Waiting for music...",
	pairing_key == "music-room" and colors.yellow or colors.lightGray)

local function receiverLoop()
	while true do
		local side, channel, replyChannel, message
		if #deferred_messages > 0 then
			local deferred = table.remove(deferred_messages, 1)
			side, channel, replyChannel, message = table.unpack(deferred)
		else
			local event
			event, side, channel, replyChannel, message = os.pullEvent("modem_message")
		end
		if channel == receiver_channel and isMessage(message) then
			if message.type == "discover" and type(message.playerId) == "number" then
				writeStatus("Paired with player #" .. message.playerId, colors.lime)
				reply(replyChannel, {
					type = "ready",
					playerId = message.playerId,
				})
			elseif message.type == "stop" then
				handleControlMessage(channel, replyChannel, message)
			elseif message.type == "audio"
				and type(message.playerId) == "number"
				and type(message.chunk) == "string"
				and #message.chunk > 0
				and #message.chunk <= 16384
				and type(message.sequence) == "number"
				and message.sequence == math.floor(message.sequence)
				and message.sequence > 0
				and type(message.session) == "string"
				and #message.session > 0
				and #message.session <= 128
				and type(message.targets) == "table"
				and message.targets[receiver_id] then

				local now = os.epoch("utc")
				local playerAvailable = active_player_id == nil
					or active_player_id == message.playerId
					or now - last_player_activity > 15000
				if playerAvailable then
					if message.playerId ~= active_player_id or message.session ~= active_session then
						resetPlayback(message.playerId, message.session)
						writeStatus("Playing from player #" .. message.playerId, colors.lime)
					end
					last_player_activity = now

					-- If an acknowledgement was repeated or delayed, acknowledge the
					-- duplicate without playing the same chunk twice.
					if last_sequence ~= nil and message.sequence <= last_sequence then
						reply(replyChannel, {
							type = "ack",
							playerId = message.playerId,
							session = message.session,
							sequence = message.sequence,
						})
					else
						local buffer = reduceAudioGrain(decoder(message.chunk))
						local packetVolume = type(message.volume) == "number"
							and math.max(0, math.min(3, message.volume)) or 1.5
						local accepted = type(message.joining) ~= "table"
							or not message.joining[receiver_id]
							or waitForJoinDelay(message.joinDelay)
						if accepted then
							for _, speaker in ipairs(speakers) do
								if not waitUntilAccepted(speaker, buffer, packetVolume) then
									accepted = false
									break
								end
							end
						end

						if accepted then
							last_sequence = message.sequence
							reply(replyChannel, {
								type = "ack",
								playerId = message.playerId,
								session = message.session,
								sequence = message.sequence,
							})
						end
					end
				end
			end
		end
	end
end

local ok, runtimeError = pcall(receiverLoop)
stopSpeakers()
pcall(modem.close, receiver_channel)
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)

if not ok and tostring(runtimeError) ~= "Terminated" then
	error(runtimeError, 0)
end
