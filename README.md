<h1 align="center">
  Audiobook Read-Along Plugin for KOReader
</h1>

<h3 align="center">

![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue)
![Platform](https://img.shields.io/badge/platform-Kobo%20%7C%20Kindle%20%7C%20Linux-blue)
![Android](https://img.shields.io/badge/Android-not%20yet%20supported-orange)
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
  <a href="https://buymeacoffee.com/stradichenko">
    <img src="https://raw.githubusercontent.com/pachadotdev/buymeacoffee-badges/main/bmc-donate-white.svg" alt="BuyMeACoffee">
  </a>
</h4>

<h4 align="center">

[![Share on X](https://img.shields.io/badge/-Share%20on%20X-gray?style=flat&logo=x)](https://x.com/intent/tweet?text=Audiobook%20Read-Along%20for%20KOReader!%20TTS%20with%20word%20highlighting%20on%20e-readers.&url=https://github.com/stradichenko/audiobook.koplugin&hashtags=KOReader,TTS,eink)

</h4>

Text-to-speech for [KOReader](https://github.com/koreader/koreader) with
synchronized word highlighting, automatic page turns, and Bluetooth audio
support. Works offline on Kobo, Kindle, Android, and Linux.

## Quick start

### 1. Download and copy the plugin

Download the latest release (includes espeak-ng and Piper) from
[GitHub Releases](https://github.com/stradichenko/audiobook.koplugin/releases/latest),
unzip it, and copy the `audiobook.koplugin` folder into KOReader's plugins
directory:

| Platform | Path |
|----------|------|
| Kobo | `.adds/koreader/plugins/` |
| Kindle | `koreader/plugins/` |
| Linux | `~/.config/koreader/plugins/` |
| Android | `/sdcard/koreader/plugins/` |
| PocketBook | `applications/koreader/plugins/` |

Restart KOReader after copying.

### 2. Install a TTS engine (if not using the pre-built release)

The pre-built release from step 1 **already includes espeak-ng and Piper** —
no extra install needed on Kobo. Skip to step 3.

If you cloned the repository instead:

**Kobo** — install espeak-ng via SSH or the terminal emulator
(Menu > More tools > Terminal emulator):

```bash
opkg update && opkg install espeak-ng
```

If `opkg` is unavailable, grab the `.ipk` from
[nickel-packages](https://github.com/nickel-packages/packages) and run
`opkg install /mnt/onboard/espeak-ng*.ipk`.

**Linux** — `sudo apt install espeak-ng`

**Android (Boox, etc.)** — **not yet supported.** The bundled espeak-ng
and Piper binaries are compiled for Linux-based e-readers (Kobo, Kindle) and
will not run on Android. Android TTS integration is planned but not yet
implemented. If you have `espeak-ng` in your system PATH (e.g. via Termux), the
plugin will detect and use it, but this is untested.

### 3. Start reading

- **Long-press a word** to open the dictionary popup, then tap
  **Read aloud from here**.
- Or **select a paragraph**, then tap **Read aloud from here** in the
  selection menu.
- Or go to **Tools > Audiobook Read-Along > Start reading from current page**.

## Optional: Piper neural TTS

Piper sounds much more natural than espeak-ng. It runs fully offline on Kobo's
ARM processor (~40 MB for engine + voice model). The
[pre-built release](https://github.com/stradichenko/audiobook.koplugin/releases/latest)
already includes Piper and a default voice (`en_US-lessac-medium`). For faster
load times on Kobo, consider switching to a `low` quality voice (see
[Choosing a voice](#choosing-a-voice)).
To build a bundle yourself, see [Building from source](#building-from-source).

Switch between espeak-ng and Piper any time from
**Tools > Audiobook Read-Along > Voice settings**.

### Choosing a voice

Listen to samples and pick a voice:
[rhasspy.github.io/piper-samples](https://rhasspy.github.io/piper-samples/)

Voices come in four quality levels:

| Quality | Sample rate | Size | Notes |
|---------|-------------|------|-------|
| low | 16 kHz | ~15 MB | **Recommended for Kobo** — fast load, low RAM |
| medium | 22 kHz | ~60 MB | Better quality, but slower to load on Kobo |
| high | 22 kHz | ~100 MB | Best quality, more RAM/CPU |

> On Kobo (512 MB RAM), `low` voices are recommended. `medium` works but the
> model takes noticeably longer to load. Not every voice is available at every
> quality level — check HuggingFace for what's offered.

### Downloading additional voices

Every voice needs two files: a `.onnx` model and a `.onnx.json` config. Place
both in `audiobook.koplugin/piper/`.

Voices are hosted on HuggingFace. The URL pattern is:

```text
https://huggingface.co/rhasspy/piper-voices/resolve/main/<lang>/<lang_REGION>/<speaker>/<quality>/
```

For example, to download **en_US-lessac-medium**:

```bash
cd audiobook.koplugin/piper/
curl -LO https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx
curl -LO https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx.json
```

Or for **en_US-ryan-low**:

```bash
curl -LO https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/ryan/low/en_US-ryan-low.onnx
curl -LO https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/ryan/low/en_US-ryan-low.onnx.json
```

Browse all available voices:
[huggingface.co/rhasspy/piper-voices](https://huggingface.co/rhasspy/piper-voices/tree/main)

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
- **Voice settings** - TTS engine, voice, speech rate, pitch, volume,
  sentence/paragraph pauses (espeak-ng), sentence/paragraph gaps (Piper),
  word gap, clause pause
- **Highlight style** - background (default), invert (best for e-ink),
  underline, box
- **Auto-advance pages** - turn pages automatically
- **Highlight words / sentences** - toggle each independently
- **Quick start with espeak** - play first sentence with espeak-ng while Piper
  loads (avoids the ~3s cold start silence)
- **Keep playing when lid is closed** - prevents device suspend so audio
  continues with the case closed
- **BT headset media buttons** - use play/pause/next/prev on a Bluetooth
  headset or speaker to control TTS playback

## Architecture

```
audiobook.koplugin/
  main.lua             - entry point, menus, event hooks
  synccontroller.lua   - coordinates audio timing with highlights
  ttsengine.lua        - TTS synthesis, audio playback, backend detection
  piperqueue.lua       - persistent Piper server management
  textparser.lua       - sentence/word tokenization with positions
  highlightmanager.lua - screen-coordinate highlight via crengine
  playbackbar.lua      - transport controls widget
  menubuilder.lua      - voice/highlight settings menus
  btmanager.lua        - Bluetooth device scanning and pairing
  btui.lua             - BT menu UI and disconnect watcher
  btmediacontrol.lua   - BT headset media buttons (AVRCP play/pause/skip)
  wavutils.lua         - WAV file reading, writing, and manipulation
  utils.lua            - shared helpers
```

### Design notes

**Persistent Piper server.** On Kobo's single-core ARM, loading the ONNX model
takes ~4.5 seconds. A persistent server process keeps the model in memory and
accepts sentences over a FIFO. Combined with 3-sentence batching this brings the
realtime factor from 0.085x (old 2-server config) to 0.329x. See
[dev/benchmark/RESULTS.md](dev/benchmark/RESULTS.md) for the full analysis.

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
[dev/benchmark/RESULTS_LONG.md](dev/benchmark/RESULTS_LONG.md) for the full data.

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Plugin not in menu | Folder must be `audiobook.koplugin` inside `plugins/`. Restart KOReader. |
| No sound | Run `espeak-ng "hello" -w /tmp/t.wav && aplay /tmp/t.wav` over SSH. |
| No TTS engine found | Install espeak-ng (see Quick start). |
| No TTS engine found (Android) | Android TTS is not yet supported. The bundled binaries only work on Linux-based e-readers (Kobo, Kindle). See [Android note](#2-install-a-tts-engine-if-not-using-the-pre-built-release). |
| BT audio silent | Restart KOReader to kill orphan pipelines. Check BT is paired in the plugin menu. |
| SSH refused on port 22 | KOReader uses port 2222: `ssh root@<ip> -p 2222` |
| `.adds` not visible | Enable hidden files on your OS. The folder starts with a dot. |

### Generating a bug report

If something isn't working, please generate a diagnostic report from the
plugin menu:

**Tools > Audiobook Read-Along > Generate bug report**

This saves a `.txt` file to your device's root storage:

| Platform | Report location |
|----------|----------------|
| Kobo | `/mnt/onboard/audiobook-bug-report-*.txt` |
| Kindle | `/mnt/us/audiobook-bug-report-*.txt` |
| Android | `/sdcard/audiobook-bug-report-*.txt` |
| Linux | `~/audiobook-bug-report-*.txt` |

Connect your device via USB, find the file, and attach it to your
[GitHub issue](https://github.com/stradichenko/audiobook.koplugin/issues).

**What the report contains:**

- Device model, platform, screen size, kernel version
- KOReader version
- TTS engine detection results (which backends were found/missing)
- Audio player availability (aplay, GStreamer, etc.)
- Plugin settings (speech rate, highlight style, etc.)
- Memory and disk info

**What the report does NOT contain:**

- Book titles, content, or reading positions
- File paths with usernames (sanitized automatically)
- Highlights, bookmarks, or notes
- Network information or credentials

## Android support

Android TTS integration is **in progress**. Here is the current status:

| Feature | Status |
|---------|--------|
| Plugin loads in KOReader | ![Works](https://img.shields.io/badge/-works-brightgreen) |
| Text parsing & highlighting | ![Works](https://img.shields.io/badge/-works-brightgreen) |
| Bundled espeak-ng / Piper | ![No](https://img.shields.io/badge/-not%20supported-red) Linux binaries, won't run on Android |
| Android system TTS | ![Planned](https://img.shields.io/badge/-planned-blue) Requires JNI bridge to `TextToSpeech` API |
| espeak-ng via Termux | ![Untested](https://img.shields.io/badge/-untested-yellow) May work if `espeak-ng` is in PATH |
| Audio playback | ![Untested](https://img.shields.io/badge/-untested-yellow) Depends on available player (`mpv`, `play`, etc.) |

### Why it doesn't work yet

The bundled `espeak-ng` and `piper` binaries in the release are
cross-compiled for **Linux ARM with glibc**. Android uses **Bionic libc**,
so these binaries cannot execute on Android devices (Boox, phones, tablets).

Android has its own `TextToSpeech` Java API, but KOReader's Lua runtime
needs a JNI bridge to call it. This bridge does not exist yet.

### Workaround for advanced users

If you have [Termux](https://termux.dev/) installed:

1. Install espeak-ng in Termux: `pkg install espeak-ng`
2. Ensure Termux's bin directory is in KOReader's PATH
3. The plugin will detect `espeak-ng` from the system PATH automatically

This is **untested** — if you try it, please
[open an issue](https://github.com/stradichenko/audiobook.koplugin/issues)
with a bug report (see above) regardless of whether it works.

## Building from source

The `package-for-kobo.sh` script cross-compiles espeak-ng for ARM and bundles
the plugin into a ready-to-deploy directory. It requires
[Nix](https://nixos.org/download) for the cross-compilation toolchain.

```bash
# Plugin + espeak-ng only
bash package-for-kobo.sh

# Plugin + espeak-ng + Piper neural TTS
bash package-for-kobo.sh --with-piper

# Use a specific Piper voice (default: en_US-lessac-medium)
bash package-for-kobo.sh --piper-voice en_US-ryan-low
```

The output is placed in `kobo-tts-bundle/audiobook.koplugin/`. Copy it to your
device:

```bash
scp -P 2222 -r kobo-tts-bundle/audiobook.koplugin root@<kobo-ip>:/mnt/onboard/.adds/koreader/plugins/
```

### Installing the Piper binary manually

If you don't want to use the packaging script, you can assemble the Piper
runtime yourself:

1. Download the **armv7l** binary from
   [Piper releases (2023.11.14-2)](https://github.com/rhasspy/piper/releases/tag/2023.11.14-2).
2. Extract `piper`, its `lib/` directory, and `espeak-ng-data/` into
   `audiobook.koplugin/piper/`.
3. Download a voice model (`.onnx` + `.onnx.json`) as described in
   [Downloading additional voices](#downloading-additional-voices) and place
   them in the same `piper/` directory.

> **Note:** The [rhasspy/piper](https://github.com/rhasspy/piper) repository
> was archived in October 2025. The binaries on the releases page still work.
> The project continues as
> [OHF-Voice/piper1-gpl](https://github.com/OHF-Voice/piper1-gpl).

## To Do

- Implement real word-level timing from TTS engines (SSML / phoneme callbacks)
- Add PDF/DjVu highlight support (currently EPUB only)
- **Android TTS support** via JNI bridge to Android's `TextToSpeech` API
- Integrate more TTS backends
- Improve accessibility
- Support whole audiobook production with hash-based verification
- Evaluate plugin with other TTS models (e.g., KittenTTS)
- Test and optimize for ultralow-quality/size voice models

## License

Copyright 2025-2026 gespitia - AGPL-3.0. See [LICENSE](LICENSE).

| Bundled component | License |
|-------------------|---------|
| [KOReader](https://github.com/koreader/koreader) | AGPL-3.0 |
| [espeak-ng](https://github.com/espeak-ng/espeak-ng) | GPL-3.0+ |
| [Piper](https://github.com/rhasspy/piper) | MIT |
| [Piper voices](https://huggingface.co/rhasspy/piper-voices) | MIT |
| glibc (bundled .so) | LGPL-2.1 |
