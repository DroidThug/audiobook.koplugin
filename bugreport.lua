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
local function fileExists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

--- Collect device and OS information.
local function collectDeviceInfo()
    local info = {}
    info.platform = Device:getPlatform and Device:getPlatform() or "unknown"
    info.model = Device:getDeviceModel and Device:getDeviceModel() or "unknown"
    info.is_android = Device:isAndroid() or false
    info.is_kindle = Device:isKindle and Device:isKindle() or false
    info.is_kobo = Device:isKobo and Device:isKobo() or false
    info.is_pocketbook = Device:isPocketBook and Device:isPocketBook() or false
    info.has_eink = Device:hasEinkScreen and Device:hasEinkScreen() or false

    -- Screen dimensions
    local screen = Device.screen
    if screen then
        info.screen_width = screen:getWidth and screen:getWidth() or "?"
        info.screen_height = screen:getHeight and screen:getHeight() or "?"
        info.screen_dpi = screen:getDPI and screen:getDPI() or "?"
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
        info.koreader_version = Version:getCurrentRevision and Version:getCurrentRevision() or "unknown"
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
    end

    info.plugin_dir = sanitizePath(_utils_dir)

    if not engine then
        info.tts_backend = "engine not initialized"
        return info
    end

    -- TTS state
    info.tts_backend = engine.backend or "nil (none detected)"
    info.tts_backend_cmd = engine.backend_cmd and sanitizePath(engine.backend_cmd) or "nil"
    info.tts_backend_error = engine.backend_error or "none"
    info.player_error = engine.player_error and "yes" or "no"

    -- Bundled binaries presence
    local plugin_dir = engine.plugin_dir or _utils_dir:sub(1, -2)
    info.has_bundled_espeak = fileExists(plugin_dir .. "/espeak-ng/bin/espeak-ng")
    info.has_bundled_piper = fileExists(plugin_dir .. "/piper/piper")
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
local function collectAudioInfo()
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

    -- Bluetooth
    info.bt_available = Utils.commandExists("bluetoothctl") or
                        Utils.commandExists("hcitool") or
                        fileExists("/sys/class/bluetooth") or false

    -- GStreamer BT sink (Kobo-specific)
    if Utils.commandExists("gst-inspect-1.0") then
        local bt_sink = shellCapture("gst-inspect-1.0 mtkbtmwrpcaudiosink 2>/dev/null | head -1", 3)
        info.gst_bt_sink = bt_sink and bt_sink:match("Factory") and "available" or "not found"
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
    local audio = collectAudioInfo()
    local resources = collectResourceInfo()
    local timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")

    local sections = {
        "=== Audiobook Read-Along Bug Report ===",
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
    if Device:isKobo and Device:isKobo() then
        save_dir = "/mnt/onboard"
    elseif Device:isKindle and Device:isKindle() then
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
