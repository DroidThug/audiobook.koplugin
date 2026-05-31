# MBROLA Audio Repeat Bug on Kobo MTK Bluetooth

## Executive Summary

MBROLA voices on Kobo devices with MediaTek (MTK) Bluetooth chipsets produce mid-sentence audio repeats when played through the `mtkbtmwrpcaudiosink` GStreamer element. The repeat sounds similar to the original audio but with a lower pitch ("deeper voice"). Only the `mb-en1` (UK English Male 1) voice is unaffected. All other tested MBROLA voices trigger the bug.

This document records every diagnostic test, attempted fix, and hypothesis so that future investigation can build on this work rather than repeat it.

## Affected Hardware

| Device Family | Bluetooth Chipset | Audio Sink |
|---|---|---|
| Kobo (various models) | MediaTek (MTK) | `mtkbtmwrpcaudiosink` |

The MTK Bluetooth firmware is a proprietary binary blob located at `/lib/gstreamer-1.0/libgstmtkbtmwrpc.so`. It is authored by George Talusan at Rakuten/Kobo and runs as part of the `mtkbtd` daemon. There is no source code, no configuration file, and no documented update mechanism.

## Affected Voices

| Voice | Language | Gender | Status |
|---|---|---|---|
| `mb-en1` | UK English | Male | **WORKING** (only unaffected voice) |
| `mb-us2` | US English | Female | BROKEN |
| `mb-es1` | Spanish | Male | BROKEN |
| `mb-fr1` | French | Male | BROKEN |
| `mb-fr3` | French | Female | BROKEN |
| `mb-us1` | US English | Male | BROKEN |

Approximately 60+ MBROLA voice files exist in the plugin. Only `mb-en1` is confirmed working.

## Symptom Description

1. Playback begins normally.
2. Approximately 5 to 6 seconds into a sentence, a portion of the audio repeats.
3. The repeated segment sounds "similar but with a deeper voice" (user's words).
4. The repeat can last for several seconds.
5. Stopping and restarting playback resets the condition.

The issue occurs both with individual sentences and with merged paragraph files. It is not a boundary artifact between sentences.

## Diagnostic Tests Performed

### Test 1: Source Audio Verification

**Method:** Synthesize a problematic sentence with `mb-us2`, transfer the WAV file from the Kobo, and analyze it on a PC.

**Result:** The WAV file is clean. No repeats, no corruption, valid header (16000 Hz, mono, S16LE).

**Conclusion:** The bug is not in espeak-ng or MBROLA synthesis.

### Test 2: GStreamer Capture Before MTK Sink

**Method:** Add a `tee` element before `mtkbtmwrpcaudiosink` to capture the exact data being fed into the MTK sink.

```
filesrc → wavparse → audioconvert → audioresample → tee → filesink (capture)
                                          |
                                          +--→ mtkbtmwrpcaudiosink
```

**Result:** The capture file is clean. No repeats in the audio entering the MTK sink.

**Conclusion:** The bug is introduced inside the MTK sink or the Bluetooth firmware, not in GStreamer.

### Test 3: Synthetic Sine Wave

**Method:** Generate a pure 1kHz sine wave at 16000 Hz mono S16LE and play it through the same pipeline.

```bash
gst-launch-1.0 audiotestsrc wave=sine freq=1000 num-buffers=5000 \
  ! audioconvert ! audioresample \
  ! 'audio/x-raw,format=S16LE,rate=48000,channels=2' \
  ! mtkbtmwrpcaudiosink sync=false
```

**Result:** The sine wave plays cleanly for the full 10+ seconds with no repeats.

**Conclusion:** The bug is **content-dependent**, not format-dependent. The pipeline and MTK sink handle synthetic audio perfectly. The trigger is something specific to MBROLA speech audio.

### Test 4: Voice Parameter Analysis

**Method:** Parse MBROLA database headers for `en1` and `us2`.

| Property | `en1` | `us2` |
|---|---|---|
| Version | 2.060 | 2.060 |
| Sample rate | 16000 Hz | 16000 Hz |
| MBRPeriod | 140 | 140 |
| Coding | DIPHONE_RAW | DIPHONE_RAW |
| nb_diphone | 2116 | 2066 |
| File size | 6.7 MB | 7.1 MB |

**Result:** Identical audio format. Only the database content differs.

**Conclusion:** The trigger is in the audio waveform content, not the container format.

### Test 5: Volume Attenuation

**Method:** Add `volume=0.7` (3 dB reduction) before the MTK sink.

**Result:** Audio is quieter but the repeat still occurs.

**Conclusion:** Not a simple peak amplitude issue.

### Test 6: Buffer Size Changes

**Method:** Vary `buffer-time`, `latency-time`, `blocksize`, and `slave-method` on the MTK sink.

| Parameter | Values Tested |
|---|---|
| buffer-time | 100ms, 200ms, 500ms |
| latency-time | 10ms, 50ms |
| blocksize | 4096, 8192, 32768 |
| slave-method | reample, actual-rate |

**Result:** No combination prevents the repeat.

**Conclusion:** Not a simple buffer sizing issue.

### Test 7: Shorter Text Chunks

**Method:** Reduce `max_text_len` from 1000 to 300 to 150 characters for MBROLA voices.

**Result:** Sentences are truncated but the repeat still occurs in the remaining audio.

**Conclusion:** Not triggered by sentence length.

### Test 8: Shorter Merged Files

**Method:** Reduce `MAX_CONCAT_MS` from 30000 ms to 15000 ms.

**Result:** Paragraphs are split but the repeat still occurs within individual sentences.

**Conclusion:** Not triggered by merged file length.

### Test 9: Pre-Resample to 22050 Hz

**Method:** Resample MBROLA output from 16000 Hz to 22050 Hz before playback.

**Result:** The repeat still occurs.

**Conclusion:** Not a sample rate ratio issue. The 3x integer ratio (16000 to 48000) is not the trigger.

### Test 10: Dithering Noise

**Method:** Add imperceptible random noise (+/- 2 LSB, approximately -90 dB) to every sample.

**Result:** The repeat still occurs.

**Conclusion:** Not triggered by exact sample value sequences. The bug is robust to small perturbations.

### Test 11: Pre-Convert to Stereo

**Method:** Convert mono WAV to stereo interleaved WAV before playback, bypassing `audioconvert`.

**Result:** The repeat still occurs.

**Conclusion:** Not triggered by the mono-to-stereo conversion in `audioconvert`.

### Test 12: Micro-Gaps Every 4 Seconds

**Method:** Insert 50 ms silence gaps every 4 seconds into the audio to reset the MTK buffer.

**Result:** The repeat still occurs.

**Conclusion:** Not a buffer overflow due to continuous audio duration.

### Test 13: Kernel Log Analysis

**Method:** Check `dmesg` during playback.

**Observed messages:**

```
mtk_axi_interrupt: N callbacks suppressed
[connlog] bt_fw emi ring is empty!!
```

**Result:** These messages appear during both working and broken playback. No clear correlation.

**Conclusion:** Kernel logs do not reveal the root cause.

## Hypotheses About Root Cause

### Hypothesis A: SBC Encoder Subband Sensitivity

The SBC codec allocates bits to subbands based on signal energy. MBROLA speech has rapidly changing spectral content (vowels, consonants, diphone boundaries). A sine wave has constant spectral content. If the MTK firmware's SBC encoder has a bug in its adaptive bit allocation, speech might trigger it while a sine wave does not.

**Why `mb-en1` works:** `mb-en1` has lower amplitude and fewer clipped samples in its database. Clipping introduces high-frequency harmonics that might push more energy into high subbands, changing the bit allocation pattern.

**Status:** Plausible but unverified.

### Hypothesis B: DMA Buffer Misalignment

The MTK Bluetooth controller uses DMA to transfer audio data. If the DMA controller requires specific alignment (e.g., 4-byte or 8-byte boundaries) and the audio data is misaligned, the controller might read from a wrong offset, causing a loop. The "deeper voice" would be explained by reading stereo samples at a 2-byte offset, effectively halving the sample rate.

**Why `mb-en1` works:** `mb-en1` produces files with different sizes or boundary alignments by chance.

**Status:** Unlikely. We verified alignment in the feeder script, and the non-persistent pipeline (different alignment path) also exhibits the bug.

### Hypothesis C: Diphone Boundary Transients

MBROLA concatenates diphone recordings at specific pitch marks. At each boundary, there may be phase discontinuities or amplitude jumps. These create transient clicks. If the MTK firmware's encoder or buffer management is sensitive to rapid transients, the high density of diphone boundaries in speech might trigger the bug.

**Why `mb-en1` works:** `mb-en1` has higher voicing (150 vs 80 for `mb-us2`), which means more harmonic content and smoother transitions between diphones.

**Status:** Plausible. However, changing the voicing parameter for all voices did not fix the issue, suggesting the database recordings themselves (not just the synthesis parameters) matter.

### Hypothesis D: Internal Ring Buffer Wrap-Around

The MTK sink may use a ring buffer for audio data. If the write pointer laps the read pointer, old data is overwritten. If the playback pointer then reads from the overwritten section, a repeat occurs. The "deeper voice" could be a misalignment in the ring buffer causing every other sample to be skipped.

**Why micro-gaps did not help:** The ring buffer might be inside the SBC encoder or Bluetooth controller, not the PCM buffer. A 50 ms gap might not be long enough to flush the internal state.

**Status:** Plausible but unverifiable without firmware source code.

## What Does NOT Work (Definitively Ruled Out)

| Approach | Result |
|---|---|
| Shorter sentences (150/300 chars) | Does not prevent repeat |
| Shorter merged files (15s) | Does not prevent repeat |
| Pre-resample to 22050 Hz | Does not prevent repeat |
| Dithering (+/- 2 LSB) | Does not prevent repeat |
| Pre-convert to stereo | Does not prevent repeat |
| Micro-gaps every 4s | Does not prevent repeat |
| Volume attenuation (0.5 to 0.7) | Does not prevent repeat |
| Buffer size changes (various) | Does not prevent repeat |
| Changing voicing parameter | Does not prevent repeat |
| Different slave-method settings | Does not prevent repeat |

## Workarounds

### Recommended: Use `mb-en1`

The `mb-en1` (UK English Male 1) voice is the only confirmed working MBROLA voice. It produces natural-sounding speech without triggering the firmware bug.

### Fallback: Plain espeak-ng

Disable MBROLA and use espeak-ng's built-in voices. Quality is robotic but playback is reliable.

### Not Recommended: Live with Repeats

Other MBROLA voices will occasionally repeat on long sentences. This is unpredictable and breaks the reading flow.

## Future Investigation (If Firmware Access Becomes Available)

1. Disassemble `libgstmtkbtmwrpc.so` to understand the buffer management logic.
2. Hook the SBC encoder to inspect bit allocation patterns for working vs broken audio.
3. Test with a modified MBROLA database that reduces clipped samples.
4. Check if a firmware update exists for the MTK Bluetooth controller.

## References

- [GStreamer mtkbtmwrpcaudiosink inspection](PLATFORM_AUDIO.md)
- [MBROLA project documentation](http://tcts.fpms.ac.be/synthesis/mbrola.html)
- [SBC codec specification (A2DP)](https://www.bluetooth.com/specifications/specs/)
- [espeak-ng MBROLA integration](https://github.com/espeak-ng/espeak-ng/blob/master/docs/mbrola.md)

## Revision History

| Date | Author | Change |
|---|---|---|
| 2026-05-31 | stradichenko | Initial report after exhaustive debugging session |
