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
local _ = require("gettext")

local Downloader = {}

-- Known Piper voices from the rhasspy/piper-voices HuggingFace repository.
-- Place custom .onnx files in plugins/audiobook.koplugin/piper/ to use voices
-- not listed here.
Downloader.PIPER_VOICES = {
    -- English (US)
    { id = "en_US-danny-low",      name = "Danny (US English, low)",       size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/danny/low/en_US-danny-low.onnx" },
    { id = "en_US-danny-medium",   name = "Danny (US English, medium)",    size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/danny/medium/en_US-danny-medium.onnx" },
    { id = "en_US-ryan-low",       name = "Ryan (US English, low)",        size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/ryan/low/en_US-ryan-low.onnx" },
    { id = "en_US-ryan-medium",    name = "Ryan (US English, medium)",     size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/ryan/medium/en_US-ryan-medium.onnx" },
    { id = "en_US-amy-low",        name = "Amy (US English, low)",         size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/amy/low/en_US-amy-low.onnx" },
    { id = "en_US-amy-medium",     name = "Amy (US English, medium)",      size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/amy/medium/en_US-amy-medium.onnx" },
    { id = "en_US-lessac-low",     name = "Lessac (US English, low)",      size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/low/en_US-lessac-low.onnx" },
    { id = "en_US-lessac-medium",  name = "Lessac (US English, medium)",   size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx" },
    { id = "en_US-ljspeech-low",   name = "LJSpeech (US English, low)",    size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/ljspeech/low/en_US-ljspeech-low.onnx" },
    { id = "en_US-ljspeech-medium",name = "LJSpeech (US English, medium)", size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/ljspeech/medium/en_US-ljspeech-medium.onnx" },
    { id = "en_US-arctic-medium",  name = "Arctic (US English, medium)",   size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/arctic/medium/en_US-arctic-medium.onnx" },
    { id = "en_US-bryce-medium",   name = "Bryce (US English, medium)",    size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/bryce/medium/en_US-bryce-medium.onnx" },
    { id = "en_US-john-medium",    name = "John (US English, medium)",     size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/john/medium/en_US-john-medium.onnx" },
    { id = "en_US-kristin-medium", name = "Kristin (US English, medium)",  size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/kristin/medium/en_US-kristin-medium.onnx" },
    -- English (GB)
    { id = "en_GB-semaine-medium", name = "Semaine (GB English, medium)",  size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/semaine/medium/en_GB-semaine-medium.onnx" },
    { id = "en_GB-alan-low",       name = "Alan (GB English, low)",        size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/alan/low/en_GB-alan-low.onnx" },
    { id = "en_GB-alan-medium",    name = "Alan (GB English, medium)",     size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/alan/medium/en_GB-alan-medium.onnx" },
    { id = "en_GB-alba-medium",    name = "Alba (GB English, medium)",     size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/alba/medium/en_GB-alba-medium.onnx" },
    { id = "en_GB-southern_english_female-low", name = "Southern English Female (GB, low)", size_mb = 15, url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/southern_english_female/low/en_GB-southern_english_female-low.onnx" },
    -- Spanish
    { id = "es_ES-sharvard-medium",name = "Sharvard (Spanish, medium)",    size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/es/es_ES/sharvard/medium/es_ES-sharvard-medium.onnx" },
    { id = "es_ES-carlfm-low",     name = "Carlfm (Spanish, low)",         size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/es/es_ES/carlfm/low/es_ES-carlfm-low.onnx" },
    { id = "es_ES-carlfm-medium",  name = "Carlfm (Spanish, medium)",      size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/es/es_ES/carlfm/medium/es_ES-carlfm-medium.onnx" },
    { id = "es_ES-mls_10246-low",  name = "MLS 10246 (Spanish, low)",      size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/es/es_ES/mls_10246/low/es_ES-mls_10246-low.onnx" },
    { id = "es_ES-mls_9972-low",   name = "MLS 9972 (Spanish, low)",       size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/es/es_ES/mls_9972/low/es_ES-mls_9972-low.onnx" },
    -- German
    { id = "de_DE-thorsten-low",   name = "Thorsten (German, low)",        size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/de/de_DE/thorsten/low/de_DE-thorsten-low.onnx" },
    { id = "de_DE-thorsten-medium",name = "Thorsten (German, medium)",     size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/de/de_DE/thorsten/medium/de_DE-thorsten-medium.onnx" },
    { id = "de_DE-eva_k-low",      name = "Eva K (German, low)",           size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/de/de_DE/eva_k/low/de_DE-eva_k-low.onnx" },
    { id = "de_DE-eva_k-medium",   name = "Eva K (German, medium)",        size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/de/de_DE/eva_k/medium/de_DE-eva_k-medium.onnx" },
    { id = "de_DE-karlsson-low",   name = "Karlsson (German, low)",        size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/de/de_DE/karlsson/low/de_DE-karlsson-low.onnx" },
    { id = "de_DE-karlsson-medium",name = "Karlsson (German, medium)",     size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/de/de_DE/karlsson/medium/de_DE-karlsson-medium.onnx" },
    { id = "de_DE-pavoque-low",    name = "Pavoque (German, low)",         size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/de/de_DE/pavoque/low/de_DE-pavoque-low.onnx" },
    { id = "de_DE-pavoque-medium", name = "Pavoque (German, medium)",      size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/de/de_DE/pavoque/medium/de_DE-pavoque-medium.onnx" },
    { id = "de_DE-ramona-low",     name = "Ramona (German, low)",          size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/de/de_DE/ramona/low/de_DE-ramona-low.onnx" },
    { id = "de_DE-ramona-medium",  name = "Ramona (German, medium)",       size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/de/de_DE/ramona/medium/de_DE-ramona-medium.onnx" },
    -- French
    { id = "fr_FR-siwis-low",      name = "Siwis (French, low)",           size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/fr/fr_FR/siwis/low/fr_FR-siwis-low.onnx" },
    { id = "fr_FR-siwis-medium",   name = "Siwis (French, medium)",        size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/fr/fr_FR/siwis/medium/fr_FR-siwis-medium.onnx" },
    { id = "fr_FR-gilles-low",     name = "Gilles (French, low)",          size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/fr/fr_FR/gilles/low/fr_FR-gilles-low.onnx" },
    { id = "fr_FR-gilles-medium",  name = "Gilles (French, medium)",       size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/fr/fr_FR/gilles/medium/fr_FR-gilles-medium.onnx" },
    { id = "fr_FR-mls_1840-low",   name = "MLS 1840 (French, low)",        size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/fr/fr_FR/mls_1840/low/fr_FR-mls_1840-low.onnx" },
    -- Portuguese (Brazil)
    { id = "pt_BR-faber-medium",   name = "Faber (Portuguese BR, medium)", size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/pt/pt_BR/faber/medium/pt_BR-faber-medium.onnx" },
    { id = "pt_BR-edresson-low",   name = "Edresson (Portuguese BR, low)", size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/pt/pt_BR/edresson/low/pt_BR-edresson-low.onnx" },
    -- Italian
    { id = "it_IT-paola-medium",   name = "Paola (Italian, medium)",       size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/it/it_IT/paola/medium/it_IT-paola-medium.onnx" },
    { id = "it_IT-riccardo-x-low", name = "Riccardo (Italian, low)",       size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/it/it_IT/riccardo/low/it_IT-riccardo-x-low.onnx" },
    -- Dutch
    { id = "nl_NL-mls_5809-low",   name = "MLS 5809 (Dutch, low)",         size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/nl/nl_NL/mls_5809/low/nl_NL-mls_5809-low.onnx" },
    { id = "nl_NL-mls_7432-low",   name = "MLS 7432 (Dutch, low)",         size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/nl/nl_NL/mls_7432/low/nl_NL-mls_7432-low.onnx" },
    -- Polish
    { id = "pl_PL-darkman-medium", name = "Darkman (Polish, medium)",      size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/pl/pl_PL/darkman/medium/pl_PL-darkman-medium.onnx" },
    { id = "pl_PL-gosia-medium",   name = "Gosia (Polish, medium)",        size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/pl/pl_PL/gosia/medium/pl_PL-gosia-medium.onnx" },
    { id = "pl_PL-mc_speech-medium",name = "MC Speech (Polish, medium)",   size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/pl/pl_PL/mc_speech/medium/pl_PL-mc_speech-medium.onnx" },
    { id = "pl_PL-mls_6892-low",   name = "MLS 6892 (Polish, low)",        size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/pl/pl_PL/mls_6892/low/pl_PL-mls_6892-low.onnx" },
    -- Czech
    { id = "cs_CZ-jirka-low",      name = "Jirka (Czech, low)",            size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/cs/cs_CZ/jirka/low/cs_CZ-jirka-low.onnx" },
    { id = "cs_CZ-jirka-medium",   name = "Jirka (Czech, medium)",         size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/cs/cs_CZ/jirka/medium/cs_CZ-jirka-medium.onnx" },
    -- Ukrainian
    { id = "uk_UA-lada-medium",    name = "Lada (Ukrainian, medium)",      size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/uk/uk_UA/lada/medium/uk_UA-lada-medium.onnx" },
    -- Finnish
    { id = "fi_FI-harri-low",      name = "Harri (Finnish, low)",          size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/fi/fi_FI/harri/low/fi_FI-harri-low.onnx" },
    { id = "fi_FI-harri-medium",   name = "Harri (Finnish, medium)",       size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/fi/fi_FI/harri/medium/fi_FI-harri-medium.onnx" },
    -- Russian
    { id = "ru_RU-irina-medium",   name = "Irina (Russian, medium)",       size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/ru/ru_RU/irina/medium/ru_RU-irina-medium.onnx" },
    -- Greek
    { id = "el_GR-rapunzelina-low",name = "Rapunzelina (Greek, low)",      size_mb = 15,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/el/el_GR/rapunzelina/low/el_GR-rapunzelina-low.onnx" },
    -- Norwegian
    { id = "no_NO-talesyntese-medium", name = "Talesyntese (Norwegian, medium)", size_mb = 60, url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/no/no_NO/talesyntese/medium/no_NO-talesyntese-medium.onnx" },
    -- Swedish
    { id = "sv_SE-nst-medium",     name = "NST (Swedish, medium)",         size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/sv/sv_SE/nst/medium/sv_SE-nst-medium.onnx" },
    -- Turkish
    { id = "tr_TR-dfki-medium",    name = "DFKI (Turkish, medium)",        size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/tr/tr_TR/dfki/medium/tr_TR-dfki-medium.onnx" },
    -- Hungarian
    { id = "hu_HU-anna-medium",    name = "Anna (Hungarian, medium)",      size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/hu/hu_HU/anna/medium/hu_HU-anna-medium.onnx" },
    -- Romanian
    { id = "ro_RO-mihai-medium",   name = "Mihai (Romanian, medium)",      size_mb = 60,  url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/ro/ro_RO/mihai/medium/ro_RO-mihai-medium.onnx" },
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
    for _, v in ipairs(self:getPiperVoiceList(plugin_dir)) do
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

-- ── Hybrid voice list (cached + online refresh) ──────────────────────
-- URL of the voices.json on the master branch (raw GitHub content).
Downloader.VOICES_JSON_URL = "https://raw.githubusercontent.com/stradichenko/audiobook.koplugin/master/voices.json"

--[[--
Return the effective Piper voice list.
1. If a cached voices.json exists in plugin_dir/piper/voices_cache.json,
   parse and return it.
2. Otherwise fall back to the built-in PIPER_VOICES table.
@return table  Array of voice entries {id, name, size_mb, url}
--]]
function Downloader:getPiperVoiceList(plugin_dir)
    local cache_path = plugin_dir .. "/piper/voices_cache.json"
    local cf = io.open(cache_path, "r")
    if cf then
        local content = cf:read("*a")
        cf:close()
        if content and #content > 0 then
            local JSON = require("json")
            local ok, voices = pcall(JSON.decode, content)
            if ok and type(voices) == "table" and #voices > 0 then
                logger.dbg("Downloader: using cached voice list (", #voices, "voices)")
                return voices
            else
                logger.warn("Downloader: cached voice list invalid, using built-in")
            end
        end
    end
    logger.dbg("Downloader: using built-in voice list (", #self.PIPER_VOICES, "voices)")
    return self.PIPER_VOICES
end

--[[--
Fetch the latest voice list from the internet and cache it locally.
@param plugin_dir string
@param callback function(success, voices_or_err_msg)
--]]
function Downloader:refreshVoiceList(plugin_dir, callback)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socketutil = require("socketutil")
    local JSON = require("json")

    local sink = {}
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_BLOCK_TIMEOUT)
    local code, headers, status = require("socket").skip(1, http.request{
        url = self.VOICES_JSON_URL,
        method = "GET",
        headers = {
            ["User-Agent"] = "audiobook.koplugin-downloader",
        },
        sink = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()

    if code ~= 200 then
        logger.warn("Downloader: voice list fetch failed, code=", code, "status=", status)
        if callback then callback(false, T(_("Failed to fetch voice list (HTTP %1)"), tostring(code or status or "no response"))) end
        return
    end

    local body = table.concat(sink)
    local ok, voices = pcall(JSON.decode, body)
    if not ok or type(voices) ~= "table" or #voices == 0 then
        logger.warn("Downloader: voice list JSON parse failed:", tostring(voices))
        if callback then callback(false, _("Failed to parse voice list.")) end
        return
    end

    -- Cache the fetched list
    local piper_dir = plugin_dir .. "/piper"
    os.execute(string.format('mkdir -p "%s"', piper_dir))
    local cache_path = piper_dir .. "/voices_cache.json"
    local cf = io.open(cache_path, "w")
    if cf then
        cf:write(body)
        cf:close()
        logger.warn("Downloader: cached", #voices, "voices to", cache_path)
    else
        logger.warn("Downloader: could not write voice cache to", cache_path)
    end

    if callback then callback(true, voices) end
end

return Downloader
