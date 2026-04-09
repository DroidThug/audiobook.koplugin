--[[--
TTS Engine Module
Handles text-to-speech synthesis with timing metadata.

@module ttsengine
--]]

local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local ffi = require("ffi")

-- Declare C functions needed for pipe buffer resize and Piper server FIFO I/O.
-- Each declaration is wrapped separately so a duplicate from another module
-- doesn't prevent the remaining declarations from being registered.
-- CRITICAL: fcntl MUST be declared as variadic (...) — on ARM EABI, variadic
-- args go on the stack while fixed args go in registers.  The old declaration
-- int fcntl(int fd, int cmd, int arg) put the size in register r2, but the
-- real libc fcntl read it from the stack → garbage → EINVAL.
pcall(function() ffi.cdef[[ int open(const char *pathname, int flags); ]] end)
pcall(function() ffi.cdef[[ int close(int fd); ]] end)
pcall(function() ffi.cdef[[ int fcntl(int fd, int cmd, ...); ]] end)
pcall(function() ffi.cdef[[ long write(int fd, const void *buf, unsigned long count); ]] end)

-- LIPC FFI: direct binding to Kindle's liblipc.so for native TTS playback.
-- CLI tools (lipc-set-prop) use anonymous, transient LIPC connections.
-- VoiceView uses named, persistent connections via the C API.
-- playermgr may only trigger TTS for named LIPC sources.
pcall(function() ffi.cdef[[
    typedef struct _LIPC LIPC;
    LIPC *LipcOpenEx(const char *service_name, int *code);
    LIPC *LipcOpenNoName(int *code);
    int LipcClose(LIPC *lipc);
    int LipcSetStringProperty(LIPC *lipc, const char *source, const char *prop, const char *value);
    int LipcGetIntProperty(LIPC *lipc, const char *source, const char *prop, int *value);
    int LipcGetStringProperty(LIPC *lipc, const char *source, const char *prop, char **value);
    void LipcFreeString(char *str);
]] end)
local _lipc_lib  -- loaded lazily on first Kindle native TTS use
local logger = require("logger")
local time = require("ui/time")
local _ = require("gettext")

-- Shared utility modules (DRY: extracted from ttsengine, synccontroller, main)
local _utils_dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
local Utils = dofile(_utils_dir .. "utils.lua")
local WavUtils = dofile(_utils_dir .. "wavutils.lua")
local PiperQueue = dofile(_utils_dir .. "piperqueue.lua")
local AndroidTts = dofile(_utils_dir .. "androidtts.lua")

local TTSEngine = {
    -- Supported TTS backends
    BACKENDS = {
        PICO = "pico",
        ESPEAK = "espeak", 
        FLITE = "flite",
        FESTIVAL = "festival",
        ANDROID = "android",
        PIPER = "piper",
        KINDLE_NATIVE = "kindle-native",
    },
    
    -- Default settings
    DEFAULT_RATE = 1.0,
    DEFAULT_PITCH = 1.0,
    DEFAULT_VOLUME = 1.0,
    
    -- Status flags
    backend_error = nil,
    player_error = nil,
}

function TTSEngine:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    
    o.rate = o.rate or self.DEFAULT_RATE
    o.pitch = o.pitch or 50  -- espeak-ng default pitch
    o.volume = o.volume or self.DEFAULT_VOLUME
    o.voice = o.voice or "en"  -- espeak-ng voice id
    o.word_gap = o.word_gap or 0  -- espeak-ng word gap (units of 10ms)
    o.clause_pause = o.clause_pause or 0  -- extra pause at clause punctuation (seconds)
    o.backend = nil
    o.is_speaking = false
    o.is_paused = false
    o.current_audio_file = nil
    o.timing_data = {}
    o.on_word_callback = nil
    o.on_complete_callback = nil
    o.audio_pid = nil
    -- Piper TTS state
    o.piper_model = o.piper_model or nil  -- path or name of .onnx voice model
    o.piper_speaker = o.piper_speaker or 0  -- speaker id for multi-speaker models
    -- Prefetch state: holds pre-synthesized audio for the next sentence
    o._prefetch_file = nil
    o._prefetch_timing = nil
    o._prefetch_text = nil
    -- Piper async prefetch queue (extracted module)
    o._piper = PiperQueue:new{engine = o}
    -- Android TTS wrapper (initialized lazily in detectBackend)
    o._android_tts = nil
    
    o:detectBackend()
    
    return o
end

--[[--
Detect available TTS backend.
--]]
function TTSEngine:detectBackend()
    local is_android = Device:isAndroid()

    --- Check if a file exists, with shell fallback for devices where
    --- io.open may fail on binary files (observed on some Kindle models).
    local function fileAccessible(path)
        local f, err = io.open(path, "r")
        if f then
            f:close()
            return true
        end
        -- io.open failed -- try shell-based check as fallback
        local rc = os.execute("test -f '" .. path .. "' 2>/dev/null")
        if rc == 0 or rc == true then
            logger.warn("TTSEngine: io.open failed for", path, "(" .. tostring(err) .. ") but test -f succeeded")
            return true
        end
        return false
    end

    --- Rename a .bin-suffixed file back to its original name.
    -- The release zip ships ELF binaries with a .bin extension so they
    -- survive Windows extraction / antivirus.  On first run we rename
    -- them back.  Returns true if the file now exists at `path`.
    local function ensureBinary(path)
        if fileAccessible(path) then return true end
        local bin_path = path .. ".bin"
        if fileAccessible(bin_path) then
            local ok = os.rename(bin_path, path)
            if ok then
                os.execute("chmod +x '" .. path .. "' 2>/dev/null")
                logger.warn("TTSEngine: renamed", bin_path, "->", path)
                return true
            end
            -- os.rename failed (cross-device?), try shell mv
            local rc = os.execute("mv '" .. bin_path .. "' '" .. path .. "' 2>/dev/null")
            if rc == 0 or rc == true then
                os.execute("chmod +x '" .. path .. "' 2>/dev/null")
                logger.warn("TTSEngine: mv renamed", bin_path, "->", path)
                return true
            end
            logger.warn("TTSEngine: found .bin but rename failed:", bin_path)
        end
        return false
    end

    -- On Android, the bundled espeak-ng/Piper binaries are compiled for Linux
    -- (glibc) and won't run on Android's Bionic libc.  Skip bundled binaries
    -- and go straight to system PATH detection.
    if not is_android then
        -- Detect all available bundled engines first, then pick the best default.
        local plugin_dir = self.plugin_dir or "/mnt/onboard/.adds/koreader/plugins/audiobook.koplugin"
        logger.warn("TTSEngine: detectBackend plugin_dir =", plugin_dir)

        -- Check for bundled espeak-ng (rename .bin -> original if needed)
        local bundled_base = plugin_dir .. "/espeak-ng"
        local bundled_bin = bundled_base .. "/bin/espeak-ng"
        local found_espeak = false
        if ensureBinary(bundled_bin) then
            found_espeak = true
            self.backend_cmd = bundled_bin
            self.espeak_bin = bundled_bin  -- keep reference for fallback even when Piper is active
            self.espeak_lib_path = bundled_base .. "/lib"
            self.espeak_data_path = bundled_base .. "/share"
            self.espeak_linker = bundled_base .. "/lib/ld-linux-armhf.so.3"
            logger.dbg("TTSEngine: Found bundled espeak-ng at", bundled_bin)
        else
            logger.warn("TTSEngine: bundled espeak-ng not found at", bundled_bin)
        end

        -- Check for bundled Piper TTS binary (rename .bin -> original if needed)
        local piper_dir = plugin_dir .. "/piper"
        local bundled_piper_bin = piper_dir .. "/piper"
        local found_piper = false
        if ensureBinary(bundled_piper_bin) then
            -- Also rename Piper's helper binaries (.bin -> original)
            ensureBinary(piper_dir .. "/piper_phonemize")
            ensureBinary(piper_dir .. "/espeak-ng")
            found_piper = true
            self.piper_cmd = bundled_piper_bin
            self.piper_model_dir = piper_dir
            logger.dbg("TTSEngine: Found bundled Piper TTS at", bundled_piper_bin)
        else
            logger.warn("TTSEngine: bundled Piper not found at", bundled_piper_bin)
        end

        -- Check for bundled wav-play (ALSA player for devices without aplay)
        local wav_play_bin = plugin_dir .. "/wav-play/wav-play"
        if ensureBinary(wav_play_bin) then
            self._wav_play_bin = wav_play_bin
            self._wav_play_lib = plugin_dir .. "/wav-play/lib"
            logger.dbg("TTSEngine: Found bundled wav-play at", wav_play_bin)
        end

        -- Pick default backend: espeak-ng first (lighter), then Piper
        if found_espeak then
            self.backend = self.BACKENDS.ESPEAK
            return
        elseif found_piper then
            self.backend = self.BACKENDS.PIPER
            self.backend_cmd = bundled_piper_bin
            return
        end
    end

    -- Fall back to system PATH (also the primary path on Android)
    local backends_to_try = {
        {name = self.BACKENDS.ESPEAK, cmd = "espeak-ng"},
        {name = self.BACKENDS.ESPEAK, cmd = "espeak"},
        {name = self.BACKENDS.PIPER, cmd = "piper"},
        {name = self.BACKENDS.PICO, cmd = "pico2wave"},
        {name = self.BACKENDS.FLITE, cmd = "flite"},
        {name = self.BACKENDS.FESTIVAL, cmd = "festival"},
    }
    
    for _, backend in ipairs(backends_to_try) do
        if self:commandExists(backend.cmd) then
            self.backend = backend.name
            self.backend_cmd = backend.cmd
            logger.dbg("TTSEngine: Using", backend.name, "backend with command:", backend.cmd)
            return
        end
    end
    
    -- Log what we searched for
    logger.warn("TTSEngine: No TTS backend found. Searched for: espeak-ng, espeak, pico2wave, flite, festival")

    -- On Android, try the native TextToSpeech API via JNI
    if is_android then
        local atts = AndroidTts:new{
            plugin_dir = self.plugin_dir or ".",
        }
        if atts:init() then
            -- Wait up to 3 seconds for the TTS engine to initialize
            if atts:waitForInit(3000) then
                self._android_tts = atts
                self.backend = self.BACKENDS.ANDROID
                logger.dbg("TTSEngine: Using Android TTS backend")
                return
            else
                atts:shutdown()
                logger.warn("TTSEngine: Android TTS init timed out or failed")
            end
        else
            logger.warn("TTSEngine: Android TTS helper .dex not available")
        end
    end

    -- Kindle native TTS: Amazon's Ivona SDK via tts.orchestrator/playermgr.
    -- Last resort when no bundled or system TTS binaries are found.
    -- The Kindle's built-in TTS handles both synthesis and audio output.
    if Device:isKindle() and self:commandExists("lipc-get-prop") then
        local h = io.popen("lipc-get-prop com.lab126.tts.orchestrator orchestratorStarted 2>/dev/null")
        if h then
            local val = h:read("*a") or ""; h:close()
            if val:match("^%s*1") then
                self.backend = self.BACKENDS.KINDLE_NATIVE
                logger.warn("TTSEngine: Using Kindle native TTS (Ivona SDK via tts.orchestrator)")
                return
            end
        end
    end

    self.backend = nil
    if is_android then
        self.backend_error = _("No TTS engine available on this device.\n\nThe plugin needs the Android TTS helper (.dex) which is not yet included.\n\nAs a workaround, install espeak-ng via Termux:\n  pkg install espeak-ng\n\nThen add Termux to your PATH before launching KOReader.")
    else
        -- Check if the user has .onnx voice models but no binaries.
        -- This usually means a source-code install or incomplete extraction.
        local plugin_dir = self.plugin_dir or "."
        local has_onnx = false
        local lh = io.popen("ls '" .. plugin_dir .. "'/piper/*.onnx 2>/dev/null")
        if lh then
            local lr = lh:read("*a") or ""
            lh:close()
            has_onnx = lr:match("%.onnx")
        end
        if has_onnx then
            self.backend_error = _("No TTS engine found.\n\nVoice model files were found but the TTS binaries (espeak-ng, piper) are missing.\n\nPlease download the .zip file (audiobook-koplugin-v*.zip) from:\nhttps://github.com/stradichenko/audiobook.koplugin/releases/latest\n\nDo not download 'Source code' -- it does not include the TTS engines.\n\nIf you already installed from the .zip, please generate a bug report from the plugin menu and post it on GitHub.")
        else
            self.backend_error = _("No TTS engine found. Please install espeak-ng.")
        end
    end
end

--[[--
Check if a command exists in PATH.
Delegates to shared Utils module.
@param cmd string Command name
@return boolean
--]]
function TTSEngine:commandExists(cmd)
    return Utils.commandExists(cmd)
end

--[[--
Get menu items for engine selection.
@return table Menu items
--]]
function TTSEngine:getEngineMenu()
    local menu = {}
    
    for name, backend in pairs(self.BACKENDS) do
        table.insert(menu, {
            text = name,
            checked_func = function()
                return self.backend == backend
            end,
            callback = function()
                self.backend = backend
                if self.plugin then
                    self.plugin:setSetting("tts_backend", backend)
                end
            end,
        })
    end
    
    return menu
end

--[[--
Set speech rate.
@param rate number Rate multiplier (0.5 to 2.0)
--]]
function TTSEngine:setRate(rate)
    self.rate = math.max(0.25, math.min(2.0, rate))
    logger.dbg("TTSEngine: Rate set to", self.rate)
end

--[[--
Set speech pitch.
@param pitch number Pitch value (0 to 99, espeak-ng native range)
--]]
function TTSEngine:setPitch(pitch)
    self.pitch = math.max(0, math.min(99, pitch))
    logger.dbg("TTSEngine: Pitch set to", self.pitch)
end

--[[--
Set speech volume.
@param volume number Volume level (0.0 to 1.0)
--]]
function TTSEngine:setVolume(volume)
    self.volume = math.max(0.0, math.min(1.0, volume))
    logger.dbg("TTSEngine: Volume set to", self.volume)
end

--[[--
Set the espeak-ng voice/language.
@param voice string espeak-ng voice identifier (e.g. "en", "en-us")
--]]
function TTSEngine:setVoice(voice)
    self.voice = voice
    logger.dbg("TTSEngine: Voice set to", self.voice)
end

--[[--
Set the espeak-ng word gap (extra silence between words).
@param gap number Gap in units of 10ms (0 = default)
--]]
function TTSEngine:setWordGap(gap)
    self.word_gap = gap or 0
    logger.dbg("TTSEngine: Word gap set to", self.word_gap)
end

--[[
Set the extra pause at clause punctuation (commas, semicolons, etc.).
@param pause number Pause in seconds (0 = off)
--]]
function TTSEngine:setClausePause(pause)
    self.clause_pause = pause or 0
    logger.dbg("TTSEngine: Clause pause set to", self.clause_pause)
end

--[[--
Synthesize text and return timing metadata.
@param text string Text to synthesize
@param callback function Callback when synthesis is complete
@return boolean Success
--]]
function TTSEngine:synthesize(text, callback)
    if not self.backend then
        logger.err("TTSEngine: No TTS backend available")
        -- Show error to user
        UIManager:show(InfoMessage:new{
            text = self.backend_error or _("No TTS engine available.\n\nOn Kobo/Kindle, install espeak-ng or use the pre-built release.\nOn Android, TTS is not yet supported.\n\nSee README for details."),
            timeout = 5,
        })
        if callback then
            callback(false, nil)
        end
        return false
    end
    
    self.timing_data = {}

    -- Kindle native TTS: text goes directly to playermgr (no WAV synthesis).
    -- The Kindle's Ivona SDK handles both synthesis and audio output.
    if self.backend == self.BACKENDS.KINDLE_NATIVE then
        self._native_tts_text = text
        self:generateTimingEstimates(text)
        local dur_ms = 0
        if #self.timing_data > 0 then
            dur_ms = self.timing_data[#self.timing_data].end_time
        end
        self._current_audio_duration_ms = dur_ms
        self.current_audio_file = "/tmp/.kindle_native_tts"
        logger.warn("TTSEngine: Kindle native TTS queued:", text:sub(1, 60),
            "est_dur=", dur_ms, "ms")
        if callback then callback(true, self.timing_data) end
        return true
    end
    
    logger.dbg("TTSEngine: Starting synthesis with backend:", self.backend)
    
    return self:synthesizeCommand(text, callback)
end

--[[--
Synthesize using command-line TTS.
@param text string Text to synthesize
@param callback function Callback when synthesis is complete
@return boolean Success
--]]
function TTSEngine:synthesizeCommand(text, callback)
    -- Store text for kindle-native-tts playback (hybrid mode: espeak for
    -- timing, native TTS for audio when tts.orchestrator is available)
    self._native_tts_text = text

    -- Use Android cache dir when running on Android (no /tmp); otherwise /tmp
    local temp_dir = self._android_tts and self._android_tts:getTempDir() or "/tmp"
    self.file_counter = (self.file_counter or 0) + 1
    local audio_file = temp_dir .. "/audiobook_tts_" .. os.time() .. "_" .. self.file_counter .. ".wav"
    local timing_file = temp_dir .. "/audiobook_timing_" .. os.time() .. ".txt"
    
    local cmd
    
    -- Limit text length to avoid command line issues
    local max_text_len = 1000
    if #text > max_text_len then
        text = text:sub(1, max_text_len)
        logger.dbg("TTSEngine: Truncated text to", max_text_len, "chars")
    end
    
    if self.backend == self.BACKENDS.ESPEAK then
        -- espeak-ng supports word timing output
        local speed = math.floor(175 * self.rate) -- Default is 175 wpm
        local pitch = self.pitch or 50
        local amplitude = math.floor((self.volume or 1.0) * 100)
        local voice = self.voice or "en"
        local word_gap = self.word_gap or 0
        -- Build invocation for bundled espeak-ng on Kobo:
        -- Use the bundled ld-linux to bypass the ancient system glibc (2.11)
        local exec_prefix = ""
        if self.espeak_linker then
            exec_prefix = string.format(
                "ESPEAK_DATA_PATH=%s %s --library-path %s ",
                self.espeak_data_path, self.espeak_linker, self.espeak_lib_path
            )
        elseif self.espeak_lib_path then
            exec_prefix = string.format(
                "LD_LIBRARY_PATH=%s ESPEAK_DATA_PATH=%s ",
                self.espeak_lib_path, self.espeak_data_path
            )
        end
        -- Build word-gap flag only if non-zero
        local gap_flag = ""
        if word_gap > 0 then
            gap_flag = string.format(" -g %d", word_gap)
        end
        -- Clause pause: inject SSML <break> tags after clause punctuation
        -- (, ; : — –).  Write SSML to a temp file and use -m -f to avoid
        -- shell escaping issues and ensure ebook text is XML-safe.
        local clause_pause = self.clause_pause or 0
        if clause_pause > 0 then
            local break_ms = math.floor(clause_pause * 1000)
            local break_tag = string.format('<break time="%dms"/>', break_ms)
            -- Minimal XML-escape: only & and < are strictly required in text
            -- nodes.  Strip < and > entirely (HTML artifacts from ebook) and
            -- escape &.  Avoid &apos;/&quot; which espeak-ng may not handle.
            local safe_text = text:gsub("&", "&amp;"):gsub("[<>]", "")
            -- Insert breaks after ASCII clause punctuation
            safe_text = safe_text:gsub("([,;:])(%s)", "%1" .. break_tag .. "%2")
            -- IMPORTANT: Use literal string gsub for multi-byte UTF-8 dashes.
            -- A Lua character class like [—–] matches individual BYTES, which
            -- would corrupt smart quotes, ellipsis, and other characters that
            -- share the 0xe2 0x80 prefix bytes.
            safe_text = safe_text:gsub("—(%s?)", "—" .. break_tag .. "%1")
            safe_text = safe_text:gsub("–(%s?)", "–" .. break_tag .. "%1")
            -- Wrap in SSML speak tags
            safe_text = '<speak>' .. safe_text .. '</speak>'
            -- Write SSML to a temp file (avoids shell escaping entirely)
            self.file_counter = (self.file_counter or 0) + 1
            local ssml_file = temp_dir .. "/audiobook_ssml_" .. os.time() .. "_" .. self.file_counter .. ".xml"
            local sf = io.open(ssml_file, "w")
            if sf then
                sf:write(safe_text)
                sf:close()
                cmd = string.format(
                    '%s%s -v %s -s %d -p %d -a %d%s -m -f "%s" -w "%s" 2>&1',
                    exec_prefix, self.backend_cmd, voice, speed, pitch, amplitude, gap_flag, ssml_file, audio_file
                )
                -- Clean up SSML file after synthesis completes
                self._ssml_temp_file = ssml_file
            end
        end
        if not cmd then
            cmd = string.format(
                '%s%s -v %s -s %d -p %d -a %d%s -w "%s" "%s" 2>&1',
                exec_prefix, self.backend_cmd, voice, speed, pitch, amplitude, gap_flag, audio_file, self:escapeText(text)
            )
        end
    elseif self.backend == self.BACKENDS.PIPER then
        local text_file
        cmd, text_file = self._piper:buildCommand(text, audio_file)
        self._piper_text_file = text_file
    elseif self.backend == self.BACKENDS.PICO then
        cmd = string.format(
            'pico2wave -l en-US -w "%s" "%s" 2>&1',
            audio_file, self:escapeText(text)
        )
    elseif self.backend == self.BACKENDS.FLITE then
        cmd = string.format(
            'flite -t "%s" -o "%s" 2>&1',
            self:escapeText(text), audio_file
        )
    elseif self.backend == self.BACKENDS.FESTIVAL then
        cmd = string.format(
            'echo "%s" | text2wave -o "%s"',
            self:escapeText(text), audio_file
        )
    elseif self.backend == self.BACKENDS.ANDROID then
        -- Android TTS via JNI: synthesize to WAV file asynchronously
        return self:synthesizeAndroid(text, audio_file, callback)
    end
    
    if not cmd then
        logger.err("TTSEngine: Cannot create command for backend:", self.backend)
        UIManager:show(InfoMessage:new{
            text = _("TTS backend error: Cannot create synthesis command."),
            timeout = 3,
        })
        if callback then
            callback(false, nil)
        end
        return false
    end
    
    logger.dbg("TTSEngine: Running:", cmd)
    
    -- Piper TTS is slow (~8-11s per sentence on Kobo ARM).
    -- Run it asynchronously so the UI stays responsive.
    if self.backend == self.BACKENDS.PIPER then
        -- Wrap: run synthesis in background, write a marker file when done
        local done_marker = audio_file .. ".done"
        local bg_cmd = string.format(
            '(%s; echo $? > "%s") &',
            cmd, done_marker
        )
        logger.dbg("TTSEngine: Launching Piper async:", bg_cmd)
        os.execute(bg_cmd)
        -- Save state for the async completion handler
        local piper_text_file = self._piper_text_file
        self._piper_text_file = nil  -- prevent premature cleanup
        local engine = self
        local poll_count = 0
        local max_polls = 120  -- 60 seconds max (120 × 0.5s)
        local function pollPiperDone()
            poll_count = poll_count + 1
            -- Check if the done marker file exists
            local mf = io.open(done_marker, "r")
            if mf then
                local exit_code = mf:read("*a"):gsub("%s+", "")
                mf:close()
                os.remove(done_marker)
                -- Clean up text input file
                if piper_text_file then
                    os.remove(piper_text_file)
                end
                -- Check if audio file was created
                local af = io.open(audio_file, "r")
                if af then
                    af:close()
                    local size = engine:getFileSize(audio_file)
                    if size and size > 0 then
                        engine.current_audio_file = audio_file
                        engine:generateTimingEstimates(text)
                        logger.dbg("TTSEngine: Piper async done, file size:", size)
                        -- Chain: launch next queued prefetch now that the process slot is free
                        engine:_launchNextPiperPrefetch()
                        if callback then
                            callback(true, engine.timing_data)
                        end
                        return
                    end
                end
                logger.err("TTSEngine: Piper async failed, exit_code:", exit_code)
                engine:_launchNextPiperPrefetch()
                if callback then
                    callback(false, nil)
                end
                return
            end
            -- Not done yet — keep polling
            if poll_count < max_polls then
                UIManager:scheduleIn(0.5, pollPiperDone)
            else
                logger.err("TTSEngine: Piper timed out after", max_polls * 0.5, "seconds")
                -- Clean up
                if piper_text_file then os.remove(piper_text_file) end
                os.remove(done_marker)
                engine:_launchNextPiperPrefetch()
                if callback then
                    callback(false, nil)
                end
            end
        end
        -- Start polling after a short initial delay
        UIManager:scheduleIn(0.5, pollPiperDone)
        -- Return nil (not false) to indicate async — caller should NOT
        -- treat this as an immediate failure.
        return nil
    end

    -- Non-Piper backends: run synchronously (espeak-ng is fast ~100ms)
    local result = os.execute(cmd)

    -- Clean up SSML temp file if one was created
    if self._ssml_temp_file then
        os.remove(self._ssml_temp_file)
        self._ssml_temp_file = nil
    end
    -- Clean up Piper text input file if one was created
    if self._piper_text_file then
        os.remove(self._piper_text_file)
        self._piper_text_file = nil
    end
    logger.dbg("TTSEngine: Command result:", result)
    
    -- Check if file was created
    local file = io.open(audio_file, "r")
    if file then
        file:close()
        local size = self:getFileSize(audio_file)
        logger.dbg("TTSEngine: Audio file created, size:", size)
        
        if size and size > 0 then
            self.current_audio_file = audio_file
            -- Generate timing estimates since most engines don't provide timing
            self:generateTimingEstimates(text)
            if callback then
                callback(true, self.timing_data)
            end
            return true
        else
            logger.err("TTSEngine: Audio file is empty")
        end
    else
        logger.err("TTSEngine: Failed to create audio file at:", audio_file)
    end
    
    -- Show error to user
    UIManager:show(InfoMessage:new{
        text = _("TTS synthesis failed.\n\nCould not generate audio file.\nCheck that espeak-ng is installed."),
        timeout = 4,
    })
    if callback then
        callback(false, nil)
    end
    return false
end

--[[--
Get file size.
Delegates to WavUtils.
@param path string File path
@return number|nil File size in bytes
--]]
function TTSEngine:getFileSize(path)
    return WavUtils.getFileSize(path)
end

--[[--
Synthesize using Android TTS via JNI.
Dispatches synthesis to the TtsHelper, then polls for completion.
Runs asynchronously via UIManager:scheduleIn so the UI stays responsive.
@param text string Text to synthesize
@param audio_file string Output WAV file path
@param callback function Callback(success, timing_data)
@return nil  (async -- caller should not treat as immediate failure)
--]]
function TTSEngine:synthesizeAndroid(text, audio_file, callback)
    local atts = self._android_tts
    if not atts then
        logger.err("TTSEngine: Android TTS not initialized")
        if callback then callback(false, nil) end
        return false
    end

    -- Forward rate/pitch settings to the Android engine
    atts:setRate(self.rate or 1.0)
    -- espeak-ng pitch is 0-99 (default 50); Android pitch is a multiplier
    -- around 1.0.  Map 0-99 to 0.5-2.0 range.
    local android_pitch = 0.5 + ((self.pitch or 50) / 99) * 1.5
    atts:setPitch(android_pitch)

    logger.dbg("TTSEngine: Android TTS synthesis for:", text:sub(1, 60))

    -- Dispatch synthesis (async -- the Java engine writes the WAV in background)
    local dispatch = atts:synthesizeToFile(text, audio_file)
    if dispatch ~= 0 then
        logger.err("TTSEngine: Android TTS dispatch failed, code:", dispatch)
        if callback then callback(false, nil) end
        return false
    end

    -- Poll for completion via UIManager (keeps UI responsive)
    local engine = self
    self._android_synth_gen = (self._android_synth_gen or 0) + 1
    local my_gen = self._android_synth_gen
    local poll_count = 0
    local max_polls = 120  -- 60 seconds max (120 x 0.5s)
    local function pollAndroidDone()
        -- Stale poll guard: another synthesis was dispatched
        if (engine._android_synth_gen or 0) ~= my_gen then return end
        poll_count = poll_count + 1
        local status = atts:getSynthStatus()
        if status == 1 then
            -- Synthesis complete -- check the output file
            local f = io.open(audio_file, "r")
            if f then
                f:close()
                local size = engine:getFileSize(audio_file)
                if size and size > 0 then
                    engine.current_audio_file = audio_file
                    engine:generateTimingEstimates(text)
                    logger.dbg("TTSEngine: Android TTS done, file size:", size)
                    if callback then
                        callback(true, engine.timing_data)
                    end
                    return
                end
            end
            logger.err("TTSEngine: Android TTS reported done but WAV missing/empty")
            if callback then callback(false, nil) end
        elseif status == 2 then
            logger.err("TTSEngine: Android TTS synthesis error")
            if callback then callback(false, nil) end
        elseif poll_count < max_polls then
            UIManager:scheduleIn(0.5, pollAndroidDone)
        else
            logger.err("TTSEngine: Android TTS timed out after", max_polls * 0.5, "s")
            if callback then callback(false, nil) end
        end
    end
    UIManager:scheduleIn(0.3, pollAndroidDone)
    -- Return nil to signal async (same convention as Piper)
    return nil
end

--[[--
Generate timing estimates for words in text.
@param text string The text being spoken
--]]
function TTSEngine:generateTimingEstimates(text)
    self.timing_data = {}
    local current_time = 0
    local pos = 1
    local is_piper = self.backend == self.BACKENDS.PIPER
    
    while pos <= #text do
        -- Skip whitespace
        while pos <= #text and text:sub(pos, pos):match("%s") do
            pos = pos + 1
        end
        
        if pos > #text then
            break
        end
        
        -- Find word
        local word_start = pos
        while pos <= #text and not text:sub(pos, pos):match("%s") do
            pos = pos + 1
        end
        
        local word = text:sub(word_start, pos - 1)
        local clean_word = word:gsub("[%p]", "")
        
        if clean_word ~= "" then
            local duration
            if is_piper then
                -- Neural TTS: character-length proportional estimation.
                -- Piper synthesizes at a fairly uniform rate per character,
                -- so character count gives better proportional distribution
                -- than syllable count.  These raw values are later scaled to
                -- match the real WAV duration — only the ratios matter.
                duration = math.floor(#clean_word * 80)
                -- Punctuation after a word causes Piper to insert a natural
                -- pause — model that for better within-sentence proportions.
                if word:match("[,;:]$") then
                    duration = duration + 150
                elseif word:match("[%.%?!]$") then
                    duration = duration + 200
                end
            else
                local syllables = self:countSyllables(clean_word)
                duration = math.floor((syllables * 200) / self.rate)
            end
            
            table.insert(self.timing_data, {
                word = word,
                start_pos = word_start,
                end_pos = pos - 1,
                start_time = current_time,
                end_time = current_time + duration,
            })
            
            current_time = current_time + duration + (is_piper and 30 or 50)
        end
    end
    
    logger.dbg("TTSEngine: Generated timing for", #self.timing_data, "words")
end

--[[--
Count syllables in a word.
Delegates to shared Utils module.
@param word string The word
@return number Syllable count
--]]
function TTSEngine:countSyllables(word)
    return Utils.countSyllables(word)
end

--[[--
Escape text for shell command.
@param text string Text to escape
@return string Escaped text
--]]
function TTSEngine:escapeText(text)
    -- Escape special characters for shell
    text = text:gsub("\\", "\\\\")
    text = text:gsub('"', '\\"')
    text = text:gsub("`", "\\`")
    text = text:gsub("%$", "\\$")
    return text
end

--[[--
Append silence (zero samples) to the end of an existing WAV file.
Delegates to WavUtils.
@param path string  WAV file path
@param duration_ms number  Silence duration in milliseconds
@return boolean  true on success
--]]
function TTSEngine:appendSilenceToWav(path, duration_ms)
    return WavUtils.appendSilence(path, duration_ms)
end

--[[--
Append a gap (silence or audible tone) to a WAV file.
When "gap_test_mode" is enabled, writes a low tone instead of silence
so the user can hear exactly where each gap is placed.
Uses different frequencies for sentence vs paragraph gaps.
@param path string          WAV file path
@param duration_ms number   Gap duration in milliseconds
@param gap_type string      "sentence" or "paragraph"
@return boolean             true on success
--]]
function TTSEngine:appendGapToWav(path, duration_ms, gap_type)
    if self._gap_test_mode then
        -- Sentence gaps: 220 Hz (A3, low hum)
        -- Paragraph gaps: 330 Hz (E4, slightly higher)
        local freq = (gap_type == "paragraph") and 330 or 220
        return WavUtils.appendTone(path, duration_ms, freq, 2000)
    end
    return WavUtils.appendSilence(path, duration_ms)
end

--[[--
Quick espeak-ng synthesis for cold-start fallback.
Synthesizes text with the bundled espeak-ng binary (typically <300ms on ARM)
and returns the WAV file path, or nil on failure.
This works even when the active backend is Piper.
@param text string Text to synthesize
@return string|nil WAV file path on success
--]]
function TTSEngine:espeakSynthesizeFallback(text)
    if not self.espeak_bin then return nil end
    local temp_dir = self._android_tts and self._android_tts:getTempDir() or "/tmp"
    self.file_counter = (self.file_counter or 0) + 1
    local audio_file = temp_dir .. "/audiobook_espeak_fb_" .. os.time() .. "_" .. self.file_counter .. ".wav"
    local exec_prefix = ""
    if self.espeak_linker then
        exec_prefix = string.format(
            "ESPEAK_DATA_PATH=%s %s --library-path %s ",
            self.espeak_data_path, self.espeak_linker, self.espeak_lib_path
        )
    elseif self.espeak_lib_path then
        exec_prefix = string.format(
            "LD_LIBRARY_PATH=%s ESPEAK_DATA_PATH=%s ",
            self.espeak_lib_path, self.espeak_data_path
        )
    end
    local speed = math.floor(175 * (self.rate or 1.0))
    local voice = self.voice or "en"
    local cmd = string.format(
        '%s%s -v %s -s %d -a 100 -w "%s" "%s" 2>&1',
        exec_prefix, self.espeak_bin, voice, speed, audio_file, self:escapeText(text)
    )
    logger.warn("TTSEngine: espeak fallback synthesis for cold-start")
    local handle = io.popen(cmd, "r")
    if handle then
        handle:read("*a")
        handle:close()
    end
    local f = io.open(audio_file, "r")
    if f then
        f:close()
        -- Smooth boundary clicks at start/end
        WavUtils.applyFade(audio_file, 15)
        -- Resample espeak output (22050Hz) to match Piper model rate if needed
        local target_sr = self._piper_sample_rate or 22050
        if target_sr ~= 22050 then
            WavUtils.resampleFile(audio_file, target_sr)
        end
        -- Generate timing estimates for the espeak audio
        self:generateTimingEstimates(text)
        self.current_audio_file = audio_file
        return audio_file
    end
    return nil
end

--[[--
Merge multiple WAV files into the current audio file.
Delegates to WavUtils.
@param concat_files table  Array of {file=path, duration_ms=number}
@return boolean  true if data was appended
--]]
function TTSEngine:mergeWavFiles(concat_files)
    if not self.current_audio_file or not concat_files or #concat_files == 0 then
        return false
    end
    return WavUtils.mergeFiles(self.current_audio_file, concat_files)
end

--[[--
Pre-synthesize audio for the next sentence while the current one plays.
This runs espeak-ng to generate the WAV file and timing data in advance,
so when the current sentence finishes we can skip straight to playback.
@param text string Text of the next sentence
@return boolean Success
--]]
function TTSEngine:prefetch(text)
    if not self.backend or not text or text == "" then
        return false
    end
    -- Android TTS: skip prefetch.  synthesizeAndroid() is async, but
    -- prefetch() assumes synchronous completion (save/restore of
    -- current_audio_file).  The async callback overwrites current_audio_file,
    -- then cleanup() deletes the prefetched WAV, breaking the chain.
    -- Android TTS synthesis is fast enough that prefetching isn't needed.
    if self.backend == self.BACKENDS.ANDROID then
        return false
    end
    -- Piper: delegate to the async queue-based prefetcher
    if self.backend == self.BACKENDS.PIPER then
        self._piper:enqueue(text)
        return true  -- launched (or already in queue)
    end
    -- Don't prefetch the same text twice
    if self._prefetch_text == text and self._prefetch_file then
        return true
    end
    -- Clean up any previous prefetch
    self:_cleanPrefetch()

    -- Save current audio file/timing so synthesizeCommand doesn't overwrite them
    local saved_file = self.current_audio_file
    local saved_timing = self.timing_data

    local ok = self:synthesizeCommand(text, function(success, timing)
        if success then
            -- Move the generated file into the prefetch slot
            self._prefetch_file = self.current_audio_file
            self._prefetch_timing = self.timing_data
            self._prefetch_text = text
            logger.dbg("TTSEngine: Prefetched audio for:", text:sub(1, 40))
        end
    end)

    -- Restore the current audio state (the playing sentence's file)
    self.current_audio_file = saved_file
    self.timing_data = saved_timing

    return ok
end

--[[--
Check if prefetched audio matches the given text and swap it in.
@param text string The sentence text to check
@return boolean true if prefetch was used
--]]
function TTSEngine:usePrefetched(text)
    -- Check single-slot prefetch (espeak-ng)
    if self._prefetch_file and self._prefetch_text == text then
        if self.current_audio_file then
            os.remove(self.current_audio_file)
        end
        self.current_audio_file = self._prefetch_file
        self.timing_data = self._prefetch_timing
        self._prefetch_file = nil
        self._prefetch_timing = nil
        self._prefetch_text = nil
        logger.dbg("TTSEngine: Using prefetched audio")
        return true
    end
    -- Check Piper async queue
    local piper_file, piper_timing = self._piper:useReady(text)
    if piper_file then
        if self.current_audio_file then
            os.remove(self.current_audio_file)
        end
        self.current_audio_file = piper_file
        self.timing_data = piper_timing
        return true
    end
    return false
end

--[[--
Peek at the prefetched audio without consuming it.
Returns file path, timing data and WAV duration if the prefetch matches the
given text.  The prefetch slot is NOT cleared — call usePrefetched() or
_cleanPrefetch() when the file is no longer needed.
@param text string  Expected sentence text
@return string|nil  WAV file path (or nil)
@return table|nil   Timing data
@return number      Duration in ms
--]]
function TTSEngine:peekPrefetch(text)
    -- Check single-slot prefetch (espeak-ng)
    if self._prefetch_file and self._prefetch_text == text then
        local dur = self:getWavDurationMs(self._prefetch_file)
        return self._prefetch_file, self._prefetch_timing, dur
    end
    -- Check Piper async queue for ready entries
    return self._piper:peek(text)
end

--[[--
Diagnostic: return a summary string of the Piper prefetch queue state.
@return string  e.g. "queued=3 pending=2 ready=1 failed=0"
--]]
function TTSEngine:getPiperQueueSnapshot()
    return self._piper:getSnapshot()
end

--[[--
Get WAV duration from an arbitrary file path.
Delegates to WavUtils.
@param path string  WAV file path
@return number  Duration in ms, 0 on error
--]]
function TTSEngine:getWavDurationMs(path)
    return WavUtils.getDurationMs(path)
end

--[[--
Generate a WAV file containing silence of the given duration.
Delegates to WavUtils.
@param duration_ms number  Duration in milliseconds
@return string|nil  Path to the generated WAV file
--]]
function TTSEngine:generateSilenceWav(duration_ms)
    return WavUtils.generateSilence(nil, duration_ms)
end

--[[--
Clean up prefetch state.
--]]
function TTSEngine:_cleanPrefetch()
    if self._prefetch_file then
        if not self._prefetch_in_use then
            os.remove(self._prefetch_file)
        end
        self._prefetch_file = nil
    end
    self._prefetch_timing = nil
    self._prefetch_text = nil
    self._prefetch_in_use = false
    -- Clean Piper async queue
    self._piper:cleanQueue()
end

-- === Persistent BT Pipeline Constants ===
-- Instead of launching a new gst-launch for each sentence (which crashes
-- when BT A2DP disconnects during gaps), maintain a single persistent
-- pipeline.  A feeder script writes silence (keeping BT alive) and
-- switches to real audio on demand.  gst-launch never stops.
local PIPE_BUFFER_DELAY_64KB = 1500 -- 64KB pipe buffer at 44100 B/s ≈ 1.45s
local PIPE_BUFFER_DELAY_16KB = 370  -- 16KB pipe buffer at 44100 B/s ≈ 370ms

--- Compute pipe buffer delay for a given sample rate and buffer size.
-- @param sample_rate number  Audio sample rate (default 22050)
-- @param buf_kb number  Pipe buffer size in KB (16 or 64)
-- @return number  Delay in milliseconds
local function pipeBufferDelay(sample_rate, buf_kb)
    local byte_rate = (sample_rate or 22050) * 2  -- 16-bit mono
    return math.floor((buf_kb * 1024) / byte_rate * 1000)
end
local PIPELINE_CTRL_DIR = "/tmp/audiobook_ctrl"
local PIPELINE_FIFO = "/tmp/audiobook_fifo"
local PIPELINE_SCRIPT = "/tmp/audiobook_pipeline.sh"

--[[--
Play the synthesized audio.
@param on_word function Callback for word timing updates
@param on_complete function Callback when playback completes
@param on_fail function Callback on async BT launch failure
@param concat_files table|nil Optional extra WAV files for seamless concat playback
       Each entry: {file=path, duration_ms=number}
@return boolean Success
--]]
function TTSEngine:play(on_word, on_complete, on_fail, concat_files)
    local t0 = UIManager:getTime()
    logger.warn("TTSEngine: play() called, audio_file=", self.current_audio_file, "is_speaking=", self.is_speaking)
    if not self.current_audio_file then
        logger.err("TTSEngine: No audio file to play")
        UIManager:show(InfoMessage:new{
            text = _("No audio file to play."),
            timeout = 2,
        })
        return false
    end
    
    self.on_word_callback = on_word
    self.on_complete_callback = on_complete
    self.on_fail_callback = on_fail
    self.is_speaking = true
    self.is_paused = false
    
    -- Start playback using system player (cached after first probe)
    local player = self._cached_player or self:findAudioPlayer()
    if player then
        self._cached_player = player
    else
        -- Clear cache so next attempt re-probes (user may pair BT between tries)
        self._cached_player = nil
    end
    if not player then
        logger.err("TTSEngine: No audio player found")
        self.player_error = true
        local msg
        if Device:isKindle() then
            msg = _("No audio output available.\n\nKindle has no built-in speaker. Audio needs Bluetooth headphones connected via Kindle Settings.\n\nPlease generate a bug report (Audiobook > Report a bug) and share it on the GitHub issue -- it will help identify the correct audio path for this Kindle model.")
        elseif Device:isKobo() then
            msg = _("No audio output available.\n\nKobo has no built-in speaker.\n\nPlease pair Bluetooth headphones:\nSettings → Bluetooth → Pair\n\nThen try again.")
        elseif Device.isPocketBook and Device:isPocketBook() then
            msg = _("No audio output available.\n\nPlease generate a bug report (Audiobook > Report a bug) and share it on the GitHub issue -- it will help identify the correct audio path for this PocketBook model.")
        else
            msg = _("No audio output available.\n\nNo supported audio player found (aplay, paplay, mpv, mplayer).\n\nIf using Bluetooth, make sure headphones are paired and connected.")
        end
        UIManager:show(InfoMessage:new{
            text = msg,
            timeout = 8,
        })
        self.is_speaking = false
        -- Do NOT call on_complete here — returning false tells
        -- beginSentencePlayback to handle the error.  Calling both
        -- on_complete and returning false creates a race: the completion
        -- callback schedules readNextSentence, then beginSentencePlayback
        -- calls stop(), so the scheduled timer finds state==STOPPED.
        return false
    end
    
    logger.dbg("TTSEngine: Using player:", player)
    logger.dbg("TTSEngine: Audio file:", self.current_audio_file)
    logger.warn("TTSEngine: play() findPlayer took", time.to_ms(UIManager:getTime() - t0), "ms")

    -- Block playback when no real audio output exists and no BT device is
    -- connected.  On single-core Kobos (no speaker), silently looping
    -- through aplay for every sentence wastes CPU and can crash the device.
    if self._no_real_audio_output then
        local bt_connected = false
        local btm = self.plugin and self.plugin.bt_manager
        if btm then
            local ok, devices = pcall(btm.listAudioDevices, btm)
            if ok and devices then
                for _, dev in ipairs(devices) do
                    if dev.connected then
                        bt_connected = true
                        break
                    end
                end
            end
        end
        if bt_connected then
            -- BT device appeared after initial findAudioPlayer (e.g.
            -- connected externally).  Re-probe the audio player so
            -- bluealsa can be started and used.
            logger.warn("TTSEngine: BT device connected, re-probing audio player")
            self._cached_player = nil
            self._no_real_audio_output = false
            player = self:findAudioPlayer()
            if not player then
                logger.warn("TTSEngine: re-probe failed, no audio player found")
                self.is_speaking = false
                return false
            end
        else
            logger.warn("TTSEngine: No soundcard and no BT connected - refusing to play")
            self.is_speaking = false
            local msg
            if Device:isKindle() then
                msg = _("No audio output available.\n\nKindle has no built-in speaker. Please connect Bluetooth headphones via Kindle Settings, then try again.\n\nIf you already have headphones connected, please generate a bug report (Audiobook > Report a bug) and share it on GitHub — it will help identify the correct audio path for this Kindle model.")
            else
                msg = _("No audio output available.\n\nThis device has no built-in speaker. Please connect a Bluetooth audio device first:\n\n1. Go to Audiobook > Bluetooth\n2. Turn Bluetooth on\n3. Scan and pair your headphones/speaker\n4. Then start read-along again.")
            end
            UIManager:show(InfoMessage:new{
                text = msg,
                timeout = 10,
            })
            return false
        end
    end
    
    -- === KINDLE NATIVE TTS PLAYBACK PATH ===
    -- Send text directly to Amazon's Ivona SDK via playermgr PlayParameter.
    -- Protocol discovered from VoiceView LIPC event capture:
    -- text → PlayParameter(JSON) → ttssrc → Ivona → mixersink → audiomgrd → BT
    --
    -- v0.1.5.37: Use liblipc.so FFI with a named LIPC source.  CLI tools
    -- (lipc-set-prop) use anonymous transient connections; playermgr may
    -- only trigger TTS for named sources (VoiceView uses the C API).
    if self.audio_player_type == "kindle-native-tts" then
        local text = self._native_tts_text
        if not text or text == "" then
            logger.err("TTSEngine: Kindle native TTS -- no text to speak")
            self:onPlaybackComplete()
            return true
        end

        self._concat_durations = nil
        -- Duration was already estimated during synthesis
        local dur_ms = self._current_audio_duration_ms or 5000
        self._expected_play_duration_ms = dur_ms
        self.play_generation = (self.play_generation or 0) + 1
        local my_gen = self.play_generation
        self.playback_latency_ms = 500

        logger.warn("TTSEngine: Kindle native TTS play:", text:sub(1, 60),
            "est_dur=", dur_ms, "ms")

        -- Check /var free space -- Ivona TTS needs temp space for synthesis.
        -- A full /var causes playermgr to silently ignore PlayParameter.
        if not self._var_space_checked then
            self._var_space_checked = true
            local df_h = io.popen("df /var 2>/dev/null | tail -1")
            if df_h then
                local df_line = df_h:read("*a") or ""; df_h:close()
                local use_pct = tonumber(df_line:match("(%d+)%%"))
                if use_pct and use_pct >= 95 then
                    logger.warn("TTSEngine: /var is", use_pct, "% full -- TTS may fail")
                    -- Try to free space: remove known safe temp files
                    os.execute("rm -f /var/tmp/audiomgrd.err /var/tmp/*.tmp 2>/dev/null")
                    -- Re-check
                    local df2 = io.popen("df /var 2>/dev/null | tail -1")
                    if df2 then
                        local df2_line = df2:read("*a") or ""; df2:close()
                        local pct2 = tonumber(df2_line:match("(%d+)%%"))
                        if pct2 and pct2 >= 98 then
                            self._var_full = true
                            UIManager:show(InfoMessage:new{
                                text = _("/var is full (" .. pct2 .. "% used).\n\nThe Kindle's native TTS engine needs temporary space in /var to synthesize speech. With /var full, playback will silently fail.\n\nTry rebooting your Kindle to clear /var, then try again."),
                                timeout = 15,
                            })
                        end
                    end
                end
            end
        end

        -- Skip native TTS entirely when /var is full and gst-play is available.
        -- Ivona SDK cannot synthesize without temp space, so going through the
        -- 10s strategy+timeout loop is pointless.  Fall back immediately.
        if self._var_full then
            if not self._kindle_gst_play_bin then
                local plugin_dir = self.plugin_dir or "."
                local gst_play_bin = plugin_dir .. "/kindle/gst-play"
                local gf = io.open(gst_play_bin, "r")
                if gf then
                    gf:close()
                    if self.espeak_linker then
                        self._kindle_gst_play_bin = string.format(
                            "%s --library-path %s:/usr/lib:/lib %s",
                            self.espeak_linker, self.espeak_lib_path, gst_play_bin)
                    else
                        self._kindle_gst_play_bin = gst_play_bin
                    end
                end
            end
            if self._kindle_gst_play_bin and self.current_audio_file then
                logger.warn("TTSEngine: /var full, skipping native TTS, using kindle-gst-play")
                self.audio_player_type = "kindle-gst-play"
                self._no_real_audio_output = false
                self.is_speaking = false
                self:play()
                return true
            end
        end

        -- JSON-escape the text for the PlayParameter payload
        local json_text = text:gsub('\\', '\\\\'):gsub('"', '\\"')
                              :gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')

        -- Build VoiceView-compatible PlayParameter payload
        local payload = '{"type":"TTS","data":{"paramName":"textsource","paramValue":"'
            .. json_text .. '"}}'

        -- --- LIPC FFI helpers (persistent named connection) ---
        -- Lazy-load liblipc.so on first use
        if _lipc_lib == nil then
            _lipc_lib = false  -- mark as attempted
            local ok, lib = pcall(ffi.load, "lipc")
            if ok then _lipc_lib = lib; logger.warn("TTSEngine: loaded liblipc.so via FFI") end
        end

        -- Get or create a persistent named LIPC handle
        local lipc_h = self._lipc_handle
        if not lipc_h and _lipc_lib then
            local open_ok, open_err = pcall(function()
                local code = ffi.new("int[1]")
                local h = _lipc_lib.LipcOpenEx("com.lab126.koreader.tts", code)
                if h ~= nil and code[0] == 0 then
                    self._lipc_handle = h
                    lipc_h = h
                    logger.warn("TTSEngine: opened named LIPC connection (com.lab126.koreader.tts)")
                else
                    logger.warn("TTSEngine: LipcOpenEx failed, code=", code[0], ", trying anonymous")
                    h = _lipc_lib.LipcOpenNoName(code)
                    if h ~= nil and code[0] == 0 then
                        self._lipc_handle = h
                        lipc_h = h
                        logger.warn("TTSEngine: opened anonymous LIPC connection")
                    else
                        logger.warn("TTSEngine: LipcOpenNoName also failed, code=", code[0])
                    end
                end
            end)
            if not open_ok then
                logger.warn("TTSEngine: LIPC FFI open crashed:", open_err, "-- disabling FFI")
                _lipc_lib = false
            end
        end

        local function ffiSetProp(service, prop, value)
            if lipc_h and _lipc_lib then
                local ok, rc = pcall(_lipc_lib.LipcSetStringProperty, lipc_h, service, prop, value)
                if ok then return rc end
                logger.warn("TTSEngine: LIPC FFI set crashed:", rc)
                return nil
            end
            return nil  -- signal: use shell fallback
        end

        local function ffiGetInt(service, prop)
            if lipc_h and _lipc_lib then
                local ok, result = pcall(function()
                    local val = ffi.new("int[1]")
                    local rc = _lipc_lib.LipcGetIntProperty(lipc_h, service, prop, val)
                    if rc == 0 then return val[0] end
                    return nil
                end)
                if ok then return result end
                logger.warn("TTSEngine: LIPC FFI get crashed:", result)
            end
            return nil  -- signal: use shell fallback
        end

        local function getTtsState()
            local st = ffiGetInt("com.lab126.playermgr", "TTS_State")
            if st ~= nil then return st end
            -- Shell fallback
            local h = io.popen("lipc-get-prop com.lab126.playermgr TTS_State 2>/dev/null")
            if h then
                local val = h:read("*a") or ""; h:close()
                return tonumber(val:match("(%d+)")) or 0
            end
            return 0
        end

        -- Stop previous playback + request audio focus
        if ffiSetProp("com.lab126.playermgr", "Stop", "") == nil then
            os.execute("lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null")
        end
        if ffiSetProp("com.lab126.audiomgrd", "setFocus", "tts") == nil then
            os.execute("lipc-set-prop com.lab126.audiomgrd setFocus 'tts' 2>/dev/null")
        end

        -- Strategy A: PlayParameter only (VoiceView's steady-state protocol)
        local using_ffi = lipc_h ~= nil
        logger.warn("TTSEngine: Kindle native TTS strategy A: PlayParameter",
            using_ffi and "(FFI)" or "(shell)")

        if using_ffi then
            ffiSetProp("com.lab126.playermgr", "PlayParameter", payload)
        else
            -- Shell-safe single-quote escaping (only ' needs escaping in '...')
            local function shellEsc(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
            local function lipc_cmd(cmd)
                local h = io.popen(cmd .. " 2>&1")
                local out = ""
                if h then out = h:read("*a") or ""; h:close() end
                return out
            end
            lipc_cmd("lipc-set-prop com.lab126.playermgr PlayParameter " .. shellEsc(payload))
        end
        local tts_state = getTtsState()

        -- Strategy B: Open TTS session + PlayParameter + Play (shell fallback only)
        if tts_state == 0 and not using_ffi then
            local function shellEsc(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
            local function lipc_cmd(cmd)
                local h = io.popen(cmd .. " 2>&1")
                local out = ""
                if h then out = h:read("*a") or ""; h:close() end
                return out
            end
            logger.warn("TTSEngine: Kindle native TTS strategy B: Open+PlayParam+Play (shell)")
            lipc_cmd("lipc-set-prop com.lab126.playermgr Open " ..
                shellEsc('{"type":"TTS"}'))
            lipc_cmd("lipc-set-prop com.lab126.playermgr PlayParameter " ..
                shellEsc(payload))
            lipc_cmd("lipc-set-prop com.lab126.playermgr Play ''")
            tts_state = getTtsState()
        end

        -- Strategy C (FFI): Open + PlayParameter + Play via FFI
        if tts_state == 0 and using_ffi then
            logger.warn("TTSEngine: Kindle native TTS strategy C: Open+PlayParam+Play (FFI)")
            ffiSetProp("com.lab126.playermgr", "Open", '{"type":"TTS"}')
            ffiSetProp("com.lab126.playermgr", "PlayParameter", payload)
            ffiSetProp("com.lab126.playermgr", "Play", "")
            tts_state = getTtsState()
        end

        logger.warn("TTSEngine: Kindle native TTS after strategies, TTS_State=", tts_state,
            using_ffi and "(FFI)" or "(shell)")

        self._audio_launched_at = UIManager:getTime()
        self:startTimingLoop()

        -- Poll TTS_State for completion
        local engine = self
        local poll_count = 0
        local max_polls = math.max(300, math.floor(dur_ms * 3 / 100))
        local startup_polls = 15  -- 1.5s for native TTS to start
        local ever_speaking = false

        local function pollNativeTtsDone()
            if (engine.play_generation or 0) ~= my_gen then return end
            if not engine.is_speaking then return end
            if engine.is_paused then
                UIManager:scheduleIn(0.3, pollNativeTtsDone)
                return
            end
            poll_count = poll_count + 1

            if poll_count > startup_polls then
                local state = getTtsState()
                if state > 0 then
                    ever_speaking = true
                elseif state == 0 and ever_speaking then
                    -- Was speaking, now done
                    logger.warn("TTSEngine: Kindle native TTS complete, polls=", poll_count)
                    engine._lipc_consec_fails = 0
                    engine:onPlaybackComplete()
                    return
                elseif state == 0 and not ever_speaking then
                    local elapsed_ms = 0
                    if engine._audio_launched_at then
                        elapsed_ms = time.to_ms(UIManager:getTime() - engine._audio_launched_at)
                            - (engine._total_pause_ms or 0)
                    end
                    if elapsed_ms > 5000 then
                        -- Never started after 5s
                        engine._lipc_consec_fails = (engine._lipc_consec_fails or 0) + 1
                        logger.err("TTSEngine: Kindle native TTS never started, elapsed=",
                            elapsed_ms, "ms, fails=", engine._lipc_consec_fails)
                        if engine._lipc_consec_fails >= 2 then
                            -- Try falling back to kindle-gst-play if the binary is present.
                            -- This bypasses the native TTS pipeline entirely and plays
                            -- the espeak-synthesized WAV via GStreamer mixersink directly.
                            if not engine._kindle_gst_play_bin then
                                local plugin_dir = engine.plugin_dir or "."
                                local gst_play_bin = plugin_dir .. "/kindle/gst-play"
                                local gf = io.open(gst_play_bin, "r")
                                if gf then
                                    gf:close()
                                    if engine.espeak_linker then
                                        engine._kindle_gst_play_bin = string.format(
                                            "%s --library-path %s:/usr/lib:/lib %s",
                                            engine.espeak_linker, engine.espeak_lib_path, gst_play_bin)
                                    else
                                        engine._kindle_gst_play_bin = gst_play_bin
                                    end
                                end
                            end
                            if engine._kindle_gst_play_bin and engine.current_audio_file then
                                logger.warn("TTSEngine: native TTS failed twice, falling back to kindle-gst-play")
                                engine.audio_player_type = "kindle-gst-play"
                                engine._no_real_audio_output = false
                                -- Replay the current audio file via gst-play
                                engine.is_speaking = false
                                engine:play()
                                return
                            end
                            engine.is_speaking = false
                            engine.play_generation = (engine.play_generation or 0) + 1
                            engine:cleanup()
                            UIManager:show(InfoMessage:new{
                                text = _("Kindle native TTS failed.\n\nThe device has a TTS engine (Ivona SDK) but playback could not be triggered via any strategy (FFI and shell).\n\nPlease generate a bug report and share it on GitHub."),
                                timeout = 10,
                            })
                            return
                        end
                        engine:onPlaybackComplete()
                        return
                    end
                end
            end

            if poll_count >= max_polls then
                logger.warn("TTSEngine: Kindle native TTS timed out after",
                    poll_count * 0.1, "s")
                ffiSetProp("com.lab126.playermgr", "Stop", "")
                os.execute("lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null")
                engine:onPlaybackComplete()
            else
                UIManager:scheduleIn(0.1, pollNativeTtsDone)
            end
        end
        UIManager:scheduleIn(0.1, pollNativeTtsDone)
        return true
    end

    -- Calculate real audio duration from WAV file.
    -- If _unpadded_duration_ms is set, the WAV was padded with trailing
    -- silence by SyncController.  Use the original (speech-only) duration
    -- for word-timing scaling so highlights stay correct.
    local real_duration_ms = self._unpadded_duration_ms or self:getAudioDurationMs()
    self._unpadded_duration_ms = nil
    self._current_audio_duration_ms = real_duration_ms
    logger.dbg("TTSEngine: Real WAV duration:", real_duration_ms, "ms (unpadded)")
    
    -- BT audio has significant startup latency (A2DP negotiation).
    -- On chained sentences the socket is still warm, so latency is lower.
    if self.audio_player_type == "gst-bt" then
        self.playback_latency_ms = self._socket_clean and 500 or 1500
    else
        self.playback_latency_ms = 0
    end
    
    -- Scale timing data to match real audio duration
    if real_duration_ms > 0 and #self.timing_data > 0 then
        local estimated_total = self.timing_data[#self.timing_data].end_time
        if estimated_total > 0 then
            local scale = real_duration_ms / estimated_total
            for _, t in ipairs(self.timing_data) do
                t.start_time = math.floor(t.start_time * scale)
                t.end_time = math.floor(t.end_time * scale)
            end
            logger.dbg("TTSEngine: Scaled timing by", scale, "(estimated", estimated_total, "-> real", real_duration_ms, ")")
        end
    end
    
    -- === ANDROID MEDIAPLAYER PATH ===
    if self.audio_player_type == "android" then
        local atts = self._android_tts
        self._concat_durations = nil
        self._expected_play_duration_ms = self._current_audio_duration_ms
        self.play_generation = (self.play_generation or 0) + 1
        local my_gen = self.play_generation
        self.playback_latency_ms = 0

        local dur_ms = atts:playFile(self.current_audio_file)
        if dur_ms < 0 then
            logger.err("TTSEngine: Android playFile failed")
            self.is_speaking = false
            return false
        end
        self._audio_launched_at = UIManager:getTime()
        logger.dbg("TTSEngine: Android playback started, duration:", dur_ms, "ms")

        -- Start timing loop for word highlighting
        self:startTimingLoop()

        -- Poll for playback completion with safety timeout.
        -- If the Java completion listener never fires (device quirk, JNI
        -- exception, etc.), force completion so the chain doesn't stall.
        local engine = self
        local poll_count = 0
        -- Max polls: at least 300 (30s) or 3x expected duration
        local max_polls = math.max(300, math.floor(dur_ms * 3 / 100))
        local function pollPlaybackDone()
            if (engine.play_generation or 0) ~= my_gen then return end
            if not engine.is_speaking then return end
            if engine.is_paused then
                UIManager:scheduleIn(0.3, pollPlaybackDone)
                return
            end
            poll_count = poll_count + 1
            if atts:isPlaybackDone() then
                logger.dbg("TTSEngine: Android playback complete")
                engine:onPlaybackComplete()
            elseif poll_count >= max_polls then
                logger.warn("TTSEngine: Android playback timed out after",
                    poll_count * 0.1, "s -- forcing completion")
                atts:stopPlayback()
                engine:onPlaybackComplete()
            else
                UIManager:scheduleIn(0.1, pollPlaybackDone)
            end
        end
        UIManager:scheduleIn(0.1, pollPlaybackDone)
        return true
    end

    -- === KINDLE LIPC PLAYBACK PATH ===
    -- Use Amazon's playermgr LIPC service (GStreamer-based) to play WAV
    -- files through the Kindle audio stack → audiomgrd → BT headphones.
    if self.audio_player_type == "kindle-lipc" then
        self._concat_durations = nil
        self._expected_play_duration_ms = self._current_audio_duration_ms
        self.play_generation = (self.play_generation or 0) + 1
        local my_gen = self.play_generation
        self.playback_latency_ms = 300  -- LIPC + GStreamer startup

        logger.warn("TTSEngine: Kindle LIPC play:", self.current_audio_file,
            "dur=", self._expected_play_duration_ms, "ms")

        -- Verify the WAV file exists and log its size (helps debug smoke test)
        local file_path = self.current_audio_file
        local fh = io.open(file_path, "rb")
        if fh then
            local size = fh:seek("end")
            fh:close()
            logger.warn("TTSEngine: Kindle LIPC wav_size=", size, "bytes")
        else
            logger.err("TTSEngine: Kindle LIPC WAV file does not exist:", file_path)
        end

        -- Stop any previous playback first
        os.execute("lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null")

        -- Request audio focus from audiomgrd.  playermgr may refuse to
        -- play unless its client has audio focus granted by the system
        -- mixer.  The setFocus property takes a client name string.
        os.execute("lipc-set-prop com.lab126.audiomgrd setFocus 'tts' 2>/dev/null")

        -- Enable GStreamer debug logging so errors appear in crash.log
        -- (gstLogLevel: 0=none, 1=error, 2=warning, 3=info, 4=debug)
        os.execute("lipc-set-prop com.lab126.playermgr gstLogLevel 2 2>/dev/null")

        -- playermgr uses GStreamer internally, which handles WAV decoding.
        -- Use io.popen to capture output for diagnostics.
        local file_uri = "file://" .. file_path

        -- Strategy 1: Open with file:// URI + Play (GStreamer prefers URIs)
        local function lipc_cmd(cmd)
            local h = io.popen(cmd .. " 2>&1")
            local out = ""
            if h then out = h:read("*a") or ""; h:close() end
            return out
        end

        logger.warn("TTSEngine: Kindle LIPC trying URI:", file_uri)
        local open_out = lipc_cmd(string.format(
            "lipc-set-prop com.lab126.playermgr Open '%s'", file_uri))
        local play_out = lipc_cmd("lipc-set-prop com.lab126.playermgr Play ''")
        logger.warn("TTSEngine: Kindle LIPC Open(URI):", open_out, "Play:", play_out)

        -- Check if playback started
        local in_play = lipc_cmd("lipc-get-prop com.lab126.playermgr InPlayback")
        local started = in_play:match("^%s*(%d+)") == "1"
        logger.warn("TTSEngine: Kindle LIPC InPlayback after URI:", in_play)

        -- Strategy 2: Open with bare path + Play
        if not started then
            logger.warn("TTSEngine: Kindle LIPC trying bare path:", file_path)
            os.execute("lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null")
            open_out = lipc_cmd(string.format(
                "lipc-set-prop com.lab126.playermgr Open '%s'", file_path))
            play_out = lipc_cmd("lipc-set-prop com.lab126.playermgr Play ''")
            logger.warn("TTSEngine: Kindle LIPC Open(path):", open_out, "Play:", play_out)

            in_play = lipc_cmd("lipc-get-prop com.lab126.playermgr InPlayback")
            started = in_play:match("^%s*(%d+)") == "1"
            logger.warn("TTSEngine: Kindle LIPC InPlayback after path:", in_play)
        end

        -- Strategy 3: Play with URI directly (no Open)
        if not started then
            logger.warn("TTSEngine: Kindle LIPC trying Play(URI) directly")
            os.execute("lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null")
            play_out = lipc_cmd(string.format(
                "lipc-set-prop com.lab126.playermgr Play '%s'", file_uri))
            logger.warn("TTSEngine: Kindle LIPC Play(URI):", play_out)

            in_play = lipc_cmd("lipc-get-prop com.lab126.playermgr InPlayback")
            started = in_play:match("^%s*(%d+)") == "1"
            logger.warn("TTSEngine: Kindle LIPC InPlayback after Play(URI):", in_play)
        end

        -- Strategy 4: Play with bare path directly (no Open)
        if not started then
            logger.warn("TTSEngine: Kindle LIPC trying Play(path) directly")
            os.execute("lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null")
            play_out = lipc_cmd(string.format(
                "lipc-set-prop com.lab126.playermgr Play '%s'", file_path))
            logger.warn("TTSEngine: Kindle LIPC Play(path):", play_out)

            in_play = lipc_cmd("lipc-get-prop com.lab126.playermgr InPlayback")
            started = in_play:match("^%s*(%d+)") == "1"
            logger.warn("TTSEngine: Kindle LIPC InPlayback after Play(path):", in_play)
        end

        if not started then
            logger.warn("TTSEngine: Kindle LIPC — none of 4 strategies got InPlayback=1")
        else
            -- At least one strategy worked -- reset consecutive failure counter
            self._lipc_consec_fails = 0
        end

        self._audio_launched_at = UIManager:getTime()

        -- Start timing loop for word highlighting
        self:startTimingLoop()

        -- Poll InPlayback property for completion detection.
        -- Also use a safety timeout based on WAV duration.
        local engine = self
        local poll_count = 0
        local dur_ms = self._expected_play_duration_ms or 5000
        -- Max polls: at least 300 (30s) or 3x expected duration at 100ms interval
        local max_polls = math.max(300, math.floor(dur_ms * 3 / 100))
        -- Allow a brief startup period before checking InPlayback
        local startup_polls = 5  -- 500ms for LIPC + GStreamer to open file
        local ever_playing = false  -- track if InPlayback was ever 1

        local function pollLipcDone()
            if (engine.play_generation or 0) ~= my_gen then return end
            if not engine.is_speaking then return end
            if engine.is_paused then
                UIManager:scheduleIn(0.3, pollLipcDone)
                return
            end
            poll_count = poll_count + 1

            -- Check InPlayback: 1 = playing, 0 = idle/completed/failed
            if poll_count > startup_polls then
                local h = io.popen("lipc-get-prop com.lab126.playermgr InPlayback 2>/dev/null")
                if h then
                    local val = h:read("*a") or ""
                    h:close()
                    val = val:match("(%d+)")
                    if val and tonumber(val) == 1 then
                        ever_playing = true
                    elseif val and tonumber(val) == 0 then
                        local elapsed_ms = 0
                        if engine._audio_launched_at then
                            elapsed_ms = time.to_ms(UIManager:getTime() - engine._audio_launched_at)
                                - (engine._total_pause_ms or 0)
                        end
                        if ever_playing then
                            -- Was playing, now stopped → playback completed normally
                            logger.warn("TTSEngine: Kindle LIPC playback complete, elapsed=",
                                elapsed_ms, "ms")
                            engine._lipc_consec_fails = 0
                            engine:onPlaybackComplete()
                            return
                        elseif elapsed_ms > 3000 then
                            -- Never started playing after 3 seconds → failure
                            engine._lipc_consec_fails = (engine._lipc_consec_fails or 0) + 1
                            logger.err("TTSEngine: Kindle LIPC playback never started, elapsed=",
                                elapsed_ms, "ms, consec_fails=", engine._lipc_consec_fails)
                            if engine._lipc_consec_fails >= 2 then
                                -- Stop after 2 consecutive failures
                                engine.is_speaking = false
                                engine.play_generation = (engine.play_generation or 0) + 1
                                engine:cleanup()
                                local msg
                                if engine._no_real_audio_output then
                                    msg = _("Kindle audio playback failed.\n\nThis Kindle model's GStreamer installation cannot decode audio files (no wavparse plugin). If your device has VoiceView (Settings > Accessibility), native TTS may work in a future update.\n\nPlease generate a bug report and share it on GitHub.")
                                else
                                    msg = _("Kindle audio playback failed.\n\nThe playermgr service accepted commands but audio never started.\n\nPlease generate a bug report (Audiobook > Report a bug) and share it on GitHub.")
                                end
                                UIManager:show(InfoMessage:new{
                                    text = msg,
                                    timeout = 10,
                                })
                                return
                            end
                            -- First failure -- try advancing to next sentence
                            engine:onPlaybackComplete()
                            return
                        end
                    end
                end
            end

            if poll_count >= max_polls then
                logger.warn("TTSEngine: Kindle LIPC playback timed out after",
                    poll_count * 0.1, "s -- forcing completion")
                os.execute("lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null")
                engine:onPlaybackComplete()
            else
                UIManager:scheduleIn(0.1, pollLipcDone)
            end
        end
        UIManager:scheduleIn(0.1, pollLipcDone)
        return true
    end

    -- === KINDLE GST-PLAY PATH ===
    -- Bundled C helper that feeds raw PCM to GStreamer mixersink via dlopen.
    -- Used on Kindle devices that have GStreamer + mixersink but no wavparse.
    -- The helper reads the WAV header, strips it, and plays raw PCM.
    if self.audio_player_type == "kindle-gst-play" then
        self._concat_durations = nil
        self._expected_play_duration_ms = self._current_audio_duration_ms
        self.play_generation = (self.play_generation or 0) + 1
        local my_gen = self.play_generation
        self.playback_latency_ms = 300

        local file_path = self.current_audio_file
        logger.warn("TTSEngine: kindle-gst-play:", file_path,
            "dur=", self._expected_play_duration_ms, "ms")

        -- Request audio focus from audiomgrd (same as kindle-lipc path)
        os.execute("lipc-set-prop com.lab126.audiomgrd setFocus 'tts' 2>/dev/null")

        -- Launch gst-play in background, capture PID.
        -- Capture stderr to a log file for diagnostics (was previously
        -- discarded, making it impossible to debug silent failures).
        local gst_log = "/tmp/.gst_play_last.log"
        local cmd = string.format(
            '%s "%s" >%s 2>&1 & echo $!',
            self._kindle_gst_play_bin, file_path, gst_log)
        local h = io.popen(cmd)
        local pid_str = h and h:read("*a") or ""
        if h then h:close() end
        local pid = tonumber(pid_str:match("(%d+)"))
        self._gst_play_pid = pid

        logger.warn("TTSEngine: kindle-gst-play launched, PID=", pid)

        self._audio_launched_at = UIManager:getTime()
        self:startTimingLoop()

        -- Poll /proc/<pid> for process completion.
        -- When the process exits, check its status to distinguish
        -- success (exit 0 = EOS) from failure (exit 3/4).
        local engine = self
        local poll_count = 0
        local dur_ms = self._expected_play_duration_ms or 5000
        local max_polls = math.max(300, math.floor(dur_ms * 3 / 100))

        local function pollGstPlayDone()
            if (engine.play_generation or 0) ~= my_gen then return end
            if not engine.is_speaking then return end
            if engine.is_paused then
                UIManager:scheduleIn(0.3, pollGstPlayDone)
                return
            end
            poll_count = poll_count + 1

            -- Check if process still running via /proc
            local proc_fh = pid and io.open("/proc/" .. pid .. "/status", "r")
            if proc_fh then
                proc_fh:close()
                -- Still running
                if poll_count >= max_polls then
                    logger.warn("TTSEngine: kindle-gst-play timed out after",
                        poll_count * 0.1, "s -- killing")
                    os.execute("kill " .. pid .. " 2>/dev/null")
                    engine._gst_play_pid = nil
                    engine:onPlaybackComplete()
                else
                    UIManager:scheduleIn(0.1, pollGstPlayDone)
                end
            else
                -- Process exited -- playback complete.
                -- Read the stderr log for diagnostics (helps debug silent failures).
                local log_fh = io.open("/tmp/.gst_play_last.log", "r")
                if log_fh then
                    local log_text = log_fh:read("*a") or ""
                    log_fh:close()
                    if log_text ~= "" then
                        logger.warn("TTSEngine: kindle-gst-play stderr:", log_text:sub(1, 500))
                    end
                end
                logger.warn("TTSEngine: kindle-gst-play finished, polls=", poll_count)
                engine._gst_play_pid = nil
                engine:onPlaybackComplete()
            end
        end
        UIManager:scheduleIn(0.2, pollGstPlayDone)
        return true
    end

    -- === PERSISTENT BT PIPELINE PATH ===
    -- For Bluetooth: use a single persistent gst-launch that never stops.
    -- A feeder script writes silence between sentences to keep BT A2DP alive,
    -- and switches to real audio on demand via a control file.
    if self.audio_player_type == "gst-bt" then
        -- Handle WAV merge for concatenated sentences
        if concat_files and #concat_files > 0 then
            self:mergeWavFiles(concat_files)
            self._concat_durations = { self._current_audio_duration_ms }
            for _, cf in ipairs(concat_files) do
                table.insert(self._concat_durations, cf.duration_ms)
            end
            logger.warn("TTSEngine: Merged", 1 + #concat_files, "sentences, durations=",
                table.concat(self._concat_durations, "+"))
        else
            self._concat_durations = nil
        end

        -- Calculate expected audio duration from actual WAV file.
        -- After mergeWavFiles(), the main WAV includes all silence padding
        -- (inter-sentence gaps, first-sentence padding, trailing gap).
        -- Reading the WAV header gives the true total duration, avoiding
        -- the bug where first-sentence padding was excluded from the sum.
        self._expected_play_duration_ms = self:getAudioDurationMs()

        -- Cancel any pending callbacks from previous play()
        if self._completion_timer_fn then
            UIManager:unschedule(self._completion_timer_fn)
            self._completion_timer_fn = nil
        end
        if self._pending_launch_fn then
            UIManager:unschedule(self._pending_launch_fn)
            self._pending_launch_fn = nil
        end

        -- Ensure the persistent pipeline is running
        if not self:_ensurePersistentPipeline() then
            logger.err("TTSEngine: Failed to start persistent pipeline")
            self.is_speaking = false
            if on_fail then on_fail() end
            return false
        end

        -- Bump generation to invalidate stale callbacks
        self.play_generation = (self.play_generation or 0) + 1
        local my_gen = self.play_generation

        -- BT latency: pipe buffer + ring buffer (~200ms)
        self.playback_latency_ms = (self._pipe_buffer_delay_ms or PIPE_BUFFER_DELAY_64KB) + 200

        logger.warn("TTSEngine: play() pre-launch took", time.to_ms(UIManager:getTime() - t0), "ms")

        -- Feed audio to the persistent pipeline
        os.remove(PIPELINE_CTRL_DIR .. "/done")
        local ctrl_f = io.open(PIPELINE_CTRL_DIR .. "/play", "w")
        if ctrl_f then
            ctrl_f:write(self.current_audio_file)
            ctrl_f:close()
        end

        self._audio_launched_at = UIManager:getTime()
        self._total_pause_ms = 0  -- reset accumulated pause time for this sentence
        logger.warn("TTSEngine: play() fed to pipeline, dur=",
            self._expected_play_duration_ms, "ms, gen=", my_gen,
            "piper_q=", self:getPiperQueueSnapshot())

        -- Poll for feeder 'done' file — logs when feeder finished writing
        -- PCM to the FIFO.  This tells us the real latency from play() to
        -- audio-data-in-pipeline.  Does NOT affect completion timing.
        local feed_start = UIManager:getTime()
        local feed_gen = my_gen
        local feed_engine = self
        local function pollFeederDone()
            if (feed_engine.play_generation or 0) ~= feed_gen then return end
            local df = io.open(PIPELINE_CTRL_DIR .. "/done", "r")
            if df then
                df:close()
                local feed_ms = time.to_ms(UIManager:getTime() - feed_start)
                logger.warn("TTSEngine: Feeder done in", feed_ms, "ms (gen=", feed_gen, ")")
                return
            end
            UIManager:scheduleIn(0.05, pollFeederDone)
        end
        UIManager:scheduleIn(0.1, pollFeederDone)

        -- Start timing loop for word highlighting
        self:startTimingLoop()

        -- Duration-based completion: fire onPlaybackComplete when the
        -- SPEECH portion of the audio has finished playing through the
        -- speaker.
        --
        -- The expected duration includes all silence padding (inter-sentence
        -- gaps + trailing gap).  We SUBTRACT the trailing gap so that
        -- readNextSentence can start preparing the next audio while the
        -- trailing gap silence is still draining through the pipe buffer.
        -- This eliminates ~700ms of extra dead silence that would otherwise
        -- accumulate between concat groups: without the subtraction, the
        -- feeder idles (writing silence) during the trailing gap + the
        -- completion margin, and that idle silence fills the pipe buffer,
        -- delaying the start of the next sentence's audio.
        --
        -- The pipe buffer adds ~512ms of latency.  Add it plus a small
        -- margin so the speech audio has fully drained to the speaker.
        local pipe_buf_ms = self._pipe_buffer_delay_ms or PIPE_BUFFER_DELAY_64KB
        local trailing_gap_ms = self._trailing_gap_ms or 0
        self._trailing_gap_ms = nil
        local completion_delay_s = (self._expected_play_duration_ms / 1000)
            - (trailing_gap_ms / 1000)
            + (pipe_buf_ms / 1000) + 0.15
        local engine = self
        local needed_ms = engine._expected_play_duration_ms
            - trailing_gap_ms + pipe_buf_ms + 150
        local function fireCompletion()
            if (engine.play_generation or 0) ~= my_gen then return end
            if not engine.is_speaking then return end
            if engine.is_paused then
                UIManager:scheduleIn(0.5, fireCompletion)
                return
            end
            -- Verify enough real playback time has elapsed (excluding
            -- time spent paused via SIGSTOP).  Without this check,
            -- resuming from pause fires completion immediately and
            -- overlaps the next sentence with the current one.
            if engine._audio_launched_at then
                local wall_ms = time.to_ms(UIManager:getTime() - engine._audio_launched_at)
                local real_ms = wall_ms - (engine._total_pause_ms or 0)
                if real_ms < needed_ms then
                    local wait_s = (needed_ms - real_ms) / 1000
                    if wait_s < 0.2 then wait_s = 0.2 end
                    UIManager:scheduleIn(wait_s, fireCompletion)
                    return
                end
            end
            logger.warn("TTSEngine: Pipeline completion (duration-based,",
                engine._expected_play_duration_ms, "ms - trailing_gap",
                trailing_gap_ms, "ms + pipe_buf",
                pipe_buf_ms, "ms)")
            engine:onPlaybackComplete()
        end
        engine._completion_timer_fn = fireCompletion
        UIManager:scheduleIn(completion_delay_s, fireCompletion)

        return true
    end

    -- === LEGACY PATH (non-Bluetooth audio) ===
    -- Build command WITHOUT trailing &; we'll add '& echo $!' for PID capture
    local play_cmd
    if self.audio_player_type == "gst-bt" then
        -- GStreamer pipeline: convert to S16LE/48kHz/stereo for Kobo BT A2DP sink.
        -- When concat_files is provided, merge them into the main WAV file
        -- (raw PCM append + header update) to avoid the GStreamer concat
        -- element which crashes on Kobo BT (exits <1 s, corrupts socket).
        if concat_files and #concat_files > 0 then
            self:mergeWavFiles(concat_files)
            -- Store per-sentence durations so the sync controller can
            -- track split points for word highlighting across sentences.
            self._concat_durations = { self._current_audio_duration_ms }
            for _, cf in ipairs(concat_files) do
                table.insert(self._concat_durations, cf.duration_ms)
            end
            logger.warn("TTSEngine: Merged", 1 + #concat_files, "sentences, durations=",
                table.concat(self._concat_durations, "+"))
        else
            self._concat_durations = nil
        end
        -- Always use a single-file pipeline (merged or original)
        play_cmd = string.format(
            'gst-launch-1.0 filesrc location="%s" ! wavparse ! audioconvert ! audioresample ! "audio/x-raw,format=S16LE,rate=48000,channels=2" ! mtkbtmwrpcaudiosink',
            self.current_audio_file
        )
    else
        play_cmd = string.format('%s "%s"', player, self.current_audio_file)
        self._concat_durations = nil
    end

    -- Store expected total audio duration so the process watcher can
    -- detect premature exits (gst-launch crashing after BT idle gap).
    if self._concat_durations then
        local total = 0
        for _, d in ipairs(self._concat_durations) do total = total + d end
        self._expected_play_duration_ms = total
    else
        self._expected_play_duration_ms = self._current_audio_duration_ms
    end
    
    -- Cancel any previously scheduled launchAndStart from an earlier play()
    -- call.  This prevents stale closures from firing after we supersede them.
    if self._pending_launch_fn then
        UIManager:unschedule(self._pending_launch_fn)
        self._pending_launch_fn = nil
    end

    -- Stop BT keepalive (if running or scheduled).  If the keepalive was
    -- holding the socket, _socket_clean is already false and the normal
    -- kill+wait logic below will handle the socket release delay.
    self:_stopBtKeepalive()

    -- Force-kill any lingering audio — SIGKILL + killall to release the
    -- @kobo:mtkbtmwrpc abstract socket held by stale gst-launch processes.
    -- Skip when socket is clean — process already exited, nothing to kill.
    if not self._socket_clean then
        self:_killAudioProcess()
    end

    -- Bump generation to invalidate any stale timing/watcher loops
    self.play_generation = (self.play_generation or 0) + 1

    logger.warn("TTSEngine: play() pre-launch took", time.to_ms(UIManager:getTime() - t0), "ms")

    -- Build PID-capturing launch command and save for potential async retry.
    -- Redirect stderr to a status file so the sync controller can detect
    -- when GStreamer transitions to PLAYING (= audio is actually flowing).
    self._gst_status_file = "/tmp/.gst_status"
    os.remove(self._gst_status_file)
    local pid_cmd = play_cmd .. ' >/dev/null 2>>' .. self._gst_status_file .. ' & echo $!'
    self._last_pid_cmd = pid_cmd

    -- Launch the audio process, start timing loop and process watcher.
    -- This is extracted so BT can call it after a non-blocking socket-release
    -- delay, while non-BT calls it immediately.
    local engine = self
    local my_gen = self.play_generation
    local function launchAndStart()
        engine._pending_launch_fn = nil
        -- Guard: bail if a newer play()/stop() call superseded us
        if (engine.play_generation or 0) ~= my_gen then
            logger.warn("TTSEngine: launchAndStart ABORTED — stale gen", my_gen, "vs", engine.play_generation)
            return
        end
        if not engine.is_speaking then
            logger.warn("TTSEngine: launchAndStart ABORTED — not speaking")
            return
        end

        -- Launch in background and capture PID for reliable process tracking.
        -- io.popen runs: sh -c '<play_cmd> >/dev/null 2>&1 & echo $!'
        -- The shell backgrounds the player, prints its PID, and exits.
        local launch_t0 = UIManager:getTime()
        logger.dbg("TTSEngine: Launching:", pid_cmd)
        local handle = io.popen(pid_cmd)
        local pid_str = handle and handle:read("*a") or ""
        if handle then handle:close() end
        engine.audio_pid = tonumber(pid_str:match("(%d+)"))
        -- Record when the audio process was actually launched so the
        -- sync controller can anchor its timing to reality, not an estimate.
        engine._audio_launched_at = UIManager:getTime()
        logger.warn("TTSEngine: io.popen launch took", time.to_ms(UIManager:getTime() - launch_t0), "ms, PID=", engine.audio_pid)

        -- Start timing loop for word highlighting (does NOT detect completion)
        engine:startTimingLoop()

        -- Start process watcher — detects normal completion AND BT early-death.
        -- For BT, the watcher retries once if the process dies within 2s (A2DP
        -- negotiation failure). This replaces the old blocking os.execute("sleep")
        -- checks so the UI stays responsive for rotation, taps, etc.
        engine:_startProcessWatcher(true)
    end

    if self.audio_player_type == "gst-bt" then
        -- If the previous process exited normally (watcher confirmed it),
        -- the socket is already free — launch immediately.
        -- Only wait when we had to force-kill a live process in this play() call.
        if self._socket_clean then
            self._socket_clean = false
            logger.warn("TTSEngine: BT socket clean — launching immediately, gen=", self.play_generation)
            launchAndStart()
        else
            local need_wait = 0.3
            if self._last_audio_kill_time then
                local since_kill_ms = time.to_ms(UIManager:getTime() - self._last_audio_kill_time)
                need_wait = math.max(0, (300 - since_kill_ms) / 1000)
            end
            logger.warn("TTSEngine: BT socket wait =", need_wait, "s, gen=", self.play_generation)
            if need_wait > 0.02 then
                self._pending_launch_fn = launchAndStart
                UIManager:scheduleIn(need_wait, launchAndStart)
            else
                launchAndStart()
            end
        end
    else
        -- Non-BT: launch immediately (no socket contention)
        launchAndStart()
    end

    return true
end

--[[--
Find available audio player.
Sets self.audio_player_type to "kindle-native-tts", "kindle-lipc", "gst-bt",
"bluealsa", "aplay", "android", or "generic".
@return string|nil Player command
--]]
function TTSEngine:findAudioPlayer()
    -- 0) Android: use MediaPlayer via TtsHelper (no CLI player needed)
    if self._android_tts then
        self.audio_player_type = "android"
        logger.dbg("TTSEngine: Using Android MediaPlayer for audio")
        return "android"
    end

    -- 0b) Kindle native TTS: Amazon's Ivona SDK via tts.orchestrator/playermgr.
    -- VoiceView uses this pipeline (confirmed via LIPC event capture):
    -- text → PlayParameter(JSON) → ttssrc (GStreamer) → Ivona SDK →
    -- mixersink → audiomgrd → A2DP → BT headphones.
    -- Bypasses the stripped GStreamer (no wavparse) entirely.
    if Device:isKindle() and self:commandExists("lipc-set-prop")
        and self:commandExists("lipc-get-prop") then
        local h = io.popen("lipc-get-prop com.lab126.tts.orchestrator orchestratorStarted 2>/dev/null")
        if h then
            local val = h:read("*a") or ""; h:close()
            if val:match("^%s*1") then
                self.audio_player_type = "kindle-native-tts"
                self._no_real_audio_output = false
                logger.warn("TTSEngine: Found Kindle native TTS (Ivona SDK, orchestratorStarted=1)")
                return "kindle-native-tts"
            end
        end
    end

    -- 0c) Kindle LIPC: use Amazon's playermgr service via lipc-set-prop.
    -- playermgr uses GStreamer internally and routes audio through
    -- audiomgrd → audio.a2dp.default.so → BT headphones.
    -- This is the native way to play audio files on Kindle devices
    -- (which have no ALSA soundcard, no BlueZ, no PulseAudio).
    if Device:isKindle() and self:commandExists("lipc-set-prop")
        and self:commandExists("lipc-get-prop") then
        -- Verify playermgr service exists by reading InPlayback property.
        -- Use io.popen (not os.execute) because Lua 5.1 os.execute return
        -- values are unreliable across builds (some return raw wait status).
        local h = io.popen("lipc-get-prop com.lab126.playermgr InPlayback 2>&1")
        if h then
            local val = h:read("*a") or ""
            h:close()
            val = val:match("^%s*(%d+)")
            if val then
                -- playermgr uses GStreamer to decode audio files.  On some
                -- Kindle models the GStreamer installation is stripped to only
                -- ttssrc+mixersink+audiblesrc -- no wavparse or audioconvert.
                -- Without wavparse, playermgr cannot decode WAV files and
                -- kindle-lipc will silently fail on every play attempt.
                -- Detect this by checking whether wavparse exists in the
                -- GStreamer plugin directory.
                local has_wavparse = false
                local gst_dirs = {"/usr/lib/gstreamer-1.0", "/usr/lib/gstreamer-0.10"}
                for _, dir in ipairs(gst_dirs) do
                    local lsh = io.popen("ls " .. dir .. "/libgstwav* 2>/dev/null")
                    if lsh then
                        local ls_out = lsh:read("*a") or ""
                        lsh:close()
                        if ls_out:match("libgstwav") then
                            has_wavparse = true
                            break
                        end
                    end
                end

                if has_wavparse then
                    self.audio_player_type = "kindle-lipc"
                    self._no_real_audio_output = false  -- LIPC routes through BT
                    logger.warn("TTSEngine: Found Kindle LIPC playermgr service, InPlayback=", val,
                        "wavparse=", has_wavparse)
                    return "kindle-lipc"
                end

                -- No wavparse -- playermgr cannot decode WAV.  Check for our
                -- bundled gst-play helper which feeds raw PCM to mixersink
                -- directly, bypassing the missing wavparse plugin.
                local plugin_dir = self.plugin_dir or "."
                local gst_play_bin = plugin_dir .. "/kindle/gst-play"
                local gf = io.open(gst_play_bin, "r")
                if gf then
                    gf:close()
                    -- Wrap through bundled ld-linux to bypass old system glibc.
                    -- Include /usr/lib:/lib so dlopen can find system libgstreamer.
                    local gst_play_cmd = gst_play_bin
                    if self.espeak_linker then
                        gst_play_cmd = string.format(
                            "%s --library-path %s:/usr/lib:/lib %s",
                            self.espeak_linker, self.espeak_lib_path, gst_play_bin)
                    end
                    -- Run --probe to verify GStreamer loads and mixersink exists
                    local ph = io.popen(gst_play_cmd .. " --probe 2>/dev/null")
                    if ph then
                        local probe = ph:read("*a") or ""
                        ph:close()
                        if probe:match("mixersink=found") then
                            self.audio_player_type = "kindle-gst-play"
                            self._kindle_gst_play_bin = gst_play_cmd
                            self._no_real_audio_output = false
                            logger.warn("TTSEngine: Found kindle-gst-play with mixersink, probe:", probe:gsub("\n", " "))
                            return "kindle-gst-play"
                        else
                            logger.warn("TTSEngine: kindle-gst-play probe failed:", probe:gsub("\n", " "))
                        end
                    end
                end

                -- Fall through: no wavparse AND no gst-play helper (or
                -- mixersink not found).  Select kindle-lipc anyway but flag
                -- that audio will fail so rapid-fail detection kicks in.
                self.audio_player_type = "kindle-lipc"
                self._no_real_audio_output = true
                logger.warn("TTSEngine: Kindle playermgr found but GStreamer lacks wavparse and no gst-play helper")
                logger.warn("TTSEngine: Found Kindle LIPC playermgr service, InPlayback=", val,
                    "wavparse=false, gst_play=not_found")
                return "kindle-lipc"
            else
                logger.warn("TTSEngine: lipc-get-prop playermgr InPlayback returned:", val)
            end
        end
    end

    -- 1) GStreamer with Kobo Bluetooth A2DP sink (primary on Kobo Libra Colour etc.)
    if self:commandExists("gst-launch-1.0") then
        local handle = io.popen("gst-inspect-1.0 mtkbtmwrpcaudiosink 2>/dev/null | head -1")
        if handle then
            local result = handle:read("*a")
            handle:close()
            if result and result:match("Factory Details") then
                self.audio_player_type = "gst-bt"
                logger.dbg("TTSEngine: Found GStreamer with Bluetooth audio sink")
                return "gst-launch-1.0"
            end
        end
    end

    -- 1b) BlueALSA: bundled BT audio bridge for BlueZ Kobo devices.
    -- When bluealsa daemon is running, aplay can route audio to BT
    -- headphones via the "bluealsa" ALSA PCM device.
    local bt = self.plugin and self.plugin.bt_manager
    if self:commandExists("aplay") and bt then
        -- If bluealsa is not running but bundled, and a BT audio device
        -- is already connected (e.g. paired externally through Kobo
        -- firmware settings), start bluealsa now so we can use it.
        if not bt:isBluealsaRunning()
            and bt:hasBluealsaBundled()
            and bt:getStackType() == "bluez" then
            local has_bt_device = false
            local ok_list, devs = pcall(bt.listAudioDevices, bt)
            if ok_list and devs then
                for _, d in ipairs(devs) do
                    if d.connected then has_bt_device = true; break end
                end
            end
            if has_bt_device then
                logger.warn("TTSEngine: BT device connected but bluealsa not running, starting it")
                bt:startBluealsa()
            else
                logger.warn("TTSEngine: BlueALSA bundled but daemon not running (no BT device)")
            end
        end

        if bt:isBluealsaRunning() then
            local plugin_dir = bt:getBluealsaPluginDir()
            local ba_dev = bt:getBluealsaDevice()
            -- ALSA_PLUGIN_DIR tells libasound where to find the bluealsa
            -- PCM plugin .so. The PCM type "bluealsa" is defined in
            -- /etc/asound.conf (installed by startBluealsa).
            -- LD_LIBRARY_PATH is needed so that when aplay loads the PCM
            -- plugin, the plugin's own deps (libsbc, libglib, libdbus,
            -- libbluetooth) can be resolved from our bundled libs.
            local lib_dir = plugin_dir and plugin_dir:gsub("/alsa%-lib$", "")
            local env = ""
            if plugin_dir then
                env = "ALSA_PLUGIN_DIR=" .. plugin_dir .. " "
            end
            if lib_dir then
                env = "LD_LIBRARY_PATH=" .. lib_dir .. " " .. env
            end
            self.audio_player_type = "bluealsa"
            self._bluealsa_env = env
            logger.warn("TTSEngine: Found BlueALSA audio bridge, device:", ba_dev)
            return env .. "aplay -q -D " .. ba_dev
        end
    end

    -- 2) Check if any ALSA soundcard exists
    local has_soundcard = false
    local cards = io.open("/proc/asound/cards", "r")
    if cards then
        local content = cards:read("*a")
        cards:close()
        has_soundcard = content and not content:match("no soundcards")
    end

    local is_kindle = Device:isKindle()

    -- Kindle audio device probing.
    -- /proc/asound/cards may say "no soundcards" even when BT audio
    -- is paired -- Amazon manages BT audio at the OS level via its own
    -- daemon (btfd/Lab126 IPC) and does NOT expose a standard ALSA PCM
    -- device.  Probe aplay -l, aplay -L, /dev/snd/ and PulseAudio for
    -- any dynamically registered device that appears when a BT headset
    -- connects.  If found, use it with an explicit -D argument; if
    -- nothing is found, flag _no_real_audio_output so the process
    -- watcher can detect rapid aplay failures instead of silently
    -- cycling through sentences.
    local kindle_audio_device = nil  -- explicit -D value when found
    if is_kindle and not has_soundcard then
        local has_aplay = self:commandExists("aplay")
        -- 1) aplay -l: registered ALSA cards (may include BT)
        if has_aplay then
            local al = io.popen("aplay -l 2>/dev/null")
            if al then
                local al_out = al:read("*a") or ""
                al:close()
                local card, dev = al_out:match("card (%d+):.+device (%d+):")
                if card and dev then
                    kindle_audio_device = "hw:" .. card .. "," .. dev
                    has_soundcard = true
                    logger.warn("TTSEngine: Kindle found ALSA hw device:", kindle_audio_device)
                end
            end
        end
        -- 2) aplay -L: named PCM devices.  Prefer BT-related names
        --    (bluealsa:*, bluetooth, a2dp) over generic ones; skip
        --    default / null / surround* which are not real sinks on a
        --    speakerless Kindle.
        if has_aplay and not has_soundcard then
            local aL = io.popen("aplay -L 2>/dev/null")
            if aL then
                local pcm_list = aL:read("*a") or ""
                aL:close()
                local bt_pcm, first_pcm = nil, nil
                for line in pcm_list:gmatch("([^\n]+)") do
                    local name = line:match("^(%S+)$")
                    if name then
                        local lower = name:lower()
                        if lower:match("blue") or lower:match("a2dp") or lower:match("bt") then
                            bt_pcm = name
                            break  -- BT device found, stop searching
                        end
                        if not first_pcm
                            and lower ~= "default" and lower ~= "null"
                            and not lower:match("^surround") then
                            first_pcm = name
                        end
                    end
                end
                kindle_audio_device = bt_pcm or first_pcm
                if kindle_audio_device then
                    has_soundcard = true
                    logger.warn("TTSEngine: Kindle found PCM device:", kindle_audio_device)
                end
            end
        end
        -- 3) /dev/snd/ pcm nodes
        if not has_soundcard then
            local snd = io.popen("ls /dev/snd/ 2>/dev/null")
            if snd then
                local snd_out = snd:read("*a") or ""
                snd:close()
                if snd_out:match("pcm") then
                    has_soundcard = true
                    logger.warn("TTSEngine: Kindle found /dev/snd/ pcm node")
                end
            end
        end
        -- 4) PulseAudio: check for a running sink (Amazon may route BT
        --    through PulseAudio on newer firmware).
        if not has_soundcard and self:commandExists("pactl") then
            local pa = io.popen("pactl list sinks short 2>/dev/null")
            if pa then
                local pa_out = pa:read("*a") or ""
                pa:close()
                if pa_out:match("%S") then
                    has_soundcard = true
                    self._kindle_use_pulseaudio = true
                    logger.warn("TTSEngine: Kindle found PulseAudio sink")
                end
            end
        end
        if not has_soundcard then
            logger.warn("TTSEngine: Kindle - no ALSA card, no PCM device, "
                        .. "no /dev/snd pcm, no PulseAudio. Audio will likely fail.")
        end
    end

    -- On Kindle, parse /etc/asound.conf for named PCM devices.
    -- v0.1.5.24 diagnostics revealed dmix0 on hw:0,0 at 44100 Hz.
    local kindle_asound_pcms = {}
    if is_kindle then
        local ac = io.open("/etc/asound.conf", "r")
        if ac then
            local content = ac:read("*a") or ""
            ac:close()
            -- Match pcm.<name> { ... } top-level definitions
            for name in content:gmatch("pcm%.(%w+)%s*{") do
                if name ~= "default" and name ~= "null" then
                    table.insert(kindle_asound_pcms, name)
                end
            end
            if #kindle_asound_pcms > 0 then
                logger.warn("TTSEngine: Kindle asound.conf PCMs:",
                            table.concat(kindle_asound_pcms, ", "))
            end
        end
    end

    -- Build player candidate list, ordered by preference.
    local players = {}
    -- Kindle-discovered device with explicit -D (highest priority)
    if is_kindle and kindle_audio_device then
        table.insert(players, {cmd = "aplay", args = "-q -D " .. kindle_audio_device})
    end
    -- Kindle asound.conf named PCMs (e.g. dmix0 found in v0.1.5.24)
    for _, pcm_name in ipairs(kindle_asound_pcms) do
        table.insert(players, {cmd = "aplay", args = "-q -D " .. pcm_name})
    end
    -- Kindle with PulseAudio: try paplay before generic aplay
    if is_kindle and self._kindle_use_pulseaudio then
        table.insert(players, {cmd = "paplay", args = ""})
    end
    if has_soundcard or is_kindle then
        table.insert(players, {cmd = "aplay", args = "-q -D default"})
        table.insert(players, {cmd = "aplay", args = "-q -D hw:0,0"})
        table.insert(players, {cmd = "aplay", args = "-q"})
    end
    table.insert(players, {cmd = "paplay", args = ""})
    table.insert(players, {cmd = "mpv", args = "--no-video --really-quiet"})
    table.insert(players, {cmd = "mplayer", args = "-really-quiet"})
    table.insert(players, {cmd = "play", args = "-q"})
    -- Last resort: try aplay even without a detected soundcard
    if not has_soundcard and not is_kindle then
        table.insert(players, {cmd = "aplay", args = "-q"})
    end
    -- Flag no real audio output for rapid-fail detection.
    if not has_soundcard then
        self._no_real_audio_output = true
    end

    for _, player in ipairs(players) do
        if self:commandExists(player.cmd) then
            logger.dbg("TTSEngine: Found audio player:", player.cmd)
            self.audio_player_type = player.cmd == "aplay" and "aplay" or "generic"
            if player.args and player.args ~= "" then
                return player.cmd .. " " .. player.args
            end
            return player.cmd
        end
    end

    -- Bundled wav-play: minimal ALSA player for devices that have a
    -- soundcard + libasound but ship no aplay (e.g. PocketBook).
    -- Uses the bundled ld-linux wrapper.  Bundled libasound gets priority
    -- so we avoid "internal error" when the system libasound is built
    -- against an older glibc than our bundled ld-linux.  System dirs are
    -- still in the path as fallback for other shared objects.
    if has_soundcard and self._wav_play_bin then
        local wav_play_cmd = self._wav_play_bin
        if self.espeak_linker and self._wav_play_lib then
            -- The bundled libasound (Nix cross-compiled) has Nix store
            -- paths compiled in for ALSA_PLUGIN_DIR and the default
            -- config.  /usr/share/alsa/alsa.conf has @hooks which call
            -- snd_dlopen(NULL); that fails because the Nix plugin dir
            -- does not exist on the device.  Use /etc/asound.conf first:
            -- it contains only PCM definitions (softvol, dmix, hw) with
            -- no hooks, so config loading succeeds.
            local alsa_env = ""
            -- ALSA_CONFIG_PATH: prefer device-specific config (no hooks)
            local alsa_conf_candidates = {
                "/etc/asound.conf",
                "/etc/alsa/alsa.conf",
                "/usr/share/alsa/alsa.conf",
            }
            for _, path in ipairs(alsa_conf_candidates) do
                local f = io.open(path, "r")
                if f then
                    f:close()
                    alsa_env = "ALSA_CONFIG_PATH=" .. path
                    logger.warn("TTSEngine: Using ALSA config:", path)
                    break
                end
            end
            -- ALSA_PLUGIN_DIR: override the Nix store plugin path
            -- compiled into the bundled libasound.  Point to the
            -- system's ALSA plugin directory (may not exist, but
            -- prevents attempts to load from /nix/store/...).
            local plugin_dir_candidates = {
                "/usr/lib/alsa-lib",
                "/usr/lib/arm-linux-gnueabihf/alsa-lib",
                "/usr/lib/alsa",
            }
            for _, path in ipairs(plugin_dir_candidates) do
                local d = io.open(path, "r")
                if d then
                    d:close()
                    alsa_env = alsa_env .. " ALSA_PLUGIN_DIR=" .. path
                    logger.warn("TTSEngine: Using ALSA plugin dir:", path)
                    break
                end
            end
            if alsa_env ~= "" then alsa_env = alsa_env .. " " end
            -- Use absolute paths in --library-path so the dynamic linker
            -- stores absolute paths in dladdr().  ALSA's snd_dlopen(NULL)
            -- calls dladdr() to find libasound.so.2; when the returned
            -- path is relative (starts without '/'), snd_dlopen prepends
            -- ALSA_PLUGIN_DIR creating a broken path like:
            --   /usr/lib/alsa-lib/plugins/.../wav-play/lib/libasound.so.2
            -- When the path is absolute, snd_dlopen calls dlopen()
            -- directly on the already-loaded library and it succeeds.
            local abs_linker = self.espeak_linker
            local abs_wav_lib = self._wav_play_lib
            local abs_esp_lib = self.espeak_lib_path
            local abs_wav_bin = self._wav_play_bin
            if abs_wav_lib:sub(1, 1) ~= "/" then
                local h = io.popen("pwd")
                if h then
                    local cwd = h:read("*l")
                    h:close()
                    if cwd and cwd ~= "" then
                        abs_linker = cwd .. "/" .. abs_linker
                        abs_wav_lib = cwd .. "/" .. abs_wav_lib
                        abs_esp_lib = cwd .. "/" .. abs_esp_lib
                        abs_wav_bin = cwd .. "/" .. abs_wav_bin
                    end
                end
            end
            wav_play_cmd = string.format(
                "%s%s --library-path %s:%s:/usr/lib:/lib %s",
                alsa_env, abs_linker, abs_wav_lib,
                abs_esp_lib, abs_wav_bin)
        end
        self.audio_player_type = "aplay"
        self._wav_play_cmd = wav_play_cmd
        logger.warn("TTSEngine: Using bundled wav-play for ALSA playback")
        -- Do NOT pass -q: we need stderr output for diagnostics.
        -- Errors are captured via the process-watcher stderr log below.
        return wav_play_cmd
    end

    logger.warn("TTSEngine: No audio player found. has_soundcard=", has_soundcard,
                "is_kindle=", is_kindle, "checked:", #players, "candidates")
    return nil
end

--[[--
Start the timing loop to call word callbacks.
NOTE: The actual word-highlight polling is handled by SyncController's
sync loop (startSentenceSyncLoop) which already runs at 20Hz.  This
method now only records the playback_start_time so that pause/resume
can adjust it correctly.  The 20Hz polling loop was removed to cut
redundant CPU wakeups and save battery.
--]]
function TTSEngine:startTimingLoop()
    self.playback_start_time = UIManager:getTime()
    self.current_word_index = 0
    -- No polling loop — SyncController handles word highlighting.
end

--[[--
Restart the timing bookkeeping after a resume (no polling loop needed).
--]]
function TTSEngine:_runTimingLoop()
    -- No-op: SyncController's sync loop handles word highlighting.
    -- Kept as a function so resume() doesn't need changes.
end

--[[--
Get actual audio duration from the current WAV file.
@return number Duration in milliseconds, or 0 on error
--]]
function TTSEngine:getAudioDurationMs()
    return self:getWavDurationMs(self.current_audio_file)
end

--[[--
Force-kill the current audio process AND any orphan gst-launch-1.0 processes.
Uses SIGKILL (not SIGTERM) because gst-launch with mtkbtmwrpcaudiosink holds
an abstract UNIX socket (@kobo:mtkbtmwrpc) that isn't released on graceful
shutdown fast enough, causing "Address already in use" for the next launch.
--]]
function TTSEngine:_killAudioProcess()
    -- Don't kill the persistent pipeline's gst-launch
    if self._persistent_pipeline then return end
    local had_pid = self.audio_pid ~= nil
    if self.audio_pid then
        os.execute("kill -9 " .. self.audio_pid .. " 2>/dev/null")
        self.audio_pid = nil
    end
    -- Always catch orphan gst-launch-1.0 processes, even if we lost our PID
    if self.audio_player_type == "gst-bt" then
        os.execute("killall -9 gst-launch-1.0 2>/dev/null")
    end
    -- Also clear keepalive PID since killall caught it
    self._bt_keepalive_pid = nil
    -- Record when we last killed a tracked process — used to skip redundant
    -- BT socket waits.  Only set when we had a real PID so that a no-op kill
    -- doesn't reset the timer and re-introduce the 0.3s wait.
    if had_pid then
        self._last_audio_kill_time = UIManager:getTime()
    end
end

--[[--%nStart a BT keepalive process that plays silence to hold the A2DP
connection alive.  Without this, the BT audio sink disconnects after
~1-2s of idle time, causing the next gst-launch to crash.
Called from onPlaybackComplete via a short delay — if the next sentence
is immediately ready, play() cancels this before it starts.
--]]
function TTSEngine:_startBtKeepalive()
    if self.audio_player_type ~= "gst-bt" then return end
    -- Don't start if there's already a keepalive running
    if self._bt_keepalive_pid then return end
    -- Create a long silence WAV once (120 seconds, covers any Piper wait)
    if not self._keepalive_wav then
        self._keepalive_wav = self:generateSilenceWav(120000)
    end
    if not self._keepalive_wav then return end
    local cmd = string.format(
        'gst-launch-1.0 filesrc location="%s" ! wavparse ! audioconvert ! audioresample'
        .. ' ! "audio/x-raw,format=S16LE,rate=48000,channels=2" ! mtkbtmwrpcaudiosink'
        .. ' >/dev/null 2>/dev/null & echo $!',
        self._keepalive_wav
    )
    local h = io.popen(cmd)
    local pid_str = h and h:read("*a") or ""
    if h then h:close() end
    self._bt_keepalive_pid = tonumber(pid_str:match("(%d+)"))
    -- Socket is now held by keepalive — NOT clean
    self._socket_clean = false
    logger.warn("TTSEngine: BT keepalive started, PID=", self._bt_keepalive_pid)
end

--[[--%nStop the BT keepalive silence process.
--]]
function TTSEngine:_stopBtKeepalive()
    -- Cancel any pending scheduled start
    if self._keepalive_scheduled_fn then
        UIManager:unschedule(self._keepalive_scheduled_fn)
        self._keepalive_scheduled_fn = nil
    end
    if self._bt_keepalive_pid then
        os.execute("kill -9 " .. self._bt_keepalive_pid .. " 2>/dev/null")
        self._bt_keepalive_pid = nil
        self._last_audio_kill_time = UIManager:getTime()
        logger.warn("TTSEngine: BT keepalive stopped")
    end
end

--[[--
Write the persistent BT pipeline feeder script to /tmp.
The script starts gst-launch reading from a named FIFO and feeds it
raw PCM (silence when idle, real audio when playing).
--]]
function TTSEngine:_writePipelineScript()
    local sr = self._piper_sample_rate or 22050
    -- Silence chunk: ~50ms at sample rate, 16-bit mono
    -- MUST be even (multiple of block_align=2) to preserve PCM sample alignment!
    local silence_samples = math.floor(sr * 0.05)
    local silence_bytes = silence_samples * 2
    local script = string.format([=[
#!/bin/sh
CTRL="/tmp/audiobook_ctrl"
FIFO="/tmp/audiobook_fifo"
mkdir -p "$CTRL"
rm -f "$CTRL/stop" "$CTRL/play" "$CTRL/done" "$CTRL/gst_pid"
rm -f "$FIFO"
mkfifo "$FIFO"
# Silence chunk: ~50ms at %dHz 16-bit mono = %d samples × 2 bytes = %d bytes
dd if=/dev/zero bs=%d count=1 of="$CTRL/s.raw" 2>/dev/null
# Start gst-launch reading raw PCM from FIFO.
# sync=false — let the BT A2DP hardware clock control the playback rate
# via socket backpressure, instead of GStreamer's pipeline clock.
# This is CRITICAL for SIGSTOP/SIGCONT pause/resume: with sync=true,
# CLOCK_MONOTONIC advances during SIGSTOP but audio timestamps don't,
# so GStreamer sees all buffered audio as "late" on SIGCONT and plays
# it in a burst (causing choppy audio on the first sentence after
# unpause).  With sync=false there is no clock to go stale.
# The Lua caller shrinks the pipe buffer to 16KB via
# fcntl(F_SETPIPE_SZ) to reduce latency while keeping enough headroom
# to absorb CPU stalls during Piper synthesis.
gst-launch-1.0 filesrc location="$FIFO" \
  ! rawaudioparse use-sink-caps=false format=pcm pcm-format=s16le sample-rate=%d num-channels=1 \
  ! audioconvert ! audioresample \
  ! "audio/x-raw,format=S16LE,rate=48000,channels=2" \
  ! mtkbtmwrpcaudiosink sync=false >/dev/null 2>/dev/null &
GST_PID=$!
# Open FIFO write end — keeps it alive between individual writes.
# This BLOCKS until gst-launch opens the read end (filesrc start).
exec 3>"$FIFO"
# Signal Lua AFTER the FIFO is fully set up (both ends open).
# Lua uses the gst_pid file as a "ready" indicator before trying to
# open(O_WRONLY|O_NONBLOCK) on the FIFO for pipe buffer resize.
echo $GST_PID > "$CTRL/gst_pid"
cleanup() { exec 3>&- 2>/dev/null; kill $GST_PID 2>/dev/null; rm -f "$FIFO" "$CTRL/s.raw" "$CTRL/gst_pid"; }
trap cleanup EXIT TERM
# Track total bytes written to detect/fix alignment
TOTAL_BYTES=0
# Feeder loop: continuous silence when idle, real audio when play file appears.
# usleep 1000 (1ms) prevents CPU busy-spin during initial pipe fill.
while kill -0 $GST_PID 2>/dev/null && [ ! -f "$CTRL/stop" ]; do
  if [ -f "$CTRL/play" ]; then
    FILE=$(cat "$CTRL/play")
    rm -f "$CTRL/play" "$CTRL/done"
    # If total bytes written so far is odd, write 1 zero byte to re-align
    ODD=$((TOTAL_BYTES %% 2))
    if [ "$ODD" -ne 0 ]; then
      printf '\0' >&3
      TOTAL_BYTES=$((TOTAL_BYTES + 1))
    fi
    # Get audio data size (file size minus 44-byte WAV header)
    FSIZE=$(wc -c < "$FILE")
    DSIZE=$((FSIZE - 44))
    # Skip 44-byte WAV header, output raw PCM
    tail -c +45 "$FILE" >&3
    TOTAL_BYTES=$((TOTAL_BYTES + DSIZE))
    touch "$CTRL/done"
  else
    cat "$CTRL/s.raw" >&3
    TOTAL_BYTES=$((TOTAL_BYTES + %d))
    usleep 1000
  fi
done
]=], sr, silence_samples, silence_bytes, silence_bytes, sr, silence_bytes)
    local f = io.open(PIPELINE_SCRIPT, "w")
    if not f then return false end
    f:write(script)
    f:close()
    os.execute("chmod +x " .. PIPELINE_SCRIPT)
    return true
end

--[[--
Start the persistent BT audio pipeline.
Creates the feeder script, launches it (piping silence/audio to gst-launch
via a named FIFO), and waits for gst-launch to initialise.
@return boolean true if pipeline started successfully
--]]
function TTSEngine:_startPersistentPipeline()
    self:_stopPersistentPipeline("restart")

    -- Verify the mtkbtmwrpc socket is actually free before starting.
    -- An orphan gst-launch from a crashed/previous session can hold it.
    -- The killall in _stopPersistentPipeline should have freed it, but
    -- the kernel needs a moment to tear down the abstract socket.
    for attempt = 1, 5 do
        local pf = io.open("/proc/net/unix", "r")
        if pf then
            local content = pf:read("*a")
            pf:close()
            if not content:find("@kobo:mtkbtmwrpc") then
                break  -- socket is free
            end
            logger.warn("TTSEngine: mtkbtmwrpc socket still held, attempt",
                attempt, "— waiting 200ms")
            os.execute("killall -9 gst-launch-1.0 2>/dev/null")
            os.execute("usleep 200000")
        else
            break  -- can't check, proceed anyway
        end
    end

    if not self:_writePipelineScript() then
        logger.err("TTSEngine: Cannot write pipeline script")
        return false
    end
    -- Clean control files
    os.execute("rm -f " .. PIPELINE_CTRL_DIR .. "/stop " .. PIPELINE_CTRL_DIR .. "/play " .. PIPELINE_CTRL_DIR .. "/done")
    -- Launch pipeline in background
    local h = io.popen(PIPELINE_SCRIPT .. " >/dev/null 2>/dev/null & echo $!")
    local pid_str = h and h:read("*a") or ""
    if h then h:close() end
    self._pipeline_wrapper_pid = tonumber(pid_str:match("(%d+)"))
    -- Wait for gst-launch PID file to appear (up to 3s)
    local gst_pid = nil
    for _ = 1, 60 do  -- 60 × 50ms = 3s
        local pf = io.open(PIPELINE_CTRL_DIR .. "/gst_pid", "r")
        if pf then
            local pid = pf:read("*a")
            pf:close()
            gst_pid = tonumber((pid or ""):match("(%d+)"))
            if gst_pid then break end
        end
        os.execute("usleep 50000")
    end
    self._pipeline_gst_pid = gst_pid
    self.audio_pid = gst_pid  -- for pause/resume compatibility
    self._socket_clean = false
    self._persistent_pipeline = true

    -- Shrink the FIFO pipe buffer from 64KB to 16KB.
    -- At 22050Hz mono 16-bit (44100 B/s): 16KB ≈ 370ms.
    -- At 16000Hz mono 16-bit (32000 B/s): 16KB ≈ 512ms.
    -- Balances low latency with headroom for Piper CPU stalls.
    local sr = self._piper_sample_rate or 22050
    self._pipe_buffer_delay_ms = pipeBufferDelay(sr, 64)  -- default: assume 64KB
    if gst_pid then
        local O_WRONLY    = 1
        local O_NONBLOCK  = 2048  -- 0x800
        local F_SETPIPE_SZ = 1031
        local fd = ffi.C.open(PIPELINE_FIFO, bit.bor(O_WRONLY, O_NONBLOCK))
        if fd >= 0 then
            -- Pass size as cdata int — required for variadic fcntl on ARM EABI.
            local ret = ffi.C.fcntl(fd, F_SETPIPE_SZ, ffi.new("int", 16384))
            if ret >= 0 then
                self._pipe_buffer_delay_ms = pipeBufferDelay(sr, 16)
                logger.warn("TTSEngine: Pipe buffer shrunk to 16KB, ret=", ret,
                    "delay=", self._pipe_buffer_delay_ms, "ms at", sr, "Hz")
            else
                logger.warn("TTSEngine: fcntl F_SETPIPE_SZ failed, ret=", ret,
                    "errno=", ffi.errno(), ", trying shell fallback")
                ffi.C.close(fd)
                -- Shell fallback: python3 or direct /proc write
                local rc = os.execute(string.format(
                    'python3 -c "import fcntl,os; fd=os.open(\'%s\',os.O_WRONLY|os.O_NONBLOCK); fcntl.fcntl(fd,1031,16384); os.close(fd)" 2>/dev/null',
                    PIPELINE_FIFO))
                if rc == 0 then
                    self._pipe_buffer_delay_ms = pipeBufferDelay(sr, 16)
                    logger.warn("TTSEngine: Pipe buffer shrunk to 16KB via python3")
                else
                    logger.warn("TTSEngine: All pipe resize methods failed, using 64KB delay")
                end
                fd = -1  -- already closed
            end
            if fd >= 0 then ffi.C.close(fd) end
        else
            logger.warn("TTSEngine: Could not open FIFO for pipe resize, errno=",
                ffi.errno(), ", using 64KB delay")
        end
    end

    logger.warn("TTSEngine: Persistent pipeline started, wrapper=",
        self._pipeline_wrapper_pid, "gst=", self._pipeline_gst_pid)
    return gst_pid ~= nil
end

--[[--
Stop the persistent BT audio pipeline.
Kills the feeder script and gst-launch, cleans up the FIFO.
@param reason string  Caller identification for diagnostic logging
--]]
function TTSEngine:_stopPersistentPipeline(reason)
    reason = reason or "unknown"
    logger.warn("TTSEngine: _stopPersistentPipeline, reason=", reason,
        "gst_pid=", self._pipeline_gst_pid)
    -- Signal feeder to stop (harmless if no feeder is running)
    local sf = io.open(PIPELINE_CTRL_DIR .. "/stop", "w")
    if sf then sf:write("1"); sf:close() end
    -- Kill tracked processes
    if self._pipeline_gst_pid then
        os.execute("kill -9 " .. self._pipeline_gst_pid .. " 2>/dev/null")
    end
    if self._pipeline_wrapper_pid then
        os.execute("kill -9 " .. self._pipeline_wrapper_pid .. " 2>/dev/null")
    end
    -- Also read gst PID from file in case Lua state was lost (crash/restart).
    -- This catches orphans whose PIDs we no longer track in memory.
    local gst_pf = io.open(PIPELINE_CTRL_DIR .. "/gst_pid", "r")
    if gst_pf then
        local file_pid = gst_pf:read("*a"):gsub("%s+", "")
        gst_pf:close()
        if file_pid ~= "" and tonumber(file_pid) ~= self._pipeline_gst_pid then
            os.execute(string.format("kill -9 %s 2>/dev/null", file_pid))
            logger.warn("TTSEngine: Killed orphan gst from PID file:", file_pid)
        end
    end
    -- Kill orphan feeder wrapper shells that Lua state doesn't track.
    -- These are /bin/sh processes not caught by killall gst-launch-1.0.
    os.execute("pkill -9 -f 'audiobook_pipeline\\.sh' 2>/dev/null")
    -- ALWAYS kill orphan gst-launch processes.  On Kobo, the
    -- mtkbtmwrpcaudiosink binds an exclusive abstract socket
    -- (@kobo:mtkbtmwrpc).  If ANY gst-launch holds it — even an
    -- orphan from a previous KOReader session or an SSH test — the
    -- new pipeline fails with "Address already in use".
    os.execute("killall -9 gst-launch-1.0 2>/dev/null")
    -- Kill the feeder wrapper shell too — if Lua lost track of its PID
    -- (crash / restart), it becomes orphaned under init (PID 1).
    os.execute("pkill -9 -f 'audiobook_pipeline\\.sh' 2>/dev/null")
    -- Brief wait for the kernel to release the abstract socket
    -- after SIGKILL.  Without this, the bind() in the new pipeline
    -- can race against socket teardown.
    if self._persistent_pipeline then
        os.execute("usleep 200000")
    end
    -- Clean up
    os.execute("rm -f " .. PIPELINE_FIFO .. " " .. PIPELINE_CTRL_DIR .. "/gst_pid")
    self._pipeline_gst_pid = nil
    self._pipeline_wrapper_pid = nil
    self._persistent_pipeline = false
    self.audio_pid = nil
    self._socket_clean = false
    logger.warn("TTSEngine: Persistent pipeline stopped, reason=", reason)
end

--[[--
Check if the persistent BT pipeline is alive.
@return boolean
--]]
function TTSEngine:_isPipelineAlive()
    if not self._persistent_pipeline or not self._pipeline_gst_pid then
        return false
    end
    local ret = os.execute("kill -0 " .. self._pipeline_gst_pid .. " 2>/dev/null")
    return ret == 0
end

--[[--
Ensure the persistent BT pipeline is running, (re)starting if needed.
@return boolean true if pipeline is alive
--]]
function TTSEngine:_ensurePersistentPipeline()
    if self:_isPipelineAlive() then
        return true
    end
    logger.warn("TTSEngine: Pipeline not alive, (re)starting...")
    return self:_startPersistentPipeline()
end

--[[--
Check if the audio player process is still running.
@return boolean true if process is alive
--]]
function TTSEngine:_isAudioProcessRunning()
    if not self.audio_pid then return false end
    -- Use /proc test instead of spawning a shell on every poll.
    -- This avoids fork+exec overhead on single-core ARM devices
    -- where it can add up with 100ms polling intervals.
    local f = io.open("/proc/" .. self.audio_pid .. "/stat", "r")
    if f then
        f:close()
        return true
    end
    return false
end

--[[--
Poll for audio process exit. When the player process finishes,
trigger playback completion.

For Bluetooth audio, also detects "early death" — if gst-launch exits
within 2 seconds it means A2DP negotiation failed (no connected sink).
On first early death it retries once (kill, 0.5s socket wait, relaunch).
On second early death it shows an error and stops the reading chain.

All waits use UIManager:scheduleIn so the main loop stays responsive
for rotation, taps, and other input events.

@param bt_retry_allowed boolean Whether BT early-death retry is allowed
--]]
function TTSEngine:_startProcessWatcher(bt_retry_allowed, skip_on_fail)
    local my_gen = self.play_generation or 0
    local launch_time = UIManager:getTime()
    -- Real BT connection failures exit in <200ms (no A2DP sink).
    -- Normal audio takes at least 500ms+ (BT negotiation + playback).
    -- Keep this low so short sentences aren't mistaken for failures.
    local BT_EARLY_DEATH_MS = 500
    local engine = self

    local function checkProcess()
        if (engine.play_generation or 0) ~= my_gen then return end
        if not engine.is_speaking then return end
        if engine.is_paused then
            UIManager:scheduleIn(0.5, checkProcess)
            return
        end

        if engine:_isAudioProcessRunning() then
            UIManager:scheduleIn(0.1, checkProcess)
        else
            local elapsed_ms = time.to_ms(UIManager:getTime() - launch_time)

            -- BT early-death detection: gst-launch exits in <200ms when
            -- there is no A2DP sink.  Normal playback always takes >500ms
            -- (BT overhead alone is ~1s).
            if engine.audio_player_type == "gst-bt" and elapsed_ms < BT_EARLY_DEATH_MS then
                if bt_retry_allowed then
                    logger.warn("TTSEngine: gst-launch died early (" .. elapsed_ms .. "ms), retrying…")
                    engine:_killAudioProcess()
                    -- Non-blocking 0.5s wait for socket release, then retry
                    UIManager:scheduleIn(0.5, function()
                        if (engine.play_generation or 0) ~= my_gen then return end
                        if not engine.is_speaking then return end
                        local handle = io.popen(engine._last_pid_cmd)
                        local pid_str = handle and handle:read("*a") or ""
                        if handle then handle:close() end
                        engine.audio_pid = tonumber(pid_str:match("(%d+)"))
                        logger.dbg("TTSEngine: Retry PID:", engine.audio_pid)
                        -- Restart watcher WITHOUT retry (second chance only)
                        engine:_startProcessWatcher(false)
                    end)
                elseif skip_on_fail then
                    -- Retry of a premature-exit also failed fast — skip
                    -- sentence and continue playback instead of showing error.
                    logger.warn("TTSEngine: gst-launch retry failed fast ("
                        .. elapsed_ms .. "ms), skipping sentence")
                    engine._socket_clean = false
                    engine:onPlaybackComplete()
                else
                    -- Retry also failed — BT not connected
                    logger.warn("TTSEngine: gst-launch died on retry — BT audio not connected")
                    engine.is_speaking = false
                    engine.audio_pid = nil
                    engine.play_generation = (engine.play_generation or 0) + 1
                    engine:cleanup()
                    UIManager:show(InfoMessage:new{
                        text = _("Bluetooth audio not connected.\n\nPlease make sure your Bluetooth headphones or speaker are:\n\n1. Powered on\n2. Paired in Kobo Settings → Bluetooth\n3. Connected and within range\n\nThen try again."),
                        timeout = 10,
                    })
                    -- Signal failure to SyncController so it stops the chain
                    if engine.on_fail_callback then
                        engine.on_fail_callback()
                    end
                end
            elseif engine.audio_player_type == "gst-bt" and engine._expected_play_duration_ms
                    and engine._expected_play_duration_ms > 2000
                    and elapsed_ms < engine._expected_play_duration_ms * 0.4 then
                -- Premature exit: gst-launch crashed (BT sink went idle
                -- during Piper synthesis wait, A2DP re-negotiation failed).
                -- The socket is NOT clean — kill and retry with a delay.
                if bt_retry_allowed then
                    logger.warn("TTSEngine: gst-launch premature exit ("
                        .. elapsed_ms .. "ms vs expected "
                        .. engine._expected_play_duration_ms .. "ms), killing BT & retrying…")
                    engine._socket_clean = false
                    engine:_killAudioProcess()
                    -- 2s wait for BT A2DP re-establishment
                    UIManager:scheduleIn(2.0, function()
                        if (engine.play_generation or 0) ~= my_gen then return end
                        if not engine.is_speaking then return end
                        local handle = io.popen(engine._last_pid_cmd)
                        local pid_str = handle and handle:read("*a") or ""
                        if handle then handle:close() end
                        engine.audio_pid = tonumber(pid_str:match("(%d+)"))
                        launch_time = UIManager:getTime()
                        logger.warn("TTSEngine: BT premature-exit retry PID:", engine.audio_pid)
                        -- On failure, skip sentence (don't show BT error)
                        engine:_startProcessWatcher(false, true)
                    end)
                else
                    -- Retry also crashed — skip this sentence so playback
                    -- can continue (next play will get a fresh socket).
                    logger.warn("TTSEngine: gst-launch retry also crashed ("
                        .. elapsed_ms .. "ms), skipping sentence")
                    engine._socket_clean = false
                    engine:onPlaybackComplete()
                end
            else
                -- Normal completion (process streamed successfully then exited)
                -- Detect rapid failure: if aplay exits in < 200ms and we have
                -- no real audio output (no soundcard), this is likely an instant
                -- failure.  Track consecutive rapid exits and bail out to prevent
                -- a runaway loop that freezes single-core devices.
                local RAPID_EXIT_MS = 200
                local is_kindle_dev = Device:isKindle()
                if elapsed_ms < RAPID_EXIT_MS and (engine._no_real_audio_output or is_kindle_dev) then
                    engine._rapid_fail_count = (engine._rapid_fail_count or 0) + 1
                    logger.warn("TTSEngine: rapid audio exit (" .. elapsed_ms
                        .. "ms), no soundcard — count:", engine._rapid_fail_count)
                    if engine._rapid_fail_count >= 3 then
                        logger.err("TTSEngine: 3 consecutive rapid audio failures — "
                            .. "no audio output available, stopping playback")
                        engine.is_speaking = false
                        engine.audio_pid = nil
                        engine.play_generation = (engine.play_generation or 0) + 1
                        engine:cleanup()
                        engine._rapid_fail_count = 0
                        local msg
                        if is_kindle_dev then
                            msg = _("No audio output available.\n\nKindle has no built-in speaker. Audio needs Bluetooth headphones connected via Kindle Settings.\n\nThe Kindle audio subsystem did not expose a usable ALSA device. Please generate a bug report (Audiobook > Report a bug) and share it on the GitHub issue -- it will help identify the correct audio path for this Kindle model.")
                        else
                            msg = _("No audio output available.\n\nThis device has no built-in speaker. Please connect a Bluetooth audio device first:\n\n1. Go to Audiobook > Bluetooth\n2. Turn Bluetooth on\n3. Scan and pair your headphones/speaker\n4. Then start read-along again.")
                        end
                        UIManager:show(InfoMessage:new{
                            text = msg,
                            timeout = 12,
                        })
                        if engine.on_fail_callback then
                            engine.on_fail_callback()
                        end
                        return
                    end
                else
                    -- Successful playback (or at least not instant failure)
                    engine._rapid_fail_count = 0
                end
                logger.warn("TTSEngine: Process watcher → normal completion, elapsed=", elapsed_ms, "ms")

                -- Capture wav-play / gst-play stderr for diagnostics
                if engine._gst_status_file then
                    local sf = io.open(engine._gst_status_file, "r")
                    if sf then
                        local stderr_out = sf:read("*a") or ""
                        sf:close()
                        if stderr_out ~= "" then
                            logger.warn("TTSEngine: player stderr:", stderr_out:sub(1, 500))
                        end
                    end
                end

                engine:onPlaybackComplete()
            end
        end
    end

    -- Short initial delay to let the process initialize
    UIManager:scheduleIn(0.15, checkProcess)
end

--[[--
Handle playback completion.
--]]
function TTSEngine:onPlaybackComplete()
    if not self.is_speaking then
        logger.warn("TTSEngine: onPlaybackComplete SKIPPED (not speaking, double-fire guard)")
        return
    end
    logger.warn("TTSEngine: onPlaybackComplete gen=", self.play_generation, "pid=", self.audio_pid)
    self.is_speaking = false
    -- Bump generation so stale watcher/timing loops exit
    self.play_generation = (self.play_generation or 0) + 1
    -- The process watcher confirmed the process exited naturally, so the BT
    -- abstract socket is already released.  No need to killall — that would
    -- just waste ~200ms spawning a shell on the ARM CPU.
    if self._persistent_pipeline then
        -- Pipeline keeps running (playing silence) — audio_pid stays set
        -- and socket stays held by the pipeline.  No keepalive needed.
    else
        self.audio_pid = nil
        self._socket_clean = true
    end
    self:cleanup()

    if self.on_complete_callback then
        self.on_complete_callback()
    end
end

--[[--
Pause playback.
--]]
function TTSEngine:pause()
    if self.is_speaking and not self.is_paused then
        self.is_paused = true
        self.pause_time = UIManager:getTime()
        -- Android: pause via MediaPlayer API
        if self.audio_player_type == "android" and self._android_tts then
            self._android_tts:pausePlayback()
        -- Kindle LIPC: pause via playermgr
        elseif self.audio_player_type == "kindle-lipc" then
            os.execute("lipc-set-prop com.lab126.playermgr Pause '' 2>/dev/null")
        -- Freeze the audio pipeline/process (SIGSTOP) so it can resume in place
        elseif self._persistent_pipeline then
            if self._pipeline_gst_pid then
                os.execute("kill -STOP " .. self._pipeline_gst_pid .. " 2>/dev/null")
            end
            if self._pipeline_wrapper_pid then
                os.execute("kill -STOP " .. self._pipeline_wrapper_pid .. " 2>/dev/null")
            end
        elseif self.audio_pid then
            os.execute("kill -STOP " .. self.audio_pid .. " 2>/dev/null")
        end
        logger.dbg("TTSEngine: Paused")
    end
end

--[[--
Resume playback.
--]]
function TTSEngine:resume()
    if self.is_speaking and self.is_paused then
        self.is_paused = false
        -- Adjust start time to account for the pause duration
        local pause_duration = UIManager:getTime() - self.pause_time
        local pause_ms = time.to_ms(pause_duration)
        self.playback_start_time = self.playback_start_time + pause_duration
        -- Accumulate total pause time so the completion timer knows how
        -- much real playback time has actually elapsed.
        self._total_pause_ms = (self._total_pause_ms or 0) + pause_ms
        -- Android: resume via MediaPlayer API
        if self.audio_player_type == "android" and self._android_tts then
            self._android_tts:resumePlayback()
        -- Kindle LIPC: resume via playermgr
        elseif self.audio_player_type == "kindle-lipc" then
            os.execute("lipc-set-prop com.lab126.playermgr Play '' 2>/dev/null")
        -- Unfreeze the audio pipeline/process (SIGCONT)
        elseif self._persistent_pipeline then
            if self._pipeline_gst_pid then
                os.execute("kill -CONT " .. self._pipeline_gst_pid .. " 2>/dev/null")
            end
            if self._pipeline_wrapper_pid then
                os.execute("kill -CONT " .. self._pipeline_wrapper_pid .. " 2>/dev/null")
            end
        elseif self.audio_pid then
            os.execute("kill -CONT " .. self.audio_pid .. " 2>/dev/null")
        end
        -- Restart the timing loop (it exited when is_paused was true)
        self:_runTimingLoop()
        logger.dbg("TTSEngine: Resumed, pause was", pause_ms, "ms, total_pause=", self._total_pause_ms, "ms")
    end
end

--[[--
Stop playback.
--]]
function TTSEngine:stop()
    -- Always bump generation and clear state, even if not speaking.
    -- This ensures stale scheduled callbacks (launchAndStart, checkProcess,
    -- updateTiming) exit immediately regardless of what state we were in.
    logger.dbg("TTSEngine: stop(), is_speaking=", self.is_speaking,
        "persistent=", self._persistent_pipeline)
    self.is_speaking = false
    self.is_paused = false
    self.play_generation = (self.play_generation or 0) + 1

    -- Cancel any pending launchAndStart so it can't fire after stop()
    if self._pending_launch_fn then
        UIManager:unschedule(self._pending_launch_fn)
        self._pending_launch_fn = nil
    end

    -- Cancel completion timer
    if self._completion_timer_fn then
        UIManager:unschedule(self._completion_timer_fn)
        self._completion_timer_fn = nil
    end

    -- Stop Android MediaPlayer if active
    if self.audio_player_type == "android" and self._android_tts then
        self._android_tts:stopPlayback()
    end

    -- Stop Kindle LIPC playermgr if active
    if self.audio_player_type == "kindle-lipc" then
        os.execute("lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null")
    end

    -- Stop kindle-gst-play process if active
    if self.audio_player_type == "kindle-gst-play" and self._gst_play_pid then
        os.execute("kill " .. self._gst_play_pid .. " 2>/dev/null")
        self._gst_play_pid = nil
    end

    -- Stop Kindle native TTS via FFI or shell
    if self.audio_player_type == "kindle-native-tts" then
        if self._lipc_handle and _lipc_lib then
            pcall(_lipc_lib.LipcSetStringProperty, self._lipc_handle,
                "com.lab126.playermgr", "Stop", "")
        end
        os.execute("lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null")
    end

    -- Stop persistent pipeline or legacy keepalive
    if self._persistent_pipeline then
        self:_stopPersistentPipeline("engine_stop")
    else
        self:_stopBtKeepalive()
    end
    
    -- Only clear _socket_clean if there was a live audio process to kill.
    -- If the process already exited naturally (onPlaybackComplete set
    -- _socket_clean=true), preserve that flag so the next play() can
    -- skip the 0.3s BT socket wait entirely.
    local had_process = self.audio_pid ~= nil
    self:_killAudioProcess()
    if had_process then
        self._socket_clean = false
    end
    
    -- Kill any background Piper synthesis processes immediately
    if self.backend == self.BACKENDS.PIPER then
        self._piper:killOrphanProcesses()
    end
    
    -- Clear concat/prefetch-in-use flag so fullCleanup can delete files
    self._prefetch_in_use = false
    self._concat_durations = nil
    self._audio_launched_at = nil
    self._gst_status_file = nil
    self:fullCleanup()
    logger.dbg("TTSEngine: Stopped, had_process=", had_process, "_socket_clean=", self._socket_clean)
end

--[[--
Check if GStreamer has reached the PLAYING state by reading its stderr
output.  Returns true once the pipeline is actually outputting audio.
@return boolean
--]]
function TTSEngine:isGstPlaying()
    -- Persistent pipeline is always in PLAYING state
    if self._persistent_pipeline then return true end
    if not self._gst_status_file then return false end
    local f = io.open(self._gst_status_file, "r")
    if not f then return false end
    local content = f:read("*a")
    f:close()
    return content and content:find("PLAYING") ~= nil
end

--[[--%
Unconditionally kill all gst-launch-1.0 processes and clean up.
Called on plugin teardown to prevent orphaned processes from holding
the BT A2DP socket when Nickel resumes after KOReader exits.
Uses SIGTERM (not SIGKILL) so GStreamer can close the BT audio sink
gracefully and not leave the BT firmware in a bad state.
--]]
function TTSEngine:forceKillAll()
    self._socket_clean = false
    -- Cancel any pending launchAndStart
    if self._pending_launch_fn then
        UIManager:unschedule(self._pending_launch_fn)
        self._pending_launch_fn = nil
    end
    -- Shut down Android TTS engine and MediaPlayer
    if self._android_tts then
        self._android_tts:shutdown()
        self._android_tts = nil
    end
    -- Stop Kindle LIPC playermgr
    if self.audio_player_type == "kindle-lipc" then
        os.execute("lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null")
    end
    -- Kill kindle-gst-play process
    if self._gst_play_pid then
        os.execute("kill " .. self._gst_play_pid .. " 2>/dev/null")
        self._gst_play_pid = nil
    end
    -- Close Kindle native TTS LIPC handle
    if self.audio_player_type == "kindle-native-tts" then
        os.execute("lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null")
        if self._lipc_handle and _lipc_lib then
            pcall(_lipc_lib.LipcClose, self._lipc_handle)
            self._lipc_handle = nil
        end
    end
    -- Stop persistent pipeline or legacy keepalive
    if self._persistent_pipeline then
        self:_stopPersistentPipeline("force_kill_all")
    else
        self:_stopBtKeepalive()
    end
    if self.audio_pid then
        os.execute("kill -9 " .. self.audio_pid .. " 2>/dev/null")
        self.audio_pid = nil
    end
    -- SIGKILL to guarantee hung gst-launch processes die (e.g. stuck in
    -- BT audio driver).  _stopPersistentPipeline already used SIGKILL for
    -- the pipeline; this catches any legacy-path or newly spawned strays.
    os.execute("killall -9 gst-launch-1.0 2>/dev/null")
    -- Full Piper shutdown: stop persistent servers AND kill per-process instances
    self._piper:shutdown()
    self:fullCleanup()
end

--[[--
Clean up temporary files.
--]]
function TTSEngine:cleanup()
    if self.current_audio_file then
        local f = io.open(self.current_audio_file, "r")
        if f then
            f:close()
            os.remove(self.current_audio_file)
        end
        self.current_audio_file = nil
    end
    -- Only clear audio_pid for the legacy (non-persistent) path.
    -- For the persistent pipeline, audio_pid points to the gst-launch
    -- process which keeps running between sentences.  Clearing it here
    -- breaks pause/resume and causes _isAudioProcessRunning to return
    -- false spuriously.
    if not self._persistent_pipeline then
        self.audio_pid = nil
    end
end

--[[--
Full stop cleanup: also discard any prefetched audio.
Called by stop() and forceKillAll().
--]]
function TTSEngine:fullCleanup()
    self:cleanup()
    self:_cleanPrefetch()
end

--[[--
Check if currently speaking.
@return boolean
--]]
function TTSEngine:isSpeaking()
    return self.is_speaking and not self.is_paused
end

--[[--
Check if paused.
@return boolean
--]]
function TTSEngine:isPaused()
    return self.is_speaking and self.is_paused
end

-- ── Piper TTS delegates (implementation in piperqueue.lua) ───────────

function TTSEngine:setPiperModel(model) self._piper:setModel(model) end
function TTSEngine:setPiperSpeaker(id)  self._piper:setSpeaker(id) end

--[[--
Switch the active TTS backend.
@param backend string One of TTSEngine.BACKENDS values
--]]
function TTSEngine:setBackend(backend)
    -- Validate
    local valid = false
    for _, v in pairs(self.BACKENDS) do
        if v == backend then valid = true; break end
    end
    if not valid then
        logger.warn("TTSEngine: Invalid backend:", backend)
        return
    end
    self.backend = backend
    logger.dbg("TTSEngine: Backend switched to", backend)
    -- Restore correct backend_cmd for the selected backend
    if backend == self.BACKENDS.PIPER then
        self.backend_cmd = self.piper_cmd or "piper"
    elseif backend == self.BACKENDS.ESPEAK then
        -- Restore bundled espeak-ng path if available
        local plugin_dir = self.plugin_dir or "/mnt/onboard/.adds/koreader/plugins/audiobook.koplugin"
        local bundled_bin = plugin_dir .. "/espeak-ng/bin/espeak-ng"
        local f = io.open(bundled_bin, "r")
        if f then
            f:close()
            self.backend_cmd = bundled_bin
        else
            self.backend_cmd = "espeak-ng"
        end
    end
end

function TTSEngine:getPiperSampleRate()  return self._piper:getSampleRate() end
function TTSEngine:listPiperVoices()     return self._piper:listVoices() end

-- Thin delegates — keep the public API surface unchanged for synccontroller
function TTSEngine:piperPrefetchAsync(text)     self._piper:enqueue(text) end
function TTSEngine:_launchNextPiperPrefetch()    self._piper:launchNext() end
function TTSEngine:consumePiperQueueEntry(text)  return self._piper:consume(text) end
function TTSEngine:getPiperPrefetchStatus(text)  return self._piper:getStatus(text) end

return TTSEngine
