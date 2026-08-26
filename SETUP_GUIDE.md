# ComputerCraft Streaming Music — Full Setup Guide

This guide covers the main player, directly attached speakers, wireless speaker receivers, use with or without an external monitor, and separate multiplayer speaker groups.

This enhanced version is based on [Terren Gurule's original ComputerCraft Streaming Music project](https://github.com/terreng/computercraft-streaming-music) and keeps its MIT license.

## 1. Requirements

### Main music computer

- One Advanced Computer
- One wireless modem for wireless speakers
- `music.lua`
- Optional 3×2 advanced monitor
- Optional directly attached speakers
- Internet access enabled for ComputerCraft

### Each wireless speaker location

- One Basic or Advanced Computer
- One wireless modem
- At least one speaker
- `wireless_receiver.lua`

A speaker cannot receive modem messages by itself. Every wireless speaker location needs a receiver computer.

## 2. Remove old program copies

On the main ComputerCraft computer, run:

```text
delete music
```

On every receiver computer, run:

```text
delete wireless_receiver
```

This only removes the old copy from that Minecraft computer. It does not remove files from your real computer.

## 3. Transfer the current files

Drag the files from your real computer onto the Minecraft window while the appropriate ComputerCraft terminal is open:

- Transfer `music.lua` to the main computer.
- Transfer `wireless_receiver.lua` to every receiver.

Keep those exact filenames. Do not install the old Pastebin version because it does not include the wireless, synchronization, group, monitor, or audio-quality improvements.

## 4. Build the main system

1. Place the Advanced Computer.
2. Attach a wireless modem to one side.
3. Optionally attach one or more speakers directly or through a wired peripheral network.
4. Optionally connect a 3-block-wide by 2-block-high advanced monitor.

The program automatically finds attached monitors and speakers when it starts. It also notices peripherals added or removed while running.

### Wired peripheral speakers

For speakers on a wired network:

1. Connect network cable to the main computer.
2. Place a wired modem next to each speaker.
3. Activate each wired modem so its attached speaker appears on the network.
4. Connect all network cables together.

## 5. Build each wireless receiver

1. Place a Basic or Advanced Computer at the speaker location.
2. Attach a wireless modem.
3. Attach one or more speakers.
4. Transfer `wireless_receiver.lua` to it.

Both computers must be within modem range, and their Minecraft chunks must remain loaded.

## 6. Create a personal multiplayer speaker group

Choose a group code containing 3–24 letters, numbers, underscores, or hyphens. For example:

```text
devan
devan-home
player_1
```

On that player's main computer, run:

```text
music setup devan
```

On every receiver belonging to that player, run the matching command:

```text
wireless_receiver setup devan
```

The code is saved and automatically generates a matching traffic tag and channel pair. You do not need to configure three separate wireless settings.

To move a receiver to another group, run its setup command again with the new group's code.

Group separation prevents normal accidental interference. It is not encrypted authentication, so use server claims or physical access controls if deliberate tampering is a concern.

## 7. Start the music system

Start every receiver first:

```text
wireless_receiver
```

Its screen displays its computer ID, speaker count, group, channel, and current connection state.

After the receivers are waiting, start the main player:

```text
music
```

Matching receivers should be discovered automatically. The main UI displays attached, wireless, and synchronizing output counts.

## 8. Use with or without a monitor

An external monitor is optional. If none is attached, `music` uses the main computer's own terminal and shows the available keyboard shortcuts along its bottom edge.

Terminal controls:

- `S`: search, then type a query and press Enter
- `1`–`9`: open a numbered search result
- `P`: play or stop; on a selected result, play it now
- `N`: skip; on a selected result, play it next
- `A`: add the selected result to the queue
- `B`: go back
- `L`: change loop mode
- `-` / `+`: lower or raise the volume

The computer terminal can also be clicked when using an Advanced Computer.

### Optional monitor UI

The monitor provides touch controls for:

- Search and search results
- Play and pause
- Next song
- Loop mode
- Queue
- Volume
- An on-screen search keyboard

A standard ComputerCraft monitor does not accept a physical keyboard directly. Use the on-screen keyboard after starting `music`, or enter setup commands through the main computer's own terminal. Attaching or removing a monitor while `music` is running switches the interface automatically.

## 9. Add a receiver while music is playing

1. Build and connect the new receiver.
2. Transfer `wireless_receiver.lua`.
3. Configure the same group code.
4. Run `wireless_receiver`.

The main computer discovers it within about three seconds. The UI shows `syncing` until it joins the current audio stream.

## 10. Audio-quality setting

The de-grain filter is enabled by default on both programs. It gently removes some DFPWM hiss while preserving filter state between chunks.

If the result sounds too soft or dull, disable it on the relevant computer:

```text
set music.audio_filter false
```

Restart the program afterward. Re-enable it with:

```text
set music.audio_filter true
```

For consistent sound, use the same value on the main computer and all receivers. Some grain will always remain because DFPWM is a one-bit audio format and ComputerCraft speakers process the decoded audio again.

## 11. Automatically start receivers

Run:

```text
edit startup.lua
```

Add:

```lua
shell.run("wireless_receiver")
```

Save with `Ctrl+S` and exit with `Ctrl+E`. If `startup.lua` already contains other commands, add the line without removing the existing content.

## 12. Change or reset a group

Change the main computer's group:

```text
music setup new-group
```

Change each receiver:

```text
wireless_receiver setup new-group
```

To return to advanced manual pairing and channel settings:

```text
music setup reset
wireless_receiver setup reset
```

## 13. Troubleshooting

### `No speakers found`

- Start at least one wireless receiver before `music`, or attach a local speaker.
- Confirm both programs use the same group code.
- Check that both wireless modems are attached and within range.
- Keep both locations in loaded chunks.

### Receiver is not discovered

Configure both sides again with the same code, then restart them:

```text
music setup devan
wireless_receiver setup devan
```

Update `music.lua` and `wireless_receiver.lua` together. Old protocol-v2 copies cannot communicate with current protocol-v3 copies.

### Audio cuts out

- Install the latest copies of both Lua files.
- Confirm the server is not heavily lagging.
- Keep receiver chunks loaded and modems within range.
- Check that a modem or speaker is not being removed during playback.

### Audio sounds grainy

- Keep `music.audio_filter` enabled.
- Try a high-quality official or music-channel source instead of a heavily compressed upload.
- Avoid placing several slightly unsynchronized speaker groups within hearing distance.
- Some noise is an unavoidable limitation of ComputerCraft's DFPWM and speaker playback formats.

### Another main cannot take over immediately

Stop the active main cleanly or wait approximately 15 seconds after its last audio packet.
