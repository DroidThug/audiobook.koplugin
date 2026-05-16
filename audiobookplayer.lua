--[[--
AudiobookPlayer -- Full-screen overlay widget for standalone audio playback.
Designed for e-ink: large tap targets, minimal refreshes, no images.

Layout:
  [☰]         Title        [spd] [▼] [✕]
  +---------------------------+
  |       Cover art           |
  +---------------------------+
        Chapter / metadata
           3:24 / 12:45
  [======== progress bar =====]
  [⏴30] [⏮] [⏸] [⏭] [30⏵]

Minimized: a small bottom bar with restore + play/pause + title

@module koplugin.audiobook.audiobookplayer
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local logger = require("logger")
local _ = require("gettext")

local AudiobookPlayer = InputContainer:extend{
    plugin = nil,
    is_playing = true,
    progress = 0,
    current_time_str = "0:00 / 0:00",
    title = "",
    chapter_title = "",
    output_name = "",
    cover_image_path = nil,
    playback_speed = 1.0,
    -- Callbacks
    on_play_pause = nil,
    on_skip_back = nil,
    on_skip_forward = nil,
    on_prev_chapter = nil,
    on_next_chapter = nil,
    on_seek = nil,
    on_close = nil,
    on_minimize = nil,
    on_chapter_list = nil,
    on_speed = nil,
    -- Reference to the underlying ReaderUI or FileManager widget for event
    -- forwarding when minimized (since UIManager only dispatches to the top
    -- widget, we must manually forward events to the UI below).
    ui_widget = nil,
}

function AudiobookPlayer:init()
    self.width = Screen:getWidth()
    self.height = Screen:getHeight()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self._minimized = false
    self._rotation_mode = Screen:getRotationMode()
    self:setupUI()
end

function AudiobookPlayer:setupUI()
    local button_size = Screen:scaleBySize(56)
    local spacing = Size.padding.large

    -- ── Top row: chapter list | title | speed | minimize | close ──
    self.chapter_list_button = Button:new{
        text = "☰",
        width = button_size,
        height = button_size,
        text_font_size = 20,
        callback = function() self:onChapterList() end,
        bordersize = 0,
        show_parent = self,
    }

    self.speed_button = Button:new{
        text = self:_speedText(),
        width = button_size,
        height = button_size,
        text_font_size = 14,
        callback = function() self:onSpeed() end,
        bordersize = 0,
        show_parent = self,
    }

    self.minimize_button = Button:new{
        text = "▼",
        width = button_size,
        height = button_size,
        text_font_size = 20,
        callback = function() self:onMinimize() end,
        bordersize = 0,
        show_parent = self,
    }

    self.close_button = Button:new{
        text = "✕",
        width = button_size,
        height = button_size,
        text_font_size = 22,
        callback = function() self:onClose() end,
        bordersize = 0,
        show_parent = self,
    }

    self.title_widget = TextWidget:new{
        text = self.title or _("Audiobook"),
        face = Font:getFace("cfont", 18),
        max_width = self.width - button_size * 5 - spacing * 5,
        truncate_left = true,
    }

    local top_row = HorizontalGroup:new{
        align = "center",
        self.chapter_list_button,
        HorizontalSpan:new{ width = spacing },
        CenterContainer:new{
            dimen = Geom:new{ w = self.title_widget:getSize().w, h = button_size },
            self.title_widget,
        },
        HorizontalSpan:new{ width = spacing },
        self.speed_button,
        HorizontalSpan:new{ width = math.floor(spacing / 2) },
        self.minimize_button,
        HorizontalSpan:new{ width = math.floor(spacing / 2) },
        self.close_button,
    }

    -- ── Cover art placeholder ──
    -- Responsive: base on smaller screen dimension so it works in both orientations
    local smaller_dim = math.min(self.width, self.height)
    self._cover_height = math.floor(smaller_dim * 0.32)
    self._cover_width = math.floor(self._cover_height * 0.75)
    self.cover_frame = self:_buildCoverFrame()

    -- ── Metadata under cover ──
    self.chapter_widget = TextWidget:new{
        text = self.chapter_title or "",
        face = Font:getFace("cfont", 16),
        max_width = self.width - spacing * 4,
        truncate_left = true,
    }

    self.output_widget = TextWidget:new{
        text = self.output_name or "",
        face = Font:getFace("cfont", 12),
        max_width = self.width - spacing * 4,
        truncate_left = true,
    }

    -- ── Time display ──
    self.time_widget = TextWidget:new{
        text = self.current_time_str or "0:00 / 0:00",
        face = Font:getFace("cfont", 18),
        max_width = self.width - spacing * 4,
    }

    -- ── Progress bar ──
    local bar_height = Screen:scaleBySize(10)
    self.progress_bar = ProgressWidget:new{
        width = self.width - spacing * 4,
        height = bar_height,
        percentage = self.progress / 100,
        fillcolor = Blitbuffer.COLOR_BLACK,
        bgcolor = Blitbuffer.COLOR_LIGHT_GRAY,
        bordersize = 0,
        margin_h = 0,
        margin_v = 0,
        radius = Screen:scaleBySize(5),
    }

    self._scrubber_touch_height = Screen:scaleBySize(40)
    self._scrubber_dragging = false
    self._scrubber_drag_pct = nil

    -- ── Playback controls: all same size ──
    self.skip_back_button = Button:new{
        text = "⏴30",
        width = button_size,
        height = button_size,
        text_font_size = 13,
        callback = function() self:onSkipBack() end,
        bordersize = Size.border.thin,
        radius = Screen:scaleBySize(6),
        show_parent = self,
    }

    self.prev_chapter_button = Button:new{
        text = "⏮",
        width = button_size,
        height = button_size,
        text_font_size = 18,
        callback = function() self:onPrevChapter() end,
        bordersize = Size.border.thin,
        radius = Screen:scaleBySize(6),
        show_parent = self,
    }

    self.play_pause_button = Button:new{
        text = self.is_playing and "⏸" or "▶",
        width = button_size,
        height = button_size,
        text_font_size = 28,
        callback = function() self:onPlayPause() end,
        bordersize = Size.border.thin,
        radius = Screen:scaleBySize(6),
        show_parent = self,
    }

    self.next_chapter_button = Button:new{
        text = "⏭",
        width = button_size,
        height = button_size,
        text_font_size = 18,
        callback = function() self:onNextChapter() end,
        bordersize = Size.border.thin,
        radius = Screen:scaleBySize(6),
        show_parent = self,
    }

    self.skip_forward_button = Button:new{
        text = "30⏵",
        width = button_size,
        height = button_size,
        text_font_size = 13,
        callback = function() self:onSkipForward() end,
        bordersize = Size.border.thin,
        radius = Screen:scaleBySize(6),
        show_parent = self,
    }

    local control_row = HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = spacing },
        self.skip_back_button,
        HorizontalSpan:new{ width = spacing },
        self.prev_chapter_button,
        HorizontalSpan:new{ width = spacing * 2 },
        self.play_pause_button,
        HorizontalSpan:new{ width = spacing * 2 },
        self.next_chapter_button,
        HorizontalSpan:new{ width = spacing },
        self.skip_forward_button,
        HorizontalSpan:new{ width = spacing },
    }

    -- ── Assemble full layout ──
    local content = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = Size.padding.small },
        top_row,
        VerticalSpan:new{ width = self.height * 0.025 },
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self._cover_height },
            self.cover_frame,
        },
        VerticalSpan:new{ width = self.height * 0.015 },
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.chapter_widget:getSize().h },
            self.chapter_widget,
        },
        VerticalSpan:new{ width = math.floor(self.height * 0.006) },
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.output_widget:getSize().h },
            self.output_widget,
        },
        VerticalSpan:new{ width = self.height * 0.015 },
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.time_widget:getSize().h },
            self.time_widget,
        },
        VerticalSpan:new{ width = spacing },
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = bar_height + self._scrubber_touch_height },
            self.progress_bar,
        },
        VerticalSpan:new{ width = self.height * 0.025 },
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = button_size },
            control_row,
        },
        VerticalSpan:new{ width = Size.padding.small },
    }

    -- Full-screen white background frame
    self[1] = FrameContainer:new{
        width = self.width,
        height = self.height,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        content,
    }

    self.dimen = self[1]:getSize()
    self.dimen.x = 0
    self.dimen.y = 0

    -- ── Mini-player bar (shown when minimized) ──
    self._mini_height = Screen:scaleBySize(44)
    local mini_btn_size = self._mini_height - 8  -- slightly smaller containing box

    self._mini_play_pause = Button:new{
        text = self.is_playing and "⏸" or "▶",
        width = mini_btn_size,
        height = mini_btn_size,
        text_font_size = 18,
        callback = function() self:onPlayPause() end,
        bordersize = 0,
        show_parent = self,
    }

    self._mini_close = Button:new{
        text = "✕",
        width = mini_btn_size,
        height = mini_btn_size,
        text_font_size = 16,
        callback = function() self:onClose() end,
        bordersize = 0,
        show_parent = self,
    }

    -- Center: title + time stacked and centered
    local center_max_width = self.width - mini_btn_size * 2 - spacing * 4
    self._mini_title = TextWidget:new{
        text = self.output_name or self.title or _("Audiobook"),
        face = Font:getFace("cfont", 13),
        max_width = center_max_width,
        truncate_left = true,
    }
    self._mini_time = TextWidget:new{
        text = self.current_time_str or "",
        face = Font:getFace("cfont", 11),
        max_width = center_max_width,
    }
    local mini_center = VerticalGroup:new{
        align = "center",
        self._mini_title,
        self._mini_time,
    }

    local mini_row = HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = spacing },
        self._mini_play_pause,
        HorizontalSpan:new{ width = spacing },
        CenterContainer:new{
            dimen = Geom:new{ w = center_max_width, h = self._mini_height },
            mini_center,
        },
        HorizontalSpan:new{ width = spacing },
        self._mini_close,
        HorizontalSpan:new{ width = spacing },
    }
    self._mini_bar = FrameContainer:new{
        width = self.width,
        height = self._mini_height,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.thin,
        padding = 0,
        mini_row,
    }
end

-- Callback handlers
function AudiobookPlayer:onPlayPause()
    if self.on_play_pause then self.on_play_pause() end
end

function AudiobookPlayer:onSkipBack()
    if self.on_skip_back then self.on_skip_back() end
end

function AudiobookPlayer:onSkipForward()
    if self.on_skip_forward then self.on_skip_forward() end
end

function AudiobookPlayer:onPrevChapter()
    if self.on_prev_chapter then self.on_prev_chapter() end
end

function AudiobookPlayer:onNextChapter()
    if self.on_next_chapter then self.on_next_chapter() end
end

function AudiobookPlayer:onClose()
    if self.on_close then self.on_close() end
end

function AudiobookPlayer:onMinimize()
    self._minimized = true
    self._scrubber_dragging = false
    self._scrubber_drag_pct = nil
    self:_updateMiniWidgets()
    -- Shrink dimen to only cover the mini bar area at the bottom
    -- so touch events pass through to the rest of the screen.
    self.dimen.h = self._mini_height
    self.dimen.y = self.height - self._mini_height
    logger.warn("AudiobookPlayer: minimized, dimen=",
        self.dimen.x, self.dimen.y, self.dimen.w, self.dimen.h)
    UIManager:setDirty("all", "ui")
    if self.on_minimize then self.on_minimize() end
end

function AudiobookPlayer:_restore()
    self._minimized = false
    self._scrubber_dragging = false
    self._scrubber_drag_pct = nil
    -- Restore dimen to full screen so we receive all events again
    self.dimen.h = self.height
    self.dimen.y = 0
    UIManager:setDirty("all", "ui")
end

function AudiobookPlayer:onChapterList()
    if self.on_chapter_list then self.on_chapter_list() end
end

function AudiobookPlayer:onSeek(pct)
    if self.on_seek then self.on_seek(pct) end
end

function AudiobookPlayer:onSpeed()
    if self.on_speed then self.on_speed() end
end

-- UI update helpers
function AudiobookPlayer:setPlaying(is_playing)
    if is_playing ~= self.is_playing then
        self.is_playing = is_playing
        local txt = is_playing and "⏸" or "▶"
        self.play_pause_button:setText(txt, self.play_pause_button.width)
        self._mini_play_pause:setText(txt, self._mini_play_pause.width)
        UIManager:setDirty(self, function()
            return "ui", self.play_pause_button.dimen
        end)
    end
end

function AudiobookPlayer:updateTimeDisplay(current_sec, total_sec)
    local text = self:_formatTime(current_sec) .. " / " .. self:_formatTime(total_sec)
    if text ~= self.current_time_str then
        self.current_time_str = text
        self.time_widget:setText(text)
        self._mini_time:setText(text)
        UIManager:setDirty(self, function()
            return "ui", self.time_widget.dimen
        end)
    end
end

function AudiobookPlayer:updateProgress(progress)
    -- Suppress poller updates while user is dragging the scrubber
    if self._scrubber_dragging then return end
    if progress ~= self.progress then
        self.progress = progress
        self.progress_bar:setPercentage(progress / 100)
        if self._minimized then
            UIManager:setDirty(self, function()
                return "ui", self._mini_bar:getSize()
            end)
        else
            UIManager:setDirty(self, function()
                return "ui", self.progress_bar.dimen
            end)
        end
    end
end

function AudiobookPlayer:updateChapterTitle(title)
    if title and title ~= self.chapter_title then
        self.chapter_title = title
        self.chapter_widget:setText(title)
        UIManager:setDirty(self, function()
            return "ui", self.chapter_widget.dimen
        end)
    end
end

function AudiobookPlayer:updateOutputName(name)
    if name and name ~= self.output_name then
        self.output_name = name
        self.output_widget:setText(name)
        UIManager:setDirty(self, function()
            return "ui", self.output_widget.dimen
        end)
    end
end

function AudiobookPlayer:_buildCoverFrame()
    local cover_height = self._cover_height or math.floor(math.min(self.width, self.height) * 0.32)
    local cover_width = self._cover_width or math.floor(cover_height * 0.75)
    local inner_widget
    if self.cover_image_path then
        local ok, image_widget = pcall(function()
            return ImageWidget:new{
                file = self.cover_image_path,
                width = cover_width - Size.border.thin * 2,
                height = cover_height - Size.border.thin * 2,
                scale_factor = 0, -- let ImageWidget auto-scale
            }
        end)
        if ok and image_widget then
            inner_widget = image_widget
        end
    end
    if not inner_widget then
        inner_widget = TextWidget:new{
            text = "♪",
            face = Font:getFace("cfont", 36),
        }
    end
    return FrameContainer:new{
        width = cover_width,
        height = cover_height,
        background = Blitbuffer.COLOR_LIGHT_GRAY,
        bordersize = Size.border.thin,
        radius = Screen:scaleBySize(4),
        padding = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = cover_width, h = cover_height },
            inner_widget,
        },
    }
end

function AudiobookPlayer:setCoverImage(path)
    self.cover_image_path = path
    -- Rebuild the cover frame widget
    if self.cover_frame then
        self.cover_frame = self:_buildCoverFrame()
        -- Rebuild the main layout with the new cover frame
        self:setupUI()
        -- Restore other state
        if self.chapter_title and self.chapter_title ~= "" then
            self.chapter_widget:setText(self.chapter_title)
        end
        if self.output_name and self.output_name ~= "" then
            self.output_widget:setText(self.output_name)
        end
        self.time_widget:setText(self.current_time_str or "0:00 / 0:00")
        self.progress_bar:setPercentage((self.progress or 0) / 100)
        self.play_pause_button:setText(self.is_playing and "⏸" or "▶", self.play_pause_button.width)
        self.speed_button:setText(self:_speedText(), self.speed_button.width)
        UIManager:setDirty(self, "ui")
    end
end

function AudiobookPlayer:updateSpeed(speed)
    speed = tonumber(speed) or 1.0
    if speed ~= self.playback_speed then
        self.playback_speed = speed
        self.speed_button:setText(self:_speedText(), self.speed_button.width)
        UIManager:setDirty(self, function()
            return "ui", self.speed_button.dimen
        end)
    end
end

function AudiobookPlayer:_speedText()
    local s = self.playback_speed or 1.0
    if s == 1.0 then return "1×" end
    if s == math.floor(s) then return string.format("%d×", s) end
    return string.format("%.2f×", s):gsub("0×", "×"):gsub("%.(%d)0×", ".%1×")
end

function AudiobookPlayer:_formatTime(seconds)
    seconds = math.floor(seconds or 0)
    local mins = math.floor(seconds / 60)
    local secs = seconds % 60
    return string.format("%d:%02d", mins, secs)
end

function AudiobookPlayer:_xToPercentage(x)
    if not self.progress_bar or not self.progress_bar.dimen then return nil end
    local bar_left = self.progress_bar.dimen.x
    local bar_width = self.progress_bar.dimen.w
    if not bar_left or not bar_width or bar_width <= 0 then return nil end
    local pct = (x - bar_left) / bar_width
    return math.max(0, math.min(1, pct))
end

function AudiobookPlayer:_updateScrubberPreview(x)
    local pct = self:_xToPercentage(x)
    if not pct then return end
    self._scrubber_drag_pct = pct
    self.progress_bar:setPercentage(pct)
    -- Use string-form setDirty for reliable repaint during rapid drag
    -- (function-form with region can be coalesced/ignored on e-ink)
    UIManager:setDirty(self, "ui")
end

function AudiobookPlayer:_updateMiniWidgets()
    -- Show track filename (output_name) in mini bar; fall back to title
    local track = self.output_name
    if not track or track == "" then
        track = self.title or _("Audiobook")
    end
    self._mini_title:setText(track)
    self._mini_time:setText(self.current_time_str or "")
    local txt = self.is_playing and "⏸" or "▶"
    self._mini_play_pause:setText(txt, self._mini_play_pause.width)
end

-- Show / hide
function AudiobookPlayer:show()
    self.visible = true
    self._minimized = false
    UIManager:show(self, "ui")
end

function AudiobookPlayer:hide()
    self.visible = false
    self._minimized = false
    UIManager:close(self)
    UIManager:setDirty("all", "ui")
end

function AudiobookPlayer:isVisible()
    return self.visible
end

-- Event handling
function AudiobookPlayer:handleEvent(event)
    -- Rotation support: KOReader dispatches SetRotationMode first, then
    -- SetDimensions.  On Kobo the framebuffer size never changes, so we
    -- track rotation mode and swap width/height ourselves.
    -- Rotation handling: UIManager:sendEvent only reaches the top widget.
    -- We must let ReaderUI handle rotation FIRST (it checks old Screen mode),
    -- then rotate Screen, then rebuild ourselves.  Order is critical:
    -- 1) ReaderUI sees old mode -> does full re-layout
    -- 2) Screen rotates atomically
    -- 3) Our widget rebuilds for the new orientation
    if event.handler == "onSetRotationMode" then
        local new_mode = event.args and event.args[1]
        logger.warn("ABP onSetRotationMode event, mode=", new_mode,
            "current=", self._rotation_mode)
        -- 1) Let ReaderUI/FileManager do its rotation handling while Screen
        --    still reports the old mode (ReaderUI compares old vs new).
        if self.ui_widget then
            self.ui_widget:handleEvent(event)
        end
        -- 2) Rotate the display atomically
        Screen:setRotationMode(new_mode)
        UIManager:onRotation()
        -- 3) Rebuild our widget for the new orientation
        if self.visible then
            self:onSetDimensions(nil, new_mode)
        end
        return false
    end
    if event.handler == "onSetDimensions" then
        local size = event.args and event.args[1]
        return self:onSetDimensions(size)
    end

    -- When minimized, handle taps on the mini bar; forward ALL other gestures
    -- to the underlying UI widget (ReaderUI/FileManager) so the user can
    -- interact with menus, swipe pages, pull down the top bar, etc.
    if self._minimized then
        local arg1 = event.args and event.args[1]
        local is_gesture = event.handler == "onGesture" or (type(arg1) == "table" and arg1.ges)
        if is_gesture then
            local ges = type(arg1) == "table" and arg1 or nil
            if ges and ges.pos then
                local mini_y = self.height - self._mini_height
                local on_bar = ges.pos.y >= mini_y
                if on_bar and ges.ges == "tap" then
                    -- Tap on play/pause button?
                    if self:_isTapOnWidget(ges.pos, self._mini_play_pause) then
                        self:onPlayPause()
                        return true
                    end
                    -- Tap on close button?
                    if self:_isTapOnWidget(ges.pos, self._mini_close) then
                        self:onClose()
                        return true
                    end
                    -- Tap anywhere else on the mini bar -> restore full player
                    self:_restore()
                    return true
                end
                -- Gesture outside mini bar (or non-tap on bar) -> forward to underlying UI
                if self.ui_widget then
                    return self.ui_widget:handleEvent(event)
                end
                return false
            end
        end
        -- Non-gesture events pass through
        return false
    end

    local arg1 = event.args and event.args[1]
    if event.handler == "onGesture" or (type(arg1) == "table" and arg1.ges) then
        local ges = type(arg1) == "table" and arg1 or nil
        if not ges then return false end

        -- DEBUG: log every gesture we receive
        logger.warn("ABP gesture:", ges.ges,
            "pos=", ges.pos and (tostring(ges.pos.x) .. "," .. tostring(ges.pos.y)) or "nil",
            "minimized=", self._minimized,
            "dragging=", self._scrubber_dragging)

        -- Let hold pass through unconditionally.
        -- Swipe is treated as a release when we're in the middle of a drag.
        if ges.ges == "hold" then
            return false
        end
        if ges.ges == "swipe" and self._scrubber_dragging then
            -- Gesture detector sometimes emits swipe instead of pan_release.
            -- Treat it as a release and perform the seek.
            logger.warn("ABP swipe while dragging -> seek")
            self._scrubber_dragging = false
            if self._scrubber_drag_pct and self.on_seek then
                self:onSeek(self._scrubber_drag_pct)
                self._scrubber_drag_pct = nil
            end
            return true
        end

        -- Pan / hold_pan on progress bar: visual drag preview
        -- NOTE: hold_pan is what KOReader emits for press-and-drag on e-ink.
        -- pan is what KOReader emits for quick drags (move > PAN_THRESHOLD while down).
        if (ges.ges == "pan" or ges.ges == "hold_pan") and ges.pos then
            if self.progress_bar and self.progress_bar.dimen then
                local bar_y = self.progress_bar.dimen.y
                local bar_h = self.progress_bar.dimen.h
                local in_zone = ges.pos.y >= bar_y - self._scrubber_touch_height / 2
                    and ges.pos.y <= bar_y + bar_h + self._scrubber_touch_height / 2
                logger.warn("ABP pan/hold_pan bar_y=", bar_y, "bar_h=", bar_h,
                    "touch_h=", self._scrubber_touch_height,
                    "in_zone=", in_zone, "dragging=", self._scrubber_dragging)
                if in_zone then
                    self:_updateScrubberPreview(ges.pos.x)
                    self._scrubber_dragging = true
                    return true
                end
            else
                logger.warn("ABP pan/hold_pan NO progress_bar.dimen")
            end
        end

        -- Pan release / hold release on progress bar: perform seek
        if (ges.ges == "pan_release" or ges.ges == "hold_release")
            and self._scrubber_dragging then
            self._scrubber_dragging = false
            if self._scrubber_drag_pct and self.on_seek then
                self:onSeek(self._scrubber_drag_pct)
                self._scrubber_drag_pct = nil
            end
            return true
        end

        -- Tap handling
        if ges.ges == "tap" and ges.pos then
            -- If we were dragging and got a tap instead of pan_release, complete the seek
            -- only if the tap is on or near the progress bar.  Otherwise cancel the drag.
            if self._scrubber_dragging then
                local on_bar = false
                if self.progress_bar and self.progress_bar.dimen then
                    local bar_y = self.progress_bar.dimen.y
                    local bar_h = self.progress_bar.dimen.h
                    on_bar = ges.pos.y >= bar_y - self._scrubber_touch_height
                        and ges.pos.y <= bar_y + bar_h + self._scrubber_touch_height
                end
                if on_bar then
                    self._scrubber_dragging = false
                    local pct = self:_xToPercentage(ges.pos.x)
                    if pct and self.on_seek then
                        self:onSeek(pct)
                        self._scrubber_drag_pct = nil
                    end
                    return true
                else
                    -- Cancel the stale drag
                    self._scrubber_dragging = false
                    self._scrubber_drag_pct = nil
                end
            end

            -- Check if tap is inside any button
            local buttons = {
                self.play_pause_button, self.skip_back_button, self.skip_forward_button,
                self.prev_chapter_button, self.next_chapter_button,
                self.speed_button, self.close_button, self.minimize_button,
                self.chapter_list_button,
            }
            for _, btn in ipairs(buttons) do
                if self:_isTapOnWidget(ges.pos, btn) then
                    return InputContainer.handleEvent(self, event)
                end
            end

            -- Check progress bar area (tap to seek)
            if self.progress_bar and self.progress_bar.dimen then
                local bar_y = self.progress_bar.dimen.y
                local bar_h = self.progress_bar.dimen.h
                if ges.pos.y >= bar_y - self._scrubber_touch_height / 2
                    and ges.pos.y <= bar_y + bar_h + self._scrubber_touch_height / 2 then
                    local pct = self:_xToPercentage(ges.pos.x)
                    if pct then
                        self:onSeek(pct)
                        return true
                    end
                end
            end

            -- Tap outside any control: do nothing (only X closes)
            return true
        end
    end

    return InputContainer.handleEvent(self, event)
end

function AudiobookPlayer:_isTapOnWidget(pos, widget)
    if not widget or not widget.dimen then return false end
    local d = widget.dimen
    return pos.x >= d.x and pos.x <= d.x + d.w
        and pos.y >= d.y and pos.y <= d.y + d.h
end

-- Handle rotation mode change.  On Kobo the framebuffer size is fixed
-- (1264x1680) and the hardware rotates the display; we must rebuild
-- with the SAME dimensions so the framebuffer content is rotated
-- Handle screen dimension changes (e.g. after device rotation).
-- We close and re-show the widget so UIManager registers the new
-- x, y coordinates, matching how PlaybackBar handles rotation.
function AudiobookPlayer:onSetDimensions(size, rotation_mode)
    if not self.visible then return end
    -- Kobo framebuffer is fixed at 1264x1680.  Standalone widgets never see
    -- updated Screen dimensions after rotation, so we derive logical size
    -- from the rotation mode passed in (or from the event that triggered us).
    local rot = rotation_mode or Screen:getRotationMode()
    local new_w, new_h
    if size and size.w and size.h then
        new_w = size.w
        new_h = size.h
    elseif rot == 1 or rot == 3 then
        new_w = 1680
        new_h = 1264
    else
        new_w = 1264
        new_h = 1680
    end
    logger.warn("AudiobookPlayer: onSetDimensions, size=",
        size and (size.w .. "x" .. size.h) or "nil",
        "rot=", rot, "using=", new_w, "x", new_h,
        "screen=", Screen:getWidth(), "x", Screen:getHeight())
    -- Preserve state across the rebuild
    local was_minimized = self._minimized
    local was_playing = self.is_playing
    local title = self.title
    local chapter = self.chapter_title
    local output = self.output_name
    local progress = self.progress
    local time_str = self.current_time_str
    local speed = self.playback_speed
    local cover_path = self.cover_image_path
    -- Remove from UIManager so old coordinates are discarded
    UIManager:close(self)
    -- Re-derive dimensions from the (potentially rotated) screen
    self.width = new_w
    self.height = new_h
    self._rotation_mode = Screen:getRotationMode()
    -- Rebuild the UI tree with new dimensions
    self:setupUI()
    -- Restore state into the fresh widgets
    self.is_playing = was_playing
    self.title = title
    self.chapter_title = chapter
    self.output_name = output
    self.progress = progress
    self.current_time_str = time_str
    self.playback_speed = speed
    self.cover_image_path = cover_path
    self.play_pause_button:setText(was_playing and "⏸" or "▶", self.play_pause_button.width)
    if chapter and chapter ~= "" then self.chapter_widget:setText(chapter) end
    if output and output ~= "" then self.output_widget:setText(output) end
    self.time_widget:setText(time_str or "0:00 / 0:00")
    self.progress_bar:setPercentage((progress or 0) / 100)
    self.speed_button:setText(self:_speedText(), self.speed_button.width)
    self:_updateMiniWidgets()
    -- Re-show at the correct position — this registers the new x,y with
    -- UIManager so paintTo receives the right coordinates.
    self.visible = true
    self._minimized = was_minimized
    if was_minimized then
        self.dimen.h = self._mini_height
        self.dimen.y = self.height - self._mini_height
    else
        self.dimen.h = self.height
        self.dimen.y = 0
    end
    UIManager:show(self, "ui")
    UIManager:setDirty(self, "ui")
    return true
end

function AudiobookPlayer:onCloseWidget()
    -- Cleanup hook
end

function AudiobookPlayer:paintTo(bb, x, y)
    if not self.visible then return end
    if self._minimized then
        -- Draw only the mini player bar at bottom
        if self._mini_bar and self._mini_bar.paintTo then
            self._mini_bar:paintTo(bb, x or 0, (y or 0) + self.height - self._mini_height)
        end
        return
    end
    if self[1] and self[1].paintTo then
        self[1]:paintTo(bb, x or 0, y or 0)
    end
end

return AudiobookPlayer
