--[[--
Bluetooth Media Control (AVRCP) Module
Handles BT headset media buttons (play/pause/next/prev) and sends
playback status / metadata back to the connected BT device.

Two mechanisms for receiving media button events:
  1. **evdev** — If BlueZ/mtkbtd creates a virtual input device for AVRCP
     passthrough commands, we open it and read key events directly.
  2. **D-Bus polling** — If no evdev device is found, we poll the
     org.bluez.MediaControl1 / MediaPlayer1 interfaces via D-Bus.

For sending feedback to the BT device:
  - Uses the org.bluez.MediaPlayer1 D-Bus interface (if available) to
    set Track metadata, Status, and Position.
  - Falls back to dbus-send commands to update AVRCP target properties.

@module btmediacontrol
--]]

local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local BtMediaControl = {}

-- ── Linux media key codes ────────────────────────────────────────────
local KEY_NEXTSONG     = 163
local KEY_PLAYPAUSE    = 164
local KEY_PREVIOUSSONG = 165
local KEY_STOPCD       = 166
local KEY_PLAYCD       = 200
local KEY_PAUSECD      = 201
local KEY_FASTFORWARD  = 208
local KEY_REWIND       = 168

-- Event map: media key codes → our internal event names
BtMediaControl.MEDIA_KEY_MAP = {
    [KEY_PLAYPAUSE]    = "MediaPlayPause",
    [KEY_PLAYCD]       = "MediaPlay",
    [KEY_PAUSECD]      = "MediaPause",
    [KEY_STOPCD]       = "MediaStop",
    [KEY_NEXTSONG]     = "MediaNext",
    [KEY_PREVIOUSSONG] = "MediaPrev",
    [KEY_FASTFORWARD]  = "MediaFastForward",
    [KEY_REWIND]       = "MediaRewind",
}

-- D-Bus constants
local DBUS_DEST = "com.kobo.mtk.bluedroid"

-- ── State ────────────────────────────────────────────────────────────

-- Path to the opened AVRCP evdev device (nil if not found)
BtMediaControl._avrcp_evdev_path = nil
-- Whether the evdev-based input is active
BtMediaControl._evdev_active = false
-- Original event_map before we merged media keys
BtMediaControl._original_event_map = nil
-- Whether the D-Bus polling fallback is active
BtMediaControl._dbus_polling_active = false
-- Reference to the plugin for callbacks
BtMediaControl._plugin = nil
-- Last known status sent to BT device
BtMediaControl._last_sent_status = nil

-- ══════════════════════════════════════════════════════════════════════
-- RECEIVING MEDIA BUTTONS
-- ══════════════════════════════════════════════════════════════════════

--[[--
Start listening for BT media button events.
Tries evdev first, falls back to D-Bus polling.

@param plugin  The Audiobook plugin instance (for pause/resume/next/prev callbacks)
--]]
function BtMediaControl.start(plugin)
    BtMediaControl._plugin = plugin

    -- Try evdev approach first
    local found = BtMediaControl._tryEvdevApproach()
    if found then
        logger.warn("BtMediaControl: AVRCP evdev device found and opened")
        return true
    end

    -- Fall back to D-Bus key monitoring
    logger.warn("BtMediaControl: No AVRCP evdev device found, trying D-Bus polling")
    BtMediaControl._startDbusPolling()
    return true
end

--[[--
Stop listening for BT media button events.
--]]
function BtMediaControl.stop()
    BtMediaControl._stopEvdev()
    BtMediaControl._stopDbusPolling()
    BtMediaControl._plugin = nil
end

-- ── evdev approach ───────────────────────────────────────────────────

--[[--
Scan /sys/class/input/ for an AVRCP virtual input device.
BlueZ creates these with "(AVRCP)" in the name.

@return string|nil  Path to the evdev device (e.g. "/dev/input/event5")
@return string|nil  Device name
--]]
function BtMediaControl._findAvrcpEvdevDevice()
    -- Method 1: scan /sys/class/input/ for AVRCP device name
    -- Collect all AVRCP devices, prefer the device-specific one (has
    -- the BT device name like "OpenRun Pro by Shokz (AVRCP)") over the
    -- generic "AVRCP" device.
    local handle = io.popen(
        'for d in /sys/class/input/event*; do '
        .. '  name_file="$d/device/name"; '
        .. '  [ -f "$name_file" ] && name=$(cat "$name_file") && '
        .. '  echo "$d $name"; '
        .. 'done 2>/dev/null'
    )
    if handle then
        local output = handle:read("*a")
        handle:close()
        local generic_path, generic_name = nil, nil
        for line in output:gmatch("[^\n]+") do
            local sys_path, dev_name = line:match("^(%S+)%s+(.+)$")
            if sys_path and dev_name then
                local ev_num = sys_path:match("event(%d+)")
                if ev_num and dev_name:lower():find("avrcp") then
                    local dev_path = "/dev/input/event" .. ev_num
                    -- Prefer device-specific name (contains more than just "AVRCP")
                    if dev_name ~= "AVRCP" then
                        logger.warn("BtMediaControl: Found device-specific AVRCP evdev:",
                            dev_path, "name:", dev_name)
                        return dev_path, dev_name
                    else
                        generic_path = dev_path
                        generic_name = dev_name
                    end
                end
            end
        end
        -- Fall back to generic AVRCP device
        if generic_path then
            logger.warn("BtMediaControl: Found generic AVRCP evdev:",
                generic_path, "name:", generic_name)
            return generic_path, generic_name
        end
    end

    -- Method 2: check /proc/bus/input/devices for AVRCP
    handle = io.popen("cat /proc/bus/input/devices 2>/dev/null")
    if handle then
        local output = handle:read("*a")
        handle:close()
        -- Parse blocks separated by empty lines
        local current_name = nil
        local current_handlers = nil
        for line in output:gmatch("[^\n]+") do
            local name = line:match('^N: Name="(.-)"')
            if name then
                current_name = name
                current_handlers = nil
            end
            local handlers = line:match("^H: Handlers=(.*)")
            if handlers then
                current_handlers = handlers
            end
            -- Check if this was an AVRCP device
            if current_name and current_handlers
                    and (current_name:lower():find("avrcp")
                         or current_name:lower():find("media key")
                         or current_name:lower():find("bluetooth.*key")) then
                local event_dev = current_handlers:match("(event%d+)")
                if event_dev then
                    local dev_path = "/dev/input/" .. event_dev
                    logger.warn("BtMediaControl: Found AVRCP in /proc/bus/input:",
                        dev_path, "name:", current_name)
                    return dev_path, current_name
                end
            end
        end
    end

    return nil, nil
end

--[[--
Try to open the AVRCP evdev device and merge media keys into the event map.
@return boolean  true if an AVRCP device was found and opened
--]]
function BtMediaControl._tryEvdevApproach()
    local dev_path, dev_name = BtMediaControl._findAvrcpEvdevDevice()
    if not dev_path then
        return false
    end

    -- Check if the device is already opened by KOReader's input system
    if Device.input and Device.input.opened_devices
            and Device.input.opened_devices[dev_path] then
        logger.warn("BtMediaControl: AVRCP device already opened:", dev_path)
        -- Just ensure our keys are in the event map
        BtMediaControl._mergeMediaKeyMap()
        BtMediaControl._avrcp_evdev_path = dev_path
        BtMediaControl._evdev_active = true
        return true
    end

    -- Open the evdev device
    if Device.input and Device.input.open then
        local ok, fd = pcall(Device.input.open, Device.input, dev_path)
        if ok and fd then
            logger.warn("BtMediaControl: Opened AVRCP evdev:", dev_path, "fd:", fd)
            BtMediaControl._avrcp_evdev_path = dev_path
            BtMediaControl._evdev_active = true
            BtMediaControl._mergeMediaKeyMap()
            return true
        else
            logger.warn("BtMediaControl: Failed to open AVRCP device:", dev_path, fd)
        end
    end

    return false
end

--[[--
Merge media key codes into KOReader's event_map and install
event_map_adapter + UIManager.event_handlers so media key presses
are dispatched directly to our handlers (like SleepCover / Power).

KOReader dispatch flow for adapter-mapped keys:
  evdev EV_KEY → event_map[code] → event_map_adapter[name](ev)
  → returns string → UIManager.event_handlers[string]()

This bypasses the widget tree (no onKeyPress needed) and gives us
reliable global handling regardless of what widget is focused.
--]]
function BtMediaControl._mergeMediaKeyMap()
    if not Device.input or not Device.input.event_map then return end
    if BtMediaControl._keys_installed then return end

    -- Save original map entries for restoration
    BtMediaControl._original_event_map = {}
    BtMediaControl._original_adapters = {}
    BtMediaControl._original_handlers = {}

    -- Step 1: Add key codes → names in event_map
    for keycode, event_name in pairs(BtMediaControl.MEDIA_KEY_MAP) do
        BtMediaControl._original_event_map[keycode] = Device.input.event_map[keycode]
        Device.input.event_map[keycode] = event_name
    end

    -- Step 2: Add event_map_adapter entries (convert press/release → string)
    -- The adapter function receives the raw ev and returns a string on press.
    local adapter = Device.input.event_map_adapter
    if adapter then
        for _, event_name in pairs(BtMediaControl.MEDIA_KEY_MAP) do
            if not BtMediaControl._original_adapters[event_name] then
                BtMediaControl._original_adapters[event_name] = adapter[event_name]
                adapter[event_name] = function(ev)
                    -- Only handle key press, ignore repeat/release
                    if Device.input:isEvKeyPress(ev) then
                        return event_name
                    end
                end
            end
        end
    end

    -- Step 3: Register UIManager.event_handlers for each media event name
    if UIManager.event_handlers then
        for _, event_name in pairs(BtMediaControl.MEDIA_KEY_MAP) do
            if not BtMediaControl._original_handlers[event_name] then
                BtMediaControl._original_handlers[event_name] = UIManager.event_handlers[event_name]
                UIManager.event_handlers[event_name] = function()
                    BtMediaControl._dispatchMediaEvent(event_name)
                end
            end
        end
    end

    BtMediaControl._keys_installed = true
    logger.warn("BtMediaControl: Media key map + adapters + handlers installed")
end

--[[--
Close the AVRCP evdev device and restore event_map, adapters, and handlers.
--]]
function BtMediaControl._stopEvdev()
    if BtMediaControl._avrcp_evdev_path and Device.input then
        pcall(Device.input.close, Device.input, BtMediaControl._avrcp_evdev_path)
        logger.warn("BtMediaControl: Closed AVRCP evdev:", BtMediaControl._avrcp_evdev_path)
    end

    -- Restore everything we changed
    if BtMediaControl._keys_installed and Device.input then
        -- Restore event_map
        if BtMediaControl._original_event_map then
            for keycode, orig_val in pairs(BtMediaControl._original_event_map) do
                Device.input.event_map[keycode] = orig_val
            end
        end
        -- Restore event_map_adapter
        if BtMediaControl._original_adapters and Device.input.event_map_adapter then
            for name, orig_fn in pairs(BtMediaControl._original_adapters) do
                Device.input.event_map_adapter[name] = orig_fn
            end
        end
        -- Restore UIManager.event_handlers
        if BtMediaControl._original_handlers and UIManager.event_handlers then
            for name, orig_fn in pairs(BtMediaControl._original_handlers) do
                UIManager.event_handlers[name] = orig_fn
            end
        end
    end

    BtMediaControl._avrcp_evdev_path = nil
    BtMediaControl._evdev_active = false
    BtMediaControl._original_event_map = nil
    BtMediaControl._original_adapters = nil
    BtMediaControl._original_handlers = nil
    BtMediaControl._keys_installed = false
end

-- ── D-Bus polling fallback ───────────────────────────────────────────
-- If no evdev device exists, poll for AVRCP button events via D-Bus.
-- mtkbtd may expose a MediaControl1 or MediaPlayer1 interface that
-- reflects button presses from the connected headset.

function BtMediaControl._startDbusPolling()
    if BtMediaControl._dbus_polling_active then return end
    BtMediaControl._dbus_polling_active = true
    BtMediaControl._last_dbus_status = nil

    BtMediaControl._pollDbusMediaControl()
end

function BtMediaControl._stopDbusPolling()
    BtMediaControl._dbus_polling_active = false
end

--[[--
Poll for AVRCP/MediaPlayer1 status changes via D-Bus.
Checks the connected device's MediaPlayer1 or MediaControl1 properties
for status changes that indicate headset button presses.
--]]
function BtMediaControl._pollDbusMediaControl()
    if not BtMediaControl._dbus_polling_active then return end

    local plugin = BtMediaControl._plugin
    if not plugin then
        BtMediaControl._dbus_polling_active = false
        return
    end

    -- Look for MediaPlayer1 Status property on connected device
    local cmd = string.format(
        'dbus-send --system --print-reply --dest=%s / '
        .. 'org.freedesktop.DBus.ObjectManager.GetManagedObjects 2>/dev/null '
        .. '| grep -A2 "MediaPlayer1" | grep -i "status" | head -1',
        DBUS_DEST
    )
    local handle = io.popen(cmd)
    if handle then
        local output = handle:read("*a") or ""
        handle:close()

        -- Parse status if found
        local status = output:match('string "(%w+)"')
        if status and BtMediaControl._last_dbus_status
                and status ~= BtMediaControl._last_dbus_status then
            -- Status changed — headset button was pressed
            logger.warn("BtMediaControl: D-Bus status changed:",
                BtMediaControl._last_dbus_status, "→", status)
            BtMediaControl._handleDbusStatusChange(status)
        end
        if status then
            BtMediaControl._last_dbus_status = status
        end
    end

    -- Reschedule polling (2s interval — low overhead)
    if BtMediaControl._dbus_polling_active then
        UIManager:scheduleIn(2.0, BtMediaControl._pollDbusMediaControl)
    end
end

--[[--
Handle a status change detected via D-Bus polling.
--]]
function BtMediaControl._handleDbusStatusChange(new_status)
    local plugin = BtMediaControl._plugin
    if not plugin then return end

    if new_status == "paused" then
        BtMediaControl._dispatchMediaEvent("MediaPause")
    elseif new_status == "playing" then
        BtMediaControl._dispatchMediaEvent("MediaPlay")
    elseif new_status == "stopped" then
        BtMediaControl._dispatchMediaEvent("MediaStop")
    end
end

-- ── Event dispatch ───────────────────────────────────────────────────

--[[--
Dispatch a media event to the plugin.
@param event_name string  One of "MediaPlayPause", "MediaPlay", "MediaPause",
                          "MediaStop", "MediaNext", "MediaPrev"
--]]
function BtMediaControl._dispatchMediaEvent(event_name)
    local plugin = BtMediaControl._plugin
    if not plugin then return end

    logger.warn("BtMediaControl: Dispatching media event:", event_name)

    if event_name == "MediaPlayPause" then
        if plugin.sync_controller:isPlaying() then
            plugin:pauseReadAlong()
        elseif plugin.sync_controller:isPaused() then
            plugin:resumeReadAlong()
        end
    elseif event_name == "MediaPlay" then
        if plugin.sync_controller:isPaused() then
            plugin:resumeReadAlong()
        end
    elseif event_name == "MediaPause" then
        if plugin.sync_controller:isPlaying() then
            plugin:pauseReadAlong()
        end
    elseif event_name == "MediaStop" then
        plugin:stopReadAlong()
    elseif event_name == "MediaNext" then
        if plugin.sync_controller:isPlaying() or plugin.sync_controller:isPaused() then
            plugin.sync_controller:nextSentence()
        end
    elseif event_name == "MediaPrev" then
        if plugin.sync_controller:isPlaying() or plugin.sync_controller:isPaused() then
            plugin.sync_controller:prevSentence()
        end
    end
end


-- ══════════════════════════════════════════════════════════════════════
-- SENDING FEEDBACK TO BT DEVICE
-- ══════════════════════════════════════════════════════════════════════

--[[--
Send playback status update to the connected BT device.

Kobo's mtkbtd exposes MediaTransport1 (not MediaPlayer1), so we update
the transport State property.  Some headsets reflect this as a status
indicator or voice prompt.

@param status string  "playing", "paused", or "stopped"
--]]
function BtMediaControl.sendPlaybackStatus(status)
    if BtMediaControl._last_sent_status == status then return end
    BtMediaControl._last_sent_status = status

    local transport_path = BtMediaControl._findMediaTransportPath()
    if not transport_path then
        logger.dbg("BtMediaControl: No MediaTransport1 path found, cannot send status")
        return
    end

    -- Map our status names to MediaTransport1 State values
    -- MediaTransport1 uses: "idle", "pending", "active"
    local state_map = {
        playing = "active",
        paused  = "pending",
        stopped = "idle",
    }
    local state = state_map[status] or "idle"

    local cmd = string.format(
        'dbus-send --system --print-reply --dest=%s %s '
        .. 'org.freedesktop.DBus.Properties.Set '
        .. 'string:"org.bluez.MediaTransport1" '
        .. 'string:"State" variant:string:"%s" 2>/dev/null',
        DBUS_DEST, transport_path, state
    )
    os.execute(cmd .. " &")
    logger.dbg("BtMediaControl: Sent transport state:", state, "(", status, ") to", transport_path)
end

--[[--
Send track metadata to the connected BT device.
Note: Requires a registered MediaPlayer via org.bluez.Media1.RegisterPlayer,
which is not yet implemented. This is a stub for future use.

@param title string     Track title (e.g. sentence or book title)
@param artist string    Artist (e.g. "TTS" or book author)
@param duration number  Duration in milliseconds (optional)
--]]
function BtMediaControl.sendTrackMetadata(title, artist, duration)
    -- MediaPlayer1 registration would be needed to push track metadata.
    -- For now just log it; a future version can use Media1.RegisterPlayer.
    logger.dbg("BtMediaControl: Track metadata (not yet sent):",
        title and title:sub(1, 60) or "(nil)")
end

--[[--
Find the D-Bus object path for MediaTransport1 on the connected device.
Caches the result for repeated calls.

On Kobo mtkbtd this is typically:
  /org/bluez/hci0/dev_XX_XX_XX_XX_XX_XX/fd0

@return string|nil  Object path
--]]
function BtMediaControl._findMediaTransportPath()
    -- Use cached value if recent
    if BtMediaControl._transport_path
            and BtMediaControl._transport_path_time
            and (os.time() - BtMediaControl._transport_path_time) < 30 then
        return BtMediaControl._transport_path
    end

    local cmd = string.format(
        'dbus-send --system --print-reply --dest=%s / '
        .. 'org.freedesktop.DBus.ObjectManager.GetManagedObjects 2>/dev/null',
        DBUS_DEST
    )
    local handle = io.popen(cmd)
    if not handle then return nil end
    local output = handle:read("*a") or ""
    handle:close()

    -- Find the object path that has MediaTransport1 interface
    -- Look for a path containing "fd" (transport endpoints) under a device
    local transport_path = nil
    local current_path = nil
    for line in output:gmatch("[^\n]+") do
        local path = line:match('object path "(.-)"')
        if path then
            current_path = path
        end
        if current_path and line:find("MediaTransport1") then
            transport_path = current_path
            break
        end
    end

    if transport_path then
        BtMediaControl._transport_path = transport_path
        BtMediaControl._transport_path_time = os.time()
        logger.dbg("BtMediaControl: Found MediaTransport1 path:", transport_path)
        return transport_path
    end

    return nil
end

--[[--
Re-scan for the AVRCP evdev device.
Call this after a BT device connects — the AVRCP input device may
appear asynchronously after the A2DP connection is established.
--]]
function BtMediaControl.rescan()
    if BtMediaControl._evdev_active then return end  -- already have a device

    local found = BtMediaControl._tryEvdevApproach()
    if found then
        logger.warn("BtMediaControl: AVRCP evdev device found on rescan")
    end

    -- Refresh the MediaTransport1 path cache
    BtMediaControl._transport_path = nil
    BtMediaControl._transport_path_time = nil
end

return BtMediaControl
