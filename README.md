# Streaming music in Minecraft (ComputerCraft CC: Tweaked mod)

**Version:** 2.9

> This project is a derivative of [terreng/computercraft-streaming-music](https://github.com/terreng/computercraft-streaming-music), originally created by Terren Gurule. It retains the original MIT license. This version adds wireless receiver groups, synchronized local and remote speakers, a touch-monitor UI, multiplayer setup, reliability improvements, and audio filtering.

For complete installation, multiplayer-group, monitor, startup, audio-quality, and troubleshooting instructions, see [SETUP_GUIDE.md](SETUP_GUIDE.md).

**Install:** Transfer the repository's current `music.lua` to the main computer. The old Pastebin copy does not include the wireless, synchronized-speaker, monitor, or touch-keyboard changes.

**Run:** `music`

## How to use

1. Install the [CC: Tweaked](https://tweaked.cc/) mod to your world/server. Make sure you're using version 1.100.0 of the mod (released December 2021) or newer, or it won't work.
2. Craft an Advanced Computer and connect it to a speaker, or craft an Advanced Noisy Pocket Computer.
3. Open the computer and then drag and drop the `music.lua` script on top of the Minecraft window to transfer the file over.
4. Run the `music` command and enjoy your music!

## Wireless speakers

CC: Tweaked speakers cannot receive wireless messages by themselves, so each remote speaker location needs a ComputerCraft computer to act as its receiver. A basic computer is enough.

### Main music computer

1. Attach a wireless modem to the computer that runs `music.lua`.
2. Transfer `music.lua` to it as normal.

### Receiver computer

1. Attach a wireless modem and at least one speaker to a basic or advanced computer.
2. Transfer `wireless_receiver.lua` to that computer and save it with that name.
3. Run `wireless_receiver` and leave it running.
4. Start `music` on the main computer. It discovers running receivers automatically.

Multiple receivers are supported. You can start another receiver while a song is already playing; the main computer discovers it within about three seconds, buffers it, and brings it into sync automatically. Local speakers attached directly to the main computer and speakers connected through a wired peripheral network work at the same time. Speakers and receivers added while music is playing are synchronized before joining playback.

When attached and wireless outputs are mixed, attached speakers pace their own buffers independently and wireless acknowledgements run in the background. A slow or briefly interrupted wireless receiver therefore cannot drain the attached speakers' buffers and make every output cut out. Wireless-only playback continues to use acknowledgements as its playback clock.

Receivers also keep a short packet backlog while waiting for their speaker buffers. This prevents the next chunk from being consumed and lost when local and wireless speakers become ready a fraction of a second apart.

For wireless-only startup, start at least one receiver before the main music program. Both computers must be within wireless-modem range and in loaded chunks.

### Multiplayer setup

Each player can create a personal speaker group with one short code. On that player's **main computer**, run:

```text
music setup devan
```

On **every receiver computer** that should belong to that player, run the same code:

```text
wireless_receiver setup devan
```

Then start `wireless_receiver` normally on the receivers and `music` normally on the main computer. You can leave the code off either setup command to be prompted for it. Codes are converted to lowercase and may contain 3-24 letters, numbers, underscores, or hyphens.

The code automatically creates a matching traffic tag and channel pair, so players do not need to choose three separate settings. The active group name appears on the main dashboard and receiver status screen. To move a receiver to another player's group, run its setup command again with the new code.

The group separates normal nearby music systems, but it is not encrypted authentication. Another player who deliberately inspects ComputerCraft modem traffic or copies the code can imitate the group. Use server claims or physical access controls if deliberate tampering is a concern.

#### Advanced manual configuration

The earlier manual settings still work when no automatic group is selected. Clear an automatic group with `music setup reset` or `wireless_receiver setup reset`, then configure the same values on the relevant computers:

```text
set music.pairing_key my-private-music-room
set music.receiver_channel 43120
set music.player_channel 43121
```

Use different whole numbers from `0` to `65535`, and do not use the same number for both settings. Restart the programs after changing settings. You no longer need to edit either Lua file to change channels.

A receiver stays with its active main computer while audio is arriving. If that main disappears, another correctly paired main can take over after 15 seconds. This stops two players using the same room settings from repeatedly interrupting one another.

The manual defaults are channels `42420` and `42421`. Version 2.9 continues to use wireless protocol v3. Update `music.lua` and `wireless_receiver.lua` together before using automatic groups.

## External monitor controls

Attach a monitor directly to the main computer or through a wired peripheral network before starting `music`. The player automatically uses the monitor, selects the smallest text scale, and provides large touch controls for tabs, playback, skipping, loop mode, search results, and volume. If the monitor is attached or removed while the program is running, the UI switches displays automatically.

The Now Playing dashboard is centered and capped at a readable width on large displays. A 3-block-wide by 2-block-high monitor gets taller playback buttons, a centered song display and queue, and larger two-row keyboard keys instead of controls being stretched across the full screen.

Touch the search box to open the on-screen keyboard. It provides letters, numbers, common punctuation, Space, Back, Clear, Cancel, and Search, so monitor searches do not require the main computer's keyboard. The normal keyboard remains available when using the computer terminal without a monitor.

The Now Playing screen shows the number of local/wired and wireless speakers. A newly discovered wireless receiver is labelled as syncing until it joins the current audio stream.

## Troubleshooting
- "No speakers found" when using wireless mode: Start `wireless_receiver.lua` first, and check that both wireless modems are attached and within range.
- A receiver is not discovered after updating: Run `music setup your-code` on the main and `wireless_receiver setup your-code` on the receiver, using exactly the same code, then restart both programs. Protocol v3 receivers are not compatible with older v2 main programs.
- Another main computer cannot take over a receiver: Stop the active main cleanly, or wait 15 seconds after its last audio packet.
- "No speakers found" when using an Advanced Noisy Pocket Computer: Restart your Minecraft game. If that doesn't work, restart the server.
- "Module 'cc.audio.dfpwm' not found" error: Make sure you're using version 1.100.0 or newer of the CC: Tweaked mod (December 2021 or later). New audio features were added in this version, so it won't work in 1.99.X or below.
- Grainy or hissy audio: Version 2.9 enables a gentle DFPWM de-grain filter. Install the current main and receiver files. If it sounds too dull, run `set music.audio_filter false` on that computer and restart the program.

## How to self-host

> [!IMPORTANT]  
> Self-hosting is not required to use this program. Transfer the current Lua files from this repository to use the enhanced player.

The ComputerCraft program connects to a web server to download the music files. This server is hosted with Firebase Cloud Functions. The server uses two unofficial APIs on RapidAPI: one for searching YouTube and one for downloading the audio.

1. Download this repository to your computer into a folder.
2. Create an account for RapidAPI and sign up for the free tier of both of these APIs:
   - "YT-API" (used for search): [https://rapidapi.com/ytjar/api/yt-api](https://rapidapi.com/ytjar/api/yt-api)
   - "YouTube MP3" (used for downloading): [https://rapidapi.com/ytjar/api/youtube-mp36](https://rapidapi.com/ytjar/api/youtube-mp36)
3. If you sign up for both APIs on the same account, you will have a single RapidAPI key. Copy and paste it into the file `functions/index.js` where it says "YOUR API KEY HERE". Leave the quotes.
4. Paste your RapidAPI username into `functions/index.js` where it says "YOUR RAPIDAPI USERNAME HERE". Leave the quotes.
5. Sign up for Firebase and make a new project at [https://firebase.google.com/](https://firebase.google.com/). A billing account is required even for the free plan. The limits of the free plan should be plenty for most people.
6. Install Node.js version 20 from [https://nodejs.org/en/download/](https://nodejs.org/en/download/).
7. In your terminal, run `npm install -g firebase-tools` to install Firebase.
8. In your terminal, navigate inside the project folder. Run `firebase login` and follow the steps.
9. Run `firebase init functions` and follow the steps. Choose JavaScript. Don't choose to overwrite the `functions/index.js` or `functions/package.json` files when it asks you. Install the dependencies when prompted.
10. Run `cd functions` to go inside the `functions` directory and then run `npm install` to install more dependencies.
11. Run `cd ..` to go back and then run `firebase deploy` to deploy your new Cloud Function.
12. After the deployment is complete it will give you the Function URL. Copy that URL into the first line of `music.lua`.
