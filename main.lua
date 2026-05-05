--[[--
Audiobook TTS Plugin with Word Highlight Sync Read-Along
Provides text-to-speech with synchronized word highlighting.

@module koplugin.audiobook
--]]

-- CRITICAL: Only require() modules that have existed in every KOReader version.
-- If ANY top-level statement throws, KOReader's pcall(dofile, "main.lua") fails
-- and the plugin vanishes from menus entirely -- no error shown to the user.
-- Newer / optional modules (Dispatcher) and plugin dofile() submodules are
-- loaded inside init() where failures are caught and reported gracefully.
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

-- Forward-declared module-level locals.  Populated by init() Phase 1.
-- Every function in this file can reference them as upvalues; they start
-- as nil and become usable after init() succeeds.
local Device, UIManager, InfoMessage, T
local BtUI, BtMediaControl, BugReport, BenchmarkRunner, MenuBuilder, Utils, Updater
local PLUGIN_PATH

local Audiobook = WidgetContainer:extend{
    name = "audiobook",
    is_doc_only = true,
}

function Audiobook:init()
    -- ── Phase 1: Load ancillary modules ─────────────────────────────
    -- These are loaded here (not at module top level) because a failed
    -- top-level require/dofile makes KOReader silently drop the entire
    -- plugin.  Loading them inside init() lets us catch errors and still
    -- show a menu entry with a helpful error message.
    --
    -- The forward-declared module-level locals (Device, UIManager, etc.)
    -- are assigned here.  All functions defined below this point see the
    -- assignments through their upvalue references.
    local load_ok, load_err = pcall(function()
        Device = require("device")
        UIManager = require("ui/uimanager")
        InfoMessage = require("ui/widget/infomessage")
        T = require("ffi/util").template

        -- Resolve plugin directory from self.path (set by KOReader's plugin
        -- loader) with a debug.getinfo fallback for dev/testing.
        local _utils_dir = self.path and (self.path .. "/")
            or debug.getinfo(2, "S").source:match("^@(.*/)[^/]*$")
            or "./"
        PLUGIN_PATH = _utils_dir

        -- Load each submodule independently so a failure in one
        -- (e.g. btui.lua) doesn't prevent BugReport from loading.
        local function try_dofile(path)
            local ok, mod = pcall(dofile, path)
            if ok then return mod end
            logger.warn("Audiobook: failed to load", path, ":", mod)
            return nil
        end
        BtUI = try_dofile(_utils_dir .. "btui.lua")
        BtMediaControl = try_dofile(_utils_dir .. "btmediacontrol.lua")
        BugReport = try_dofile(_utils_dir .. "bugreport.lua")
        BenchmarkRunner = try_dofile(_utils_dir .. "benchmarkrunner.lua")
        MenuBuilder = try_dofile(_utils_dir .. "menubuilder.lua")
        Utils = try_dofile(_utils_dir .. "utils.lua")
    end)
    if not load_ok then
        logger.warn("Audiobook: module loading failed:", load_err)
        self._init_error = tostring(load_err)
        -- Still register the menu so the user sees *something*.
        pcall(function() self.ui.menu:registerToMainMenu(self) end)
        return
    end

    -- ── Phase 2: Register menu and dispatcher actions ───────────────
    -- Register the menu so the plugin always appears, even if heavy
    -- submodule loading (Phase 3) fails.  Callbacks check self._init_ok.
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()

    -- Heavy initialization is wrapped in pcall so a crash in any
    -- submodule (e.g. FFI on Android, missing library) doesn't
    -- prevent the plugin from showing in the menu at all.
    local ok, err = pcall(function() self:_initSubmodules() end)
    if not ok then
        logger.warn("Audiobook: init failed:", err)
        self._init_error = tostring(err)
        return
    end
    self._init_ok = true

    -- Install SleepCover event override so we can prevent device suspend
    -- while audio is playing (when the user enables the setting).
    self:_installSleepCoverOverride()

    -- Add "Read aloud from here" to the text selection / highlight popup.
    -- This appears when the user selects a paragraph or multiple words
    -- (as opposed to the single-word dictionary popup, which is handled
    -- by onDictButtonsReady).
    if self.ui.highlight and self.ui.highlight.addToHighlightDialog then
        self.ui.highlight:addToHighlightDialog("15_read_aloud", function(this)
            return {
                text = _("Read aloud from here"),
                callback = function()
                    if not self._init_ok then
                        self:_showInitError()
                        return
                    end
                    local selected_text = this.selected_text
                    local context = nil
                    if selected_text then
                        context = {
                            pos0 = selected_text.pos0,
                            pos1 = selected_text.pos1,
                        }
                    end
                    this:onClose()
                    UIManager:scheduleIn(0.3, function()
                        local word = selected_text and selected_text.text
                        if word then
                            -- Use the first word for position matching
                            word = word:match("^%s*(%S+)") or word
                        end
                        self:startReadAlongFromWord(word, context)
                    end)
                end,
            }
        end)
    end
end

function Audiobook:_initSubmodules()
    -- ── Orphan cleanup from previous crash/SIGKILL ──
    -- If KOReader was killed (OOM, watchdog, etc.), no Lua cleanup ran.
    -- Kill any orphan processes from the previous session to free the
    -- BT audio socket and reclaim CPU/memory.
    self:_killOrphanProcessesFromPreviousSession()

    -- Load submodules from plugin directory
    local pp = PLUGIN_PATH
    local TextParser = dofile(pp .. "textparser.lua")
    local TTSEngine = dofile(pp .. "ttsengine.lua")
    local HighlightManager = dofile(pp .. "highlightmanager.lua")
    local SyncController = dofile(pp .. "synccontroller.lua")
    self.bt_manager = dofile(pp .. "btmanager.lua")
    
    self.text_parser = TextParser:new()
    self.tts_engine = TTSEngine:new{
        plugin = self,
        plugin_dir = pp:sub(1, -2), -- strip trailing slash
    }
    -- Restore saved TTS backend selection (if user explicitly chose one)
    local saved_backend = self:getSetting("tts_backend", nil)
    if saved_backend then
        self.tts_engine:setBackend(saved_backend)
    end
    -- Restore saved voice settings
    self.tts_engine:setRate(self:getSetting("speech_rate", 1.0))
    self.tts_engine:setPitch(self:getSetting("speech_pitch", 50))
    self.tts_engine:setVolume(self:getSetting("speech_volume", 1.0))
    -- Compose full voice id: base accent + optional variant (e.g. "en-us+f1")
    local voice_base = self:getSetting("tts_voice", "en")
    local voice_variant = self:getSetting("tts_voice_variant", "")
    local full_voice = voice_base
    if voice_variant ~= "" then
        full_voice = voice_base .. "+" .. voice_variant
    end
    self.tts_engine:setVoice(full_voice)
    self.tts_engine:setWordGap(self:getSetting("word_gap", 2))
    self.tts_engine:setClausePause(self:getSetting("clause_pause", 0))
    -- Restore Piper-specific settings
    local piper_model = self:getSetting("piper_model", nil)
    if piper_model then
        self.tts_engine:setPiperModel(piper_model)
    end
    self.tts_engine:setPiperSpeaker(self:getSetting("piper_speaker", 0))
    self.tts_engine._gap_test_mode = self:getSetting("gap_test_mode", false)
    self.highlight_manager = HighlightManager:new{
        plugin = self,
        ui = self.ui,
        style = self:getSetting("highlight_style", "background"),
    }
    self.sync_controller = SyncController:new{
        plugin = self,
        tts_engine = self.tts_engine,
        highlight_manager = self.highlight_manager,
        text_parser = self.text_parser,
    }
end

function Audiobook:onDispatcherRegisterActions()
    local ok, Dispatcher = pcall(require, "dispatcher")
    if not ok then return end
    Dispatcher:registerAction("audiobook_toggle", {
        category = "none",
        event = "AudiobookToggle",
        title = _("Toggle Read-Along"),
        reader = true,
    })
    Dispatcher:registerAction("audiobook_stop", {
        category = "none",
        event = "AudiobookStop",
        title = _("Stop Read-Along"),
        reader = true,
    })
end

function Audiobook:_showInitError()
    if not UIManager or not InfoMessage then
        logger.warn("Audiobook: init failed:", self._init_error or "Unknown error")
        return
    end
    UIManager:show(InfoMessage:new{
        text = _("Audiobook plugin failed to initialize.\n\n") .. (self._init_error or "Unknown error"),
        timeout = 8,
    })
end

function Audiobook:addToMainMenu(menu_items)
    -- If Phase 1 module loading failed, show a minimal error menu.
    -- The full menu references modules (BtUI, MenuBuilder, T) that are nil
    -- when loading fails, so we must not build it.
    -- Check MenuBuilder directly: Phase 1 loads UIManager *before* the
    -- plugin submodules, so UIManager can be set even when loading failed.
    if not MenuBuilder then
        menu_items.audiobook = {
            text = _("Audiobook Read-Along (error)"),
            sorting_hint = "tools",
            sub_item_table = {
                {
                    text = _("Plugin failed to load"),
                    callback = function()
                        logger.warn("Audiobook: init failed:", self._init_error)
                    end,
                    help_text = self._init_error,
                },
                {
                    text = _("Generate bug report"),
                    callback = function()
                        if BugReport then
                            BugReport.menuCallback(self)
                        elseif UIManager and InfoMessage then
                            UIManager:show(InfoMessage:new{
                                text = _("Bug report module failed to load.\n\nRun generate-report.sh via SSH or the terminal emulator instead."),
                                timeout = 10,
                            })
                        end
                    end,
                },
            },
        }
        return
    end

    menu_items.audiobook = {
        text = _("Audiobook Read-Along"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Start reading from current page"),
                callback = function()
                    if not self._init_ok then self:_showInitError(); return end
                    self:startReadAlong()
                end,
            },
            -- ── Bluetooth settings ──
            {
                text = _("Bluetooth settings"),
                sub_item_table = {
                    {
                        text_func = function()
                            return BtUI.btMenuLabel(self)
                        end,
                        sub_item_table_func = function()
                            return BtUI.buildBluetoothMenu(self)
                        end,
                    },
                    {
                        text = _("Headset media buttons"),
                        checked_func = function()
                            return self:getSetting("bt_media_control", true)
                        end,
                        callback = function()
                            self:toggleSetting("bt_media_control", true)
                            if self:getSetting("bt_media_control", true) then
                                BtMediaControl.start(self)
                            else
                                BtMediaControl.stop()
                            end
                        end,
                        help_text = _("When enabled, play/pause/next/prev buttons on a Bluetooth headset or speaker will control TTS playback. The connected device will also show playback status."),
                    },
                    {
                        text_func = function()
                            local val = self:getSetting("bt_disconnect_check", 30)
                            if val == 0 then
                                return _("Disconnect alert: off")
                            end
                            return T(_("Disconnect alert: %1s"), val)
                        end,
                        sub_item_table_func = function()
                            return BtUI.buildBTDisconnectMenu(self)
                        end,
                    },
                },
            },
            -- ── Voice settings ──
            {
                text_func = function()
                    if not self._init_ok then return _("Voice settings") end
                    if self.tts_engine.backend == self.tts_engine.BACKENDS.PIPER then
                        local model_label = self:getSetting("piper_model_label", "default")
                        return T(_("Voice settings (Piper - %1)"), model_label)
                    end
                    local voice_label = self:getSetting("tts_voice_label", "English (GB)")
                    local variant_label = self:getSetting("tts_variant_label", "")
                    if variant_label ~= "" and variant_label ~= "Default (male)" then
                        voice_label = voice_label .. " - " .. variant_label
                    end
                    return T(_("Voice settings (%1)"), voice_label)
                end,
                sub_item_table_func = function()
                    return MenuBuilder.buildVoiceSettingsMenu(self)
                end,
            },
            -- ── General settings ──
            {
                text = _("General settings"),
                sub_item_table = {
                    {
                        text_func = function()
                            if not self._init_ok or not self.tts_engine._wav_play_bin then
                                return _("Audio output (PocketBook): N/A")
                            end
                            local pb_default = self.tts_engine._pb_has_tts_sm and "tts_sm" or ""
                            local dev = self:getSetting("pb_alsa_device", pb_default)
                            local labels = {
                                ["tts_sm"] = _("PocketBook pipeline"),
                                [""] = _("Auto"),
                            }
                            return T(_("Audio output (PocketBook): %1"), labels[dev] or dev)
                        end,
                        sub_item_table_func = function()
                            return MenuBuilder.buildAlsaDeviceMenu(self)
                        end,
                        enabled_func = function()
                            return self._init_ok and self.tts_engine._wav_play_bin ~= nil
                        end,
                        help_text = _("PocketBook devices route audio through different paths depending on firmware. The default works on most devices. Change this only if you hear no sound, distorted sound, or playback at 2-3x speed (known issue on PB631). Each option in the submenu has its own help text describing what to try."),
                    },
                    {
                        text = _("Keep playing when lid is closed"),
                        checked_func = function()
                            return self:getSetting("keep_playing_on_lid_close", false)
                        end,
                        callback = function()
                            self:toggleSetting("keep_playing_on_lid_close", false)
                        end,
                        help_text = _("When enabled, closing the case/cover will not stop audio playback. When disabled (default), playback pauses on lid close and resumes when reopened. Disabling prevents device crashes caused by audio processes running during hardware suspend."),
                    },
                    {
                        text = _("Hide control bar while playing (experimental)"),
                        checked_func = function()
                            return self:getSetting("playback_bar_visibility", "always") == "paused_only"
                        end,
                        callback = function()
                            local cur = self:getSetting("playback_bar_visibility", "always")
                            local new_val = (cur == "paused_only") and "always" or "paused_only"
                            self:setSetting("playback_bar_visibility", new_val)
                            if self.sync_controller and self.sync_controller._applyBarVisibility then
                                self.sync_controller:_applyBarVisibility()
                            end
                        end,
                        help_text = _("Experimental: when enabled, the playback control bar disappears while TTS is playing so the bottom of the page is fully visible for read-along. Pause playback (via tap-to-pause overlay or BT headset button) to bring the bar back."),
                    },
                    {
                        text_func = function()
                            local styles = {
                                background = _("Background"),
                                underline = _("Underline"),
                                box = _("Box"),
                                invert = _("Invert"),
                            }
                            return T(_("Highlight style: %1"), styles[self:getSetting("highlight_style", "background")] or _("Background"))
                        end,
                        sub_item_table_func = function()
                            return MenuBuilder.buildHighlightStyleMenu(self)
                        end,
                    },
                    {
                        text = _("Auto-advance pages"),
                        checked_func = function()
                            return self:getSetting("auto_advance", true)
                        end,
                        callback = function()
                            self:toggleSetting("auto_advance", true)
                        end,
                    },
                    {
                        text = _("Highlight sentences"),
                        checked_func = function()
                            return self:getSetting("highlight_sentences", true)
                        end,
                        callback = function()
                            self:toggleSetting("highlight_sentences", true)
                        end,
                    },
                },
            },
            -- ── Diagnostics ──
            {
                text = _("Generate bug report"),
                callback = function()
                    BugReport.menuCallback(self)
                end,
                help_text = _("Saves a diagnostic report to your device storage. The report contains device model, TTS engine status, and audio configuration — no personal data or book content. Share it when reporting issues on GitHub."),
            },
            {
                text = _("Run device benchmark"),
                callback = function()
                    if not self._init_ok then self:_showInitError(); return end
                    if BenchmarkRunner then
                        BenchmarkRunner.menuCallback(self)
                    end
                end,
                enabled_func = function()
                    return self._init_ok and BenchmarkRunner ~= nil
                end,
                help_text = _("Runs a standardized TTS benchmark on test sentences using each available engine (espeak-ng, Piper). Saves a report you can share on GitHub to help document device performance. Piper tests may take several minutes on slow devices."),
            },
            {
                text = _("Check for updates"),
                callback = function()
                    if not Updater then
                        local ok, mod = pcall(dofile, PLUGIN_PATH .. "/updater.lua")
                        if not ok then
                            local UIManager = require("ui/uimanager")
                            local InfoMessage = require("ui/widget/infomessage")
                            UIManager:show(InfoMessage:new{
                                text = _("Could not load updater module."),
                            })
                            return
                        end
                        Updater = mod
                    end
                    Updater.checkForUpdate(self)
                end,
                help_text = _("Checks GitHub for a newer release. If an update is available, downloads and installs it. Requires Wi-Fi."),
            },
            {
                text = _("About / Debug info"),
                callback = function()
                    local lines = {}
                    -- Plugin version
                    local ok, meta = pcall(dofile, PLUGIN_PATH .. "_meta.lua")
                    if ok and meta then
                        table.insert(lines, T(_("Plugin: Audiobook Read-Along %1"), meta.version or "unknown"))
                    end
                    -- KOReader version
                    local rev = "unknown"
                    local ok_v, Version = pcall(require, "version")
                    if ok_v and Version and Version.getCurrentRevision then
                        rev = Version:getCurrentRevision() or rev
                    else
                        local rev_file = io.open("git-rev", "r")
                        if rev_file then
                            rev = rev_file:read("*l") or rev
                            rev_file:close()
                        end
                    end
                    table.insert(lines, T(_("KOReader: %1"), rev))
                    -- Device info
                    local model = (Device.getDeviceModel and Device:getDeviceModel())
                        or (Device.model or "unknown")
                    local platform = (Device.getPlatform and Device:getPlatform())
                        or (Device.platform or "unknown")
                    table.insert(lines, T(_("Device: %1 (%2)"), model, platform))
                    -- TTS backend
                    local engine = self.tts_engine
                    if engine then
                        local backend_name = engine.backend or "none"
                        local backend_labels = {
                            espeak = "espeak-ng",
                            piper = "Piper",
                            pico = "Pico",
                            flite = "Flite",
                            festival = "Festival",
                            android = "Android",
                        }
                        table.insert(lines, T(_("TTS backend: %1"), backend_labels[backend_name] or backend_name))
                        -- Audio player
                        local player = engine.audio_player_type or "none"
                        table.insert(lines, T(_("Audio player: %1"), player))
                    end
                    -- Plugin directory
                    table.insert(lines, T(_("Plugin path: %1"), PLUGIN_PATH or "unknown"))
                    UIManager:show(InfoMessage:new{
                        text = table.concat(lines, "\n"),
                        timeout = 10,
                    })
                end,
                help_text = _("Shows plugin version, KOReader version, device model, active TTS backend, and audio player. Useful when reporting issues."),
            },
        },
    }
end

--- Hook into dictionary popup to add "Read aloud from here" button
function Audiobook:onDictButtonsReady(dict_popup, buttons)
    if not self._init_ok then return end
    if dict_popup.is_wiki_fullpage then
        return
    end
    
    local plugin = self
    
    -- Add "Read aloud from here" button at the end (below Wikipedia/Search/Close)
    table.insert(buttons, {{
        id = "audiobook_read",
        text = _("Read aloud from here"),
        font_bold = false,
        callback = function()
            local word = dict_popup.word or dict_popup.lookupword
            -- Capture surrounding text context from the highlight selection
            -- so we can find the correct occurrence of the word on the page,
            -- not just the first one.
            local selected_text_context = nil
            if dict_popup.highlight and dict_popup.highlight.selected_text then
                local sel = dict_popup.highlight.selected_text
                -- For CRe docs, pos0 is an xpointer string with an offset;
                -- for paged docs it's a table.  Either way, save the surrounding
                -- selected text or the raw pos0 for position matching.
                selected_text_context = {
                    pos0 = sel.pos0,
                    pos1 = sel.pos1,
                }
            end
            UIManager:close(dict_popup)
            -- Give the dictionary popup and any parent highlight enough time
            -- to fully close and leave the UIManager window stack before we
            -- add the PlaybackBar.  Too short a delay means _isOverlayActive()
            -- still sees stale non-toast widgets and suppresses the bar.
            UIManager:scheduleIn(0.3, function()
                plugin:startReadAlongFromWord(word, selected_text_context)
            end)
        end,
    }})
end

function Audiobook:startReadAlong(text, start_pos)
    if not self._init_ok then self:_showInitError(); return end
    local page_text = text or self:getCurrentPageText()
    if not page_text or page_text == "" then
        UIManager:show(InfoMessage:new{
            text = _("Could not extract text from this page.\n\nThe document format may not be fully supported."),
            timeout = 3,
        })
        return
    end
    
    logger.dbg("Audiobook: Starting read-along with text length:", #page_text)
    
    -- If start position provided, extract text from that point
    if start_pos and start_pos > 1 then
        -- Find the beginning of the sentence containing this word
        local sentence_start = start_pos
        for i = start_pos, 1, -1 do
            local char = page_text:sub(i, i)
            if char:match("[%.%?!]") then
                sentence_start = i + 1
                break
            end
            if i == 1 then
                sentence_start = 1
            end
        end
        
        -- Trim leading whitespace
        while sentence_start <= #page_text and page_text:sub(sentence_start, sentence_start):match("%s") do
            sentence_start = sentence_start + 1
        end
        
        page_text = page_text:sub(sentence_start)
        logger.dbg("Audiobook: Starting from position", sentence_start)
    end
    
    -- Check if TTS engine has a backend
    if not self.tts_engine.backend then
        UIManager:show(InfoMessage:new{
            text = self.tts_engine.backend_error
                or _("No TTS engine found.\n\nPlease install espeak-ng."),
            timeout = 8,
        })
        return
    end

    -- If we're using Bluetooth audio, start a lightweight watcher that
    -- will notify the user if all audio BT devices disconnect while
    -- read-along is active.  This runs infrequently and only while the
    -- plugin is in use to avoid extra battery drain.
    --
    -- Also probe for an audio player now, before synthesis starts, so we
    -- can warn the user immediately if no audio output is available instead
    -- of making them wait through TTS synthesis only to get an error.
    pcall(function()
        if not self.tts_engine.audio_player_type then
            self.tts_engine:findAudioPlayer()
        end
        if self.tts_engine.audio_player_type == "gst-bt" then
            BtUI.startWatcher(self)
            -- Start listening for BT headset media buttons (play/pause/next/prev)
            if self:getSetting("bt_media_control", true) then
                BtMediaControl.start(self)
            end
        end
    end)

    -- Early no-audio warning: if the probe found no usable audio player
    -- and there is no BT device connected, warn before synthesis runs.
    if self.tts_engine._no_real_audio_output and not self.tts_engine._cached_player then
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = _("No audio output device found.\n\nTTS synthesis will run but audio may not play. Start anyway?"),
            ok_text = _("Start"),
            cancel_text = _("Cancel"),
            ok_callback = function()
                pcall(function() BtMediaControl.sendPlaybackStatus("playing") end)
                self.sync_controller:start(page_text)
            end,
        })
        return
    end

    -- Notify BT device that playback is starting
    pcall(function() BtMediaControl.sendPlaybackStatus("playing") end)

    self.sync_controller:start(page_text)
end

function Audiobook:startReadAlongFromWord(word, context)
    if not self._init_ok then self:_showInitError(); return end
    local page_text = self:getCurrentPageText()
    if not page_text or page_text == "" then
        -- Try to get text from the dictionary lookup context instead
        if self.ui.highlight and self.ui.highlight.selected_text then
            local selected = self.ui.highlight.selected_text
            -- Get surrounding context
            if selected.text then
                page_text = selected.text
            end
        end
    end
    
    if not page_text or page_text == "" then
        UIManager:show(InfoMessage:new{
            text = _("Could not retrieve page text. This document type may not be supported yet."),
            timeout = 3,
        })
        return
    end
    
    -- Find the word position in the page text
    local start_pos = nil
    if word then
        -- Escape special pattern chars
        local pattern = word:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")

        -- Helper: find the occurrence of `pattern` in page_text closest to
        -- `target_offset` (a character index into page_text).
        local function find_closest_occurrence(target_offset)
            local best_pos = nil
            local best_dist = math.huge
            local search_start = 1
            while true do
                local found = page_text:find(pattern, search_start)
                if not found then break end
                local dist = math.abs(found - target_offset)
                if dist < best_dist then
                    best_dist = dist
                    best_pos = found
                end
                search_start = found + 1
            end
            return best_pos, best_dist
        end

        -- Primary approach: convert the xpointer to a screen position,
        -- then ask CRe for all text from the top of the page down to that
        -- screen position.  The length of that text is the char offset
        -- into page_text.
        if context and context.pos0 and self.ui.document
                and self.ui.rolling
                and self.ui.document.getScreenPositionFromXPointer then
            local ok, screen_y, screen_x = pcall(
                self.ui.document.getScreenPositionFromXPointer,
                self.ui.document, context.pos0)
            if ok and screen_y then
                local ScreenDev = Device.screen
                -- Clamp screen_y to visible area
                if screen_y < 0 then screen_y = 0 end
                -- Get text from top-left of page to the word's position.
                -- Use the word's screen_x so we stop in the middle of the
                -- line rather than grabbing the whole line.
                local use_x = (screen_x and screen_x > 0) and screen_x or ScreenDev:getWidth()
                local ok2, res = pcall(
                    self.ui.document.getTextFromPositions,
                    self.ui.document,
                    {x = 0, y = 0},
                    {x = use_x, y = screen_y},
                    true)
                if ok2 and res and res.text then
                    local approx_offset = #res.text
                    local best, dist = find_closest_occurrence(approx_offset)
                    if best then
                        start_pos = best
                        logger.warn("Audiobook: Found word '", word,
                            "' via screen-pos at", start_pos,
                            "(approx_offset=", approx_offset,
                            "screen_y=", screen_y, "dist=", dist, ")")
                    end
                end
            end
        end

        -- Final fallback: first occurrence
        if not start_pos then
            start_pos = page_text:find(pattern)
            logger.warn("Audiobook: Found word '", word, "' via first-occurrence at", start_pos)
        end
    end
    
    -- If we couldn't find the word, just start from beginning
    if not start_pos then
        logger.warn("Audiobook: Word not found, starting from beginning")
        start_pos = 1
    end
    
    -- Start reading from the found position
    self:startReadAlong(page_text, start_pos)
end

--[[--
Kill orphan processes from a previous KOReader session that was SIGKILL'd.
Checks for PID files and known process names left behind when cleanup
didn't run (OOM kill, watchdog, hard reboot).
Called once at plugin init — idempotent and safe when no orphans exist.
--]]
function Audiobook:_killOrphanProcessesFromPreviousSession()
    -- These orphan cleanup commands (pgrep, killall, pkill) are Linux-specific
    -- and don't exist on Android.  Skip entirely on Android.
    if Device:isAndroid() then return end

    local dominated = false

    -- 1. Kill orphan gst-launch-1.0 (frees the exclusive BT A2DP socket)
    --    Check if any gst-launch is running before paying the killall cost.
    local h = io.popen("pgrep -c gst-launch 2>/dev/null")
    if h then
        local count = tonumber(h:read("*a"))
        h:close()
        if count and count > 0 then
            os.execute("killall -9 gst-launch-1.0 2>/dev/null")
            dominated = true
            logger.warn("Audiobook: Startup cleanup — killed orphan gst-launch-1.0")
        end
    end

    -- 2. Kill orphan piper processes
    h = io.popen("pgrep -c piper 2>/dev/null")
    if h then
        local count = tonumber(h:read("*a"))
        h:close()
        if count and count > 0 then
            os.execute("killall -9 piper 2>/dev/null")
            dominated = true
            logger.warn("Audiobook: Startup cleanup — killed orphan piper")
        end
    end

    -- 3. Kill orphan feeder/server shell scripts by PID file
    local pid_files = {
        "/tmp/audiobook_ctrl/gst_pid",    -- persistent pipeline gst PID
        "/tmp/piper_server_1.pid",         -- piper server 1 reader PID
        "/tmp/piper_server_1.piper_pid",   -- piper server 1 piper PID
        "/tmp/piper_server_2.pid",         -- piper server 2 reader PID
        "/tmp/piper_server_2.piper_pid",   -- piper server 2 piper PID
    }
    for _, pf_path in ipairs(pid_files) do
        local pf = io.open(pf_path, "r")
        if pf then
            local pid = pf:read("*a"):gsub("%s+", "")
            pf:close()
            if pid ~= "" then
                os.execute(string.format("kill -9 %s 2>/dev/null", pid))
                dominated = true
                logger.warn("Audiobook: Startup cleanup — killed PID", pid, "from", pf_path)
            end
            os.remove(pf_path)
        end
    end

    -- 4. Kill the feeder wrapper shell by finding /bin/sh audiobook_pipeline
    --    This catches the wrapper that io.popen("script & echo $!") spawned.
    os.execute("pkill -9 -f 'audiobook_pipeline\\.sh' 2>/dev/null")

    -- 5. Kill orphan server wrapper shells
    os.execute("pkill -9 -f 'piper_server_.*\\.sh' 2>/dev/null")

    -- 6. Clean up stale temp files
    os.execute("rm -f /tmp/audiobook_fifo /tmp/audiobook_pipeline.sh /tmp/audiobook_ctrl/gst_pid /tmp/audiobook_ctrl/stop /tmp/audiobook_ctrl/play /tmp/audiobook_ctrl/done 2>/dev/null")
    os.execute("rm -f /tmp/piper_server_*.pid /tmp/piper_server_*.piper_pid /tmp/piper_server_*.sh /tmp/piper_server_*.log 2>/dev/null")

    if dominated then
        -- Give kernel time to release sockets after SIGKILL
        os.execute("usleep 300000")
    end
end

function Audiobook:stopReadAlong()
    if not self._init_ok then return end
    logger.warn("Audiobook: stopReadAlong() called")
    pcall(function() BtUI.stopWatcher(self) end)
    pcall(function() BtMediaControl.stop() end)
    pcall(function() BtMediaControl.sendPlaybackStatus("stopped") end)
    pcall(function() self.sync_controller:stop() end)
    pcall(function() self.highlight_manager:clearHighlights() end)
    -- Always kill orphan audio processes, even if we think we're not playing.
    -- A stale gst-launch-1.0 holding the BT socket can destabilize the
    -- system when Nickel resumes after KOReader exits.
    pcall(function() self.tts_engine:forceKillAll() end)
end

function Audiobook:pauseReadAlong()
    if not self._init_ok then return end
    self.sync_controller:pause()
    pcall(function() BtMediaControl.sendPlaybackStatus("paused") end)
end

function Audiobook:resumeReadAlong()
    if not self._init_ok then return end
    self.sync_controller:resume()
    pcall(function() BtMediaControl.sendPlaybackStatus("playing") end)
end


function Audiobook:getCurrentPageText()
    if not self.ui or not self.ui.document then
        logger.warn("Audiobook: No UI or document")
        return nil
    end

    local document = self.ui.document
    local text = nil
    local Screen = Device.screen

    -- EPUB / CreDocument (rolling mode):
    -- Select all visible text by spanning the full screen rectangle.
    -- This is exactly how KOReader's own ReaderView:getCurrentPageLineWordCounts() works.
    if self.ui.rolling then
        local ok, res = pcall(document.getTextFromPositions, document,
            {x = 0, y = 0},
            {x = Screen:getWidth(), y = Screen:getHeight()},
            true)  -- do_not_draw_selection
        if ok and res and res.text and res.text ~= "" then
            text = res.text
        end
    end

    -- PDF / DjVu (paged mode):
    -- Get structured word boxes for the current page and concatenate them.
    if not text and self.ui.paging then
        local page = self.ui:getCurrentPage()
        if page then
            local ok, page_boxes = pcall(document.getTextBoxes, document, page)
            if ok and page_boxes and page_boxes[1] then
                local lines = {}
                for _, line in ipairs(page_boxes) do
                    local words = {}
                    for _, wb in ipairs(line) do
                        if wb.word and wb.word ~= "" then
                            table.insert(words, wb.word)
                        end
                    end
                    if #words > 0 then
                        table.insert(lines, table.concat(words, " "))
                    end
                end
                text = table.concat(lines, "\n")
            end
        end
    end

    if text and text ~= "" then
        -- Don't trim to last complete sentence — the visible text rectangle
        -- from getTextFromPositions doesn't overlap between pages, so partial
        -- sentences at page boundaries must be kept or they'll be skipped.
        logger.dbg("Audiobook: Got page text, length:", #text)
        return text
    end

    logger.warn("Audiobook: Could not get page text")
    return nil
end

-- Event handlers
function Audiobook:onAudiobookToggle()
    if not self._init_ok then self:_showInitError(); return true end
    if self.sync_controller:isPlaying() then
        self:pauseReadAlong()
    elseif self.sync_controller:isPaused() then
        self:resumeReadAlong()
    else
        self:startReadAlong()
    end
    return true
end

function Audiobook:onAudiobookStop()
    if not self._init_ok then return true end
    logger.warn("Audiobook: onAudiobookStop event received")
    self:stopReadAlong()
    return true
end

-- ── BT media button event handlers (AVRCP) ──────────────────────────
-- These are dispatched by KOReader's input system when the AVRCP evdev
-- device sends key events (play/pause/next/prev from a BT headset).

function Audiobook:onMediaPlayPause()
    if not self._init_ok then return true end
    if self.sync_controller:isPlaying() then
        self:pauseReadAlong()
    elseif self.sync_controller:isPaused() then
        self:resumeReadAlong()
    end
    return true
end

function Audiobook:onMediaPlay()
    if not self._init_ok then return true end
    if self.sync_controller:isPaused() then
        self:resumeReadAlong()
    end
    return true
end

function Audiobook:onMediaPause()
    if not self._init_ok then return true end
    if self.sync_controller:isPlaying() then
        self:pauseReadAlong()
    end
    return true
end

function Audiobook:onMediaStop()
    if not self._init_ok then return true end
    logger.warn("Audiobook: onMediaStop event received")
    self:stopReadAlong()
    return true
end

function Audiobook:onMediaNext()
    if not self._init_ok then return true end
    if self.sync_controller:isPlaying() or self.sync_controller:isPaused() then
        self.sync_controller:nextSentence()
    end
    return true
end

function Audiobook:onMediaPrev()
    if not self._init_ok then return true end
    if self.sync_controller:isPlaying() or self.sync_controller:isPaused() then
        self.sync_controller:prevSentence()
    end
    return true
end

-- NOTE: onPageUpdate intentionally removed.
-- Our SyncController manages page flow via advanceToNextPage().
-- Having onPageUpdate here caused an infinite restart loop:
-- highlight → screen refresh → PageUpdate → updateText → stop audio → restart → highlight → ...

-- Auto-pause TTS when any KOReader menu or popup opens.
-- NOTE: ShowConfigMenu event is consumed by ReaderConfig before reaching us,
-- so onShowConfigMenu may never fire. The PlaybackBar handles its own
-- visibility via paintTo (checks for overlay widgets in the stack).
function Audiobook:onShowReaderMenu()
    if not self._init_ok then return end
    if self.sync_controller:isPlaying() then
        self._paused_by_menu = true
        self.sync_controller:pause()
    end
end

function Audiobook:onCloseReaderMenu()
    if not self._init_ok then return end
    if self._paused_by_menu then
        self._paused_by_menu = false
        if self.sync_controller:isPaused() then
            self.sync_controller:resume()
        end
    end
end

-- Also pause for the config/bottom menu
function Audiobook:onShowConfigMenu()
    if not self._init_ok then return end
    if self.sync_controller:isPlaying() then
        self._paused_by_menu = true
        self.sync_controller:pause()
    end
end

function Audiobook:onCloseConfigMenu()
    if not self._init_ok then return end
    if self._paused_by_menu then
        self._paused_by_menu = false
        if self.sync_controller:isPaused() then
            self.sync_controller:resume()
        end
    end
end

-- ── Suspend / Resume (lid close, power button) ──────────────────────
-- On suspend we MUST kill all audio processes (gst-launch, piper) before
-- the kernel enters hardware sleep.  Merely freezing them with SIGSTOP
-- leaves them holding audio hardware resources, which can crash the
-- entire device on some Kobo models.
function Audiobook:onSuspend()
    if not self._init_ok then return end
    if self.sync_controller:isPlaying() or self.sync_controller:isPaused() then
        -- Save current position so we can resume later
        self._suspend_sentence_idx = self.sync_controller.reading_sentence_idx
        self._suspend_was_playing = self.sync_controller:isPlaying()

        -- Hard-kill all audio processes to prevent kernel crash
        pcall(function() self.tts_engine:forceKillAll() end)

        -- Set sync controller to paused WITHOUT clearing parsed data
        -- (stop() would destroy everything; we just want a clean audio state)
        self.sync_controller.state = self.sync_controller.STATE.PAUSED
        self.sync_controller._user_paused = false
        if self.sync_controller.playback_bar then
            self.sync_controller.playback_bar:updatePlayState(false)
            if self.sync_controller._applyBarVisibility then
                self.sync_controller:_applyBarVisibility()
            end
        end

        self._paused_by_suspend = true
        logger.warn("Audiobook: Suspend — killed audio processes, will resume from sentence",
            self._suspend_sentence_idx)
    end
end

function Audiobook:onResume()
    if not self._init_ok then return end
    if self._paused_by_suspend then
        self._paused_by_suspend = false
        local sentence_idx = self._suspend_sentence_idx
        local was_playing = self._suspend_was_playing
        self._suspend_sentence_idx = nil
        self._suspend_was_playing = nil

        -- Restart playback from saved position after a delay to let the
        -- device fully wake up and re-initialize audio hardware.
        if was_playing and sentence_idx
                and self.sync_controller.parsed_data then
            UIManager:scheduleIn(1.5, function()
                -- readNextSentence increments the index, so subtract 1
                self.sync_controller.reading_sentence_idx = sentence_idx - 1
                self.sync_controller.state = self.sync_controller.STATE.PLAYING
                if self.sync_controller.playback_bar then
                    self.sync_controller.playback_bar:updatePlayState(true)
                end
                -- Reset Piper warm-up flag so prefetch queue restarts cleanly
                if self.tts_engine.backend == self.tts_engine.BACKENDS.PIPER then
                    self.sync_controller._piper_warmed_up = false
                end
                logger.warn("Audiobook: Resume — restarting from sentence", sentence_idx)
                self.sync_controller:readNextSentence()
            end)
        else
            -- Not resuming playback; ensure bar visibility matches the paused state
            if self.sync_controller and self.sync_controller._applyBarVisibility then
                self.sync_controller:_applyBarVisibility()
            end
        end
    end
end

function Audiobook:onCloseDocument()
    logger.warn("Audiobook: onCloseDocument event received")
    self:stopReadAlong()
end

-- Safety net: if UIManager tears down the widget tree (exit, doc switch)
-- without CloseDocument firing first, force-stop everything.
function Audiobook:onCloseWidget()
    logger.warn("Audiobook: onCloseWidget event received")
    self:stopReadAlong()
    if self._init_ok then
        self:_removeSleepCoverOverride()
    end
end

--[[--
Install custom SleepCoverClosed/Opened handlers.
When "keep playing on lid close" is enabled AND audio is playing, the
override prevents the device from entering full hardware suspend so
audio continues uninterrupted.  When the setting is off (or audio isn't
playing), the original KOReader handlers are called normally.
--]]
function Audiobook:_installSleepCoverOverride()
    if self._orig_sleep_cover_closed then return end  -- already installed

    -- Only install on devices that actually have SleepCover support
    if not UIManager.event_handlers
            or not UIManager.event_handlers.SleepCoverClosed then
        return
    end

    -- Save original handlers
    self._orig_sleep_cover_closed = UIManager.event_handlers.SleepCoverClosed
    self._orig_sleep_cover_opened = UIManager.event_handlers.SleepCoverOpened

    local plugin = self

    UIManager.event_handlers.SleepCoverClosed = function()
        -- If "keep playing" is on AND we're actively playing, prevent suspend
        if plugin:getSetting("keep_playing_on_lid_close", false)
                and (plugin.sync_controller:isPlaying()
                     or plugin.sync_controller:isPaused()) then
            if Device.is_cover_closed ~= nil then
                Device.is_cover_closed = true
            end
            plugin._prevented_lid_suspend = true
            logger.warn("Audiobook: SleepCover closed — keeping audio alive (suspend prevented)")
            return
        end
        -- Setting off or not playing: use original KOReader behavior
        if plugin._orig_sleep_cover_closed then
            plugin._orig_sleep_cover_closed()
        end
    end

    UIManager.event_handlers.SleepCoverOpened = function()
        if Device.is_cover_closed ~= nil then
            Device.is_cover_closed = false
        end
        if plugin._prevented_lid_suspend then
            -- We blocked suspend on close, so there's nothing to resume from
            plugin._prevented_lid_suspend = false
            logger.warn("Audiobook: SleepCover opened — no resume needed (suspend was prevented)")
            return
        end
        -- Normal resume path
        if plugin._orig_sleep_cover_opened then
            plugin._orig_sleep_cover_opened()
        end
    end

    logger.dbg("Audiobook: SleepCover override installed")
end

--[[--
Restore original SleepCover handlers.
Called on plugin teardown to leave KOReader in a clean state.
--]]
function Audiobook:_removeSleepCoverOverride()
    if not self._orig_sleep_cover_closed then return end

    if UIManager.event_handlers then
        UIManager.event_handlers.SleepCoverClosed = self._orig_sleep_cover_closed
        UIManager.event_handlers.SleepCoverOpened = self._orig_sleep_cover_opened
    end
    self._orig_sleep_cover_closed = nil
    self._orig_sleep_cover_opened = nil
    self._prevented_lid_suspend = nil
    logger.dbg("Audiobook: SleepCover override removed")
end

-- Handle screen rotation: pause TTS, rebuild the PlaybackBar for the new
-- screen dimensions, then resume.
-- NOTE: SetDimensions is dispatched via self.ui:handleEvent() which only
-- reaches reader plugins — standalone UIManager widgets like PlaybackBar
-- never receive it.  We must explicitly tell the bar to rebuild here.
function Audiobook:onSetRotationMode()
    if not self._init_ok then return end
    local Device = require("device")
    local Screen = Device.screen
    local mode = Screen:getScreenMode()
    local cur_w, cur_h = Screen:getWidth(), Screen:getHeight()
    logger.warn("Audiobook: onSetRotationMode — mode=", mode,
        "dims=", cur_w, "x", cur_h,
        "rotation=", Screen.getRotationMode and Screen:getRotationMode() or "?")
    local was_playing = self.sync_controller:isPlaying()
    if was_playing then
        self.sync_controller:pause()
    end
    -- Rebuild the PlaybackBar for the new screen size.
    -- Screen dimensions have already been updated by ReaderView before
    -- this event reaches us.
    local bar = self.sync_controller and self.sync_controller.playback_bar
    if bar and bar.visible then
        bar:onSetDimensions()
    end
    if was_playing then
        -- Resume after a short delay to let the rotation redraw settle
        UIManager:scheduleIn(0.5, function()
            if self.sync_controller:isPaused() then
                self.sync_controller:resume()
            end
        end)
    end
end

-- Settings management
function Audiobook:getSetting(key, default)
    local settings = G_reader_settings:readSetting("audiobook_settings") or {}
    if settings[key] ~= nil then
        return settings[key]
    end
    return default
end

function Audiobook:setSetting(key, value)
    local settings = G_reader_settings:readSetting("audiobook_settings") or {}
    settings[key] = value
    G_reader_settings:saveSetting("audiobook_settings", settings)
end

function Audiobook:toggleSetting(key, default)
    local current = self:getSetting(key, default or false)
    self:setSetting(key, not current)
end

--[[--
Delete all plugin settings from KOReader's persistent storage.
Called by KOReader's "Delete plugin settings" UI action.
--]]
function Audiobook:deletePluginSettings()
    G_reader_settings:delSetting("audiobook_settings")
    -- Reset in-memory state to defaults
    self.current_speed = 1.0
    self.current_pitch = 1.0
    self.current_volume = 1.0
    self.tts_engine_type = "espeak"
    self.voice = nil
    self.highlight_style = "background"
end

return Audiobook
