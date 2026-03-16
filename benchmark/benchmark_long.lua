#!/usr/bin/env lua
--[[--
Long-Sentence Benchmark for Piper TTS
======================================
Tests different strategies for handling sentences that exceed the
efficient synthesis window (~200 chars at ~5.4 chars/s on ARM).

Strategies tested:
  1. no_split        - Send full sentence as-is (baseline)
  2. clause_split    - Split at natural clause boundaries (; : - , + conjunction)
  3. chunk_200       - Fixed-size chunking at ~200 chars on word boundaries
  4. chunk_300       - Fixed-size chunking at ~300 chars on word boundaries
  5. chunk_400       - Fixed-size chunking at ~400 chars on word boundaries
  6. hybrid          - Clause-first, then chunk any fragments still > 300 chars
  7. progressive     - Split + synthesize first chunk, play while rest synthesizes

Metrics per sentence:
  - total_synth_ms   : wall time to synthesize entire sentence
  - first_chunk_ms   : time until first chunk WAV is ready (time-to-first-audio)
  - audio_duration_ms : total audio output duration
  - chunks           : how many pieces the sentence was split into
  - throughput       : chars/s
  - overhead_ratio   : synth_time / (chars * reference_per_char_time)

Usage:
  lua benchmark_long.lua                  -- run all strategies
  lua benchmark_long.lua clause_split     -- run one strategy
  lua benchmark_long.lua --list           -- list strategies
  lua benchmark_long.lua --min 400        -- only sentences >= 400 chars

@script benchmark_long
--]]

-- ── Helpers (same as benchmark.lua) ──────────────────────────────────

local function timestamp_ms()
    -- BusyBox date does not support %3N; use /proc/uptime for sub-second precision
    local f = io.open("/proc/uptime", "r")
    if f then
        local line = f:read("*l") or ""
        f:close()
        local uptime = tonumber(line:match("^([%d%.]+)"))
        if uptime then return math.floor(uptime * 1000) end
    end
    -- Fallback: seconds only
    return os.time() * 1000
end

local function sleep_ms(ms)
    os.execute(string.format("usleep %d 2>/dev/null || sleep %s",
        ms * 1000, string.format("%.3f", ms / 1000)))
end

local function file_exists(path)
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

local function file_size(path)
    local f = io.open(path, "rb")
    if not f then return 0 end
    local size = f:seek("end") or 0
    f:close()
    return size
end

local function wav_duration_ms(path)
    local f = io.open(path, "rb")
    if not f then return 0 end
    local header = f:read(44)
    if not header or #header < 44 then f:close(); return 0 end
    local byte_rate = header:byte(29) + header:byte(30) * 256
        + header:byte(31) * 65536 + header:byte(32) * 16777216
    local data_size = header:byte(41) + header:byte(42) * 256
        + header:byte(43) * 65536 + header:byte(44) * 16777216
    -- Fallback: if header data_size is 0 or suspiciously small, use actual file size
    if data_size <= 0 then
        local total = f:seek("end") or 0
        data_size = math.max(0, total - 44)
    end
    f:close()
    if byte_rate == 0 then
        -- Assume 16kHz 16-bit mono as fallback
        byte_rate = Config.sample_rate * 2
    end
    if byte_rate == 0 then return 0 end
    return math.floor(data_size * 1000 / byte_rate)
end

local function clean_text(s)
    return s:gsub("[\r\n\t]+", " "):gsub("  +", " "):match("^%s*(.-)%s*$") or ""
end

local function printf(fmt, ...)
    io.write(string.format(fmt, ...))
    io.flush()
end

local function log(fmt, ...)
    printf("[%s] " .. fmt .. "\n", os.date("%H:%M:%S"), ...)
end

-- ── Config ───────────────────────────────────────────────────────────

local Config = {
    piper_bin = nil,
    model_path = nil,
    espeak_data = nil,
    lib_path = nil,
    ld_linux = nil,
    sample_rate = 22050,
    output_dir = "/tmp/piper-bench-long/wav",
    results_dir = "/tmp/piper-bench-long/results",
    plugin_dir = "/mnt/onboard/.adds/koreader/plugins/audiobook.koplugin",
}

local function resolve_config()
    local candidates = {
        Config.plugin_dir .. "/piper/piper",
        "./piper/piper",
        "/usr/local/bin/piper",
        "/usr/bin/piper",
    }
    for _, path in ipairs(candidates) do
        if file_exists(path) then Config.piper_bin = path; break end
    end
    if not Config.piper_bin then
        local h = io.popen("which piper 2>/dev/null")
        if h then
            local r = h:read("*a"):gsub("%s+", ""); h:close()
            if r ~= "" then Config.piper_bin = r end
        end
    end
    if not Config.piper_bin then
        io.stderr:write("ERROR: Cannot find Piper binary\n"); os.exit(1)
    end
    log("Piper binary: %s", Config.piper_bin)

    local piper_dir = Config.piper_bin:match("^(.*/)[^/]*$") or "./"
    local h = io.popen(string.format(
        'find "%s" -name "*-low.onnx" -o -name "*-medium.onnx" 2>/dev/null | head -5', piper_dir))
    if h then
        for line in h:lines() do
            local path = line:gsub("%s+$", "")
            if path ~= "" and path:match("%-low%.onnx$") then
                Config.model_path = path; break
            end
            if not Config.model_path and path ~= "" then Config.model_path = path end
        end
        h:close()
    end
    if not Config.model_path then
        h = io.popen('find "' .. piper_dir .. '/.." -name "*.onnx" -type f 2>/dev/null | head -1')
        if h then
            local r = h:read("*a"):gsub("%s+", ""); h:close()
            if r ~= "" then Config.model_path = r end
        end
    end
    if not Config.model_path then
        io.stderr:write("ERROR: Cannot find Piper .onnx model\n"); os.exit(1)
    end
    log("Model: %s", Config.model_path)

    local json_path = Config.model_path .. ".json"
    local jf = io.open(json_path, "r")
    if jf then
        local c = jf:read("*a"); jf:close()
        local sr = tonumber(c:match('"sample_rate"%s*:%s*(%d+)'))
        if sr and sr > 0 then Config.sample_rate = sr end
    end
    log("Sample rate: %d Hz", Config.sample_rate)

    local lib_path = piper_dir .. "lib"
    if file_exists(lib_path .. "/libonnxruntime.so.1.14.1") then
        Config.lib_path = lib_path
    elseif file_exists(piper_dir .. "libonnxruntime.so.1.14.1") then
        Config.lib_path = piper_dir
    end

    local espeak_data = piper_dir .. "espeak-ng-data"
    if file_exists(espeak_data .. "/phontab") then Config.espeak_data = espeak_data end

    local espeak_ng_dir = Config.plugin_dir .. "/espeak-ng"
    local ld_linux = espeak_ng_dir .. "/lib/ld-linux-armhf.so.3"
    if file_exists(ld_linux) then
        Config.ld_linux = ld_linux
        local espeak_lib = espeak_ng_dir .. "/lib"
        Config.lib_path = Config.lib_path
            and (Config.lib_path .. ":" .. espeak_lib) or espeak_lib
    end

    os.execute(string.format('mkdir -p "%s" "%s"', Config.output_dir, Config.results_dir))
end

local function build_piper_cmd(extra_flags)
    extra_flags = extra_flags or ""
    local prefix = ""
    if Config.ld_linux then
        prefix = string.format('"%s" --library-path "%s" ',
            Config.ld_linux, Config.lib_path)
    elseif Config.lib_path then
        prefix = string.format('LD_LIBRARY_PATH="%s" ', Config.lib_path)
    end
    local espeak_flag = ""
    if Config.espeak_data then
        espeak_flag = string.format(' --espeak_data "%s"', Config.espeak_data)
    end
    return string.format('nice -n 19 %s%s --model "%s"%s --sentence_silence 0 %s',
        prefix, Config.piper_bin, Config.model_path, espeak_flag, extra_flags)
end

-- ── WAV concatenation ────────────────────────────────────────────────

local function concat_wavs(input_files, output_path)
    if #input_files == 0 then return false end
    if #input_files == 1 then
        os.execute(string.format('cp "%s" "%s"', input_files[1], output_path))
        return true
    end
    local out = io.open(output_path, "wb")
    if not out then return false end
    local total_data_size = 0
    local header = nil
    local pcm_chunks = {}
    for _, path in ipairs(input_files) do
        local f = io.open(path, "rb")
        if f then
            local h = f:read(44)
            if h and #h == 44 then
                if not header then header = h end
                local data = f:read("*a")
                if data then
                    table.insert(pcm_chunks, data)
                    total_data_size = total_data_size + #data
                end
            end
            f:close()
        end
    end
    if not header then out:close(); return false end
    local function le32(n)
        return string.char(n % 256, math.floor(n/256) % 256,
            math.floor(n/65536) % 256, math.floor(n/16777216) % 256)
    end
    header = header:sub(1, 4) .. le32(36 + total_data_size) ..
             header:sub(9, 40) .. le32(total_data_size)
    out:write(header)
    for _, chunk in ipairs(pcm_chunks) do out:write(chunk) end
    out:close()
    return true
end

-- ── Sentence splitting functions ─────────────────────────────────────

--[[--
Split at clause boundaries: ; : " - " and ", CONJ"
Returns array of text chunks.
--]]
local function split_at_clauses(text)
    local chunks = {}
    -- Pattern: split at semicolons, colons, or " - " (em-dash surrogate)
    -- Also split at ", <conjunction>" where conjunction is and/but/or/so/yet/nor/
    -- which/that/because/although/however/while/when/where/since/unless/though
    local conjunctions = {
        "and", "but", "or", "so", "yet", "nor",
        "which", "that", "because", "although", "however",
        "while", "when", "where", "since", "unless", "though",
    }
    local conj_set = {}
    for _, c in ipairs(conjunctions) do conj_set[c] = true end

    -- Work through the text finding split points
    local split_positions = {}

    -- Find ; and : positions
    for pos in text:gmatch("()[;:]%s") do
        -- Split AFTER the punctuation and space
        local after = pos + 1
        while after <= #text and text:sub(after, after):match("%s") do
            after = after + 1
        end
        table.insert(split_positions, after)
    end

    -- Find " - " positions
    local search_from = 1
    while true do
        local pos = text:find(" %- ", search_from, true)
        if not pos then break end
        table.insert(split_positions, pos + 3)
        search_from = pos + 3
    end

    -- Find ", <conjunction>" positions
    for pos in text:gmatch("(),%s+") do
        local after_comma = pos + 1
        while after_comma <= #text and text:sub(after_comma, after_comma):match("%s") do
            after_comma = after_comma + 1
        end
        -- Check if next word is a conjunction
        local next_word = text:match("^(%a+)", after_comma)
        if next_word and conj_set[next_word:lower()] then
            table.insert(split_positions, after_comma)
        end
    end

    -- Sort positions and deduplicate
    table.sort(split_positions)
    local unique = {}
    local prev = nil
    for _, p in ipairs(split_positions) do
        if p ~= prev and p > 1 and p <= #text then
            table.insert(unique, p)
            prev = p
        end
    end

    -- Build chunks from split positions
    if #unique == 0 then
        return { text }
    end

    local start = 1
    for _, pos in ipairs(unique) do
        local chunk = text:sub(start, pos - 1):match("^%s*(.-)%s*$")
        if chunk and chunk ~= "" then
            table.insert(chunks, chunk)
        end
        start = pos
    end
    -- Last chunk
    local last = text:sub(start):match("^%s*(.-)%s*$")
    if last and last ~= "" then
        table.insert(chunks, last)
    end

    return #chunks > 0 and chunks or { text }
end

--[[--
Split at fixed character count on word boundaries.
@param text string  Input text
@param max_chars number  Target maximum chunk size
@return table Array of text chunks
--]]
local function split_at_word_boundary(text, max_chars)
    if #text <= max_chars then return { text } end

    local chunks = {}
    local words = {}
    for w in text:gmatch("%S+") do table.insert(words, w) end

    local current = ""
    for _, word in ipairs(words) do
        local candidate = current == "" and word or (current .. " " .. word)
        if #candidate > max_chars and current ~= "" then
            table.insert(chunks, current)
            current = word
        else
            current = candidate
        end
    end
    if current ~= "" then
        table.insert(chunks, current)
    end

    return #chunks > 0 and chunks or { text }
end

--[[--
Hybrid: clause-split first, then chunk any fragments still > max_chars.
@param text string  Input text
@param max_chars number  Maximum chunk size after clause splitting
@return table Array of text chunks
--]]
local function split_hybrid(text, max_chars)
    local clause_chunks = split_at_clauses(text)
    local final = {}
    for _, chunk in ipairs(clause_chunks) do
        if #chunk > max_chars then
            local sub = split_at_word_boundary(chunk, max_chars)
            for _, s in ipairs(sub) do table.insert(final, s) end
        else
            table.insert(final, chunk)
        end
    end
    return final
end

-- ── Persistent server management ─────────────────────────────────────

local Server = {
    _pid = nil,
    _fifo = "/tmp/piper_bench_long_srv",
}

function Server:start()
    os.execute("killall -9 piper 2>/dev/null")
    sleep_ms(300)
    local fifo = self._fifo
    os.execute(string.format('rm -f "%s" "%s.pid" "%s.log"', fifo, fifo, fifo))

    local script = string.format([=[#!/bin/sh
FIFO="%s"
rm -f "$FIFO" "${FIFO}.pid"
mkfifo "$FIFO"
exec 3<>"$FIFO"
%s --json-input <&3 2>>"${FIFO}.log" | while IFS= read -r wav_path; do
  wav_path=$(echo "$wav_path" | tr -d '\r\n')
  if [ -n "$wav_path" ]; then echo "0" > "${wav_path}.done"; fi
done &
PIPE_PID=$!
echo "$PIPE_PID" > "${FIFO}.pid"
wait $PIPE_PID 2>/dev/null
exec 3>&-
rm -f "$FIFO" "${FIFO}.pid"
]=], fifo, build_piper_cmd())

    local sp = fifo .. ".sh"
    local sf = io.open(sp, "w")
    if sf then sf:write(script); sf:close() end
    os.execute('chmod +x "' .. sp .. '"')
    os.execute(string.format('/bin/sh "%s" &', sp))

    log("Waiting for persistent server...")
    local t0 = timestamp_ms()
    for _ = 1, 200 do
        sleep_ms(300)
        local pf = io.open(fifo .. ".pid", "r")
        if pf then
            local pid = pf:read("*a"):gsub("%s+", ""); pf:close()
            self._pid = tonumber(pid)
            log("Server ready (PID %s) in %dms", pid, timestamp_ms() - t0)
            return true
        end
    end
    log("WARNING: Server startup timed out")
    return false
end

function Server:stop()
    if self._pid then
        os.execute(string.format("kill %d 2>/dev/null", self._pid))
    end
    os.execute("killall -9 piper 2>/dev/null")
    local fifo = self._fifo
    os.execute(string.format('rm -f "%s" "%s.pid" "%s.sh" "%s.log"', fifo, fifo, fifo, fifo))
    self._pid = nil
end

--[[--
Synthesize a single text via the persistent server.
@param text string  Text to synthesize
@param wav_file string  Output WAV path
@param timeout_s number  Timeout in seconds (default 300)
@return number synth_ms, number audio_ms
--]]
function Server:synthesize(text, wav_file, timeout_s)
    timeout_s = timeout_s or 180
    local done_marker = wav_file .. ".done"
    os.execute(string.format('rm -f "%s" "%s"', wav_file, done_marker))

    local clean = clean_text(text):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\t", "\\t")
    local json_line = string.format('{"text":"%s","output_file":"%s"}\n', clean, wav_file)

    local t0 = timestamp_ms()
    local ff = io.open(self._fifo, "w")
    if ff then ff:write(json_line); ff:close() end

    local polls = math.floor(timeout_s * 5)  -- 200ms interval
    for _ = 1, polls do
        sleep_ms(200)
        if file_exists(done_marker) then break end
    end
    local t1 = timestamp_ms()
    os.remove(done_marker)

    local dur = wav_duration_ms(wav_file)
    return t1 - t0, dur
end

-- ── Strategies ───────────────────────────────────────────────────────

local Strategies = {}

-- ── 1. no_split: send full sentence as-is ────────────────────────────

Strategies.no_split = {
    name = "no_split",
    description = "Baseline - send entire sentence unchanged to Piper",
}

function Strategies.no_split:init() Server:start() end
function Strategies.no_split:cleanup() Server:stop() end

function Strategies.no_split:synthesize_one(idx, sent)
    local wav = string.format("%s/nosplit_%d.wav", Config.output_dir, idx)
    local t0 = timestamp_ms()
    local synth_ms, audio_ms = Server:synthesize(sent.text, wav)
    return {
        total_synth_ms = synth_ms,
        first_chunk_ms = synth_ms,  -- no splitting, same as total
        audio_duration_ms = audio_ms,
        chunks = 1,
        chunk_details = { { text = sent.text, len = #sent.text, synth_ms = synth_ms, audio_ms = audio_ms } },
        wav_file = wav,
    }
end

-- ── 2. clause_split: natural clause boundaries ──────────────────────

Strategies.clause_split = {
    name = "clause_split",
    description = "Split at ; : - and ', conjunction' boundaries",
}

function Strategies.clause_split:init() Server:start() end
function Strategies.clause_split:cleanup() Server:stop() end

function Strategies.clause_split:synthesize_one(idx, sent)
    local chunks = split_at_clauses(sent.text)
    local chunk_details = {}
    local wav_files = {}
    local total_synth = 0
    local total_audio = 0
    local first_chunk_ms = nil

    for ci, chunk in ipairs(chunks) do
        local wav = string.format("%s/clause_%d_%d.wav", Config.output_dir, idx, ci)
        local synth_ms, audio_ms = Server:synthesize(chunk, wav)
        total_synth = total_synth + synth_ms
        total_audio = total_audio + audio_ms
        if not first_chunk_ms then first_chunk_ms = synth_ms end
        table.insert(chunk_details, {
            text = chunk, len = #chunk, synth_ms = synth_ms, audio_ms = audio_ms,
        })
        table.insert(wav_files, wav)
    end

    -- Concatenate WAVs
    local combined = string.format("%s/clause_%d.wav", Config.output_dir, idx)
    concat_wavs(wav_files, combined)
    -- Clean intermediates
    for _, w in ipairs(wav_files) do os.remove(w) end

    return {
        total_synth_ms = total_synth,
        first_chunk_ms = first_chunk_ms or 0,
        audio_duration_ms = total_audio,
        chunks = #chunks,
        chunk_details = chunk_details,
        wav_file = combined,
    }
end

-- ── 3-5. chunk_N: fixed-size word-boundary splitting ────────────────

local function make_chunk_strategy(name, max_chars)
    local strat = {
        name = name,
        description = string.format("Fixed-size chunking at ~%d chars on word boundaries", max_chars),
        _max_chars = max_chars,
    }

    function strat:init() Server:start() end
    function strat:cleanup() Server:stop() end

    function strat:synthesize_one(idx, sent)
        local chunks = split_at_word_boundary(sent.text, self._max_chars)
        local chunk_details = {}
        local wav_files = {}
        local total_synth = 0
        local total_audio = 0
        local first_chunk_ms = nil

        for ci, chunk in ipairs(chunks) do
            local wav = string.format("%s/%s_%d_%d.wav", Config.output_dir, name, idx, ci)
            local synth_ms, audio_ms = Server:synthesize(chunk, wav)
            total_synth = total_synth + synth_ms
            total_audio = total_audio + audio_ms
            if not first_chunk_ms then first_chunk_ms = synth_ms end
            table.insert(chunk_details, {
                text = chunk, len = #chunk, synth_ms = synth_ms, audio_ms = audio_ms,
            })
            table.insert(wav_files, wav)
        end

        local combined = string.format("%s/%s_%d.wav", Config.output_dir, name, idx)
        concat_wavs(wav_files, combined)
        for _, w in ipairs(wav_files) do os.remove(w) end

        return {
            total_synth_ms = total_synth,
            first_chunk_ms = first_chunk_ms or 0,
            audio_duration_ms = total_audio,
            chunks = #chunks,
            chunk_details = chunk_details,
            wav_file = combined,
        }
    end

    return strat
end

Strategies.chunk_200 = make_chunk_strategy("chunk_200", 200)
Strategies.chunk_300 = make_chunk_strategy("chunk_300", 300)
Strategies.chunk_400 = make_chunk_strategy("chunk_400", 400)

-- ── 6. hybrid: clause-first, then chunk large fragments ─────────────

Strategies.hybrid = {
    name = "hybrid",
    description = "Clause-split first, then word-boundary chunk any fragments > 300 chars",
    _max_chars = 300,
}

function Strategies.hybrid:init() Server:start() end
function Strategies.hybrid:cleanup() Server:stop() end

function Strategies.hybrid:synthesize_one(idx, sent)
    local chunks = split_hybrid(sent.text, self._max_chars)
    local chunk_details = {}
    local wav_files = {}
    local total_synth = 0
    local total_audio = 0
    local first_chunk_ms = nil

    for ci, chunk in ipairs(chunks) do
        local wav = string.format("%s/hybrid_%d_%d.wav", Config.output_dir, idx, ci)
        local synth_ms, audio_ms = Server:synthesize(chunk, wav)
        total_synth = total_synth + synth_ms
        total_audio = total_audio + audio_ms
        if not first_chunk_ms then first_chunk_ms = synth_ms end
        table.insert(chunk_details, {
            text = chunk, len = #chunk, synth_ms = synth_ms, audio_ms = audio_ms,
        })
        table.insert(wav_files, wav)
    end

    local combined = string.format("%s/hybrid_%d.wav", Config.output_dir, idx)
    concat_wavs(wav_files, combined)
    for _, w in ipairs(wav_files) do os.remove(w) end

    return {
        total_synth_ms = total_synth,
        first_chunk_ms = first_chunk_ms or 0,
        audio_duration_ms = total_audio,
        chunks = #chunks,
        chunk_details = chunk_details,
        wav_file = combined,
    }
end

-- ── 7. progressive: simulate play-while-synthesizing ─────────────────
-- Split with hybrid strategy, measure "effective latency" as:
--   first_chunk_synth + max(0, chunk_N_synth - chunk_(N-1)_audio) for each N

Strategies.progressive = {
    name = "progressive",
    description = "Hybrid split + simulate play-while-synthesizing overlap",
    _max_chars = 300,
}

function Strategies.progressive:init() Server:start() end
function Strategies.progressive:cleanup() Server:stop() end

function Strategies.progressive:synthesize_one(idx, sent)
    local chunks = split_hybrid(sent.text, self._max_chars)
    local chunk_details = {}
    local wav_files = {}
    local total_synth = 0
    local total_audio = 0
    local first_chunk_ms = nil
    -- Track effective timeline: playback starts after first chunk synth,
    -- subsequent gaps = max(0, synth_N - audio_N-1)
    local effective_gaps = 0
    local prev_audio = 0

    for ci, chunk in ipairs(chunks) do
        local wav = string.format("%s/prog_%d_%d.wav", Config.output_dir, idx, ci)
        local synth_ms, audio_ms = Server:synthesize(chunk, wav)
        total_synth = total_synth + synth_ms
        total_audio = total_audio + audio_ms

        if not first_chunk_ms then
            first_chunk_ms = synth_ms
        else
            -- Gap: if this chunk took longer to synthesize than the previous
            -- chunk's audio, the user would hear silence
            local gap = math.max(0, synth_ms - prev_audio)
            effective_gaps = effective_gaps + gap
        end
        prev_audio = audio_ms

        table.insert(chunk_details, {
            text = chunk, len = #chunk, synth_ms = synth_ms, audio_ms = audio_ms,
        })
        table.insert(wav_files, wav)
    end

    local combined = string.format("%s/prog_%d.wav", Config.output_dir, idx)
    concat_wavs(wav_files, combined)
    for _, w in ipairs(wav_files) do os.remove(w) end

    return {
        total_synth_ms = total_synth,
        first_chunk_ms = first_chunk_ms or 0,
        audio_duration_ms = total_audio,
        chunks = #chunks,
        chunk_details = chunk_details,
        wav_file = combined,
        effective_gaps_ms = effective_gaps,
        -- Effective wall time = first_chunk + total_audio + gaps
        -- (vs. no_split where wall time = total_synth)
        effective_wall_ms = (first_chunk_ms or 0) + total_audio + effective_gaps,
    }
end

-- ── Strategy dispatch ────────────────────────────────────────────────

local STRATEGY_ORDER = {
    "no_split", "clause_split",
    "chunk_200", "chunk_300", "chunk_400",
    "hybrid", "progressive",
}

-- ── Results & Reporting ──────────────────────────────────────────────

local function write_report(strategy_name, sentence_results, wall_ms)
    local path = string.format("%s/%s.txt", Config.results_dir, strategy_name)
    local f = io.open(path, "w")
    if not f then return end

    f:write(string.format("═══════════════════════════════════════════════════════════════════════════\n"))
    f:write(string.format("  LONG-SENTENCE BENCHMARK - %s\n", strategy_name:upper()))
    f:write(string.format("═══════════════════════════════════════════════════════════════════════════\n"))
    f:write(string.format("  Model:   %s\n", Config.model_path:match("([^/]+)$") or Config.model_path))
    f:write(string.format("  Date:    %s\n", os.date()))
    f:write(string.format("  Wall:    %.1f s\n", wall_ms / 1000))
    f:write(string.format("───────────────────────────────────────────────────────────────────────────\n"))
    f:write(string.format("%-5s %6s %7s %7s %7s %3s %7s  %s\n",
        "#", "Chars", "Synth", "1stChk", "Audio", "N", "Ch/s", "Text"))
    f:write(string.format("───────────────────────────────────────────────────────────────────────────\n"))

    local totals = { synth = 0, first = 0, audio = 0, chars = 0, chunks = 0 }

    for i, r in ipairs(sentence_results) do
        local chars = #r.sent.text
        local cps = r.total_synth_ms > 0 and chars * 1000 / r.total_synth_ms or 0
        f:write(string.format("%-5d %6d %6.1fs %6.1fs %6.1fs %3d %7.1f  %s\n",
            i, chars,
            r.total_synth_ms / 1000, r.first_chunk_ms / 1000,
            r.audio_duration_ms / 1000, r.chunks, cps,
            r.sent.text:sub(1, 40)))
        totals.synth = totals.synth + r.total_synth_ms
        totals.first = totals.first + r.first_chunk_ms
        totals.audio = totals.audio + r.audio_duration_ms
        totals.chars = totals.chars + chars
        totals.chunks = totals.chunks + r.chunks

        -- Chunk breakdown
        if r.chunks > 1 then
            for ci, cd in ipairs(r.chunk_details) do
                f:write(string.format("      chunk %d: %d chars, %.1fs synth, %.1fs audio | %s\n",
                    ci, cd.len, cd.synth_ms / 1000, cd.audio_ms / 1000,
                    cd.text:sub(1, 50)))
            end
        end
    end

    f:write(string.format("───────────────────────────────────────────────────────────────────────────\n"))
    f:write(string.format("TOTALS: %d chars, %.1fs synth, %.1fs first-chunk, %.1fs audio, %d chunks\n",
        totals.chars, totals.synth/1000, totals.first/1000, totals.audio/1000, totals.chunks))
    f:write(string.format("  Throughput:    %.1f chars/s\n",
        totals.synth > 0 and totals.chars * 1000 / totals.synth or 0))
    f:write(string.format("  Avg 1st-chunk: %.1f s\n",
        #sentence_results > 0 and totals.first / #sentence_results / 1000 or 0))
    f:write(string.format("  RT factor:     %.3fx\n",
        totals.synth > 0 and totals.audio / totals.synth or 0))
    f:write(string.format("═══════════════════════════════════════════════════════════════════════════\n"))

    f:close()
    log("Report: %s", path)
end

local function write_comparison(all_results)
    local path = Config.results_dir .. "/COMPARISON.txt"
    local f = io.open(path, "w")
    if not f then return end

    f:write("╔════════════════════════════════════════════════════════════════════════════════════════╗\n")
    f:write("║         LONG-SENTENCE BENCHMARK - STRATEGY COMPARISON                                ║\n")
    f:write("╠════════════════════════════════════════════════════════════════════════════════════════╣\n")
    f:write(string.format("║  Model: %-80s║\n",
        Config.model_path:match("([^/]+)$") or Config.model_path))
    f:write(string.format("║  Date:  %-80s║\n", os.date()))
    f:write("╠════════════════════════════════════════════════════════════════════════════════════════╣\n")

    -- Summary table
    f:write(string.format("║ %-15s │ %8s │ %8s │ %8s │ %6s │ %7s │ %6s │ %7s ║\n",
        "Strategy", "TotalSyn", "Avg1stCh", "AvgSynth", "AvgChk", "Ch/s", "RT", "EffGap"))
    f:write("╠════════════════════════════════════════════════════════════════════════════════════════╣\n")

    for _, entry in ipairs(all_results) do
        local totals = { synth = 0, first = 0, audio = 0, chars = 0, chunks = 0, eff_gaps = 0 }
        for _, r in ipairs(entry.results) do
            totals.synth = totals.synth + r.total_synth_ms
            totals.first = totals.first + r.first_chunk_ms
            totals.audio = totals.audio + r.audio_duration_ms
            totals.chars = totals.chars + #r.sent.text
            totals.chunks = totals.chunks + r.chunks
            totals.eff_gaps = totals.eff_gaps + (r.effective_gaps_ms or 0)
        end
        local n = #entry.results
        f:write(string.format("║ %-15s │ %7.1fs │ %7.1fs │ %7.1fs │ %6.1f │ %7.1f │ %5.3f │ %6.1fs ║\n",
            entry.name,
            totals.synth / 1000,
            n > 0 and totals.first / n / 1000 or 0,
            n > 0 and totals.synth / n / 1000 or 0,
            n > 0 and totals.chunks / n or 0,
            totals.synth > 0 and totals.chars * 1000 / totals.synth or 0,
            totals.synth > 0 and totals.audio / totals.synth or 0,
            totals.eff_gaps / 1000))
    end

    f:write("╚════════════════════════════════════════════════════════════════════════════════════════╝\n\n")

    -- Per-sentence comparison across strategies (grouped by sentence length)
    f:write("Per-sentence comparison (synth time in seconds):\n")
    f:write(string.format("%-6s │", "Chars"))
    for _, entry in ipairs(all_results) do
        f:write(string.format(" %-12s│", entry.name:sub(1, 12)))
    end
    f:write("\n")
    f:write(string.rep("─", 8 + 13 * #all_results) .. "\n")

    -- Use first strategy's results as reference for sentence order
    if #all_results > 0 then
        for si, ref in ipairs(all_results[1].results) do
            f:write(string.format("%-6d │", #ref.sent.text))
            for _, entry in ipairs(all_results) do
                local r = entry.results[si]
                if r then
                    f:write(string.format(" %5.1fs/%dchk │",
                        r.total_synth_ms / 1000, r.chunks))
                else
                    f:write("     -/-     │")
                end
            end
            f:write(string.format("  %s\n", ref.sent.text:sub(1, 30)))
        end
    end

    -- First-chunk latency comparison
    f:write("\nFirst-chunk latency (seconds) - time until audio can start:\n")
    f:write(string.format("%-6s │", "Chars"))
    for _, entry in ipairs(all_results) do
        f:write(string.format(" %-12s│", entry.name:sub(1, 12)))
    end
    f:write("\n")
    f:write(string.rep("─", 8 + 13 * #all_results) .. "\n")

    if #all_results > 0 then
        for si, ref in ipairs(all_results[1].results) do
            f:write(string.format("%-6d │", #ref.sent.text))
            for _, entry in ipairs(all_results) do
                local r = entry.results[si]
                if r then
                    f:write(string.format(" %10.1fs │", r.first_chunk_ms / 1000))
                else
                    f:write("          -  │")
                end
            end
            f:write("\n")
        end
    end

    f:close()
    log("Comparison: %s", path)

    -- Print to stdout
    local rf = io.open(path, "r")
    if rf then io.write("\n" .. rf:read("*a")); rf:close() end
end

-- ── Main ─────────────────────────────────────────────────────────────

local function main()
    local args = arg or {}
    local run_strategy = nil
    local min_chars = 0

    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "--list" then
            printf("Available strategies:\n")
            for _, name in ipairs(STRATEGY_ORDER) do
                printf("  %-15s  %s\n", name, Strategies[name].description)
            end
            return
        elseif a == "--min" then
            i = i + 1
            min_chars = tonumber(args[i]) or 0
        elseif a == "--help" or a == "-h" then
            printf("Usage: lua benchmark_long.lua [strategy] [--min N] [--list]\n")
            printf("  strategy   Run only this strategy (default: all)\n")
            printf("  --min N    Only test sentences >= N chars\n")
            printf("  --list     List available strategies\n")
            return
        elseif not a:match("^%-") then
            run_strategy = a
        end
        i = i + 1
    end

    resolve_config()

    -- Load test document
    local script_dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
    local TestDocLong = dofile(script_dir .. "testdoc_long.lua")

    local stats = TestDocLong:getStats()
    log("Test document: %d sentences, %d-%d chars (median %d, avg %.0f)",
        stats.count, stats.min_len, stats.max_len, stats.median_len, stats.avg_len)

    -- Filter sentences
    local test_sentences = {}
    for _, s in ipairs(TestDocLong:getSentences()) do
        if #s.text >= min_chars then
            table.insert(test_sentences, s)
        end
    end
    log("Testing %d sentences (min %d chars)", #test_sentences, min_chars)

    -- Preview splits for first long sentence
    if #test_sentences > 0 then
        local sample = test_sentences[math.min(5, #test_sentences)]
        log("Split preview for %d-char sentence:", #sample.text)
        log("  Clause splits:")
        for ci, c in ipairs(split_at_clauses(sample.text)) do
            log("    %d. [%d chars] %s", ci, #c, c:sub(1, 60))
        end
        log("  Word-boundary 200:")
        for ci, c in ipairs(split_at_word_boundary(sample.text, 200)) do
            log("    %d. [%d chars] %s", ci, #c, c:sub(1, 60))
        end
        log("  Hybrid 300:")
        for ci, c in ipairs(split_hybrid(sample.text, 300)) do
            log("    %d. [%d chars] %s", ci, #c, c:sub(1, 60))
        end
    end

    -- Determine strategies
    local strategies_to_run = {}
    if run_strategy then
        if Strategies[run_strategy] then
            table.insert(strategies_to_run, run_strategy)
        else
            io.stderr:write("Unknown strategy: " .. run_strategy .. "\n")
            os.exit(1)
        end
    else
        strategies_to_run = STRATEGY_ORDER
    end

    -- Run benchmarks
    local all_results = {}

    for _, name in ipairs(strategies_to_run) do
        local strat = Strategies[name]
        if strat then
            log("═══════════════════════════════════════════════════════")
            log("STRATEGY: %s", name)
            log("  %s", strat.description)
            log("═══════════════════════════════════════════════════════")

            os.execute(string.format('rm -f %s/*.wav %s/*.done',
                Config.output_dir, Config.output_dir))

            -- Init (starts persistent server)
            local ok, err = pcall(function() strat:init() end)
            if not ok then
                log("ERROR: Init failed: %s", tostring(err))
                goto continue
            end

            local t_wall_0 = timestamp_ms()
            local sentence_results = {}

            for si, sent in ipairs(test_sentences) do
                printf("  [%d/%d] %d chars: ", si, #test_sentences, #sent.text)

                local rok, result = pcall(function()
                    return strat:synthesize_one(si, sent)
                end)

                if rok and result then
                    result.sent = sent
                    table.insert(sentence_results, result)
                    local cps = result.total_synth_ms > 0
                        and #sent.text * 1000 / result.total_synth_ms or 0
                    printf("%.1fs synth, %.1fs 1st, %.1fs audio, %d chunks, %.1f ch/s\n",
                        result.total_synth_ms / 1000,
                        result.first_chunk_ms / 1000,
                        result.audio_duration_ms / 1000,
                        result.chunks, cps)
                else
                    printf("ERROR: %s\n", tostring(result))
                end
            end

            local wall_ms = timestamp_ms() - t_wall_0

            write_report(name, sentence_results, wall_ms)
            table.insert(all_results, { name = name, results = sentence_results })

            pcall(function() strat:cleanup() end)

            os.execute(string.format('rm -f %s/*.wav %s/*.done',
                Config.output_dir, Config.output_dir))

            ::continue::
        end
    end

    if #all_results > 1 then
        write_comparison(all_results)
    end

    log("Benchmark complete. Results in %s", Config.results_dir)
end

main()
