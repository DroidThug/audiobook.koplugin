--[[--
Download manager for voice/language packs.
Uses curl (preferred) or wget (fallback) for HTTP downloads,
and tar or unzip for extraction.

@module downloader
--]]

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("logger")
local time = require("ui/time")

local Downloader = {}

-- Known Piper voices (voice id → {name, url, size_mb})
Downloader.PIPER_VOICES = {
    { id = "en_US-danny-low",     name = "Danny (US English, low)",      size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/danny/low/en_US-danny-low.onnx" },
    { id = "en_US-ryan-low",      name = "Ryan (US English, low)",       size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/ryan/low/en_US-ryan-low.onnx" },
    { id = "en_US-ryan-medium",   name = "Ryan (US English, medium)",    size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/ryan/medium/en_US-ryan-medium.onnx" },
    { id = "en_GB-semaine-medium",name = "Semaine (GB English, medium)", size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/semaine/medium/en_GB-semaine-medium.onnx" },
    { id = "es_ES-sharvard-medium",name = "Sharvard (Spanish, medium)",  size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/es/es_ES/sharvard/medium/es_ES-sharvard-medium.onnx" },
    { id = "de_DE-thorsten-low",  name = "Thorsten (German, low)",       size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/de/de_DE/thorsten/low/de_DE-thorsten-low.onnx" },
    { id = "fr_FR-siwis-low",     name = "Siwis (French, low)",          size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/fr/fr_FR/siwis/low/fr_FR-siwis-low.onnx" },
    { id = "pt_BR-faber-medium",  name = "Faber (Portuguese BR, medium)",size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/pt/pt_BR/faber/medium/pt_BR-faber-medium.onnx" },
}

--[[--
Detect which download tool is available.
@return string|nil  "curl", "wget", or nil
--]]
function Downloader:_detectTool()
    local h = io.popen("which curl 2>/dev/null")
    if h then
        local r = h:read("*a"):gsub("%s+", "")
        h:close()
        if r ~= "" then return "curl" end
    end
    h = io.popen("which wget 2>/dev/null")
    if h then
        local r = h:read("*a"):gsub("%s+", "")
        h:close()
        if r ~= "" then return "wget" end
    end
    return nil
end

--[[--
Build a shell command to download a URL to a destination file.
@param url string
@param dest string  Absolute destination file path
@param tool string  "curl" or "wget"
@return string
--]]
function Downloader:_buildCmd(url, dest, tool)
    if tool == "curl" then
        -- -L follows redirects, -f fails silently on HTTP errors,
        -- --progress-bar gives visual feedback when run in foreground
        return string.format('curl -Lf -o "%s" "%s" 2>&1', dest, url)
    else
        -- BusyBox wget: -O output, -q quiet, -c continue
        return string.format('wget -q -c -O "%s" "%s" 2>&1', dest, url)
    end
end

--[[--
Download a file with optional progress reporting.
@param url string
@param dest string  Absolute destination path
@param on_progress function(done_bytes, total_bytes) — optional
@param on_complete function(success, err_msg) — required
--]]
function Downloader:download(url, dest, on_progress, on_complete)
    local tool = self:_detectTool()
    if not tool then
        if on_complete then
            on_complete(false, _("No download tool found.\nInstall curl or wget on your device."))
        end
        return
    end

    -- Ensure destination directory exists
    local dir = dest:match("^(.+)/[^/]+$")
    if dir then
        os.execute(string.format('mkdir -p "%s"', dir))
    end

    local cmd = self:_buildCmd(url, dest, tool)
    logger.warn("Downloader: starting download via", tool, ":", url)

    -- Launch in background so UI stays responsive
    local bg_cmd = string.format('(%s; echo $? > "%s.exit") &', cmd, dest)
    os.execute(bg_cmd)

    local start_time = UIManager:getTime()
    local last_size = 0
    local poll_count = 0

    local function poll()
        poll_count = poll_count + 1
        -- Check for completion marker
        local ef = io.open(dest .. ".exit", "r")
        if ef then
            local code = ef:read("*a"):gsub("%s+", "")
            ef:close()
            os.remove(dest .. ".exit")
            if code == "0" then
                logger.warn("Downloader: finished", dest)
                if on_complete then on_complete(true, nil) end
            else
                logger.err("Downloader: failed, exit code", code)
                os.remove(dest)
                if on_complete then
                    on_complete(false, _("Download failed (server or network error)."))
                end
            end
            return
        end

        -- Report progress via file size
        if on_progress then
            local sf = io.open(dest, "r")
            if sf then
                sf:seek("end")
                local size = sf:seek()
                sf:close()
                if size > last_size then
                    last_size = size
                    on_progress(size, nil)
                end
            end
        end

        -- Timeout after 10 minutes
        if time.to_ms(UIManager:getTime() - start_time) > 600000 then
            logger.err("Downloader: timed out after 10 min")
            os.execute(string.format('rm -f "%s" "%s.exit"', dest, dest))
            if on_complete then on_complete(false, _("Download timed out after 10 minutes.")) end
            return
        end

        UIManager:scheduleIn(1.0, poll)
    end

    UIManager:scheduleIn(1.0, poll)
end

--[[--
Extract a .tar.gz or .zip file to a destination directory.
@param archive string  Path to archive
@param dest_dir string  Destination directory
@param on_complete function(success, err_msg)
--]]
function Downloader:extract(archive, dest_dir, on_complete)
    os.execute(string.format('mkdir -p "%s"', dest_dir))

    local cmd
    if archive:match("%.tar%.gz$") or archive:match("%.tgz$") then
        cmd = string.format('tar xzf "%s" -C "%s" 2>&1', archive, dest_dir)
    elseif archive:match("%.zip$") then
        cmd = string.format('unzip -o "%s" -d "%s" 2>&1', archive, dest_dir)
    else
        if on_complete then
            on_complete(false, _("Unknown archive format."))
        end
        return
    end

    logger.warn("Downloader: extracting", archive, "to", dest_dir)
    local h = io.popen(cmd .. "; echo $?")
    if h then
        local out = h:read("*a") or ""
        h:close()
        local code = out:match("(%d+)%s*$") or "1"
        if code == "0" then
            os.remove(archive)
            if on_complete then on_complete(true, nil) end
        else
            logger.err("Downloader: extract failed:", out:sub(1, 200))
            if on_complete then
                on_complete(false, _("Extraction failed."))
            end
        end
    else
        if on_complete then on_complete(false, _("Could not run extractor.")) end
    end
end

--[[--
Download a Piper voice model (.onnx + .json).
@param voice_id string  e.g. "en_US-danny-low"
@param plugin_dir string
@param on_progress function(done_bytes, total_bytes)
@param on_complete function(success, err_msg)
--]]
function Downloader:downloadPiperVoice(voice_id, plugin_dir, on_progress, on_complete)
    local voice = nil
    for _, v in ipairs(self.PIPER_VOICES) do
        if v.id == voice_id then
            voice = v
            break
        end
    end
    if not voice then
        if on_complete then on_complete(false, _("Unknown voice.")) end
        return
    end

    local piper_dir = plugin_dir .. "/piper"
    os.execute(string.format('mkdir -p "%s"', piper_dir))

    local onnx_url = voice.url
    local json_url = voice.url .. ".json"
    local onnx_dest = piper_dir .. "/" .. voice_id .. ".onnx"
    local json_dest = piper_dir .. "/" .. voice_id .. ".onnx.json"

    -- Download ONNX model
    self:download(onnx_url, onnx_dest, on_progress, function(ok, err)
        if not ok then
            if on_complete then on_complete(false, err) end
            return
        end
        -- Download JSON config (small, synchronous is fine)
        local tool = self:_detectTool()
        if tool then
            local cmd = self:_buildCmd(json_url, json_dest, tool)
            os.execute(cmd)
        end
        logger.warn("Downloader: Piper voice", voice_id, "installed")
        if on_complete then on_complete(true, nil) end
    end)
end

--[[--
Check whether a Piper voice model is installed.
@param voice_id string
@param plugin_dir string
@return boolean
--]]
function Downloader:hasPiperVoice(voice_id, plugin_dir)
    local f = io.open(plugin_dir .. "/piper/" .. voice_id .. ".onnx", "r")
    if f then f:close(); return true end
    return false
end

return Downloader
