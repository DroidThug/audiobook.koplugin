# Development Report: TTS Benchmarking and Highlight Selection Fix

**Date:** March 14-15, 2026
**Device:** Kobo Libra 2 (ARMv7 dual-core Cortex-A7, 1GHz, 512MB RAM)
**KOReader:** v2025.10

---

## 1. Piper TTS Benchmark

### Goal

Find the optimal Piper TTS configuration for Kobo's constrained ARM hardware.
The default config (2 persistent servers, batch size 1) was tuned for multi-core
desktops and performed poorly on single-core ARM.

### Method

13 strategies tested on-device using a custom LuaJIT benchmark harness. Test
corpus: 25 sentences, 513 characters, ~33 seconds of audio. Each strategy was
measured for realtime factor, average inter-sentence gap, max gap, and cold
start latency.

### Key Findings

| Rank | Strategy | RT factor | Avg gap | Max gap |
|------|----------|-----------|---------|---------|
| 1 | server_1x1_batch3 | 0.329x | 2697ms | 5150ms |
| 2 | server_1x1 | 0.322x | 2791ms | 8944ms |
| 3 | adaptive | 0.319x | 2717ms | 3746ms |
| 4 | batch_10 | 0.316x | 2793ms | 4053ms |
| 13 | server_2x2 (old default) | 0.085x | 14438ms | 30864ms |

The old 2-server config was 4x slower than a single server due to CPU
contention on single-core hardware.

### Applied Changes (piperqueue.lua)

- Auto-detect CPU cores from `/sys/devices/system/cpu/possible`
- Single-core: 1 server, batch size 3
- Multi-core: up to 2 servers, batch size 1
- Pipeline depth capped at 1 on single-core (avoids FIFO measurement overhead)

Full results with charts and raw data: [dev/benchmark/RESULTS.md](../dev/benchmark/RESULTS.md)

---

## 2. Highlight Selection Fix

### Problem

Two user-reported issues:
1. Highlighted text was slightly misaligned with spoken text
2. At sentence boundaries, the highlight sometimes bled into the first word
   of the next sentence

### Root Cause

The highlight manager converts sentence character offsets to screen pixel
coordinates by dividing line width proportionally by character count. CRe
(crengine, KOReader's EPUB renderer) snaps selections to word boundaries.

With proportional fonts, character-based x estimates are unreliable:
- A narrow sentence ending (like a period) could place end_x slightly past the
  sentence boundary, causing CRe to snap forward and grab the next word
  (overshoot)
- A wide sentence ending could place end_x slightly before the last character,
  causing CRe to snap backward and drop the period (undershoot)

The original code used a single `char_w` pullback heuristic. Diagnostic logging
on-device confirmed the pattern:
- S2 "The boy reached..." - **overshoot** by 4 chars ("The" from next sentence)
- S3, S5, S6, S8 - **undershoot** by 1 char (missing period)
- S7 - matched correctly (lucky alignment)

No single pullback factor works for all cases because CRe's word-boundary
snapping is non-linear.

### Fix (highlightmanager.lua)

Replaced the static pullback with a two-phase binary search:

1. **Phase 1 - Initial estimate:** Proportional character-to-pixel mapping
   (same as before, no pullback bias)

2. **Phase 2 - Refine end_x:** Query CRe with the estimated coordinates,
   compare the returned text against the expected sentence. If it overshoots
   (too many characters), binary-search leftward. If it undershoots (too few),
   binary-search rightward. Converges in 2-4 CRe calls.

3. **Phase 3 - Refine start_x:** Same binary search for sentences starting
   mid-line, where the proportional estimate might land on the wrong word.

Typical convergence: 3-5 total CRe queries per sentence (vs 1 before). On ARM
this adds ~5-10ms per highlight, well within e-ink refresh budget.

---

## 3. Other Fixes Applied

### tonumber/gsub crash (piperqueue.lua:516)

`tonumber(ppf:read("*a"):gsub("%s+", ""))` crashed because `string.gsub`
returns two values (string, count). When passed directly to `tonumber`, the
count became the base argument. Fixed by assigning to a local first:
```lua
local raw = ppf:read("*a"):gsub("%s+", "")
piper_pid = tonumber(raw)
```

### Orphan process hardening

- `forceKillAll()` changed from SIGTERM to SIGKILL for gst-launch
- `_stopPersistentPipeline()` now kills wrapper shells via pkill
- `stopServers()` early-return guard removed so cleanup always runs
- `killOrphanProcesses()` restored to server-safe behavior (only kills when
  servers are not managed)
- Wrapper shell cleanup (`pkill -9 -f 'piper_server_.*\.sh'`) added to both
  `stopServers()` and `killOrphanProcesses()`

### BT audio pipeline fix

Root cause: orphan gst-launch processes from previous sessions holding the
exclusive `@kobo:mtkbtmwrpc` abstract socket. Fixed by:
- `cleanup()` preserving `audio_pid` when persistent pipeline is active
- Startup orphan killer in `_killOrphanProcessesFromPreviousSession()`

---

## 4. Kindle Audio Output Investigation (v0.1.5.24)

### Problem

Issue #11: Kindle Basic 2022 (11th Gen, speakerless) -- TTS engine detected,
BT headphones connected, but no audio output.

### Root Cause

Kindle Basic 2022 has no built-in speaker.  `/proc/asound/cards` reports
"no soundcards".  Amazon manages BT audio routing internally via `btfd`
(Lab126 IPC), but does not expose the BT headphone as a standard ALSA device.
The plugin forced `aplay` on Kindle regardless, but `aplay` exited immediately
with no audio device.

The rapid-fail detection in the process watcher was gated on
`_no_real_audio_output`, which was never set for Kindle (the code specifically
bypassed it).  This caused sentences to advance silently -- aplay exits in
<200ms, the watcher treats it as "normal completion", and the next sentence
starts immediately.

### Fix

1. **Active ALSA probing** (`ttsengine.lua findAudioPlayer`):
   - Probe `aplay -l` for dynamically registered ALSA cards (BT devices)
   - Probe `aplay -L` for named PCM devices, preferring BT-related names
     (`bluealsa:*`, `bluetooth`, `a2dp`) over generic sinks
   - Check `/dev/snd/` for kernel pcm device nodes
   - Probe PulseAudio (`pactl list sinks short`) for BT sinks
   - If a device is found, use it with explicit `-D` argument (or `paplay`)
   - If no device found, set `_no_real_audio_output = true` for Kindle too

2. **Rapid-fail detection for Kindle** (`ttsengine.lua _startProcessWatcher`):
   - Extended rapid-exit (<200ms) tracking to also trigger on Kindle devices
   - After 3 consecutive rapid failures, stops playback with actionable error
     asking user to generate a bug report

3. **Comprehensive Kindle audio diagnostics** (`bugreport.lua`, `generate-report.sh`):
   - `/dev/snd/` listing
   - `aplay -l` and `aplay -L` output
   - `/proc/asound/pcm` content
   - Running audio-related processes
   - PulseAudio availability and sink listing
   - lipc audio/sound/media service enumeration
   - Available audio binaries scan
   - Kernel sound modules
   - ALSA config (`/etc/asound.conf`)

4. **btfd A2DP reverse-engineering diagnostics** (`bugreport.lua`, `generate-report.sh`):
   Amazon's `btfd` daemon manages BT audio routing on Kindle via a proprietary
   stack (Lab126 IPC, not BlueZ/D-Bus). To understand how it pipes PCM data to
   BT headphones -- and whether we can inject into that path -- the bug report
   now collects:
   - `btfd` PID, command line, open file descriptors, unix sockets, memory maps
   - HCI device presence (`/dev/hci*`, `/sys/class/bluetooth/`, `hciconfig -a`)
   - D-Bus daemon presence and BlueZ registration status
   - System-wide unix sockets matching bt/audio/a2dp/blue/sbc
   - LIPC service probing: `com.lab126.kaf.TTSService` and
     `com.lab126.audioPlayer` property listings

5. **v0.1.5.24 report analysis and targeted follow-up diagnostics**:

   The v0.1.5.24 report from Kindle Basic 2022 revealed:
   - `/etc/asound.conf` defines `pcm.dmix0` on `hw:0,0` at 44100 Hz -- ALSA is
     configured but no card is registered at runtime
   - `/dev/snd/` has only `seq` and `timer` (no `pcmC0D0p`) -- ALSA kernel
     base loaded, but PCM device not instantiated
   - `audiomgrd` daemon (PID 23435) is running -- Amazon's audio manager,
     separate from `btfd`, likely controls ALSA card lifecycle
   - LIPC services `com.lab126.playermgr` and `com.lab126.audiomgrd` exist --
     `com.lab126.audio` does NOT exist on this device
   - BT headphones connected ("Bonne Heaphone 1") via btfd, BTstate=2
   - `aplay` exists at `/usr/bin/aplay` -- Amazon ships it, but no soundcard

   Hypothesized audio path:
   ```
   App -> LIPC to audiomgrd -> audiomgrd loads ALSA hw:0,0 -> dmix0 -> btfd A2DP -> BT
   ```

   New diagnostics added in v0.1.5.26:
   - `audiomgrd` PID, command line, open file descriptors, memory maps
   - `lipc-probe com.lab126.playermgr` -- may accept file paths to play audio
   - `lipc-probe com.lab126.audiomgrd` -- may control ALSA card initialization
   - Full `/etc/asound.conf` dump (v0.1.5.24 only showed first 10 lines)
   - Complete `/dev/snd/` listing
   - All LIPC services listing (not filtered by keyword)

   Also added `aplay -D dmix0` (and other asound.conf-defined PCMs) as player
   candidates, since `dmix0` is the named PCM in the Kindle's ALSA config.

### Status

Waiting for v0.1.5.26 report to reveal `audiomgrd` internals and `playermgr`
LIPC properties. If `playermgr` accepts file paths, we can route Piper WAV
output through Amazon's native audio stack without needing direct ALSA access.
