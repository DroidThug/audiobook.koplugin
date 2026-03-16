<h1 align="center">
  Audiobook Read-Along Plugin for KOReader
</h1>

<h3 align="center">

![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue)
![Platform](https://img.shields.io/badge/platform-Kobo%20%7C%20Kindle%20%7C%20Android%20%7C%20Linux-blue)
![TTS](https://img.shields.io/badge/TTS-Piper%20%7C%20espeak--ng-green)

</h3>

<h4 align="center">
  Consider supporting:<br><br>
  <a href="https://www.patreon.com/8153512/join">
    <img src="https://img.shields.io/badge/Patreon-F96854?style=for-the-badge&logo=patreon&logoColor=white" alt="Patreon">
  </a>
  <a href="https://github.com/sponsors/stradichenko">
    <img src="https://img.shields.io/badge/sponsor-30363D?style=for-the-badge&logo=GitHub-Sponsors&logoColor=#EA4AAA" alt="GitHub Sponsors">
  </a>
</h4>

<h4 align="center">

[![Share on X](https://img.shields.io/badge/-Share%20on%20X-gray?style=flat&logo=x)](https://x.com/intent/tweet?text=Audiobook%20Read-Along%20for%20KOReader!%20TTS%20with%20word%20highlighting%20on%20e-readers.&url=https://github.com/stradichenko/audiobook.koplugin&hashtags=KOReader,TTS,eink)

</h4>

Text-to-speech for [KOReader](https://github.com/koreader/koreader) with
synchronized word highlighting, automatic page turns, and Bluetooth audio
support. Works offline on Kobo, Kindle, Android, and Linux.

## Quick start

### 1. Copy the plugin

Put `audiobook.koplugin` into KOReader's plugins folder:

| Platform | Path |
|----------|------|
| Kobo | `.adds/koreader/plugins/` |
| Kindle | `koreader/plugins/` |
| Linux | `~/.config/koreader/plugins/` |
| Android | `/sdcard/koreader/plugins/` |
| PocketBook | `applications/koreader/plugins/` |

Restart KOReader after copying.

### 2. Install a TTS engine

**Kobo** - ships with no TTS. Install espeak-ng via SSH or the terminal
emulator (Menu > More tools > Terminal emulator):

```bash
opkg update && opkg install espeak-ng
```

If `opkg` is unavailable, grab the `.ipk` from
[nickel-packages](https://github.com/nickel-packages/packages) and run
`opkg install /mnt/onboard/espeak-ng*.ipk`.

**Linux** - `sudo apt install espeak-ng`

**Android** - uses the system TTS. No extra install needed.

### 3. Start reading

- **Long-press a word** to open the dictionary popup, then tap
  **Read aloud from here**.
- Or **select a paragraph**, then tap **Read aloud from here** in the
  selection menu.
- Or go to **Tools > Audiobook Read-Along > Start reading from current page**.

## Optional: Piper neural TTS

Piper sounds much more natural than espeak-ng. It runs fully offline on Kobo's
ARM processor (~40 MB for engine + voice model).

```bash
bash package-for-kobo.sh --with-piper
```

Pick a different voice with `--piper-voice en_US-ryan-low`. Voice samples:
[rhasspy.github.io/piper-samples](https://rhasspy.github.io/piper-samples/).

To install manually, download the armv7l binary from
[Piper releases](https://github.com/rhasspy/piper/releases/tag/2023.11.14-2)
and a voice model from
[HuggingFace](https://huggingface.co/rhasspy/piper-voices), then place them in
`audiobook.koplugin/piper/`.

Switch between espeak-ng and Piper any time from
**Tools > Audiobook Read-Along > Voice settings**.

## Bluetooth audio (Kobo)

The plugin outputs audio through GStreamer's Bluetooth A2DP sink when a BT
device is paired. The connection is managed through the plugin menu:

**Tools > Audiobook Read-Along > Bluetooth settings**

The BT audio pipeline uses an exclusive abstract socket. If audio stops working
after a crash, restart KOReader - the plugin kills orphan processes on startup.

> Kobo's BT stack (MediaTek mtkbtmwrpc) binds a single abstract socket.
> Only one GStreamer pipeline can hold it at a time. The plugin keeps one
> persistent pipeline alive across sentences to avoid reconnection gaps.

## Playback controls

| Button | Action |
|--------|--------|
| Rewind | Previous sentence. Hold for 3x skip. |
| Play/Pause | Toggle playback. |
| Forward | Next sentence. Hold for 3x skip. |
| Close | Stop reading and dismiss the bar. |

Reading pauses automatically when you open a menu and resumes when you close it.

## Settings

All settings are under **Tools > Audiobook Read-Along**:

- **Bluetooth settings** - pair, connect, disconnect alert interval
- **Voice settings** - TTS engine, voice, speech rate, pitch
- **Highlight style** - invert (best for e-ink), underline, box, background
- **Auto-advance pages** - turn pages automatically
- **Highlight words / sentences** - toggle each independently
- **Quick start with espeak** - play first sentence with espeak-ng while Piper
  loads (avoids the ~3s cold start silence)

## Architecture

```
audiobook.koplugin/
  main.lua             - entry point, menus, event hooks
  synccontroller.lua   - coordinates audio timing with highlights
  ttsengine.lua        - TTS synthesis, audio playback, BT pipeline
  piperqueue.lua       - persistent Piper server management
  textparser.lua       - sentence/word tokenization with positions
  highlightmanager.lua - screen-coordinate highlight via crengine
  playbackbar.lua      - transport controls widget
  menubuilder.lua      - voice/highlight settings menus
  btmanager.lua        - Bluetooth device scanning and pairing
  btui.lua             - BT menu UI and disconnect watcher
  btpipeline.lua       - GStreamer BT audio pipeline management
  utils.lua            - shared helpers
```

### Design notes

**Persistent Piper server.** On Kobo's single-core ARM, loading the ONNX model
takes ~4.5 seconds. A persistent server process keeps the model in memory and
accepts sentences over a FIFO. Combined with 3-sentence batching this brings the
realtime factor from 0.085x (old 2-server config) to 0.329x. See
[benchmark/RESULTS.md](benchmark/RESULTS.md) for the full analysis.

**Binary-search highlight alignment.** CRe (crengine) snaps text selections to
word boundaries, and proportional fonts make character-to-pixel estimates
unreliable. The highlight manager uses the proportional estimate as an initial
guess, then binary-searches the x coordinate by querying CRe until the selected
text matches the target sentence. Converges in 2-4 queries.

**Exclusive BT socket.** Kobo's MediaTek BT firmware exposes a single abstract
socket (`@kobo:mtkbtmwrpc`). The plugin keeps one GStreamer pipeline alive for
the entire reading session and feeds audio through a FIFO. Orphan pipelines from
crashes are killed on startup via PID files and `pkill`.

**Long-sentence splitting.** Piper's attention mechanism scales quadratically
with input length. On Kobo's 512 MB of RAM the server OOMs on sentences above
~1000 characters and throughput drops from ~7 ch/s at 300 chars to ~3 ch/s at
1400 chars. The text parser automatically splits any sentence longer than 300
characters at natural clause boundaries (`;` `:` `, and/but/or...` ` - `) then
merges fragments shorter than 80 characters with a neighbour (below that, ~90%
of synthesis time is wasted on per-request overhead) and re-splits anything still
over 300 at word boundaries. See
[benchmark/RESULTS_LONG.md](benchmark/RESULTS_LONG.md) for the full data.

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Plugin not in menu | Folder must be `audiobook.koplugin` inside `plugins/`. Restart KOReader. |
| No sound | Run `espeak-ng "hello" -w /tmp/t.wav && aplay /tmp/t.wav` over SSH. |
| No TTS engine found | Install espeak-ng (see Quick start). |
| BT audio silent | Restart KOReader to kill orphan pipelines. Check BT is paired in the plugin menu. |
| SSH refused on port 22 | KOReader uses port 2222: `ssh root@<ip> -p 2222` |
| `.adds` not visible | Enable hidden files on your OS. The folder starts with a dot. |
| Highlight bleeds into next sentence | Update the plugin - fixed via binary-search alignment. |

## Contributing

Areas that could use work:

- Real word-level timing from TTS engines (SSML / phoneme callbacks)
- PDF/DjVu highlight support (currently EPUB only)
- More TTS backends
- Accessibility improvements

## License

Copyright 2025 gespitia - AGPL-3.0. See [LICENSE](LICENSE).

| Bundled component | License |
|-------------------|---------|
| [KOReader](https://github.com/koreader/koreader) | AGPL-3.0 |
| [espeak-ng](https://github.com/espeak-ng/espeak-ng) | GPL-3.0+ |
| [Piper](https://github.com/rhasspy/piper) | MIT |
| [Piper voices](https://huggingface.co/rhasspy/piper-voices) | MIT |
| glibc (bundled .so) | LGPL-2.1 |
