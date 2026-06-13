--[[--
EPUB Media Overlay Parser -- Detect, parse, and extract timing data from EPUB 3 Media Overlays.
Uses `unzip` CLI to extract files from the EPUB ZIP archive.
Caches extracted audio to persistent storage (not /tmp, to avoid RAM exhaustion).

@module koplugin.audiobook.epubmediaoverlay
--]]

local logger = require("logger")
local _ = require("gettext")

local EpubMediaOverlay = {}

function EpubMediaOverlay:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o._cache_dir = nil
    o._epub_path = nil
    return o
end

-- ---------------------------------------------------------------------------
-- Utility
-- ---------------------------------------------------------------------------

function EpubMediaOverlay:_fileExists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

function EpubMediaOverlay:_runCommand(cmd)
    local h = io.popen(cmd .. " 2>&1")
    if not h then return nil end
    local out = h:read("*a") or ""
    h:close()
    return out
end

function EpubMediaOverlay:_ensureCacheDir(plugin_dir, epub_path)
    -- Use a hash of the epub path to create a stable cache directory
    local hash = self:_simpleHash(epub_path)
    local cache = plugin_dir .. "/cache/overlays/" .. hash
    os.execute("mkdir -p '" .. cache:gsub("'", "'\\''") .. "'")
    return cache
end

function EpubMediaOverlay:_simpleHash(str)
    -- DJB2 hash -> hex string.
    -- hash * 33 == (hash << 5) + hash, written arithmetically because
    -- LuaJIT is Lua 5.1: the 5.3 bitwise operators do not parse and a
    -- bare `<<` makes this whole module fail to load ("Failed to load
    -- EPUB Media Overlay parser").  Doubles stay exact here: hash is
    -- kept below 2^32, so hash*33 + byte < 2^38, well under 2^53.
    local hash = 5381
    for i = 1, #str do
        hash = (hash * 33 + str:byte(i)) % 4294967296
    end
    return string.format("%08x", hash)
end

function EpubMediaOverlay:_parseTimeToSeconds(time_str)
    -- SMIL clock values: "hh:mm:ss.ms", "mm:ss.ms", "ss.ms", or timecounts
    -- with a metric suffix: "25.180s", "300ms", "2.5min", "1.5h"
    -- (Storyteller emits the "...s" form for clipBegin/clipEnd).
    if not time_str then return 0 end
    time_str = time_str:gsub("^%s*", ""):gsub("%s*$", "")

    -- Timecount with metric suffix
    local num, suffix = time_str:match("^([%d%.]+)(m?s?i?n?h?)$")
    if num and suffix and suffix ~= "" then
        local n = tonumber(num)
        if n then
            if suffix == "s" then return n end
            if suffix == "ms" then return n / 1000 end
            if suffix == "min" then return n * 60 end
            if suffix == "h" then return n * 3600 end
        end
    end

    -- ss.ms format
    local secs = tonumber(time_str:match("^([%d%.]+)$"))
    if secs then return secs end

    -- mm:ss.ms format
    local mm, ss = time_str:match("^(%d+):([%d%.]+)$")
    if mm and ss then
        return tonumber(mm) * 60 + tonumber(ss)
    end

    -- hh:mm:ss.ms format
    local hh, mm2, ss2 = time_str:match("^(%d+):(%d+):([%d%.]+)$")
    if hh and mm2 and ss2 then
        return tonumber(hh) * 3600 + tonumber(mm2) * 60 + tonumber(ss2)
    end

    logger.warn("EpubMediaOverlay: could not parse time:", time_str)
    return 0
end

-- ---------------------------------------------------------------------------
-- EPUB container / OPF parsing
-- ---------------------------------------------------------------------------

function EpubMediaOverlay:_extractFromZip(epub_path, internal_path)
    -- Extract a single file from the EPUB using unzip
    local cmd = string.format(
        'unzip -p "%s" "%s"',
        epub_path:gsub('"', '\\"'),
        internal_path:gsub('"', '\\"')
    )
    return self:_runCommand(cmd)
end

function EpubMediaOverlay:_findOpfPath(epub_path)
    -- Read META-INF/container.xml to find the OPF path
    local container_xml = self:_extractFromZip(epub_path, "META-INF/container.xml")
    if not container_xml or container_xml == "" then
        logger.warn("EpubMediaOverlay: could not read container.xml")
        return nil
    end

    -- Parse container.xml for full-path attribute
    local opf_path = container_xml:match('full%-path%s*=%s*"([^"]+)"')
    if not opf_path then
        -- Try without escaping the hyphen
        opf_path = container_xml:match('full%-path%s*=%s*"([^"]+)"')
    end
    if not opf_path then
        -- Fallback: look for any .opf reference
        opf_path = container_xml:match('href%s*=%s*"([^"]-%.opf)"')
    end

    return opf_path
end

function EpubMediaOverlay:_parseOpfManifest(opf_xml)
    -- Extract manifest items from OPF.
    -- We need: items with media-overlay attributes, and the smil files they reference.
    local manifest = {}
    local manifest_items = {}

    -- Find the manifest section
    local manifest_block = opf_xml:match("<manifest[^>]*>(.-)</manifest>")
    if not manifest_block then
        logger.warn("EpubMediaOverlay: no manifest found in OPF")
        return nil
    end

    -- Parse each item in the manifest.
    -- The character class must allow '/' inside the capture: hrefs are
    -- paths ("text/part0007.html", "MediaOverlays/part0007.smil"), and a
    -- class of [^/>] silently dropped every such item, leaving the
    -- overlay map empty ("no media overlays found") on real books.
    for item_str in manifest_block:gmatch("<item([^>]-)/>") do
        local id = item_str:match('id%s*=%s*"([^"]+)"')
        local href = item_str:match('href%s*=%s*"([^"]+)"')
        local media_type = item_str:match('media%-type%s*=%s*"([^"]+)"')
        local media_overlay = item_str:match('media%-overlay%s*=%s*"([^"]+)"')

        if id and href then
            manifest_items[id] = {
                id = id,
                href = href,
                media_type = media_type,
                media_overlay = media_overlay,
            }
        end
    end

    -- Build overlay mapping: content file -> smil file
    for id, item in pairs(manifest_items) do
        if item.media_overlay then
            local overlay_item = manifest_items[item.media_overlay]
            if overlay_item then
                manifest[id] = {
                    content_id = id,
                    content_href = item.href,
                    smil_href = overlay_item.href,
                }
            end
        end
    end

    return manifest, manifest_items
end

-- ---------------------------------------------------------------------------
-- SMIL parsing
-- ---------------------------------------------------------------------------

function EpubMediaOverlay:_parseSmil(smil_xml, smil_base_path)
    -- Parse a SMIL file and return timing_data entries.
    -- SMIL structure:
    --   <smil>
    --     <body>
    --       <seq epub:textref="chapter.xhtml">
    --         <par>
    --           <text src="chapter.xhtml#id1"/>
    --           <audio src="audio.mp3" clipBegin="0:00:00.000" clipEnd="0:00:05.234"/>
    --         </par>
    --       </seq>
    --     </body>
    --   </smil>
    local timing_data = {}
    -- smil_base_path is already the SMIL file's directory (the caller
    -- strips the filename); taking another dirname here emptied the base
    -- and broke every relative audio src.
    local audio_base = smil_base_path or ""

    -- Find all <par> elements.  gmatch with two captures yields two loop
    -- values; the old single-variable loop bound only the attribute
    -- capture and threw away the body that holds <text>/<audio>.
    for _par_attrs, par_block in smil_xml:gmatch("<par([^>]*)>(.-)</par>") do
        -- Extract text src (match the <text> element specifically; a bare
        -- src= match would also hit <audio src=...>)
        local text_src = par_block:match('<text[^>]-src%s*=%s*"([^"]+)"')
            or par_block:match('src%s*=%s*"([^"]+)"')
        -- Extract audio attributes ('/' must stay allowed in the capture:
        -- src paths contain slashes)
        local audio_block = par_block:match("<audio([^>]-)/>")
        if not audio_block then
            audio_block = par_block:match("<audio(.-)</audio>")
        end

        if audio_block then
            local audio_src = audio_block:match('src%s*=%s*"([^"]+)"')
            local clip_begin = audio_block:match('clipBegin%s*=%s*"([^"]+)"')
            local clip_end = audio_block:match('clipEnd%s*=%s*"([^"]+)"')

            if audio_src then
                -- Resolve relative paths
                local resolved_audio = audio_src
                if audio_src:sub(1, 1) ~= "/" and audio_base ~= "" then
                    resolved_audio = audio_base .. "/" .. audio_src
                end
                -- Collapse "dir/../" segments: SMIL audio srcs are written
                -- relative to the SMIL dir ("../Audio/x.mp3"), but zip
                -- member names ("Audio/x.mp3") contain no dot-dots, so
                -- unzip would find nothing.
                local prev
                repeat
                    prev = resolved_audio
                    resolved_audio = resolved_audio:gsub("[^/]+/%.%./", "", 1)
                until resolved_audio == prev
                resolved_audio = resolved_audio:gsub("^%./", "")

                local start_time = self:_parseTimeToSeconds(clip_begin)
                local end_time = self:_parseTimeToSeconds(clip_end)

                table.insert(timing_data, {
                    text = text_src or "",
                    text_ref = text_src,
                    audio_src = resolved_audio,
                    start_time = start_time,
                    end_time = end_time,
                })
            end
        end
    end

    return timing_data
end

-- ---------------------------------------------------------------------------
-- Audio extraction
-- ---------------------------------------------------------------------------

function EpubMediaOverlay:_extractAudioFile(epub_path, internal_path, cache_dir)
    -- unzip -d preserves directory structure, so the extracted file lives
    -- at cache_dir/internal_path.  Check THAT path first: this function is
    -- called once per SMIL par entry (thousands of times per book, with a
    -- handful of distinct audio files), and the old check against only the
    -- flattened name made every single entry re-extract its multi-MB audio
    -- file from the zip.
    local extracted = cache_dir .. "/" .. internal_path
    if self:_fileExists(extracted) then
        return extracted
    end

    local cache_path = cache_dir .. "/" .. internal_path:gsub("/", "_")
    if self:_fileExists(cache_path) then
        return cache_path
    end

    -- Extract the file
    local cmd = string.format(
        'unzip -o "%s" "%s" -d "%s" >/dev/null 2>&1',
        epub_path:gsub('"', '\\"'),
        internal_path:gsub('"', '\\"'),
        cache_dir:gsub('"', '\\"')
    )
    os.execute(cmd)

    -- The extracted file will be at cache_dir/internal_path
    -- But unzip preserves the directory structure, so we need to find it
    local extracted = cache_dir .. "/" .. internal_path
    if self:_fileExists(extracted) then
        return extracted
    end

    -- Fallback: try flat cache path
    if self:_fileExists(cache_path) then
        return cache_path
    end

    logger.warn("EpubMediaOverlay: failed to extract", internal_path)
    return nil
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function EpubMediaOverlay:loadFromEpub(epub_path, plugin_dir)
    if not epub_path or not plugin_dir then
        return nil, "missing path or plugin_dir"
    end

    self._epub_path = epub_path
    self._cache_dir = self:_ensureCacheDir(plugin_dir, epub_path)

    -- Step 1: Find OPF path
    local opf_path = self:_findOpfPath(epub_path)
    if not opf_path then
        return nil, "could not find OPF"
    end
    logger.dbg("EpubMediaOverlay: OPF path =", opf_path)

    -- Step 2: Parse OPF manifest
    local opf_xml = self:_extractFromZip(epub_path, opf_path)
    if not opf_xml or opf_xml == "" then
        return nil, "could not read OPF"
    end

    local overlay_manifest, manifest_items = self:_parseOpfManifest(opf_xml)
    if not overlay_manifest or not next(overlay_manifest) then
        return nil, "no media overlays found"
    end

    logger.dbg("EpubMediaOverlay: found", self:_tableCount(overlay_manifest), "overlay entries")

    -- Step 3: Parse SMIL files
    local all_timing_data = {}
    local opf_base = opf_path:match("^(.*)/") or ""

    for content_id, overlay_info in pairs(overlay_manifest) do
        local smil_href = overlay_info.smil_href
        if not smil_href then goto continue end

        -- Resolve SMIL path relative to OPF
        local smil_path = smil_href
        if smil_href:sub(1, 1) ~= "/" and opf_base ~= "" then
            smil_path = opf_base .. "/" .. smil_href
        end

        local smil_xml = self:_extractFromZip(epub_path, smil_path)
        if not smil_xml or smil_xml == "" then
            logger.warn("EpubMediaOverlay: could not read SMIL", smil_path)
            goto continue
        end

        local smil_base = smil_path:match("^(.*)/") or ""
        local timing_data = self:_parseSmil(smil_xml, smil_base)

        -- Extract audio files and resolve paths
        for _, entry in ipairs(timing_data) do
            if entry.audio_src then
                local audio_path = self:_extractAudioFile(epub_path, entry.audio_src, self._cache_dir)
                if audio_path then
                    entry.audio_path = audio_path
                end
            end
            table.insert(all_timing_data, entry)
        end

        ::continue::
    end

    if #all_timing_data == 0 then
        return nil, "no timing data extracted"
    end

    -- Sort by start_time
    table.sort(all_timing_data, function(a, b)
        return a.start_time < b.start_time
    end)

    logger.warn("EpubMediaOverlay: loaded", #all_timing_data, "timing entries")
    return all_timing_data
end

function EpubMediaOverlay:getCacheDir()
    return self._cache_dir
end

function EpubMediaOverlay:cleanupOldCaches(plugin_dir, max_age_days)
    max_age_days = max_age_days or 7
    local cache_root = plugin_dir .. "/cache/overlays"
    -- Find directories older than max_age_days and remove them
    local cmd = string.format(
        'find "%s" -maxdepth 1 -type d -mtime +%d -exec rm -rf {} + 2>/dev/null',
        cache_root:gsub('"', '\\"'),
        max_age_days
    )
    os.execute(cmd)
end

function EpubMediaOverlay:_tableCount(t)
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

return EpubMediaOverlay
