--[[--
Bug Report Generator
Collects device and plugin diagnostics for troubleshooting.
Privacy-conscious: no book content, highlights, or personal file paths.

@module bugreport
--]]

local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local _utils_dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
local Utils = dofile(_utils_dir .. "utils.lua")

local BugReport = {}

--- Sanitize a path: strip user-identifiable directory components.
-- Replaces /home/<user>/ and /sdcard/ account dirs with generic placeholders.
local function sanitizePath(path)
    if not path then return "nil" end
    path = path:gsub("/home/[^/]+/", "/home/<user>/")
    path = path:gsub("/Users/[^/]+/", "/Users/<user>/")
    path = path:gsub("/storage/emulated/%d+/", "/sdcard/")
    return path
end

--- Run a shell command and return trimmed stdout (max 500 chars).
local function shellCapture(cmd, timeout_s)
    local full_cmd = cmd .. " 2>/dev/null"
    if timeout_s then
        -- timeout(1) may or may not exist; harmless if missing
        full_cmd = "timeout " .. timeout_s .. " " .. full_cmd
    end
    local handle = io.popen(full_cmd)
    if not handle then return nil end
    local output = handle:read("*a") or ""
    handle:close()
    output = output:gsub("^%s+", ""):gsub("%s+$", "")
    if #output > 1500 then
        output = output:sub(1, 1500) .. "…(truncated)"
    end
    return output ~= "" and output or nil
end

--- Check if a file/dir exists.
-- Uses io.open with a shell fallback for devices where io.open may fail
-- on binary files (observed on some Kindle models).
local function fileExists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    local rc = os.execute("test -f '" .. path .. "' 2>/dev/null")
    if rc == 0 or rc == true then return true end
    return false
end

--- Collect device and OS information.
local function collectDeviceInfo()
    local info = {}
    info.platform = Device.getPlatform and Device:getPlatform() or "unknown"
    info.model = Device.getDeviceModel and Device:getDeviceModel() or "unknown"
    info.is_android = Device:isAndroid() or false
    info.is_kindle = Device.isKindle and Device:isKindle() or false
    info.is_kobo = Device.isKobo and Device:isKobo() or false
    info.is_pocketbook = Device.isPocketBook and Device:isPocketBook() or false
    info.has_eink = Device.hasEinkScreen and Device:hasEinkScreen() or false

    -- Screen dimensions
    local screen = Device.screen
    if screen then
        info.screen_width = screen.getWidth and screen:getWidth() or "?"
        info.screen_height = screen.getHeight and screen:getHeight() or "?"
        info.screen_dpi = screen.getDPI and screen:getDPI() or "?"
    end

    -- Kernel / uname
    info.uname = shellCapture("uname -a", 3)

    -- Architecture
    info.arch = shellCapture("uname -m", 2)

    -- Android-specific
    if info.is_android then
        info.android_version = shellCapture("getprop ro.build.version.release", 2)
        info.android_sdk = shellCapture("getprop ro.build.version.sdk", 2)
        info.android_device = shellCapture("getprop ro.product.model", 2)
        info.android_brand = shellCapture("getprop ro.product.brand", 2)
    end

    return info
end

--- Collect KOReader version info.
local function collectKoreaderInfo()
    local info = {}

    -- KOReader version
    local ok, Version = pcall(require, "version")
    if ok and Version then
        info.koreader_version = Version.getCurrentRevision and Version:getCurrentRevision() or "unknown"
    else
        -- Fallback: try reading git_rev file
        local rev_file = io.open("git-rev", "r")
        if rev_file then
            info.koreader_version = rev_file:read("*l") or "unknown"
            rev_file:close()
        else
            info.koreader_version = "unknown"
        end
    end

    return info
end

--- Collect plugin-specific diagnostics.
local function collectPluginInfo(plugin)
    local info = {}
    local engine = plugin and plugin.tts_engine

    -- Plugin meta
    local ok, meta = pcall(dofile, _utils_dir .. "_meta.lua")
    if ok and meta then
        info.plugin_name = meta.name or "audiobook"
        info.plugin_fullname = meta.fullname or "?"
        info.plugin_version = meta.version or "unknown"
    end

    info.plugin_dir = sanitizePath(_utils_dir)
    info.cwd = shellCapture("pwd", 2)

    if not engine then
        info.tts_backend = "engine not initialized"
        return info
    end

    -- TTS state
    info.tts_backend = engine.backend or "nil (none detected)"
    info.tts_backend_cmd = engine.backend_cmd and sanitizePath(engine.backend_cmd) or "nil"
    info.tts_backend_error = engine.backend_error or "none"
    info.player_error = engine.player_error and "yes" or "no"
    info.audio_player_type = engine.audio_player_type or "not set"
    info.audio_player_cached = engine._cached_player or "not set"
    info.no_real_audio_output = engine._no_real_audio_output and "yes" or "no"

    -- Bundled binaries presence (check both original and .bin-renamed variants)
    local plugin_dir = engine.plugin_dir or _utils_dir:sub(1, -2)
    local espeak_path = plugin_dir .. "/espeak-ng/bin/espeak-ng"
    local piper_path = plugin_dir .. "/piper/piper"
    info.has_bundled_espeak = fileExists(espeak_path) or fileExists(espeak_path .. ".bin")
    info.has_bundled_piper = fileExists(piper_path) or fileExists(piper_path .. ".bin")
    -- Show what's on disk in the binary directories
    info.espeak_bin_ls = shellCapture("ls -la '" .. plugin_dir .. "/espeak-ng/bin/' 2>/dev/null", 3)
    info.piper_bin_ls = shellCapture("ls -la '" .. plugin_dir .. "/piper/' 2>/dev/null | head -10", 3)
    info.has_piper_model = false
    local piper_dir = plugin_dir .. "/piper"
    local piper_ls = shellCapture("ls " .. piper_dir .. "/*.onnx 2>/dev/null", 3)
    if piper_ls then
        info.has_piper_model = true
        -- Just show filenames, not full paths
        info.piper_models = piper_ls:gsub(piper_dir .. "/", "")
    end

    -- Current settings (non-private subset)
    if plugin.getSetting then
        info.settings = {
            tts_backend = plugin:getSetting("tts_backend", "auto"),
            speech_rate = plugin:getSetting("speech_rate", 1.0),
            speech_pitch = plugin:getSetting("speech_pitch", 50),
            speech_volume = plugin:getSetting("speech_volume", 1.0),
            highlight_style = plugin:getSetting("highlight_style", "background"),
            auto_advance = plugin:getSetting("auto_advance", true),
            highlight_words = plugin:getSetting("highlight_words", true),
            highlight_sentences = plugin:getSetting("highlight_sentences", true),
            espeak_cold_start = plugin:getSetting("espeak_cold_start", true),
            keep_playing_on_lid_close = plugin:getSetting("keep_playing_on_lid_close", false),
            bt_media_control = plugin:getSetting("bt_media_control", true),
            piper_model = plugin:getSetting("piper_model", nil) and
                sanitizePath(plugin:getSetting("piper_model", "")) or "none",
        }
    end

    return info
end

--- Collect system audio and TTS tool availability.
local function collectAudioInfo(plugin)
    local info = {}

    -- TTS command availability
    local tts_cmds = {"espeak-ng", "espeak", "piper", "pico2wave", "flite", "festival"}
    info.tts_in_path = {}
    for _, cmd in ipairs(tts_cmds) do
        if Utils.commandExists(cmd) then
            info.tts_in_path[cmd] = shellCapture("which " .. cmd, 2) or "found"
        end
    end

    -- Audio player availability
    local player_cmds = {"aplay", "paplay", "mpv", "mplayer", "play", "gst-launch-1.0", "gst-inspect-1.0"}
    info.players_in_path = {}
    for _, cmd in ipairs(player_cmds) do
        if Utils.commandExists(cmd) then
            info.players_in_path[cmd] = true
        end
    end

    -- ALSA soundcards
    local cards = io.open("/proc/asound/cards", "r")
    if cards then
        info.alsa_cards = cards:read("*a") or "empty"
        cards:close()
        info.alsa_cards = info.alsa_cards:gsub("^%s+", ""):gsub("%s+$", "")
        if info.alsa_cards == "" then info.alsa_cards = "none" end
    else
        info.alsa_cards = "not available (/proc/asound/cards missing)"
    end

    -- ALSA PCM devices (may reveal BT sinks not in /proc/asound/cards)
    if Utils.commandExists("aplay") then
        info.alsa_pcm_devices = shellCapture("aplay -L 2>/dev/null | head -20", 3) or "none"
    end

    -- Bluetooth
    info.bt_available = Utils.commandExists("bluetoothctl") or
                        Utils.commandExists("hcitool") or
                        fileExists("/sys/class/bluetooth") or false

    -- BT adapter present?
    info.bt_hci_devices = shellCapture("ls -1 /sys/class/bluetooth/ 2>/dev/null", 2) or "none"

    -- Paired / connected BT devices (bluetoothctl)
    -- Older BlueZ (< 5.65) doesn't support "devices Paired" subcommand
    -- and outputs "Too many arguments" to stdout.
    if Utils.commandExists("bluetoothctl") then
        local paired = shellCapture("bluetoothctl paired-devices 2>/dev/null", 3)
            or shellCapture("bluetoothctl devices Paired 2>/dev/null", 3)
        if not paired or paired:match("[Tt]oo many") or paired:match("[Ii]nvalid") then
            paired = shellCapture("bluetoothctl devices 2>/dev/null | head -10", 3)
        end
        info.bt_paired_devices = paired or "none"

        local connected = shellCapture("bluetoothctl info 2>/dev/null | grep -E 'Device|Name|Connected|Paired'", 3)
        info.bt_connected_devices = connected or "none"

        -- Adapter state: powered/pairable/discoverable
        info.bt_adapter_info = shellCapture("bluetoothctl show 2>/dev/null | grep -E 'Powered|Pairable|Discoverable|Controller'", 3) or "unavailable"
    end

    -- Shell printf portability (Kobo busybox ash needs printf, not echo -e)
    info.bt_printf_test = shellCapture("printf 'line1\\nline2\\n' 2>/dev/null | wc -l", 2) or "unknown"

    -- Busybox sleep fractional support
    info.bt_sleep_test = shellCapture("sleep 0.1 2>&1 && echo 'ok' || echo 'unsupported'", 2) or "unknown"

    -- hcitool fallback (older Kobo firmware)
    if Utils.commandExists("hcitool") then
        info.bt_hcitool_con = shellCapture("hcitool con 2>/dev/null", 3) or "none"
    end

    -- Kobo BT daemon
    info.bt_daemon_running = shellCapture("pidof mtkbtmwrpc 2>/dev/null || pidof bluetoothd 2>/dev/null", 2) or "not running"

    -- bluetoothd binary location (key for Kobo pairing)
    local daemon_paths = {
        "/libexec/bluetooth/bluetoothd",
        "/usr/libexec/bluetooth/bluetoothd",
        "/usr/lib/bluetooth/bluetoothd",
    }
    info.bt_daemon_path = "not found"
    for _, p in ipairs(daemon_paths) do
        if fileExists(p) then
            info.bt_daemon_path = p
            break
        end
    end
    if info.bt_daemon_path == "not found" then
        local which_bt = shellCapture("which bluetoothd 2>/dev/null", 2)
        if which_bt then info.bt_daemon_path = which_bt .. " (via PATH)" end
    end

    -- Detected BT stack (MTK vs BlueZ)
    if plugin and plugin.bt_manager and plugin.bt_manager.getStackType then
        info.bt_stack = plugin.bt_manager:getStackType()
        info.bt_gst_sink = plugin.bt_manager:getGstBtSink() or "none (aplay fallback)"
        -- BlueALSA diagnostics
        info.bluealsa_bundled = plugin.bt_manager:hasBluealsaBundled() and "yes" or "no"
        info.bluealsa_running = plugin.bt_manager:isBluealsaRunning() and "yes" or "no"
    end

    -- GStreamer BT sink
    if Utils.commandExists("gst-inspect-1.0") then
        local bt_sink = shellCapture("gst-inspect-1.0 mtkbtmwrpcaudiosink 2>/dev/null | head -5", 3)
        info.gst_bt_sink_mtk = bt_sink or "not found"
        -- List all available audio sinks
        info.gst_audio_sinks = shellCapture("gst-inspect-1.0 --list-elements 2>/dev/null | grep -i 'sink\\|audio' || gst-inspect-1.0 2>/dev/null | grep -i 'sink\\|audio'", 3) or "none found"
    end

    -- Kobo BT socket (abstract socket used by mtkbtmwrpc)
    info.bt_abstract_socket = shellCapture("cat /proc/net/unix 2>/dev/null | grep -i 'kobo\\|mtk\\|bluetooth' | head -5", 2) or "none"

    -- Kindle BT diagnostics via lipc
    if Device.isKindle and Device:isKindle() then
        info.kindle_lipc_available = Utils.commandExists("lipc-get-prop") and "yes" or "no"
        if Utils.commandExists("lipc-get-prop") then
            -- Probe service+property combinations (varies by Kindle generation)
            local services = {
                "com.lab126.btfd",
                "com.lab126.btService",
                "com.lab126.cmd",
                "com.lab126.acsbt",
            }
            local properties = { "btEnabled", "btPowerState", "BTstate" }
            for _, svc in ipairs(services) do
                for _, prop in ipairs(properties) do
                    local val = shellCapture("lipc-get-prop " .. svc .. " " .. prop .. " 2>/dev/null", 2)
                    if val and val ~= "" then
                        info.kindle_bt_service = svc
                        info.kindle_bt_prop = prop
                        info.kindle_bt_enabled = val
                        info.kindle_bt_paired = shellCapture("lipc-get-prop " .. svc .. " btPairedDevicesList 2>/dev/null", 2) or "n/a"
                        info.kindle_bt_connected = shellCapture("lipc-get-prop " .. svc .. " btConnectedDevices 2>/dev/null", 2) or "n/a"
                        info.kindle_bt_connected_name = shellCapture("lipc-get-prop " .. svc .. " BTconnectedDevName 2>/dev/null", 2) or "n/a"
                        break
                    end
                end
                if info.kindle_bt_service then break end
            end
            if not info.kindle_bt_service then
                info.kindle_bt_service = "none responded"
                -- List available lipc services for debugging
                info.kindle_lipc_services = shellCapture("lipc-probe -l 2>/dev/null | grep -i 'bt\\|blue' | head -5", 2) or "none"
                -- List available properties for each BT service
                local props_dump = {}
                for _, svc in ipairs(services) do
                    local props = shellCapture("lipc-probe " .. svc .. " 2>/dev/null | head -20", 3)
                    if props and props ~= "" then
                        table.insert(props_dump, svc .. ": " .. props)
                    end
                end
                if #props_dump > 0 then
                    info.kindle_bt_props = table.concat(props_dump, "\n")
                end
            end
        end

        -- Kindle audio subsystem probing.
        -- Kindle Basic 2022 (and similar speakerless models) has no
        -- standard ALSA card.  These fields help identify what audio
        -- path Amazon exposes when BT headphones are connected.
        info.kindle_dev_snd = shellCapture("ls -la /dev/snd/ 2>/dev/null", 3) or "not found"
        info.kindle_aplay_l = shellCapture("aplay -l 2>&1 | head -15", 3) or "n/a"
        info.kindle_aplay_L = shellCapture("aplay -L 2>&1 | head -20", 3) or "n/a"
        info.kindle_proc_asound_pcm = shellCapture("cat /proc/asound/pcm 2>/dev/null", 3) or "not found"
        info.kindle_audio_procs = shellCapture(
            "ps 2>/dev/null | grep -iE 'audio|alsa|pulse|btfd|a2dp|bluez|sound' | grep -v grep | head -10", 3
        ) or "none"
        info.kindle_pulseaudio = shellCapture("pactl info 2>/dev/null | head -10", 3) or "not available"
        info.kindle_pa_sinks = shellCapture("pactl list sinks short 2>/dev/null", 3) or "none"
        -- lipc audio/sound services
        info.kindle_lipc_audio = shellCapture("lipc-probe com.lab126.audio 2>/dev/null | head -20", 3) or "not found"
        info.kindle_lipc_audio_svcs = shellCapture(
            "lipc-probe -l 2>/dev/null | grep -iE 'audio|sound|media|player' | head -5", 3
        ) or "none"
        -- Audio-related binaries
        local audio_bins = {}
        for _, b in ipairs({"aplay", "paplay", "mpv", "mplayer", "play", "madplay", "mpg123", "ffplay", "sox"}) do
            local loc = shellCapture("which " .. b .. " 2>/dev/null", 2)
            if loc then audio_bins[b] = loc end
        end
        info.kindle_audio_bins = audio_bins
        -- Kernel sound modules
        info.kindle_snd_modules = shellCapture("lsmod 2>/dev/null | grep -i snd | head -10", 3) or "n/a"
        -- ALSA config files
        info.kindle_asound_conf = shellCapture("cat /etc/asound.conf 2>/dev/null | head -10", 3) or "not found"

        -- btfd A2DP reverse-engineering: understand how Amazon routes
        -- BT audio so we can inject PCM data into the same path.
        local btfd_pid = shellCapture("pidof btfd 2>/dev/null", 2)
        info.kindle_btfd_pid = btfd_pid or "not running"
        if btfd_pid and btfd_pid:match("%d") then
            local pid = btfd_pid:match("(%d+)")
            info.kindle_btfd_cmdline = shellCapture("cat /proc/" .. pid .. "/cmdline 2>/dev/null | tr '\\0' ' '", 2) or "n/a"
            info.kindle_btfd_fds = shellCapture("ls -la /proc/" .. pid .. "/fd/ 2>/dev/null | head -30", 3) or "n/a"
            info.kindle_btfd_sockets = shellCapture("cat /proc/" .. pid .. "/net/unix 2>/dev/null | head -20", 3) or "n/a"
            info.kindle_btfd_maps = shellCapture("cat /proc/" .. pid .. "/maps 2>/dev/null | grep -iE 'audio|alsa|pulse|blue|a2dp|sbc|socket|pipe' | head -20", 3) or "n/a"
        end
        -- BT HCI interface: is BlueZ's /dev/hci0 or /sys/class/bluetooth present?
        info.kindle_hci_devs = shellCapture("ls -la /dev/hci* 2>/dev/null", 2) or "none"
        info.kindle_sys_bt = shellCapture("ls -la /sys/class/bluetooth/ 2>/dev/null", 2) or "none"
        info.kindle_hciconfig = shellCapture("hciconfig -a 2>/dev/null | head -20", 3) or "not available"
        -- D-Bus: does it exist? Is BlueZ registered?
        info.kindle_dbus_running = shellCapture("pidof dbus-daemon 2>/dev/null", 2) or "not running"
        info.kindle_dbus_bluez = shellCapture("dbus-send --system --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.ListNames 2>/dev/null | grep -i blue | head -5", 3) or "no bluez on dbus"
        -- Unix/network sockets that mention bt/audio/a2dp
        info.kindle_bt_sockets = shellCapture("cat /proc/net/unix 2>/dev/null | grep -iE 'bt|audio|a2dp|blue|sbc' | head -15", 3) or "none"
        -- LIPC: what happens when Amazon plays audio internally?
        info.kindle_lipc_tts_props = shellCapture("lipc-probe com.lab126.kaf.TTSService 2>/dev/null | head -15", 3) or "not found"
        info.kindle_lipc_audio_player = shellCapture("lipc-probe com.lab126.audioPlayer 2>/dev/null | head -15", 3) or "not found"

        -- audiomgrd: Amazon's audio manager daemon -- likely controls ALSA
        -- card lifecycle and routes audio to btfd for BT output.
        local amgr_pid = shellCapture("pidof audiomgrd 2>/dev/null", 2)
        info.kindle_audiomgrd_pid = amgr_pid or "not running"
        if amgr_pid and amgr_pid:match("%d") then
            local pid = amgr_pid:match("(%d+)")
            info.kindle_audiomgrd_cmdline = shellCapture("cat /proc/" .. pid .. "/cmdline 2>/dev/null | tr '\\0' ' '", 2) or "n/a"
            info.kindle_audiomgrd_fds = shellCapture("ls -la /proc/" .. pid .. "/fd/ 2>/dev/null | head -30", 3) or "n/a"
            info.kindle_audiomgrd_maps = shellCapture("cat /proc/" .. pid .. "/maps 2>/dev/null | grep -iE 'audio|alsa|snd|pcm|mixer|pipe|socket|hw' | head -20", 3) or "n/a"
        end
        -- LIPC services discovered in v0.1.5.24: playermgr and audiomgrd
        info.kindle_lipc_playermgr = shellCapture("lipc-probe com.lab126.playermgr 2>/dev/null | head -20", 3) or "not found"
        info.kindle_lipc_audiomgrd = shellCapture("lipc-probe com.lab126.audiomgrd 2>/dev/null | head -20", 3) or "not found"
        -- v0.1.5.27: capture actual playermgr/audiomgrd state values
        info.kindle_playermgr_inplayback = shellCapture("lipc-get-prop com.lab126.playermgr InPlayback 2>/dev/null", 2) or "n/a"
        info.kindle_playermgr_tts_state = shellCapture("lipc-get-prop com.lab126.playermgr TTS_State 2>/dev/null", 2) or "n/a"
        info.kindle_audiomgrd_output_connected = shellCapture("lipc-get-prop com.lab126.audiomgrd audioOutputConnected 2>/dev/null", 2) or "n/a"
        info.kindle_audiomgrd_current_output = shellCapture("lipc-get-prop com.lab126.audiomgrd audioCurrentOutput 2>/dev/null", 2) or "n/a"
        info.kindle_audiomgrd_volume = shellCapture("lipc-get-prop com.lab126.audiomgrd speakerVolume 2>/dev/null", 2) or "n/a"
        -- Full ALSA config: v0.1.5.24 showed dmix0 on hw:0,0 -- we need
        -- the complete config to see all defined PCMs and their routing.
        info.kindle_asound_conf_full = shellCapture("cat /etc/asound.conf 2>/dev/null", 5) or "not found"
        -- Dynamic ALSA card: check if /dev/snd/ changes after poking
        -- audiomgrd.  List all of /dev/snd/ before and after.
        info.kindle_dev_snd_full = shellCapture("ls -la /dev/snd/ 2>/dev/null", 3) or "empty"
        -- All LIPC services (not just bt-related) for discovery
        info.kindle_lipc_all_services = shellCapture("lipc-probe -l 2>/dev/null | head -40", 3) or "n/a"
        -- v0.1.5.30: LIPC playback smoke test -- multi-strategy.
        -- Generate a 1-second 22050Hz mono 16-bit WAV (silence) and try
        -- 4 LIPC strategies + 2 aplay strategies.
        -- NOTE: first line MUST be a real command (not a variable assignment)
        -- because shellCapture prepends 'timeout N' which wraps only line 1.
        info.kindle_lipc_test = shellCapture([[dd if=/dev/zero bs=44100 count=1 2>/dev/null | {
  printf 'RIFF'
  printf '\x24\xac\x00\x00'
  printf 'WAVE'
  printf 'fmt '
  printf '\x10\x00\x00\x00'
  printf '\x01\x00'
  printf '\x01\x00'
  printf '\x22\x56\x00\x00'
  printf '\x44\xac\x00\x00'
  printf '\x02\x00'
  printf '\x10\x00'
  printf 'data'
  printf '\x04\xac\x00\x00'
  cat
} > /tmp/.lipc_test.wav
echo "wav_size=$(wc -c < /tmp/.lipc_test.wav 2>/dev/null)"
echo "setFocus=$(lipc-set-prop com.lab126.audiomgrd setFocus 'tts' 2>&1)"
echo "gstLog=$(lipc-set-prop com.lab126.playermgr gstLogLevel 2 2>&1)"
echo "--- strategy1: Open(URI)+Play ---"
lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
echo "open_uri=$(lipc-set-prop com.lab126.playermgr Open 'file:///tmp/.lipc_test.wav' 2>&1)"
echo "play1=$(lipc-set-prop com.lab126.playermgr Play '' 2>&1)"
sleep 1 2>/dev/null || usleep 1000000 2>/dev/null
echo "inplayback1=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
echo "tts_state1=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
echo "--- strategy2: Open(path)+Play ---"
lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
echo "open_path=$(lipc-set-prop com.lab126.playermgr Open '/tmp/.lipc_test.wav' 2>&1)"
echo "play2=$(lipc-set-prop com.lab126.playermgr Play '' 2>&1)"
sleep 1 2>/dev/null || usleep 1000000 2>/dev/null
echo "inplayback2=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
echo "--- strategy3: Play(URI) ---"
lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
echo "play_uri=$(lipc-set-prop com.lab126.playermgr Play 'file:///tmp/.lipc_test.wav' 2>&1)"
sleep 1 2>/dev/null || usleep 1000000 2>/dev/null
echo "inplayback3=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
echo "--- strategy4: Play(path) ---"
lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
echo "play_path=$(lipc-set-prop com.lab126.playermgr Play '/tmp/.lipc_test.wav' 2>&1)"
sleep 1 2>/dev/null || usleep 1000000 2>/dev/null
echo "inplayback4=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
echo "--- strategy5: aplay dmix0 ---"
lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
echo "aplay_dmix0=$(aplay -D dmix0 /tmp/.lipc_test.wav 2>&1 | head -3)"
echo "--- strategy6: aplay default ---"
echo "aplay_default=$(aplay -D default /tmp/.lipc_test.wav 2>&1 | head -3)"
echo "--- audiomgrd state ---"
echo "audioOutput=$(lipc-get-prop com.lab126.audiomgrd audioCurrentOutput 2>&1)"
echo "outputConn=$(lipc-get-prop com.lab126.audiomgrd audioOutputConnected 2>&1)"
rm -f /tmp/.lipc_test.wav
]], 20) or "failed"
        -- audiomgrd error log (audiomgrd logs to /var/tmp/audiomgrd.err)
        info.kindle_audiomgrd_err = shellCapture("tail -20 /var/tmp/audiomgrd.err", 3) or "n/a"
        -- GStreamer plugins available on device
        info.kindle_gst_plugins = shellCapture("ls /usr/lib/gstreamer-*/ 2>/dev/null | head -30", 3) or "n/a"
        -- v0.1.5.31: tts.orchestrator -- Amazon's native TTS service.
        -- GStreamer on Kindle is stripped (no wavparse/audioconvert), so
        -- playermgr cannot decode WAV files.  The native TTS path is:
        --   tts.orchestrator → ttssrc (GStreamer) → mixersink → audiomgrd → A2DP → BT
        -- If we can speak text through tts.orchestrator, audio will flow.
        info.kindle_tts_orchestrator = shellCapture("lipc-probe com.lab126.tts.orchestrator 2>/dev/null | head -30", 3) or "not found"
        -- audiomgrd isStarted property (is the audio subsystem initialized?)
        info.kindle_audiomgrd_is_started = shellCapture("lipc-get-prop com.lab126.audiomgrd isStarted 2>/dev/null", 2) or "n/a"
        -- GStreamer + audio tools on the device
        info.kindle_gst_tools = shellCapture([[echo "gst_launch=$(which gst-launch-1.0 2>/dev/null || echo not_found)"
echo "gst_inspect=$(which gst-inspect-1.0 2>/dev/null || echo not_found)"
echo "amixer=$(which amixer 2>/dev/null || echo not_found)"
echo "pactl=$(which pactl 2>/dev/null || echo not_found)"
]], 3) or "n/a"
        -- Shared memory segments (audiomgrd uses libaudioShmbuffer)
        info.kindle_shm = shellCapture("ls -la /dev/shm/ 2>/dev/null || echo 'no /dev/shm'", 3) or "n/a"
        -- Full A2DP socket state (both .a2dp_ctrl and .a2dp_data)
        info.kindle_a2dp_sockets = shellCapture("cat /proc/net/unix 2>/dev/null | grep -i a2dp", 3) or "none"
        -- GStreamer element inspection (what does ttssrc/mixersink accept?)
        info.kindle_gst_inspect_ttssrc = shellCapture("gst-inspect-1.0 ttssrc 2>/dev/null | head -30", 3) or "n/a"
        info.kindle_gst_inspect_mixersink = shellCapture("gst-inspect-1.0 mixersink 2>/dev/null | head -30", 3) or "n/a"
        -- v0.1.5.31: TTS orchestrator smoke test.
        -- Try to make the native TTS speak, which routes through the
        -- working audio pipeline (ttssrc → mixersink → audiomgrd → BT).
        -- Also test: can we write raw PCM to a pipe that audiomgrd reads?
        info.kindle_tts_test = shellCapture([[echo "--- tts.orchestrator probe ---"
echo "tts_orch_props=$(lipc-probe com.lab126.tts.orchestrator 2>&1 | head -30)"
echo "--- try native TTS speak ---"
echo "tts_speak=$(lipc-set-prop com.lab126.tts.orchestrator speak 'test' 2>&1)"
sleep 2 2>/dev/null || usleep 2000000 2>/dev/null
echo "tts_state_after=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
echo "inplayback_after=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
echo "--- try audiomgrd direct ---"
echo "amgrd_started=$(lipc-get-prop com.lab126.audiomgrd isStarted 2>&1)"
echo "amgrd_focus=$(lipc-set-prop com.lab126.audiomgrd setFocus 'tts' 2>&1)"
echo "--- ALSA after setFocus ---"
echo "aplay_l_after=$(aplay -l 2>&1 | head -5)"
echo "dev_snd_after=$(ls /dev/snd/ 2>/dev/null | grep pcm)"
echo "--- A2DP socket state ---"
echo "a2dp_socks=$(cat /proc/net/unix 2>/dev/null | grep a2dp)"
]], 15) or "failed"

        -- v0.1.5.32: Deeper TTS + audio path exploration.
        -- GStreamer 0.10 is stripped (no wavparse). tts.orchestrator is
        -- running with voices.  We need to trigger native TTS.

        -- tts.orchestrator: read hash properties and orchestratorStarted
        info.kindle_tts_orch_started = shellCapture(
            "lipc-get-prop com.lab126.tts.orchestrator orchestratorStarted 2>&1", 3) or "n/a"
        info.kindle_tts_orch_hash_cmd = shellCapture(
            "which lipc-hash-prop 2>/dev/null || echo not_found", 2) or "n/a"
        info.kindle_tts_orch_langs = shellCapture(
            "lipc-hash-prop -n com.lab126.tts.orchestrator supportedLanguages 2>&1 | head -20", 5) or "n/a"
        -- v0.1.5.33: get FULL voices list (was truncated at 20 lines)
        info.kindle_tts_orch_voices = shellCapture(
            "lipc-hash-prop -n com.lab126.tts.orchestrator voices 2>&1 | head -80", 8) or "n/a"
        info.kindle_tts_orch_installed = shellCapture(
            "lipc-hash-prop -n com.lab126.tts.orchestrator installedVoices 2>&1 | head -20", 5) or "n/a"

        -- lipc-send-event: v0.1.5.33 used the service as source ("Failed to
        -- open LIPC" -- can't impersonate another publisher).  v0.1.5.34:
        -- use our own source name so we can actually publish events.
        info.kindle_tts_event_test = shellCapture([[echo "--- lipc-send-event from custom source ---"
echo "evt1=$(lipc-send-event com.lab126.audiobook speak -s 'hello world' 2>&1)"
echo "tts1=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
echo "--- send ttsSpeak from kaf source ---"
echo "evt2=$(lipc-send-event com.lab126.kaf ttsSpeak -s 'hello' 2>&1)"
sleep 2 2>/dev/null || usleep 2000000 2>/dev/null
echo "tts2=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
echo "--- send readScreen from custom source ---"
echo "evt3=$(lipc-send-event com.lab126.audiobook readScreen -s 'hello' 2>&1)"
echo "tts3=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
]], 15) or "failed"

        -- v0.1.5.34 FIX: lipc-hash-prop has no -w flag! v0.1.5.33 used
        -- non-existent -w which just printed usage.  Correct approach:
        -- pipe hash data through stdin in the format { key = "val" }.
        info.kindle_tts_check_voice = shellCapture([[echo "--- checkVoice write via stdin pipe ---"
cv1=$(echo '{ language_code = "en" }' | lipc-hash-prop com.lab126.tts.orchestrator checkVoice 2>&1)
echo "cv1=$cv1"
echo "cv1_rc=$?"
sleep 2 2>/dev/null || usleep 2000000 2>/dev/null
echo "tts_cv1=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
echo "play_cv1=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
echo "--- checkVoice with voice name ---"
cv2=$(echo '{ language_code = "en_us", voice = "joanna" }' | lipc-hash-prop com.lab126.tts.orchestrator checkVoice 2>&1)
echo "cv2=$cv2"
sleep 2 2>/dev/null || usleep 2000000 2>/dev/null
echo "tts_cv2=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
echo "--- write text to voices hash ---"
v1=$(echo '{ Voice = "joanna", LanguageCode = "en_us" }' | lipc-hash-prop com.lab126.tts.orchestrator voices 2>&1)
echo "voices_write=$v1"
sleep 2 2>/dev/null || usleep 2000000 2>/dev/null
echo "tts_v1=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
echo "--- checkVoice read (null input) ---"
echo "cv_read=$(lipc-hash-prop -n com.lab126.tts.orchestrator checkVoice 2>&1 | head -10)"
]], 15) or "failed"

        -- v0.1.5.33: try TTS URI schemes via playermgr.
        -- playermgr might accept special URIs for TTS mode.
        info.kindle_tts_uri_test = shellCapture([[lipc-set-prop com.lab126.audiomgrd setFocus 'tts' 2>/dev/null
echo "--- tts:// URI ---"
lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
echo "open_tts=$(lipc-set-prop com.lab126.playermgr Open 'tts://hello world' 2>&1)"
echo "play_tts=$(lipc-set-prop com.lab126.playermgr Play '' 2>&1)"
sleep 2 2>/dev/null || usleep 2000000 2>/dev/null
echo "state_tts=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
echo "play_tts_ip=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
echo "--- ttssrc:// URI ---"
lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
echo "open_ttssrc=$(lipc-set-prop com.lab126.playermgr Open 'ttssrc://hello world' 2>&1)"
echo "play_ttssrc=$(lipc-set-prop com.lab126.playermgr Play '' 2>&1)"
sleep 2 2>/dev/null || usleep 2000000 2>/dev/null
echo "state_ttssrc=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
echo "--- Play with tts: ---"
lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
echo "play_tts2=$(lipc-set-prop com.lab126.playermgr Play 'tts://hello' 2>&1)"
sleep 2 2>/dev/null || usleep 2000000 2>/dev/null
echo "state_tts2=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
]], 15) or "failed"

        -- v0.1.5.35: Test VoiceView-compatible native TTS via PlayParameter.
        -- VoiceView capture showed: playermgr accepts SSML text via
        -- PlayParameter JSON → ttssrc → Ivona SDK → mixersink → BT.
        info.kindle_native_tts_test = shellCapture([[lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
lipc-set-prop com.lab126.audiomgrd setFocus 'tts' 2>/dev/null
echo "--- Strategy A: PlayParameter only ---"
lipc-set-prop com.lab126.playermgr PlayParameter '{"type":"TTS","data":{"paramName":"textsource","paramValue":"Testing native TTS."}}' 2>&1
sleep 2 2>/dev/null || usleep 2000000 2>/dev/null
echo "tts_a=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
echo "ip_a=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
echo "--- Strategy B: Open+PlayParameter+Play ---"
lipc-set-prop com.lab126.playermgr Open '{"type":"TTS"}' 2>&1
lipc-set-prop com.lab126.playermgr PlayParameter '{"type":"TTS","data":{"paramName":"textsource","paramValue":"Testing native TTS."}}' 2>&1
lipc-set-prop com.lab126.playermgr Play '' 2>&1
sleep 2 2>/dev/null || usleep 2000000 2>/dev/null
echo "tts_b=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
echo "ip_b=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
echo "--- Strategy C: PlayParameter+Play ---"
lipc-set-prop com.lab126.playermgr PlayParameter '{"type":"TTS","data":{"paramName":"textsource","paramValue":"Testing native TTS."}}' 2>&1
lipc-set-prop com.lab126.playermgr Play '{"type":"TTS"}' 2>&1
sleep 2 2>/dev/null || usleep 2000000 2>/dev/null
echo "tts_c=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
echo "ip_c=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
echo "--- Strategy D: Open+PlayParameter+Play(empty) ---"
lipc-set-prop com.lab126.playermgr Open '' 2>&1
lipc-set-prop com.lab126.playermgr PlayParameter '{"type":"TTS","data":{"paramName":"textsource","paramValue":"Testing native TTS."}}' 2>&1
lipc-set-prop com.lab126.playermgr Play '' 2>&1
sleep 2 2>/dev/null || usleep 2000000 2>/dev/null
echo "tts_d=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
echo "ip_d=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
echo "--- Strategy E: SSML with marks ---"
lipc-set-prop com.lab126.playermgr PlayParameter '{"type":"TTS","data":{"paramName":"textsource","paramValue":"<mark name=\"1\"/>Testing <mark name=\"9\"/>native <mark name=\"16\"/>TTS."}}' 2>&1
sleep 2 2>/dev/null || usleep 2000000 2>/dev/null
echo "tts_e=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
echo "ip_e=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
]], 30) or "failed"

        -- PlayParameter + raw PCM: strip the 44-byte WAV header, set
        -- GStreamer caps via PlayParameter, try Open/Play with raw audio.
        -- If mixersink accepts S16LE @ 22050 without a parser, this works.
        info.kindle_raw_pcm_test = shellCapture([[dd if=/dev/zero bs=44100 count=1 2>/dev/null | {
  printf 'RIFF'
  printf '\x24\xac\x00\x00'
  printf 'WAVE'
  printf 'fmt '
  printf '\x10\x00\x00\x00'
  printf '\x01\x00'
  printf '\x01\x00'
  printf '\x22\x56\x00\x00'
  printf '\x44\xac\x00\x00'
  printf '\x02\x00'
  printf '\x10\x00'
  printf 'data'
  printf '\x04\xac\x00\x00'
  cat
} > /tmp/.pcm_test.wav
dd if=/tmp/.pcm_test.wav of=/tmp/.pcm_test.raw bs=1 skip=44 2>/dev/null
echo "raw_size=$(wc -c < /tmp/.pcm_test.raw 2>/dev/null)"
lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
lipc-set-prop com.lab126.audiomgrd setFocus 'tts' 2>/dev/null
echo "--- PlayParameter + raw PCM (path) ---"
echo "param=$(lipc-set-prop com.lab126.playermgr PlayParameter 'audio/x-raw,format=S16LE,rate=22050,channels=1' 2>&1)"
echo "open=$(lipc-set-prop com.lab126.playermgr Open '/tmp/.pcm_test.raw' 2>&1)"
echo "play=$(lipc-set-prop com.lab126.playermgr Play '' 2>&1)"
sleep 1 2>/dev/null || usleep 1000000 2>/dev/null
echo "inplayback_raw=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
echo "--- PlayParameter + raw PCM (URI) ---"
lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
echo "param2=$(lipc-set-prop com.lab126.playermgr PlayParameter 'audio/x-raw,format=S16LE,rate=22050,channels=1' 2>&1)"
echo "open2=$(lipc-set-prop com.lab126.playermgr Open 'file:///tmp/.pcm_test.raw' 2>&1)"
echo "play2=$(lipc-set-prop com.lab126.playermgr Play '' 2>&1)"
sleep 1 2>/dev/null || usleep 1000000 2>/dev/null
echo "inplayback_raw_uri=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
rm -f /tmp/.pcm_test.wav /tmp/.pcm_test.raw
]], 20) or "failed"

        -- amixer: check ALSA mixer controls (audiomgrd may expose some)
        info.kindle_amixer = shellCapture("amixer 2>&1 | head -20", 3) or "n/a"
        info.kindle_amixer_scontrols = shellCapture("amixer scontrols 2>&1 | head -10", 3) or "n/a"

        -- GStreamer plugin directory: version, path, permissions.
        -- v0.1.5.33: separate writable test from dir listing to avoid
        -- truncation hiding the answer (v0.1.5.32 was cut off).
        info.kindle_gst_plugin_dir = shellCapture([[echo "--- GStreamer libs ---"
ls -la /usr/lib/libgstreamer* 2>/dev/null | head -5 || echo "no libgstreamer"
echo "--- plugin dir ---"
for d in /usr/lib/gstreamer-*/; do
  if [ -d "$d" ]; then
    echo "dir=$d"
    ls "$d" 2>/dev/null | head -15
  fi
done
]], 5) or "n/a"
        info.kindle_gst_dir_writable = shellCapture([[for d in /usr/lib/gstreamer-*/; do
  if [ -d "$d" ]; then
    echo "dir=$d"
    if touch "${d}.__gst_test" 2>/dev/null; then
      rm -f "${d}.__gst_test"
      echo "writable=yes"
    else
      echo "writable=no"
    fi
    echo "registry=$(ls -la ${d}registry.* 2>/dev/null || echo none)"
    echo "gst_ver_dir=$(basename $d)"
  fi
done
]], 5) or "n/a"

        -- com.lab126.kaf: Kindle Application Framework (may have TTS events)
        info.kindle_kaf_probe = shellCapture(
            "lipc-probe com.lab126.kaf 2>/dev/null | head -30", 3) or "not found"

        -- Available tools for potential A2DP socket or audio injection
        info.kindle_socket_tools = shellCapture([[echo "socat=$(which socat 2>/dev/null || echo not_found)"
echo "nc=$(which nc 2>/dev/null || echo not_found)"
echo "ncat=$(which ncat 2>/dev/null || echo not_found)"
echo "python=$(which python 2>/dev/null || which python3 2>/dev/null || echo not_found)"
echo "perl=$(which perl 2>/dev/null || echo not_found)"
echo "busybox=$(which busybox 2>/dev/null || echo not_found)"
echo "toybox=$(which toybox 2>/dev/null || echo not_found)"
echo "strace=$(which strace 2>/dev/null || echo not_found)"
]], 3) or "n/a"

        -- v0.1.5.34 FIX: lipc-wait-event requires an event-name argument.
        -- v0.1.5.33 omitted it ("Both event source and event name are
        -- expected").  Use '*' wildcard to capture all events.
        info.kindle_wait_events = shellCapture([[echo "--- tts.orchestrator events (5s) ---"
lipc-wait-event -s 5 -m com.lab126.tts.orchestrator '*' 2>&1 &
WPID=$!
sleep 1 2>/dev/null || usleep 1000000 2>/dev/null
echo '{ language_code = "en" }' | lipc-hash-prop com.lab126.tts.orchestrator checkVoice 2>/dev/null
echo '{ Voice = "joanna", LanguageCode = "en_us" }' | lipc-hash-prop com.lab126.tts.orchestrator voices 2>/dev/null
lipc-set-prop com.lab126.audiomgrd setFocus 'tts' 2>/dev/null
sleep 4 2>/dev/null || usleep 4000000 2>/dev/null
wait $WPID 2>/dev/null
echo "--- playermgr events (5s) ---"
lipc-wait-event -s 5 -m com.lab126.playermgr '*' 2>&1 &
WPID=$!
sleep 1 2>/dev/null || usleep 1000000 2>/dev/null
lipc-set-prop com.lab126.playermgr Open 'tts://hello world' 2>/dev/null
lipc-set-prop com.lab126.playermgr Play '' 2>/dev/null
sleep 4 2>/dev/null || usleep 4000000 2>/dev/null
wait $WPID 2>/dev/null
echo "--- audiomgrd events (5s) ---"
lipc-wait-event -s 5 -m com.lab126.audiomgrd '*' 2>&1 &
WPID=$!
sleep 1 2>/dev/null || usleep 1000000 2>/dev/null
lipc-set-prop com.lab126.audiomgrd setFocus 'tts' 2>/dev/null
sleep 4 2>/dev/null || usleep 4000000 2>/dev/null
wait $WPID 2>/dev/null
]], 20) or "n/a"

        -- v0.1.5.33: voice config files on the device
        info.kindle_tts_voice_configs = shellCapture([[echo "--- /usr/lib/tts/ ---"
find /usr/lib/tts/ -name '*.json' 2>/dev/null | head -20 || echo "not found"
echo "--- English voice config ---"
for f in /usr/lib/tts/english/*.json /usr/lib/tts/en_*/*.json; do
  if [ -f "$f" ]; then
    echo "file=$f"
    cat "$f" 2>/dev/null | head -30
  fi
done
echo "--- voice dirs ---"
ls -d /usr/lib/tts/*/ 2>/dev/null || echo "none"
echo "--- English liblanguage ---"
ls -la /usr/lib/tts/english/liblanguage_english.so 2>/dev/null || echo "not found"
]], 8) or "n/a"

        -- v0.1.5.34 FIX: lipc-hash-prop has no -w or -v flags.
        -- Use stdin pipe for writes, -n for reads.
        info.kindle_tts_hash_write = shellCapture([[echo "--- write to supportedLanguages hash ---"
sl=$(echo '{ language_code = "en" }' | lipc-hash-prop com.lab126.tts.orchestrator supportedLanguages 2>&1)
echo "sl=$sl"
echo "--- write to installedVoices hash ---"
iv=$(echo '{ language_code = "en_us" }' | lipc-hash-prop com.lab126.tts.orchestrator installedVoices 2>&1)
echo "iv=$iv"
echo "--- read installedVoices ---"
echo "iv_read=$(lipc-hash-prop -n com.lab126.tts.orchestrator installedVoices 2>&1 | head -20)"
]], 8) or "n/a"

        -- v0.1.5.34: VoiceView / accessibility service probe.
        -- VoiceView is Amazon's screen reader -- when active, it triggers
        -- the native TTS pipeline.  Find related LIPC services/properties.
        info.kindle_voiceview_probe = shellCapture([[echo "--- accessibility/voiceview LIPC services ---"
lipc-probe -l 2>/dev/null | grep -iE 'voice|access|a11y|screen.?read|tts' | head -20
echo "---"
echo "--- com.lab126.voiceview probe ---"
lipc-probe com.lab126.voiceview 2>&1 | head -20
echo "--- com.lab126.accessibility probe ---"
lipc-probe com.lab126.accessibility 2>&1 | head -20
echo "--- com.lab126.tts probe ---"
lipc-probe com.lab126.tts 2>&1 | head -20
echo "--- pillow (UI framework) probe ---"
lipc-probe com.lab126.pillow 2>&1 | head -20
echo "--- full service list (voice/tts/a11y) ---"
lipc-probe -l 2>/dev/null | grep -iE 'voice|tts|a11y|access|speak|screen.?read|pillow' | head -20
]], 10) or "n/a"

        -- v0.1.5.37: liblipc.so FFI diagnostic -- test if a named LIPC
        -- connection can trigger PlayParameter (the CLI tools use anonymous
        -- connections which playermgr may ignore).
        info.kindle_lipc_ffi_test = (function()
            local ok, result = pcall(function()
            local lines = {}
            local function log(s) lines[#lines + 1] = s end
            -- 1) Check liblipc.so exists
            local lib_path = nil
            for _, p in ipairs({"/usr/lib/liblipc.so", "/usr/lib/liblipc.so.0"}) do
                local f = io.open(p, "r")
                if f then f:close(); lib_path = p; break end
            end
            log("liblipc_path=" .. (lib_path or "not found"))
            if not lib_path then return table.concat(lines, "\n") end
            -- 2) Dump key exported symbols
            local nm = shellCapture("nm -D " .. lib_path .. " 2>/dev/null | grep -i 'Lipc\\|lipc' | head -30", 5)
            log("symbols=" .. (nm or "nm failed"))
            -- 3) Try FFI load + named connection + PlayParameter
            local ffi_ok, ffi = pcall(require, "ffi")
            if not ffi_ok then log("ffi=not available"); return table.concat(lines, "\n") end
            -- Declare LIPC functions (wrapped in pcall to tolerate duplicate cdef)
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
            local load_ok, lipc_lib = pcall(ffi.load, "lipc")
            if not load_ok then log("ffi_load=failed: " .. tostring(lipc_lib)); return table.concat(lines, "\n") end
            log("ffi_load=ok")
            -- 3a) Anonymous connection (same as lipc-set-prop)
            local code = ffi.new("int[1]")
            local h_anon = lipc_lib.LipcOpenNoName(code)
            log("anon_open=" .. tostring(code[0]) .. " handle=" .. tostring(h_anon ~= nil and h_anon or "nil"))
            if h_anon ~= nil and code[0] == 0 then
                local rc = lipc_lib.LipcSetStringProperty(h_anon,
                    "com.lab126.playermgr", "PlayParameter",
                    '{"type":"TTS","data":{"paramName":"textsource","paramValue":"FFI anonymous test."}}')
                log("anon_set_pp=" .. tostring(rc))
                -- Brief wait then check TTS_State
                os.execute("sleep 2 2>/dev/null || usleep 2000000 2>/dev/null")
                local st = ffi.new("int[1]")
                lipc_lib.LipcGetIntProperty(h_anon, "com.lab126.playermgr", "TTS_State", st)
                log("anon_tts_state=" .. tostring(st[0]))
                local ip = ffi.new("int[1]")
                lipc_lib.LipcGetIntProperty(h_anon, "com.lab126.playermgr", "InPlayback", ip)
                log("anon_inplayback=" .. tostring(ip[0]))
                lipc_lib.LipcSetStringProperty(h_anon, "com.lab126.playermgr", "Stop", "")
                lipc_lib.LipcClose(h_anon)
            end
            -- 3b) Named connection (might be what VoiceView does)
            -- Use a different name than the engine's cached handle to avoid
            -- LIPC error 17 (ALREADY_REGISTERED) when the engine is running.
            code[0] = 0
            local h_named = lipc_lib.LipcOpenEx("com.lab126.koreader.diag", code)
            log("named_open=" .. tostring(code[0]) .. " handle=" .. tostring(h_named ~= nil and h_named or "nil"))
            if h_named ~= nil and code[0] == 0 then
                -- Set audio focus via named connection
                lipc_lib.LipcSetStringProperty(h_named,
                    "com.lab126.audiomgrd", "setFocus", "tts")
                local rc = lipc_lib.LipcSetStringProperty(h_named,
                    "com.lab126.playermgr", "PlayParameter",
                    '{"type":"TTS","data":{"paramName":"textsource","paramValue":"FFI named test."}}')
                log("named_set_pp=" .. tostring(rc))
                os.execute("sleep 2 2>/dev/null || usleep 2000000 2>/dev/null")
                local st = ffi.new("int[1]")
                lipc_lib.LipcGetIntProperty(h_named, "com.lab126.playermgr", "TTS_State", st)
                log("named_tts_state=" .. tostring(st[0]))
                local ip = ffi.new("int[1]")
                lipc_lib.LipcGetIntProperty(h_named, "com.lab126.playermgr", "InPlayback", ip)
                log("named_inplayback=" .. tostring(ip[0]))
                lipc_lib.LipcSetStringProperty(h_named, "com.lab126.playermgr", "Stop", "")
                lipc_lib.LipcClose(h_named)
            end
            return table.concat(lines, "\n")
            end)
            if not ok then return "pcall_error: " .. tostring(result) end
            return result
        end)()

        -- v0.1.5.34: check if running as root (needed for GStreamer plugin dir)
        -- Only report yes/no, not the actual username (privacy).
        info.kindle_is_root = shellCapture("[ \"$(id -u 2>/dev/null)\" = '0' ] && echo yes || echo no", 2) or "n/a"

        -- v0.1.5.34: full English voice config (was truncated at 5 lines)
        info.kindle_voice_config_full = shellCapture(
            "cat /usr/lib/tts/english/en_us_joanna24_a11y.json 2>/dev/null | head -40", 5) or "n/a"

        -- v0.1.5.34: probe libtts_engine.so and voice data files
        info.kindle_tts_engine_probe = shellCapture([[echo "--- libtts_engine.so ---"
ls -la /usr/lib/tts/libtts_engine.so 2>/dev/null || echo "not found"
echo "--- strings from libtts_engine.so (speak/synth/init) ---"
strings /usr/lib/tts/libtts_engine.so 2>/dev/null | grep -iE 'speak|synth|init|play|audio|text|voice|tts' | head -20 || echo "no strings cmd"
echo "--- English voice data ---"
ls -la /mnt/base-us/voice/english/ 2>/dev/null | head -10 || echo "not found"
ls -la /usr/lib/tts/english/ 2>/dev/null | head -10 || echo "not found"
]], 8) or "n/a"

        -- Mixer API: check if audiomgrd exposes Unix sockets for PCM data
        info.kindle_audiomgrd_net = shellCapture([[echo "--- audiomgrd socket fds ---"
AMGR_PID=$(pidof audiomgrd 2>/dev/null)
if [ -n "$AMGR_PID" ]; then
  ls -la /proc/$AMGR_PID/fd/ 2>/dev/null | grep socket | head -10
  echo "--- socket inodes ---"
  for sock in $(ls -la /proc/$AMGR_PID/fd/ 2>/dev/null | grep socket | sed 's/.*\[\(.*\)\]/\1/'); do
    grep "$sock" /proc/net/unix 2>/dev/null
    grep "$sock" /proc/net/tcp 2>/dev/null
    grep "$sock" /proc/net/udp 2>/dev/null
  done | head -20
fi
]], 5) or "n/a"
    end

    -- /tmp writable (needed for WAV files)
    info.tmp_writable = fileExists("/tmp") and os.execute("touch /tmp/.audiobook_test 2>/dev/null && rm /tmp/.audiobook_test 2>/dev/null") ~= nil

    -- kindle-gst-play: bundled GStreamer WAV player for devices without wavparse.
    -- Reports whether the binary exists, GStreamer loads, and which elements
    -- are available (especially mixersink which is the only audio path).
    if Device.isKindle and Device:isKindle() then
        -- Try common plugin paths to find the binary
        local gst_play_path = nil
        for _, p in ipairs({
            "/mnt/us/koreader/plugins/audiobook.koplugin",
            "/opt/koreader/plugins/audiobook.koplugin",
        }) do
            local candidate = p .. "/kindle/gst-play"
            if fileExists(candidate) then gst_play_path = candidate; break end
        end
        if gst_play_path then
            info.kindle_gst_play_probe = shellCapture(
                gst_play_path .. " --probe 2>&1", 5) or "binary_exists_but_probe_failed"
            info.kindle_gst_play_version = shellCapture(
                gst_play_path .. " --version 2>&1", 2) or "n/a"
        else
            info.kindle_gst_play_probe = "binary_not_found"
        end
    end

    return info
end

--- Collect memory and resource info.
local function collectResourceInfo()
    local info = {}
    info.meminfo = shellCapture("head -5 /proc/meminfo 2>/dev/null", 2)
    info.disk_tmp = shellCapture("df -h /tmp 2>/dev/null | tail -1", 2)
    info.disk_var = shellCapture("df -h /var 2>/dev/null | tail -1", 2)
    info.disk_var_usage = shellCapture(
        "du -sh /var/* 2>/dev/null | sort -rh | head -15", 3) or "n/a"
    return info
end

--- Format a table of key-value pairs as aligned text lines.
local function formatSection(title, data, indent)
    indent = indent or ""
    local lines = {indent .. "── " .. title .. " ──"}
    if type(data) ~= "table" then
        table.insert(lines, indent .. "  " .. tostring(data))
        return table.concat(lines, "\n")
    end
    -- Sort keys for deterministic output
    local keys = {}
    for k in pairs(data) do table.insert(keys, k) end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
        local v = data[k]
        if type(v) == "table" then
            table.insert(lines, indent .. "  " .. tostring(k) .. ":")
            local subkeys = {}
            for sk in pairs(v) do table.insert(subkeys, sk) end
            table.sort(subkeys, function(a, b) return tostring(a) < tostring(b) end)
            for _, sk in ipairs(subkeys) do
                table.insert(lines, indent .. "    " .. tostring(sk) .. ": " .. tostring(v[sk]))
            end
        elseif type(v) == "boolean" then
            table.insert(lines, indent .. "  " .. tostring(k) .. ": " .. (v and "yes" or "no"))
        else
            table.insert(lines, indent .. "  " .. tostring(k) .. ": " .. tostring(v))
        end
    end
    return table.concat(lines, "\n")
end

--- Generate the full bug report as a plain-text string.
-- @param plugin table  The Audiobook plugin instance
-- @return string  The formatted bug report text
function BugReport.generate(plugin)
    local device = collectDeviceInfo()
    local koreader = collectKoreaderInfo()
    local pluginInfo = collectPluginInfo(plugin)
    local audio = collectAudioInfo(plugin)
    local resources = collectResourceInfo()
    local timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")

    local version = "unknown"
    local ok_meta, meta = pcall(dofile, _utils_dir .. "_meta.lua")
    if ok_meta and meta then
        version = meta.version or version
    end

    local sections = {
        "=== Audiobook Read-Along Bug Report (v" .. version .. ") ===",
        "Generated: " .. timestamp,
        "",
        formatSection("Device", device),
        "",
        formatSection("KOReader", koreader),
        "",
        formatSection("Plugin", pluginInfo),
        "",
        formatSection("Audio & TTS", audio),
        "",
        formatSection("Resources", resources),
        "",
        "=== End of Bug Report ===",
    }

    return table.concat(sections, "\n")
end

--- Generate and save the bug report to a file the user can access.
-- Saves to the book storage root (visible when device is connected via USB).
-- @param plugin table  The Audiobook plugin instance
-- @return string|nil  Path to the saved report, or nil on failure
function BugReport.generateAndSave(plugin)
    local report = BugReport.generate(plugin)

    -- Pick a user-accessible save location.
    -- Prefer the device's main visible storage so the file is easy to find.
    local save_dir
    if Device.isKobo and Device:isKobo() then
        save_dir = "/mnt/onboard"
    elseif Device.isKindle and Device:isKindle() then
        save_dir = "/mnt/us"
    elseif Device:isAndroid() then
        save_dir = "/sdcard"
    else
        save_dir = os.getenv("HOME") or "/tmp"
    end

    local filename = "audiobook-bug-report-" .. os.date("!%Y%m%d-%H%M%S") .. ".txt"
    local filepath = save_dir .. "/" .. filename

    local f, err = io.open(filepath, "w")
    if not f then
        -- Fallback to /tmp
        filepath = "/tmp/" .. filename
        f, err = io.open(filepath, "w")
    end

    if not f then
        logger.err("BugReport: Cannot save report:", err)
        return nil
    end

    f:write(report)
    f:close()
    logger.dbg("BugReport: Saved to", filepath)
    return filepath
end

--- Menu callback: generate report and show result to user.
-- @param plugin table  The Audiobook plugin instance
function BugReport.menuCallback(plugin)
    local filepath = BugReport.generateAndSave(plugin)
    if filepath then
        local display_path = sanitizePath(filepath)
        UIManager:show(InfoMessage:new{
            text = _("Bug report saved to:\n\n") .. display_path ..
                _("\n\nConnect your device via USB to retrieve the file. Please share it when reporting issues on GitHub."),
            timeout = 15,
        })
    else
        -- As last resort, show the report text directly so user can screenshot
        local report = BugReport.generate(plugin)
        UIManager:show(InfoMessage:new{
            text = _("Could not save report file.\n\nTake a screenshot of this:\n\n") .. report:sub(1, 1500),
            timeout = 30,
        })
    end
end

return BugReport
