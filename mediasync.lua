--[[--
MediaSync Controller -- Synchronization loop for pre-recorded audio playback.
Maps audio time position to text positions for synchronized highlighting.
Mirrors SyncController patterns but without TTS synthesis or sentence prefetch.

@module koplugin.audiobook.mediasync
--]]

local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local Screen = require("device").screen
local time = require("ui/time")
local _ = require("gettext")

local _utils_dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
local PLUGIN_PATH = _utils_dir

local MediaSync = {
    STATE = {
        STOPPED = "stopped",
        PLAYING = "playing",
        PAUSED = "paused",
        LOADING = "loading",
    },
}

function MediaSync:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self

    o.state = self.STATE.STOPPED
    o.timing_data = nil
    o.chapters = nil
    o.playback_bar = nil

    -- Current playback position tracking
    o._current_sentence_idx = 0
    o._current_word_idx = 0
    o._total_sentences = 0
    o._sync_timer = nil
    o._position_timer = nil
    o._chain_generation = 0

    -- UI update throttling
    o._last_progress_pct = -1
    o._last_ui_update_time = nil

    return o
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function MediaSync:start(audio_path, timing_data, chapters, cover_path)
    if self.state == self.STATE.PLAYING or self.state == self.STATE.PAUSED then
        self:stop()
    end

    if not audio_path or not timing_data or #timing_data == 0 then
        logger.err("MediaSync: start() called without valid audio or timing data")
        return false
    end

    self.state = self.STATE.LOADING
    self.timing_data = timing_data
    self.chapters = chapters or {}
    self.cover_path = cover_path
    self._current_sentence_idx = 1
    self._current_word_idx = 1
    self._chain_generation = self._chain_generation + 1
    self._last_progress_pct = -1
    self._last_ui_update_time = nil

    -- Build sentence index from timing data
    self:_buildSentenceIndex()

    -- Load and play audio
    if not self.media_engine:load(audio_path) then
        logger.err("MediaSync: failed to load audio", audio_path)
        self.state = self.STATE.STOPPED
        return false
    end

    -- Show playback bar in scrubber mode
    self:showPlaybackBar()

    local gen = self._chain_generation
    local ok = self.media_engine:play(
        function() self:_onPlaybackComplete(gen) end,
        function(err) self:_onPlaybackFail(gen, err) end
    )

    if not ok then
        logger.err("MediaSync: media_engine:play() failed")
        self.state = self.STATE.STOPPED
        return false
    end

    self.state = self.STATE.PLAYING
    self:_startSyncLoop(gen)
    self:_startPositionPoller(gen)

    logger.warn("MediaSync: started playback, sentences=", self._total_sentences,
        "duration=", self.media_engine:getDuration())
    return true
end

function MediaSync:stop()
    local was_playing = self.state ~= self.STATE.STOPPED
    self.state = self.STATE.STOPPED
    self._chain_generation = self._chain_generation + 1

    if self._sync_timer then
        UIManager:unschedule(self._sync_timer)
        self._sync_timer = nil
    end
    if self._position_timer then
        UIManager:unschedule(self._position_timer)
        self._position_timer = nil
    end

    if self.media_engine then
        pcall(function() self.media_engine:stop() end)
    end
    if self.highlight_manager then
        pcall(function() self.highlight_manager:clearHighlights() end)
    end
    if self.playback_bar then
        pcall(function() self.playback_bar:hide() end)
    end

    if was_playing then
        logger.warn("MediaSync: stopped")
    end
end

function MediaSync:pause(auto)
    if self.state ~= self.STATE.PLAYING then return end
    self.state = self.STATE.PAUSED
    if self.media_engine then
        pcall(function() self.media_engine:pause() end)
    end
    if self.playback_bar then
        pcall(function() self.playback_bar:setPlaying(false) end)
    end
    logger.dbg("MediaSync: paused", auto and "(auto)" or "")
end

function MediaSync:resume(auto)
    if self.state ~= self.STATE.PAUSED then return end
    self.state = self.STATE.PLAYING
    if self.media_engine then
        pcall(function() self.media_engine:resume() end)
    end
    if self.playback_bar then
        pcall(function() self.playback_bar:setPlaying(true) end)
    end
    logger.dbg("MediaSync: resumed", auto and "(auto)" or "")
end

function MediaSync:isPlaying()
    return self.state == self.STATE.PLAYING
end

function MediaSync:isPaused()
    return self.state == self.STATE.PAUSED
end

function MediaSync:setSpeed(speed)
    if self.media_engine then
        pcall(function() self.media_engine:setSpeed(speed) end)
    end
    if self.playback_bar then
        pcall(function() self.playback_bar:updateSpeed(speed) end)
    end
end

-- ---------------------------------------------------------------------------
-- Navigation
-- ---------------------------------------------------------------------------

function MediaSync:seekToTime(seconds)
    if not self.media_engine then return end
    logger.warn("MediaSync: seekToTime", seconds)
    self.media_engine:seek(seconds, "absolute")
    -- Force immediate UI update so the bar doesn't wait for the next poller tick
    if self.playback_bar then
        local dur = self.media_engine:getDuration() or 0
        if dur > 0 then
            local pct = math.floor((seconds / dur) * 100)
            self._last_progress_pct = pct
            pcall(function()
                self.playback_bar:updateProgress(pct)
                self.playback_bar:updateTimeDisplay(seconds, dur)
            end)
        end
    end
end

function MediaSync:seekToChapter(index)
    if not self.chapters or not self.chapters[index] then return end
    local ch = self.chapters[index]
    logger.warn("MediaSync: seekToChapter", index, ch.title, "@", ch.start_time)
    self:seekToTime(ch.start_time)
end

function MediaSync:nextSentence()
    if not self.timing_data then return end
    local idx = self._current_sentence_idx + 1
    if idx > #self.timing_data then
        -- At end; seek to last sentence start or just seek forward 5s
        self.media_engine:seek(5, "relative")
        return
    end
    self:seekToTime(self.timing_data[idx].start_time)
end

function MediaSync:skipBack(seconds)
    seconds = seconds or 30
    if not self.media_engine then return end
    self.media_engine:seek(-seconds, "relative")
end

function MediaSync:skipForward(seconds)
    seconds = seconds or 30
    if not self.media_engine then return end
    self.media_engine:seek(seconds, "relative")
end

function MediaSync:prevSentence()
    if not self.timing_data then return end
    local idx = self._current_sentence_idx - 1
    if idx < 1 then idx = 1 end
    self:seekToTime(self.timing_data[idx].start_time)
end

function MediaSync:nextChapter()
    if not self.chapters or #self.chapters == 0 then return end
    local current_time = self.media_engine:getPosition()
    for i, ch in ipairs(self.chapters) do
        if ch.start_time > current_time + 1 then
            self:seekToChapter(i)
            return
        end
    end
end

function MediaSync:prevChapter()
    if not self.chapters or #self.chapters == 0 then return end
    local current_time = self.media_engine:getPosition()
    for i = #self.chapters, 1, -1 do
        if self.chapters[i].start_time < current_time - 1 then
            self:seekToChapter(i)
            return
        end
    end
end

-- ---------------------------------------------------------------------------
-- Internal: sentence index
-- ---------------------------------------------------------------------------

function MediaSync:_buildSentenceIndex()
    -- timing_data is already sentence-level from parser/aligner.
    -- Each entry: {start_time, end_time, text, xpointer, words?}
    self._total_sentences = #self.timing_data
    -- Sort by start_time just in case
    table.sort(self.timing_data, function(a, b)
        return a.start_time < b.start_time
    end)
end

-- ---------------------------------------------------------------------------
-- Internal: sync loop (20Hz)
-- ---------------------------------------------------------------------------

function MediaSync:_startSyncLoop(gen)
    local function tick()
        if self._chain_generation ~= gen or self.state ~= self.STATE.PLAYING then
            return
        end

        local ok, pos = pcall(function() return self.media_engine:getPosition() end)
        if not ok then
            logger.err("MediaSync: getPosition() error in sync loop:", pos)
            self._sync_timer = UIManager:scheduleIn(0.05, tick)
            return
        end

        self:_updateHighlightAtTime(pos)

        -- Check for sentence/chapter boundary advancement
        self:_checkAutoAdvance(pos)

        self._sync_timer = UIManager:scheduleIn(0.05, tick)
    end

    self._sync_timer = UIManager:scheduleIn(0.05, tick)
end

function MediaSync:_updateHighlightAtTime(pos)
    if not self.timing_data then return end

    -- Find current sentence by binary search on start_time
    local sent_idx = self:_findSentenceAtTime(pos)
    if not sent_idx then return end

    local sentence = self.timing_data[sent_idx]
    if not sentence then return end

    -- Update sentence highlight if changed
    if sent_idx ~= self._current_sentence_idx then
        self._current_sentence_idx = sent_idx
        self._current_word_idx = 1
        if self.highlight_manager and sentence.text then
            -- Build a synthetic sentence object for HighlightManager
            local sent_obj = {
                text = sentence.text,
                start_pos = sentence.start_pos or 0,
                end_pos = sentence.end_pos or #sentence.text,
            }
            pcall(function()
                self.highlight_manager:highlightSentence(sent_obj, {sentences = {sent_obj}})
            end)
        end
    end

    -- Find current word within sentence (if word-level timing available)
    if sentence.words and #sentence.words > 0 then
        local word_idx = self:_findWordAtTime(sentence.words, pos)
        if word_idx and word_idx ~= self._current_word_idx then
            self._current_word_idx = word_idx
            local word = sentence.words[word_idx]
            if self.highlight_manager and word then
                pcall(function()
                    self.highlight_manager:highlightWord(word, {sentences = {sentence}})
                end)
            end
            -- Update playback bar word display (only in non-scrubber mode)
            if self.playback_bar and not self.playback_bar.scrubber_mode then
                pcall(function()
                    self.playback_bar:updateCurrentWord(word.text or "")
                end)
            end
        end
    end
end

function MediaSync:_findSentenceAtTime(pos)
    local data = self.timing_data
    local lo, hi = 1, #data
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local entry = data[mid]
        if pos >= entry.start_time and pos < entry.end_time then
            return mid
        elseif pos < entry.start_time then
            hi = mid - 1
        else
            lo = mid + 1
        end
    end
    -- If past the end, return last sentence
    if pos >= data[#data].end_time then
        return #data
    end
    -- If before the beginning, return first
    if pos < data[1].start_time then
        return 1
    end
    return nil
end

function MediaSync:_findWordAtTime(words, pos)
    for i, word in ipairs(words) do
        if pos >= word.start_time and pos < word.end_time then
            return i
        end
    end
    -- Fallback: find closest word
    local closest = 1
    local min_dist = math.huge
    for i, word in ipairs(words) do
        local dist = math.min(
            math.abs(pos - word.start_time),
            math.abs(pos - word.end_time)
        )
        if dist < min_dist then
            min_dist = dist
            closest = i
        end
    end
    return closest
end

function MediaSync:_checkAutoAdvance(pos)
    if not self.timing_data then return end
    local last_sent = self.timing_data[#self.timing_data]
    if not last_sent then return end

    -- If we're past the last sentence end, check if we should auto-advance
    -- (For standalone audio: just stop. For EPUB Media Overlays: advance page.)
    if pos >= last_sent.end_time then
        -- Small grace period to avoid premature stop
        if pos >= last_sent.end_time + 1 then
            -- Check if audio is still playing (might be silence at end)
            if not self.media_engine:isPlaying() then
                self:_onPlaybackComplete(self._chain_generation)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Internal: position poller (UI updates at 1Hz)
-- ---------------------------------------------------------------------------

function MediaSync:_startPositionPoller(gen)
    local function poll()
        if self._chain_generation ~= gen then return end
        if self.state ~= self.STATE.PLAYING and self.state ~= self.STATE.PAUSED then
            return
        end

        local ok_pos, pos = pcall(function() return self.media_engine:getPosition() end)
        if not ok_pos then
            logger.err("MediaSync: getPosition() error in poller:", pos)
            self._position_timer = UIManager:scheduleIn(1.0, poll)
            return
        end

        local ok_dur, dur = pcall(function() return self.media_engine:getDuration() end)
        if not ok_dur then
            logger.err("MediaSync: getDuration() error in poller:", dur)
            self._position_timer = UIManager:scheduleIn(1.0, poll)
            return
        end

        -- Update progress bar
        if dur and dur > 0 and pos then
            local pct = math.floor((pos / dur) * 100)
            if pct ~= self._last_progress_pct then
                self._last_progress_pct = pct
                if self.playback_bar then
                    pcall(function()
                        self.playback_bar:updateProgress(pct)
                    end)
                end
            end
        end

        -- Update time display
        if self.playback_bar then
            pcall(function()
                self.playback_bar:updateTimeDisplay(pos or 0, dur or 0)
            end)
            -- Update chapter title
            local ok_ch, ch = pcall(function() return self:getCurrentChapter() end)
            if ok_ch and ch then
                pcall(function()
                    self.playback_bar:updateChapterTitle(ch.title or "")
                end)
            end
        end

        self._position_timer = UIManager:scheduleIn(1.0, poll)
    end

    self._position_timer = UIManager:scheduleIn(1.0, poll)
end

-- ---------------------------------------------------------------------------
-- Completion / failure callbacks
-- ---------------------------------------------------------------------------

function MediaSync:_onPlaybackComplete(gen)
    if self._chain_generation ~= gen then return end
    logger.warn("MediaSync: playback complete")
    self:stop()
end

function MediaSync:_onPlaybackFail(gen, err)
    if self._chain_generation ~= gen then return end
    logger.err("MediaSync: playback failed:", err)
    self:stop()
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{
        text = _("Audio playback failed: ") .. tostring(err),
        timeout = 3,
    })
end

-- ---------------------------------------------------------------------------
-- Playback bar
-- ---------------------------------------------------------------------------

function MediaSync:showPlaybackBar()
    if self.playback_bar and self.playback_bar:isVisible() then
        return
    end
    -- For standalone audio (scrubber mode), use full-screen AudiobookPlayer overlay
    local AudiobookPlayer = dofile(PLUGIN_PATH .. "audiobookplayer.lua")
    local title = self.timing_data and self.timing_data[1] and self.timing_data[1].text or _("Audiobook")
    -- Derive output name from audio file path
    local output_name = ""
    if self.media_engine and self.media_engine.current_path then
        output_name = self.media_engine.current_path:match("([^/]+)$") or ""
    end

    local player = AudiobookPlayer:new{
        title = title,
        output_name = output_name,
        cover_image_path = self.cover_path,
        ui_widget = self.plugin and self.plugin.ui,
        on_play_pause = function()
            if self.state == self.STATE.PLAYING then
                self:pause()
            elseif self.state == self.STATE.PAUSED then
                self:resume()
            end
        end,
        on_skip_back = function()
            self:skipBack(30)
        end,
        on_skip_forward = function()
            self:skipForward(30)
        end,
        on_prev_chapter = function()
            self:prevChapter()
        end,
        on_next_chapter = function()
            self:nextChapter()
        end,
        on_seek = function(pct)
            local dur = self.media_engine and self.media_engine:getDuration() or 0
            if dur > 0 then
                self:seekToTime(pct * dur)
            end
        end,
        on_minimize = function()
            -- Minimize is handled internally by AudiobookPlayer
            -- (shows mini bar; tap mini bar to restore)
        end,
        on_close = function()
            self:stop()
        end,
        on_chapter_list = function()
            self:showChapterList()
        end,
        on_speed = function()
            -- Cycle speeds: 0.8 → 1.0 → 1.25 → 1.5 → 2.0 → 0.8
            local speeds = {0.8, 1.0, 1.25, 1.5, 2.0}
            local current = self.media_engine and self.media_engine:getSpeed() or 1.0
            local next_speed = speeds[1]
            for i, s in ipairs(speeds) do
                if math.abs(current - s) < 0.01 then
                    next_speed = speeds[i + 1] or speeds[1]
                    break
                end
            end
            self:setSpeed(next_speed)
        end,
    }
    player:show()
    self.playback_bar = player
end

function MediaSync:hidePlaybackBar()
    if self.playback_bar then
        pcall(function() self.playback_bar:hide() end)
        self.playback_bar = nil
    end
end

function MediaSync:showChapterList()
    if not self.chapters or #self.chapters == 0 then
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{
            text = _("No chapters available."),
            timeout = 2,
        })
        return
    end
    local Menu = require("ui/widget/menu")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local menu_items = {}
    for i, ch in ipairs(self.chapters) do
        table.insert(menu_items, {
            text = (ch.title or _("Chapter") .. " " .. i) .. "  (" .. self:_formatTime(ch.start_time) .. ")",
            callback = function()
                UIManager:close(centered_menu)
                self:seekToChapter(i)
            end,
        })
    end
    local menu = Menu:new{
        title = _("Chapters"),
        item_table = menu_items,
        width = Screen:getWidth() * 0.8,
        height = Screen:getHeight() * 0.7,
    }
    local centered_menu = CenterContainer:new{
        dimen = Screen:getSize(),
        menu,
    }
    UIManager:show(centered_menu)
end

-- ---------------------------------------------------------------------------
-- Progress / time queries
-- ---------------------------------------------------------------------------

function MediaSync:getProgress()
    local dur = self.media_engine and self.media_engine:getDuration() or 0
    if dur <= 0 then return 0 end
    local pos = self.media_engine:getPosition()
    return math.floor((pos / dur) * 100)
end

function MediaSync:getCurrentTime()
    local pos = self.media_engine and self.media_engine:getPosition() or 0
    return self:_formatTime(pos)
end

function MediaSync:getTotalTime()
    local dur = self.media_engine and self.media_engine:getDuration() or 0
    return self:_formatTime(dur)
end

function MediaSync:_formatTime(seconds)
    seconds = math.floor(seconds or 0)
    local mins = math.floor(seconds / 60)
    local secs = seconds % 60
    return string.format("%d:%02d", mins, secs)
end

-- ---------------------------------------------------------------------------
-- Chapter queries
-- ---------------------------------------------------------------------------

function MediaSync:getCurrentChapter()
    if not self.chapters or #self.chapters == 0 then return nil end
    local pos = self.media_engine:getPosition()
    for i = #self.chapters, 1, -1 do
        if pos >= self.chapters[i].start_time then
            return self.chapters[i], i
        end
    end
    return self.chapters[1], 1
end

return MediaSync
