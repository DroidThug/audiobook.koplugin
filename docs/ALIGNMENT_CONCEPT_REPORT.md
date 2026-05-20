# Audio-to-Text Alignment: What I Tried and Why I Gave Up

**Date:** 2026-05-20  
**Status:** Decided against it  

---

## The Problem

People often have an EPUB and a matching audiobook (like `GreatExpectations.epub` + `GreatExpectations.m4b`) but no timing data linking them. The plugin can already do read-along for EPUBs with Media Overlays (SMIL), but most books don't have those. So the question was: can we auto-generate the timing data on the device?

## What I Looked At

### 1. ffmpeg silence detection + espeak-ng

The idea was to use `ffmpeg silencedetect` to find pauses in the audio, treat those as sentence boundaries, and optionally use `espeak-ng` phoneme durations for rough word-level timing.

Why it doesn't work:
- **Painfully slow.** On a Kobo's single-core ARM CPU (~1 GHz), ffmpeg decodes audio at about 0.5-1x real-time. A 10-hour book would take 1-2 hours just to analyze. Nobody wants to leave their e-reader grinding for that long.
- **Battery killer.** Running the CPU flat-out for hours would drain the device even while plugged in. E-reader charging circuits are tiny.
- **Quality is meh.** Silence detection assumes clean narration with obvious pauses. It falls apart on breathy transitions, background music, sound effects, or sentences that run together. And espeak phoneme timing is just a rough guess, not real alignment.
- **Scope creep.** The current code only handles one page at a time (`getCurrentPageText()`). Doing full chapters would need complete EPUB text extraction, which is a whole other project.

### 2. OpenAI Whisper on-device

Run a Whisper model locally for word-level timestamps.

Why it doesn't work:
- **Hardware can't handle it.** Even the "tiny" Whisper model needs ~1 GB RAM and a decent CPU/GPU. Kobo devices have 256-512 MB RAM and ancient ARM Cortex-A8/A7 chips. Inference would run at 10-20x slower than real-time. Completely impractical.

### 3. aeneas or Gentle on-device

Existing open-source forced aligners.

Why they don't work:
- **Way too heavy.** aeneas needs Python + numpy + ffmpeg. Gentle needs Kaldi binaries (hundreds of MB). Not happening on a Kobo.
- **Even if bundled, they'd be too slow.** Same hardware problem as above.

### 4. Pre-compute on PC, copy JSON to device

User runs Whisper/aeneas on their laptop, exports timing data, copies it over.

Why I rejected it:
- **Too much friction for users.** Needs a separate toolchain, format conversion, manual file management. The user I talked to specifically didn't want this path.
- **Support nightmare.** Windows, macOS, Linux each need different setup instructions. I'd be debugging people's Python environments instead of working on the plugin.

## Conclusion

On-device alignment is a dead end for this plugin. The hardware is too slow, the battery cost is too high, and the best feasible method (ffmpeg silence detection) is too inaccurate to be useful.
