--[[--
MediaEngine -- Audio file playback with seeking for pre-recorded audiobooks.
Supports mpv (JSON IPC), mplayer (slave mode), gst-play-1.0, and aplay fallbacks.
Designed to mirror the audio-playback subset of TTSEngine for easy integration.

@module koplugin.audiobook.mediaengine
--]]

local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local time = require("ui/time")
local _ = require("gettext")

local ffi = require("ffi")
pcall(function() ffi.cdef[[ int kill(int pid, int sig); ]] end)
pcall(function() ffi.cdef[[ int mkfifo(const char *pathname, unsigned int mode); ]] end)

local MediaEngine = {}

MediaEngine.BACKENDS = {
    MPV = "mpv",
    MPLAYER = "mplayer",
    GST_PLAY = "gst-play",
    GST_PIPELINE = "gst-pipeline",
    APLAY = "aplay",
    WAV_PLAY = "wav-play",
}

function MediaEngine:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o.backend = nil
    o.backend_cmd = nil
    o.audio_pid = nil
    o.play_generation = 0
    o.current_path = nil
    o.current_duration = nil
    o.is_playing = false
    o.is_paused = false
    o._socket_path = nil
    o._fifo_path = nil
    o._ipc_file = nil
    o._pending_callbacks = {}
    o._position_timer = nil
    o._on_complete = nil
    o._on_fail = nil
    o._seek_target = nil
    o._plugin_dir = o.plugin_dir or "."
    -- Elapsed-time tracking for backends without IPC (gst-play, aplay)
    o._play_start_time = nil
    o._pause_start_time = nil
    o._total_pause_ms = 0
    o._seek_offset = 0
    return o
end

-- ---------------------------------------------------------------------------
-- Utility
-- ---------------------------------------------------------------------------

function MediaEngine:commandExists(cmd)
    local handle = io.popen("command -v " .. cmd .. " 2>/dev/null")
    if not handle then return false end
    local result = handle:read("*l")
    handle:close()
    return result ~= nil and result ~= ""
end

function MediaEngine:_getTempDir()
    return os.getenv("TMPDIR") or "/tmp"
end

function MediaEngine:_nextGeneration()
    self.play_generation = self.play_generation + 1
    return self.play_generation
end

-- ---------------------------------------------------------------------------
-- Backend detection
-- ---------------------------------------------------------------------------

function MediaEngine:detectBackend()
    if self.backend then
        return self.backend, self.backend_cmd
    end

    -- 1) mpv -- best seeking, JSON IPC, handles all formats
    if self:commandExists("mpv") then
        self.backend = self.BACKENDS.MPV
        self.backend_cmd = "mpv"
        logger.warn("MediaEngine: selected mpv backend")
        return self.backend, self.backend_cmd
    end

    -- 2) mplayer -- slave mode, reasonable seeking
    if self:commandExists("mplayer") then
        self.backend = self.BACKENDS.MPLAYER
        self.backend_cmd = "mplayer"
        logger.warn("MediaEngine: selected mplayer backend")
        return self.backend, self.backend_cmd
    end

    -- 3) gst-play-1.0 -- preferred over gst-launch because playbin handles
    -- URI fragments (#t=) for time-offset seeking, which uridecodebin does not.
    if self:commandExists("gst-play-1.0") then
        self.backend = self.BACKENDS.GST_PLAY
        self.backend_cmd = "gst-play-1.0"
        logger.warn("MediaEngine: selected gst-play-1.0 backend")
        return self.backend, self.backend_cmd
    end

    -- 4) gst-launch-1.0 -- build custom pipeline (fallback)
    if self:commandExists("gst-launch-1.0") then
        self.backend = self.BACKENDS.GST_PIPELINE
        self.backend_cmd = "gst-launch-1.0"
        logger.warn("MediaEngine: selected gst-launch-1.0 backend")
        return self.backend, self.backend_cmd
    end

    -- 5) aplay -- WAV only, no seeking
    if self:commandExists("aplay") then
        self.backend = self.BACKENDS.APLAY
        self.backend_cmd = "aplay"
        logger.warn("MediaEngine: selected aplay backend (WAV only, no seek)")
        return self.backend, self.backend_cmd
    end

    -- 6) bundled wav-play -- WAV only, no seeking
    local wav_play = self._plugin_dir .. "/wav-play"
    local f = io.open(wav_play, "r")
    if f then
        f:close()
        self.backend = self.BACKENDS.WAV_PLAY
        self.backend_cmd = wav_play
        logger.warn("MediaEngine: selected bundled wav-play backend (WAV only, no seek)")
        return self.backend, self.backend_cmd
    end

    logger.err("MediaEngine: no audio backend found")
    return nil, nil
end

-- ---------------------------------------------------------------------------
-- Duration probing
-- ---------------------------------------------------------------------------

function MediaEngine:_findFfprobe()
    -- Check PATH first, then plugin bin/ directory
    local h = io.popen("command -v ffprobe 2>/dev/null")
    if h then
        local result = h:read("*l")
        h:close()
        if result and result ~= "" then return result end
    end
    if self._plugin_dir then
        local plugin_ffprobe = self._plugin_dir .. "/bin/ffprobe"
        local f = io.open(plugin_ffprobe, "r")
        if f then f:close() return plugin_ffprobe end
    end
    return nil
end

function MediaEngine:_probeDurationFfprobe(path)
    local ffprobe = self:_findFfprobe()
    if not ffprobe then return nil end

    local cmd = string.format(
        '"%s" -v error -show_entries format=duration -of csv=p=0 "%s" 2>/dev/null',
        ffprobe:gsub('"', '\\"'),
        path:gsub('"', '\\"')
    )
    local h = io.popen(cmd)
    if not h then return nil end
    local out = h:read("*a") or ""
    h:close()
    local secs = tonumber(out:match("^%s*([%d%.]+)"))
    if secs and secs > 0 then
        logger.dbg("MediaEngine: ffprobe duration =", secs)
        return secs
    end
    return nil
end

function MediaEngine:_probeDurationGstDiscoverer(path)
    local cmd = string.format(
        'gst-discoverer-1.0 "%s" 2>/dev/null | grep -i "^  Duration:"',
        path:gsub('"', '\\"')
    )
    local h = io.popen(cmd)
    if not h then return nil end
    local out = h:read("*a") or ""
    h:close()
    -- Parse "  Duration: 0:11:36.163265306"
    local hh, mm, ss = out:match("Duration:%s*(%d+):(%d+):([%d%.]+)")
    if hh and mm and ss then
        local secs = tonumber(hh) * 3600 + tonumber(mm) * 60 + tonumber(ss)
        if secs and secs > 0 then
            logger.dbg("MediaEngine: gst-discoverer duration =", secs)
            return secs
        end
    end
    return nil
end

function MediaEngine:_probeDurationMpv(path)
    -- Quick probe via mpv --no-video --frames=0
    local cmd = string.format(
        'mpv --no-video --frames=0 --really-quiet --term-playing-msg="${=duration}" "%s" 2>/dev/null',
        path:gsub('"', '\\"')
    )
    local h = io.popen(cmd)
    if not h then return nil end
    local out = h:read("*a") or ""
    h:close()
    local secs = tonumber(out:match("([%d%.]+)"))
    if secs and secs > 0 then
        logger.dbg("MediaEngine: mpv probe duration =", secs)
        return secs
    end
    return nil
end

function MediaEngine:_probeDurationWav(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    -- WAV header: byte 22-23 = channels, 24-27 = sample rate, 28-31 = byte rate,
    -- 40-43 = data chunk size
    f:seek("set", 22)
    local channels_data = f:read(2)
    local rate_data = f:read(4)
    f:seek("set", 40)
    local data_size_data = f:read(4)
    f:close()
    if not channels_data or not rate_data or not data_size_data then return nil end
    local channels = channels_data:byte(1) + channels_data:byte(2) * 256
    local rate = rate_data:byte(1) + rate_data:byte(2) * 256 +
                 rate_data:byte(3) * 65536 + rate_data:byte(4) * 16777216
    local data_size = data_size_data:byte(1) + data_size_data:byte(2) * 256 +
                      data_size_data:byte(3) * 65536 + data_size_data:byte(4) * 16777216
    if channels > 0 and rate > 0 and data_size > 0 then
        local secs = data_size / (rate * channels * 2)
        logger.dbg("MediaEngine: WAV header duration =", secs)
        return secs
    end
    return nil
end

function MediaEngine:probeDuration(path)
    local ext = path:match("%.([^.]+)$") or ""
    ext = ext:lower()

    -- ffprobe is most reliable for all formats
    local dur = self:_probeDurationFfprobe(path)
    if dur then return dur end

    -- gst-discoverer-1.0 fallback (Kobo, etc.)
    dur = self:_probeDurationGstDiscoverer(path)
    if dur then return dur end

    -- mpv can also probe
    if self.backend == self.BACKENDS.MPV then
        dur = self:_probeDurationMpv(path)
        if dur then return dur end
    end

    -- WAV fallback: parse header directly
    if ext == "wav" then
        dur = self:_probeDurationWav(path)
        if dur then return dur end
    end

    logger.warn("MediaEngine: could not probe duration for", path)
    return nil
end

-- ---------------------------------------------------------------------------
-- IPC helpers (mpv)
-- ---------------------------------------------------------------------------

function MediaEngine:_hasLuaSocket()
    local ok, socket = pcall(require, "socket")
    return ok and socket ~= nil
end

function MediaEngine:_mpvSendIpc(cmd_table, timeout_ms)
    timeout_ms = timeout_ms or 500
    if not self._socket_path then return nil end

    -- Try LuaSocket first
    if self:_hasLuaSocket() then
        local ok, socket = pcall(require, "socket")
        if ok then
            local unix = socket.unix and socket.unix()
            if unix then
                unix:settimeout(timeout_ms / 1000)
                local connected, err = unix:connect(self._socket_path)
                if connected then
                    local ok_json, json = pcall(require, "json")
                    if ok_json and json then
                        local payload = json.encode(cmd_table) .. "\n"
                        unix:send(payload)
                        local response = unix:receive("*l")
                        unix:close()
                        if response then
                            local ok2, decoded = pcall(json.decode, response)
                            if ok2 then return decoded end
                        end
                    end
                else
                    logger.dbg("MediaEngine: LuaSocket connect failed:", err)
                end
            end
        end
    end

    -- Fallback: write directly to Unix socket via FFI
    if ffi.C.open then
        local ok_json, json = pcall(require, "json")
        if ok_json and json then
            local O_WRONLY = 1
            local fd = ffi.C.open(self._socket_path, O_WRONLY)
            if fd >= 0 then
                local payload = json.encode(cmd_table) .. "\n"
                ffi.C.write(fd, payload, #payload)
                ffi.C.close(fd)
                -- For commands that don't need response, this is sufficient
                return {data = true}
            end
        end
    end

    return nil
end

function MediaEngine:_mpvSendFifo(command_str)
    if not self._fifo_path then return false end
    local f = io.open(self._fifo_path, "w")
    if f then
        f:write(command_str .. "\n")
        f:close()
        return true
    end
    return false
end

function MediaEngine:_setupMpvIpc()
    local tmpdir = self:_getTempDir()
    local gen = self.play_generation

    -- Try Unix socket first
    self._socket_path = string.format("%s/mpv-audiobook-%d.sock", tmpdir, gen)
    -- Remove stale socket
    os.remove(self._socket_path)

    -- Also prepare FIFO fallback
    self._fifo_path = string.format("%s/mpv-fifo-%d", tmpdir, gen)
    os.remove(self._fifo_path)
    if ffi.C.mkfifo then
        ffi.C.mkfifo(self._fifo_path, 384) -- 0600 octal = 384 decimal
    else
        os.execute("mkfifo '" .. self._fifo_path:gsub("'", "'\\''") .. "'")
    end
end

function MediaEngine:_cleanupIpc()
    if self._socket_path then
        os.remove(self._socket_path)
        self._socket_path = nil
    end
    if self._fifo_path then
        os.remove(self._fifo_path)
        self._fifo_path = nil
    end
    if self._ipc_file then
        os.remove(self._ipc_file)
        self._ipc_file = nil
    end
end

-- ---------------------------------------------------------------------------
-- Playback control
-- ---------------------------------------------------------------------------

function MediaEngine:load(path)
    if not path or path == "" then
        logger.err("MediaEngine: load() called with empty path")
        return false
    end

    self:detectBackend()
    if not self.backend then
        logger.err("MediaEngine: no backend available")
        return false
    end

    self.current_path = path
    self.current_duration = self:probeDuration(path)
    self.is_playing = false
    self.is_paused = false
    self._seek_offset = 0

    logger.warn("MediaEngine: loaded", path,
        "backend=", self.backend,
        "duration=", self.current_duration)
    return true
end

function MediaEngine:play(on_complete, on_fail)
    if not self.current_path then
        logger.err("MediaEngine: play() called without load()")
        if on_fail then on_fail("no file loaded") end
        return false
    end

    self:stop()
    local gen = self:_nextGeneration()
    self._on_complete = on_complete
    self._on_fail = on_fail
    self.is_playing = true
    self.is_paused = false
    -- Reset elapsed-time tracking
    self._play_start_time = UIManager:getTime()
    self._pause_start_time = nil
    self._total_pause_ms = 0

    if self.backend == self.BACKENDS.MPV then
        return self:_playMpv(gen)
    elseif self.backend == self.BACKENDS.MPLAYER then
        return self:_playMplayer(gen)
    elseif self.backend == self.BACKENDS.GST_PLAY then
        return self:_playGstPlay(gen)
    elseif self.backend == self.BACKENDS.GST_PIPELINE then
        return self:_playGstPipeline(gen)
    elseif self.backend == self.BACKENDS.APLAY or self.backend == self.BACKENDS.WAV_PLAY then
        return self:_playAplay(gen)
    end

    logger.err("MediaEngine: unknown backend", self.backend)
    if on_fail then on_fail("unknown backend") end
    return false
end

function MediaEngine:_playMpv(gen)
    self:_setupMpvIpc()

    local ipc_arg
    if self:_hasLuaSocket() then
        ipc_arg = string.format('--input-ipc-server="%s"', self._socket_path)
    else
        ipc_arg = string.format('--input-file="%s"', self._fifo_path)
    end

    local cmd = string.format(
        '%s %s --no-video --really-quiet --idle=no --keep-open=no "%s" &',
        self.backend_cmd,
        ipc_arg,
        self.current_path:gsub('"', '\\"')
    )

    logger.warn("MediaEngine: mpv launch gen=", gen, "cmd=", cmd:sub(1, 200))

    -- Spawn in background and capture PID
    local pid_file = self:_getTempDir() .. "/mpv-pid-" .. gen
    os.remove(pid_file)
    local wrapper = string.format("sh -c 'echo $$ > %s; exec %s' &", pid_file, cmd)
    os.execute(wrapper)

    -- Wait briefly for PID file
    UIManager:scheduleIn(0.2, function()
        if self.play_generation ~= gen then return end
        local pf = io.open(pid_file, "r")
        if pf then
            local pid_str = pf:read("*l")
            pf:close()
            self.audio_pid = tonumber(pid_str)
            logger.warn("MediaEngine: mpv PID =", self.audio_pid)
        end
        os.remove(pid_file)
        self:_startPositionPoller(gen)
        self:_startCompletionWatcher(gen)
    end)

    return true
end

function MediaEngine:_playMplayer(gen)
    self._ipc_file = self:_getTempDir() .. "/mplayer-fifo-" .. gen
    os.remove(self._ipc_file)
    os.execute("mkfifo '" .. self._ipc_file:gsub("'", "'\\''") .. "'")

    local cmd = string.format(
        '%s -slave -input file="%s" -really-quiet -novideo "%s" &',
        self.backend_cmd,
        self._ipc_file,
        self.current_path:gsub('"', '\\"')
    )

    logger.warn("MediaEngine: mplayer launch gen=", gen)
    os.execute(cmd)

    UIManager:scheduleIn(0.3, function()
        if self.play_generation ~= gen then return end
        self:_startPositionPoller(gen)
        self:_startCompletionWatcher(gen)
    end)

    return true
end

function MediaEngine:_playGstPlay(gen)
    -- gst-play-1.0 has limited seeking; we use it for playback and
    -- implement seek via process restart at new position.
    -- On Kobo with MTK Bluetooth, force the correct audio sink.
    local sink_arg = ""
    if Device:isKobo() and os.execute("gst-inspect-1.0 mtkbtmwrpcaudiosink >/dev/null 2>&1") == 0 then
        sink_arg = " --audiosink=mtkbtmwrpcaudiosink"
    end
    -- Best-effort time offset for seeking: append #t=<seconds> URI fragment
    local path = self.current_path:gsub('"', '\\"')
    if self._seek_offset and self._seek_offset > 0 then
        path = string.format("file://%s#t=%d", path, math.floor(self._seek_offset))
    end
    local cmd = string.format(
        '%s --quiet%s "%s"',
        self.backend_cmd,
        sink_arg,
        path
    )

    logger.warn("MediaEngine: gst-play launch gen=", gen,
        "seek_offset=", self._seek_offset or 0,
        "sink=", sink_arg ~= "" and "mtkbtmwrpcaudiosink" or "auto")

    -- Spawn in background and capture PID
    local pid_file = self:_getTempDir() .. "/gst-play-pid-" .. gen
    os.remove(pid_file)
    local wrapper = string.format("sh -c 'echo $$ > %s; exec %s' &", pid_file, cmd)
    os.execute(wrapper)

    UIManager:scheduleIn(0.3, function()
        if self.play_generation ~= gen then return end
        local pf = io.open(pid_file, "r")
        if pf then
            local pid_str = pf:read("*l")
            pf:close()
            self.audio_pid = tonumber(pid_str)
            logger.warn("MediaEngine: gst-play PID =", self.audio_pid)
        end
        os.remove(pid_file)
        self:_startPositionPoller(gen)
        self:_startCompletionWatcher(gen)
    end)

    return true
end

function MediaEngine:_playGstPipeline(gen)
    -- Build a decodebin pipeline for generic audio playback.
    -- Use uridecodebin when a time offset is set so GStreamer can
    -- attempt to start from that position via URI fragment (#t=).
    local sink = "autoaudiosink"
    if Device:isKobo() and os.execute("gst-inspect-1.0 mtkbtmwrpcaudiosink >/dev/null 2>&1") == 0 then
        sink = "mtkbtmwrpcaudiosink"
    end

    local cmd
    local path = self.current_path:gsub('"', '\\"')
    if self._seek_offset and self._seek_offset > 0 then
        -- uridecodebin supports #t= URI fragments for some formats
        local uri = string.format("file://%s#t=%d", path, math.floor(self._seek_offset))
        cmd = string.format(
            '%s uridecodebin uri="%s" ! audioconvert ! audioresample ! ' ..
            '"audio/x-raw,format=S16LE,rate=48000,channels=2" ! %s',
            self.backend_cmd,
            uri,
            sink
        )
    else
        cmd = string.format(
            '%s filesrc location="%s" ! decodebin ! audioconvert ! audioresample ! ' ..
            '"audio/x-raw,format=S16LE,rate=48000,channels=2" ! %s',
            self.backend_cmd,
            path,
            sink
        )
    end

    logger.warn("MediaEngine: gst-pipeline launch gen=", gen,
        "seek_offset=", self._seek_offset or 0)

    -- Spawn in background and capture PID
    local pid_file = self:_getTempDir() .. "/gst-pipe-pid-" .. gen
    os.remove(pid_file)
    local wrapper = string.format("sh -c 'echo $$ > %s; exec %s' &", pid_file, cmd)
    os.execute(wrapper)

    UIManager:scheduleIn(0.3, function()
        if self.play_generation ~= gen then return end
        local pf = io.open(pid_file, "r")
        if pf then
            local pid_str = pf:read("*l")
            pf:close()
            self.audio_pid = tonumber(pid_str)
            logger.warn("MediaEngine: gst-pipeline PID =", self.audio_pid)
        end
        os.remove(pid_file)
        self:_startPositionPoller(gen)
        self:_startCompletionWatcher(gen)
    end)

    return true
end

function MediaEngine:_playAplay(gen)
    local cmd = string.format(
        '%s "%s"',
        self.backend_cmd,
        self.current_path:gsub('"', '\\"')
    )

    logger.warn("MediaEngine: aplay/wav-play launch gen=", gen)

    -- Set aplay start time for elapsed-time tracking
    self._aplay_start_time = UIManager:getTime()

    -- Spawn in background and capture PID
    local pid_file = self:_getTempDir() .. "/aplay-pid-" .. gen
    os.remove(pid_file)
    local wrapper = string.format("sh -c 'echo $$ > %s; exec %s' &", pid_file, cmd)
    os.execute(wrapper)

    UIManager:scheduleIn(0.3, function()
        if self.play_generation ~= gen then return end
        local pf = io.open(pid_file, "r")
        if pf then
            local pid_str = pf:read("*l")
            pf:close()
            self.audio_pid = tonumber(pid_str)
            logger.warn("MediaEngine: aplay PID =", self.audio_pid)
        end
        os.remove(pid_file)
        self:_startPositionPoller(gen)
        self:_startCompletionWatcher(gen)
    end)

    return true
end

-- ---------------------------------------------------------------------------
-- Position polling
-- ---------------------------------------------------------------------------

function MediaEngine:_startPositionPoller(gen)
    if self._position_timer then
        UIManager:unschedule(self._position_timer)
        self._position_timer = nil
    end

    local function poll()
        if self.play_generation ~= gen or not self.is_playing then
            return
        end
        -- Poll at 1Hz for position updates (e-ink friendly rate)
        self._position_timer = UIManager:scheduleIn(1.0, poll)
    end

    self._position_timer = UIManager:scheduleIn(1.0, poll)
end

function MediaEngine:_startCompletionWatcher(gen)
    -- Watch for process exit via PID polling
    local function check()
        if self.play_generation ~= gen then return end
        if not self.is_playing then return end

        -- Check if process is still alive
        if self.audio_pid then
            local h = io.open("/proc/" .. self.audio_pid .. "/status", "r")
            if not h then
                -- Process exited
                self.is_playing = false
                self.is_paused = false
                self.audio_pid = nil
                if self._on_complete then
                    local cb = self._on_complete
                    self._on_complete = nil
                    cb()
                end
                return
            end
            h:close()
        end

        -- For backends without IPC, estimate completion from elapsed time
        if (self.backend == self.BACKENDS.APLAY or self.backend == self.BACKENDS.WAV_PLAY
            or self.backend == self.BACKENDS.GST_PLAY or self.backend == self.BACKENDS.GST_PIPELINE)
            and self._play_start_time and self.current_duration then
            local pos = self:getPosition()
            if pos >= self.current_duration then
                self.is_playing = false
                self.is_paused = false
                if self._on_complete then
                    local cb = self._on_complete
                    self._on_complete = nil
                    cb()
                end
                return
            end
        end

        UIManager:scheduleIn(0.5, check)
    end

    UIManager:scheduleIn(1.0, check)
end

-- ---------------------------------------------------------------------------
-- Pause / Resume / Stop
-- ---------------------------------------------------------------------------

function MediaEngine:pause()
    if not self.is_playing or self.is_paused then return end
    self.is_paused = true
    self._pause_start_time = UIManager:getTime()

    if self.backend == self.BACKENDS.MPV then
        if self:_hasLuaSocket() and self._socket_path then
            self:_mpvSendIpc({command = {"set_property", "pause", true}})
        elseif self._fifo_path then
            self:_mpvSendFifo("set pause yes")
        end
    elseif self.backend == self.BACKENDS.MPLAYER then
        if self._ipc_file then
            local f = io.open(self._ipc_file, "w")
            if f then
                f:write("pause\n")
                f:close()
            end
        end
    elseif self.audio_pid and ffi.C.kill then
        ffi.C.kill(self.audio_pid, 19) -- SIGSTOP
    end
end

function MediaEngine:resume()
    if not self.is_playing or not self.is_paused then return end
    self.is_paused = false
    if self._pause_start_time then
        self._total_pause_ms = self._total_pause_ms + time.to_ms(UIManager:getTime() - self._pause_start_time)
        self._pause_start_time = nil
    end

    if self.backend == self.BACKENDS.MPV then
        if self:_hasLuaSocket() and self._socket_path then
            self:_mpvSendIpc({command = {"set_property", "pause", false}})
        elseif self._fifo_path then
            self:_mpvSendFifo("set pause no")
        end
    elseif self.backend == self.BACKENDS.MPLAYER then
        if self._ipc_file then
            local f = io.open(self._ipc_file, "w")
            if f then
                f:write("pause\n")
                f:close()
            end
        end
    elseif self.backend == self.BACKENDS.GST_PLAY
        or self.backend == self.BACKENDS.GST_PIPELINE then
        -- After a paused seek the GST process was killed; restart it.
        if self.audio_pid and ffi.C.kill then
            ffi.C.kill(self.audio_pid, 18) -- SIGCONT
        else
            self:play(self._on_complete, self._on_fail)
        end
    elseif self.audio_pid and ffi.C.kill then
        ffi.C.kill(self.audio_pid, 18) -- SIGCONT
    end
end

function MediaEngine:stop()
    self:_nextGeneration()
    self.is_playing = false
    self.is_paused = false

    if self._position_timer then
        UIManager:unschedule(self._position_timer)
        self._position_timer = nil
    end

    -- Kill audio process
    local dying_pid = self.audio_pid
    if dying_pid then
        if ffi.C.kill then
            ffi.C.kill(dying_pid, 15) -- SIGTERM
            UIManager:scheduleIn(0.3, function()
                local h = io.open("/proc/" .. dying_pid .. "/status", "r")
                if h then
                    h:close()
                    ffi.C.kill(dying_pid, 9) -- SIGKILL
                end
            end)
        end
        self.audio_pid = nil
    end

    -- For mplayer, also send quit command
    if self.backend == self.BACKENDS.MPLAYER and self._ipc_file then
        local f = io.open(self._ipc_file, "w")
        if f then
            f:write("quit\n")
            f:close()
        end
    end

    -- For mpv, send quit via IPC
    if self.backend == self.BACKENDS.MPV then
        if self:_hasLuaSocket() and self._socket_path then
            pcall(function()
                self:_mpvSendIpc({command = {"quit"}})
            end)
        elseif self._fifo_path then
            self:_mpvSendFifo("quit")
        end
    end

    self:_cleanupIpc()
    self._on_complete = nil
    self._on_fail = nil
    self._play_start_time = nil
    self._aplay_start_time = nil
    self._pause_start_time = nil
    self._total_pause_ms = 0
    -- NOTE: do NOT reset _seek_offset here.
    -- GST backends use seek-by-restart: seek() sets _seek_offset, calls stop(),
    -- then schedules play().  If we zero it here, the restart loses its target.
    -- _seek_offset is reset in load() when a new file is loaded.
end

-- ---------------------------------------------------------------------------
-- Seeking
-- ---------------------------------------------------------------------------

function MediaEngine:seek(seconds, mode)
    mode = mode or "absolute"

    -- Non-seekable backends
    if self.backend == self.BACKENDS.APLAY or self.backend == self.BACKENDS.WAV_PLAY then
        logger.warn("MediaEngine: seek not supported on", self.backend)
        return false
    end

    -- Remember whether we were actually playing (not paused) so we can stay
    -- paused after a seek.  is_playing stays true when paused; is_paused is
    -- the real indicator.
    local was_playing = self.is_playing and not self.is_paused

    if self.backend == self.BACKENDS.MPV then
        local mode_str = mode == "relative" and "relative" or "absolute"
        if self:_hasLuaSocket() and self._socket_path then
            self:_mpvSendIpc({command = {"seek", seconds, mode_str}})
            return true
        elseif self._fifo_path then
            local cmd = string.format("seek %f %s", seconds, mode_str)
            return self:_mpvSendFifo(cmd)
        end
    elseif self.backend == self.BACKENDS.MPLAYER then
        local cmd
        if mode == "relative" then
            cmd = string.format("seek %f 0", seconds) -- 0 = relative seconds
        else
            cmd = string.format("seek %f 2", seconds) -- 2 = absolute seconds
        end
        if self._ipc_file then
            local f = io.open(self._ipc_file, "w")
            if f then
                f:write(cmd .. "\n")
                f:close()
                return true
            end
        end
    elseif self.backend == self.BACKENDS.GST_PLAY
        or self.backend == self.BACKENDS.GST_PIPELINE then
        -- Seek via process restart with time offset.
        -- For relative seeks, compute target from current position.
        local target = seconds
        if mode == "relative" then
            target = self:getPosition() + seconds
        end
        target = math.max(0, target)
        logger.warn("MediaEngine: GST seek mode=", mode, "req=", seconds,
            "current=", self:getPosition(), "target=", target,
            "was_playing=", was_playing)
        -- Preserve callbacks before stop() nils them.
        local saved_on_complete = self._on_complete
        local saved_on_fail = self._on_fail
        self._seek_offset = target
        self._play_start_time = UIManager:getTime()
        self._total_pause_ms = 0
        self._pause_start_time = nil
        self:stop()
        -- Only restart playback if we were actually playing before the seek.
        -- When paused, restore the paused state so resume() can restart us.
        if was_playing then
            UIManager:scheduleIn(0.5, function()
                self:play(saved_on_complete, saved_on_fail)
            end)
        else
            self.is_playing = true
            self.is_paused = true
            self._on_complete = saved_on_complete
            self._on_fail = saved_on_fail
            self._play_start_time = UIManager:getTime()
            self._pause_start_time = UIManager:getTime()
        end
        return true
    end

    return false
end

-- ---------------------------------------------------------------------------
-- Position / Duration queries
-- ---------------------------------------------------------------------------

function MediaEngine:getPosition()
    -- During a seek gap (after stop, before play restarts), return the seek
    -- offset so the UI doesn't flicker back to zero.
    if not self.is_playing then
        if self._seek_offset and self._seek_offset > 0 then
            return self._seek_offset
        end
        return 0
    end

    -- For backends without IPC (gst-play, aplay), estimate from elapsed time
    if self._play_start_time then
        local ok, elapsed_ms = pcall(function()
            if self.is_paused and self._pause_start_time then
                return time.to_ms(self._pause_start_time - self._play_start_time) - self._total_pause_ms
            else
                return time.to_ms(UIManager:getTime() - self._play_start_time) - self._total_pause_ms
            end
        end)
        if ok and elapsed_ms then
            local pos = math.max(0, elapsed_ms / 1000) + (self._seek_offset or 0)
            pos = math.min(pos, self.current_duration or pos)
            logger.dbg("MediaEngine: getPosition elapsed=", elapsed_ms, "offset=", self._seek_offset, "pos=", pos)
            return pos
        else
            logger.warn("MediaEngine: getPosition elapsed-time failed, ok=", ok, "err=", elapsed_ms)
        end
        -- Fall through to other methods if elapsed-time fails
    end

    -- For aplay legacy fallback
    if (self.backend == self.BACKENDS.APLAY or self.backend == self.BACKENDS.WAV_PLAY)
        and self._aplay_start_time then
        local ok, elapsed = pcall(function()
            return time.to_ms(UIManager:getTime() - self._aplay_start_time) / 1000
        end)
        if ok and elapsed then
            return math.min(elapsed, self.current_duration or elapsed)
        end
    end

    -- Try mpv IPC for accurate position
    if self.backend == self.BACKENDS.MPV and self:_hasLuaSocket() and self._socket_path then
        local resp = self:_mpvSendIpc({command = {"get_property", "time-pos"}}, 300)
        if resp and resp.data then
            local pos = tonumber(resp.data)
            if pos then return pos end
        end
    end

    -- Try mplayer slave mode
    if self.backend == self.BACKENDS.MPLAYER and self._ipc_file then
        local f = io.open(self._ipc_file, "w")
        if f then
            f:write("get_time_pos\n")
            f:close()
        end
        -- Response comes asynchronously; we'd need a reader thread.
        -- For now, return estimated position.
    end

    return 0
end

function MediaEngine:getDuration()
    return self.current_duration or 0
end

function MediaEngine:isPlaying()
    return self.is_playing
end

function MediaEngine:isPaused()
    return self.is_paused
end

-- ---------------------------------------------------------------------------
-- Playback speed (mpv / mplayer only)
-- ---------------------------------------------------------------------------

function MediaEngine:setSpeed(speed)
    speed = tonumber(speed) or 1.0
    if speed < 0.5 then speed = 0.5 end
    if speed > 3.0 then speed = 3.0 end
    self._playback_speed = speed

    if not self.is_playing then return end

    if self.backend == self.BACKENDS.MPV then
        if self:_hasLuaSocket() and self._socket_path then
            self:_mpvSendIpc({command = {"set_property", "speed", speed}})
        elseif self._fifo_path then
            self:_mpvSendFifo(string.format("set speed %f", speed))
        end
    elseif self.backend == self.BACKENDS.MPLAYER then
        if self._ipc_file then
            local f = io.open(self._ipc_file, "w")
            if f then
                f:write(string.format("speed_set %f\n", speed))
                f:close()
            end
        end
    end
    -- gst-play / gst-pipeline / aplay do not support speed control
end

function MediaEngine:getSpeed()
    return self._playback_speed or 1.0
end

-- ---------------------------------------------------------------------------
-- Chapter support (via m4bparser integration)
-- ---------------------------------------------------------------------------

function MediaEngine:setChapters(chapters)
    -- chapters: array of {title, start_time, end_time}
    self._chapters = chapters
end

function MediaEngine:getChapters()
    return self._chapters or {}
end

function MediaEngine:seekToChapter(index)
    local chapters = self._chapters
    if not chapters or not chapters[index] then return false end
    return self:seek(chapters[index].start_time, "absolute")
end

return MediaEngine
