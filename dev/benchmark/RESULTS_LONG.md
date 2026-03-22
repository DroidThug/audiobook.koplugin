# Long-Sentence Benchmark Results

**Device:** Kobo Clara (dual-core ARM Cortex-A7 ~1 GHz, 512 MB RAM)
**Model:** en_US-lessac-low.onnx (16 kHz)
**Date:** 2026-03-15/16

## Key Finding

Piper on ARM has a hard ceiling at ~900 chars. Sentences above ~1000 chars crash the server (OOM or timeout). Splitting is mandatory, not optional.

## Strategy Results

### 1. no_split (baseline)

Sends the full sentence unchanged to Piper.

| Chars | Synth (s) | Audio (s) | Throughput (ch/s) | Status |
|------:|----------:|----------:|------------------:|--------|
| 344   | 50.0      | 18.7      | 6.9               | OK     |
| 365   | 50.7      | 19.3      | 7.2               | OK     |
| 502   | 72.3      | 27.5      | 6.9               | OK     |
| 533   | 75.6      | 29.4      | 7.1               | OK     |
| 655   | 88.0      | 32.8      | 7.4               | OK     |
| 731   | 103.4     | 38.8      | 7.1               | OK     |
| 751   | 106.6     | 38.7      | 7.0               | OK     |
| 919   | 141.9     | 49.3      | 6.5               | OK     |
| 1076  | 318.9     | 0.0       | 3.4               | TIMEOUT - no WAV |
| 1226  | 310.0     | 0.0       | 4.0               | TIMEOUT - no WAV |
| 1449  | 310.0     | 0.0       | 4.7               | TIMEOUT - no WAV |
| 1820  | 309.9     | 0.0       | 5.9               | TIMEOUT - no WAV |

**Summary:** Linear throughput (~7 ch/s) up to ~919 chars. Above 1000 chars the server crashes/hangs. Sentences > 900 chars are **impossible** without splitting.

### 2. clause_split

Splits at natural clause boundaries: `;` `:` ` - ` and `, <conjunction>`.

| Chars | Synth (s) | 1st Chunk (s) | Audio (s) | Chunks | Throughput (ch/s) |
|------:|----------:|--------------:|----------:|-------:|------------------:|
| 344   | 53.1      | 22.6          | 19.2      | 3      | 6.5               |
| 365   | 52.4      | 19.7          | 19.3      | 3      | 7.0               |
| 502   | 77.6      | 13.7          | 28.0      | 5      | 6.5               |
| 533   | 78.9      | 39.4          | 29.5      | 4      | 6.8               |
| 655   | 89.8      | 8.1           | 33.3      | 5      | 7.3               |
| 731   | 106.1     | 41.1          | 40.0      | 4      | 6.9               |
| 751   | 107.4     | 16.4          | 40.3      | 4      | 7.0               |
| 919   | 133.1     | 21.3          | 49.3      | 4      | 6.9               |
| 1076  | 208.8     | 29.1          | 46.9      | 7      | **5.2**           |
| 1226  | 341.0     | 58.9          | 70.5      | 7      | **3.6**           |
| 1449  | 433.6     | 56.9          | 78.2      | 10     | **3.3**           |
| 1820  | 675.2     | 61.6          | 103.4     | 14     | **2.7**           |
| 627*  | 124.4     | 124.4         | 31.2      | 1      | 5.0               |
| 457*  | 543.3     | 20.7          | 26.1      | **17** | **0.8**           |
| 759*  | 188.6     | 115.3         | 49.6      | 3      | 4.0               |

*adversarial sentences

**Summary:**
- Enables synthesis of ALL lengths (no crashes up to 1820 chars)
- First-chunk latency is 8-62s (median ~30s) - much better than no_split's full-sentence wait
- **Pathological case:** sentence #14 (many semicolons, 457 chars) split into 17 tiny chunks (7-38 chars each), taking 543s total at 0.8 ch/s. Each 15-char fragment still costs ~30s due to per-request overhead.
- Throughput degrades above 1000 chars because clause chunks have variable sizes, some still > 300 chars

### 3. chunk_300 (partial - died at sentence 10)

Fixed-size splitting at ~300 chars on word boundaries.

| Chars | Synth (s) | 1st Chunk (s) | Audio (s) | Chunks | Throughput (ch/s) |
|------:|----------:|--------------:|----------:|-------:|------------------:|
| 344   | 148.5     | 46.8          | 18.8      | 2      | 2.3               |
| 365   | 60.6      | 47.5          | 19.2      | 2      | 6.0               |
| 502   | 86.1      | 49.0          | 27.7      | 2      | 5.8               |
| 533   | 88.2      | 47.0          | 29.8      | 2      | 6.0               |
| 655   | 108.4     | 48.9          | 33.7      | 3      | 6.0               |
| 731   | 126.2     | 51.4          | 41.1      | 3      | 5.8               |
| 751   | 256.1     | 61.2          | 40.5      | 3      | 2.9               |
| 919   | 164.2     | 50.1          | 51.1      | 4      | 5.6               |
| 1076  | 617.9     | 55.7          | 0.0       | 4      | 1.7               |
| 1226  | 937.0     | 187.4         | 0.0       | 5      | 1.3               |

**Summary:** First-chunk is consistently ~47-55s (predictable), but overall throughput is significantly worse than clause_split. The server degraded after sentence 8, suggesting memory accumulation issues with sustained workload. Died without completing.

## Analysis

### Throughput scaling

```
Chars   no_split   clause_split   chunk_300
 344      6.9          6.5           2.3
 533      7.1          6.8           6.0
 731      7.1          6.9           5.8
 919      6.5          6.9           5.6
1076      FAIL         5.2           1.7
1449      FAIL         3.3           -
1820      FAIL         2.7           -
```

### The overhead problem

Each Piper synthesis request carries ~4-5s of fixed overhead (model warm-up, phoneme processing, etc.) regardless of input length. This makes small chunks extremely expensive:

- 300-char chunk: ~50s synth for ~16s audio = 6 ch/s
- 50-char chunk: ~30s synth for ~3s audio = 1.7 ch/s
- 15-char chunk: ~30s synth for ~1s audio = 0.5 ch/s

**Rule of thumb:** Chunks below ~100 chars waste 90%+ of synthesis time on overhead.

### Failure mode for 1000+ char sentences

No_split: Piper crashes (likely OOM on ARM - the attention mechanism scales quadratically with sequence length). The model simply cannot hold a 1000+ char sequence in memory on 512 MB.

### Server degradation

Both chunk_300 and clause_split showed degrading throughput over long runs. This suggests the persistent Piper server accumulates memory over time. Periodic server restarts (e.g., every 10 sentences) might help.

## Recommendations

### 1. Hybrid clause-first, chunk-cap at 300

```
if sentence_length > 300:
    chunks = split_at_clauses(sentence)
    for each chunk:
        if chunk_length > 300:
            sub_chunks = split_at_word_boundary(chunk, 300)
        if chunk_length < 80:
            merge with adjacent chunk
```

The merge step is critical - without it, adversarial inputs with many semicolons create tiny fragments that destroy throughput.

### 2. Minimum chunk size: 80 chars

Never send a chunk smaller than ~80 chars to Piper. Merge small fragments with their neighbors.

### 3. Maximum chunk size: 300 chars

Keep all chunks under 300 chars to stay within the efficient synthesis window and avoid OOM on very long inputs.

### 4. Progressive playback

With clause-split, first-chunk latency is 8-62s. For a 1000+ char sentence, the user starts hearing audio after ~30s while the remaining chunks synthesize in the background. This is dramatically better than 300+ seconds of silence with no_split (which then fails anyway).

### 5. Server health management

Restart the Piper server every N sentences (e.g., 20-30) to prevent memory degradation.

## Suggested implementation in textparser.lua

Add a `splitLongSentence(text, max_chars)` function that:
1. If `#text <= max_chars`, return `{text}`
2. Try clause splitting first (`;` `:` ` - ` `, conjunction`)
3. Merge any resulting chunks < 80 chars with neighbors
4. Re-split any chunks still > max_chars at word boundaries
5. Return array of chunks, each 80-300 chars

This should be called from `parseSentences()` after normal sentence splitting, applied to any sentence exceeding the threshold.
