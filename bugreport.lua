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
    if #output > 500 then
        output = output:sub(1, 500) .. "…(truncated)"
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
        -- Full ALSA config: v0.1.5.24 showed dmix0 on hw:0,0 -- we need
        -- the complete config to see all defined PCMs and their routing.
        info.kindle_asound_conf_full = shellCapture("cat /etc/asound.conf 2>/dev/null", 5) or "not found"
        -- Dynamic ALSA card: check if /dev/snd/ changes after poking
        -- audiomgrd.  List all of /dev/snd/ before and after.
        info.kindle_dev_snd_full = shellCapture("ls -la /dev/snd/ 2>/dev/null", 3) or "empty"
        -- All LIPC services (not just bt-related) for discovery
        info.kindle_lipc_all_services = shellCapture("lipc-probe -l 2>/dev/null | head -40", 3) or "n/a"
    end

    -- /tmp writable (needed for WAV files)
    info.tmp_writable = fileExists("/tmp") and os.execute("touch /tmp/.audiobook_test 2>/dev/null && rm /tmp/.audiobook_test 2>/dev/null") ~= nil

    return info
end

--- Collect memory and resource info.
local function collectResourceInfo()
    local info = {}
    info.meminfo = shellCapture("head -5 /proc/meminfo 2>/dev/null", 2)
    info.disk_tmp = shellCapture("df -h /tmp 2>/dev/null | tail -1", 2)
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
