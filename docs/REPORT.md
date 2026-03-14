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

Full results with charts and raw data: [benchmark/RESULTS.md](benchmark/RESULTS.md)

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
