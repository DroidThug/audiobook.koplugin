--[[--
Bluetooth Manager for Kobo devices.

Supports two Bluetooth stacks found on different Kobo hardware:
  - MTK (Clara 2E, Sage, Libra Colour, etc.): uses the Kobo-specific
    mtkbtd service (com.kobo.mtk.bluedroid) and GStreamer
    mtkbtmwrpcaudiosink for audio.
  - BlueZ (Libra 2/Io, etc.): uses the standard org.bluez D-Bus
    interface and ALSA audio output.

The stack is auto-detected on first use.  All D-Bus operations are
routed through the detected destination transparently.

Supported operations:
  - Power on/off the Bluetooth adapter
  - Start/stop device discovery (scanning)
  - List discovered and paired devices
  - Pair, connect, and disconnect devices

Reference: OGKevin/kobo.koplugin BT investigation
  https://ogkevin.github.io/kobo.koplugin/dev/investigations/bluetooth/

@module btmanager
--]]

local logger = require("logger")

local BTManager = {}

-- D-Bus constants (DBUS_DEST is set by detectStack)
local DBUS_DEST = "org.bluez"  -- safe default; overridden for MTK
local ADAPTER_PATH = "/org/bluez/hci0"
local ROOT_PATH = "/"
local ADAPTER_IFACE = "org.bluez.Adapter1"
local DEVICE_IFACE = "org.bluez.Device1"
local PROPS_IFACE = "org.freedesktop.DBus.Properties"
local OBJMGR_IFACE = "org.freedesktop.DBus.ObjectManager"

-- Detected stack state (set once by detectStack, then cached)
local bt_stack = nil        -- "mtk" or "bluez"
local gst_bt_sink = nil     -- "mtkbtmwrpcaudiosink" or nil
local bluetoothd_path = nil -- resolved path to bluetoothd binary
local has_bluetoothctl = nil -- cached availability of bluetoothctl

--- Detect which Bluetooth stack this Kobo device uses.
-- Called lazily from dbus_cmd() on first BT operation; a no-op
-- after the first successful detection.
local function detectStack()
    if bt_stack then return end

    -- Method 1: The mtkbtmwrpcaudiosink GStreamer element is ONLY
    -- present on MTK-based Kobo devices (Clara 2E, Sage, Libra Colour).
    local h = io.popen("gst-inspect-1.0 mtkbtmwrpcaudiosink 2>/dev/null | head -1")
    local result = h and h:read("*a") or ""
    if h then h:close() end
    if result:match("Factory Details") then
        bt_stack = "mtk"
        DBUS_DEST = "com.kobo.mtk.bluedroid"
        gst_bt_sink = "mtkbtmwrpcaudiosink"
        logger.dbg("BTManager: detected MTK Bluetooth stack")
        return
    end

    -- Method 2: Check if the MTK D-Bus service is registered (covers
    -- the case where GStreamer is not installed).
    h = io.popen(
        "dbus-send --system --print-reply "
        .. "--dest=org.freedesktop.DBus /org/freedesktop/DBus "
        .. "org.freedesktop.DBus.NameHasOwner "
        .. "string:'com.kobo.mtk.bluedroid' 2>/dev/null")
    result = h and h:read("*a") or ""
    if h then h:close() end
    if result:match("boolean true") then
        bt_stack = "mtk"
        DBUS_DEST = "com.kobo.mtk.bluedroid"
        gst_bt_sink = "mtkbtmwrpcaudiosink"
        logger.dbg("BTManager: detected MTK Bluetooth stack (D-Bus)")
        return
    end

    -- Default: standard BlueZ (Kobo Libra 2 / Io, etc.)
    bt_stack = "bluez"
    DBUS_DEST = "org.bluez"
    gst_bt_sink = nil
    logger.dbg("BTManager: detected standard BlueZ Bluetooth stack")

    -- Resolve the bluetoothd binary path.
    -- On Kobo Libra 2 / Io it lives at /libexec/bluetooth/bluetoothd
    -- rather than on PATH.
    local daemon_candidates = {
        "/libexec/bluetooth/bluetoothd",
        "/usr/libexec/bluetooth/bluetoothd",
        "/usr/lib/bluetooth/bluetoothd",
    }
    for _, p in ipairs(daemon_candidates) do
        local f = io.open(p, "r")
        if f then
            f:close()
            bluetoothd_path = p
            logger.dbg("BTManager: found bluetoothd at", p)
            break
        end
    end
    if not bluetoothd_path then
        -- Fall back to PATH lookup
        local h = io.popen("which bluetoothd 2>/dev/null")
        local r = h and h:read("*a") or ""
        if h then h:close() end
        r = r:gsub("%s+$", "")
        if r ~= "" then
            bluetoothd_path = r
            logger.dbg("BTManager: found bluetoothd via PATH:", r)
        else
            bluetoothd_path = "bluetoothd"  -- last resort
            logger.warn("BTManager: bluetoothd not found at known paths, using bare name")
        end
    end

    -- Check bluetoothctl availability (used for agent-based pairing)
    local bctl = io.popen("which bluetoothctl 2>/dev/null")
    local bctl_r = bctl and bctl:read("*a") or ""
    if bctl then bctl:close() end
    has_bluetoothctl = bctl_r:match("%S") ~= nil
    logger.dbg("BTManager: bluetoothctl available:", has_bluetoothctl)
end

--- Run a dbus-send command and return the raw output.
-- @string cmd  full dbus-send command
-- @treturn string output (may be empty)
-- @treturn bool   true if command succeeded (exit code 0)
local function dbus(cmd)
    local handle = io.popen(cmd .. " 2>/dev/null; echo \"__EXIT:$?\"")
    if not handle then return "", false end
    local output = handle:read("*a")
    handle:close()
    local exit_code = output:match("__EXIT:(%d+)%s*$")
    output = output:gsub("__EXIT:%d+%s*$", "")
    return output, exit_code == "0"
end

--- Build a dbus-send command.
-- Includes a 5-second reply timeout to prevent blocking the Lua VM
-- when bluetoothd is unresponsive or not running.
-- @string path    object path
-- @string method  full interface.method name
-- @string ...     additional arguments
-- @treturn string command
local function dbus_cmd(path, method, ...)
    detectStack()  -- lazy init on first D-Bus operation
    local args = table.concat({...}, " ")
    return string.format(
        "dbus-send --system --print-reply --reply-timeout=5000 --dest=%s %s %s %s",
        DBUS_DEST, path, method, args
    )
end

--- Get a D-Bus property.
-- @string path      object path
-- @string iface     interface owning the property
-- @string prop_name property name
-- @treturn string raw output
local function get_property(path, iface, prop_name)
    local cmd = dbus_cmd(path, PROPS_IFACE .. ".Get",
        string.format('string:"%s"', iface),
        string.format('string:"%s"', prop_name))
    return dbus(cmd)
end

--- Set a D-Bus property.
-- @string path      object path
-- @string iface     interface
-- @string prop_name property name
-- @string variant   variant value (e.g. "variant:boolean:true")
local function set_property(path, iface, prop_name, variant)
    local cmd = dbus_cmd(path, PROPS_IFACE .. ".Set",
        string.format('string:"%s"', iface),
        string.format('string:"%s"', prop_name),
        variant)
    return dbus(cmd)
end

-----------------------------------------------------------------------
-- Adapter power
-----------------------------------------------------------------------

--- Check whether the BT adapter is powered on.
-- @treturn bool powered state
function BTManager:isPowered()
    local out = get_property(ADAPTER_PATH, ADAPTER_IFACE, "Powered")
    return out:match("boolean true") ~= nil
end

--- Check if bluetoothd is already running.
-- @treturn bool
local function is_bluetoothd_running()
    local h = io.popen("pidof bluetoothd 2>/dev/null")
    local r = h and h:read("*a") or ""
    if h then h:close() end
    return r:match("%d+") ~= nil
end

--- Power on the Bluetooth adapter.
-- For BlueZ devices, starts the bluetoothd daemon and resets the HCI
-- adapter first (required on Kobo Libra 2 and similar).
-- @treturn bool success
function BTManager:powerOn()
    detectStack()
    logger.dbg("BTManager: powering on (stack:", bt_stack, ")")

    if bt_stack == "bluez" then
        -- BlueZ requires the bluetoothd daemon and an HCI adapter reset.
        -- On Kobo Libra 2 / Io, the daemon lives at /libexec/bluetooth/
        -- rather than on PATH (ref: OGKevin/kobo.koplugin BT investigation).
        if not is_bluetoothd_running() then
            local daemon = bluetoothd_path or "bluetoothd"
            logger.dbg("BTManager: starting bluetoothd from:", daemon)
            os.execute(daemon .. " 2>/dev/null &")
            os.execute("sleep 1")
            if not is_bluetoothd_running() then
                logger.warn("BTManager: bluetoothd failed to start from", daemon)
            end
        else
            logger.dbg("BTManager: bluetoothd already running")
        end
        os.execute("hciconfig hci0 down 2>/dev/null && hciconfig hci0 up 2>/dev/null")
        os.execute("sleep 1")
    end

    local _, ok = set_property(ADAPTER_PATH, ADAPTER_IFACE, "Powered", "variant:boolean:true")
    -- Give the stack a moment to initialize
    if ok then os.execute("sleep 2") end

    local powered = self:isPowered()
    logger.dbg("BTManager: powerOn result:", powered,
        "bluetoothd running:", is_bluetoothd_running())
    return powered
end

--- Power off the Bluetooth adapter.
-- For BlueZ devices, also stops the bluetoothd daemon.
-- @treturn bool success
function BTManager:powerOff()
    detectStack()
    logger.dbg("BTManager: powering off")
    set_property(ADAPTER_PATH, ADAPTER_IFACE, "Powered", "variant:boolean:false")
    os.execute("sleep 1")

    if bt_stack == "bluez" then
        -- Stop the daemon we started (safe even if it was already running)
        os.execute("killall bluetoothd 2>/dev/null")
        os.execute("hciconfig hci0 down 2>/dev/null")
    end

    return not self:isPowered()
end

-----------------------------------------------------------------------
-- Discovery (scanning)
-----------------------------------------------------------------------

--- Start BT device discovery.
-- @treturn bool success
function BTManager:startDiscovery()
    logger.dbg("BTManager: starting discovery")
    local _, ok = dbus(dbus_cmd(ADAPTER_PATH, ADAPTER_IFACE .. ".StartDiscovery"))
    return ok
end

--- Stop BT device discovery.
-- @treturn bool success
function BTManager:stopDiscovery()
    logger.dbg("BTManager: stopping discovery")
    local _, ok = dbus(dbus_cmd(ADAPTER_PATH, ADAPTER_IFACE .. ".StopDiscovery"))
    return ok
end

--- Check whether discovery is active.
-- @treturn bool
function BTManager:isDiscovering()
    local out = get_property(ADAPTER_PATH, ADAPTER_IFACE, "Discovering")
    return out:match("boolean true") ~= nil
end

-----------------------------------------------------------------------
-- Device enumeration
-----------------------------------------------------------------------

--- List Bluetooth devices known to the adapter.
-- Parses the output of ObjectManager.GetManagedObjects.
-- @treturn table array of {path, address, name, paired, connected, icon}
function BTManager:listDevices()
    local cmd = dbus_cmd(ROOT_PATH, OBJMGR_IFACE .. ".GetManagedObjects")
    local output, ok = dbus(cmd)
    if not ok then return {} end

    local devices = {}
    local cur = nil      -- current device being parsed
    local next_prop = nil  -- which property the next variant line belongs to

    for line in output:gmatch("[^\n]+") do
        -- Detect a new object path for a device
        local path = line:match('object path "(.-)"')
        if path and path:match("/org/bluez/hci0/dev_") then
            -- Save previous device if it had a non-empty name
            if cur then
                table.insert(devices, cur)
            end
            local mac = path:match("dev_(.+)$")
            mac = mac and mac:gsub("_", ":") or ""
            cur = {
                path = path,
                address = mac,
                name = "",
                paired = false,
                connected = false,
                icon = "",
            }
            next_prop = nil
        end

        -- When we're inside a device entry, detect property keys
        if cur then
            if line:match('string "Name"%s*$') then
                next_prop = "name"
            elseif line:match('string "Paired"%s*$') then
                next_prop = "paired"
            elseif line:match('string "Connected"%s*$') then
                next_prop = "connected"
            elseif line:match('string "Icon"%s*$') then
                next_prop = "icon"
            elseif next_prop and line:match("variant") then
                if next_prop == "name" then
                    cur.name = line:match('string "(.-)"') or ""
                elseif next_prop == "paired" then
                    cur.paired = line:match("boolean true") ~= nil
                elseif next_prop == "connected" then
                    cur.connected = line:match("boolean true") ~= nil
                elseif next_prop == "icon" then
                    cur.icon = line:match('string "(.-)"') or ""
                end
                next_prop = nil
            end
        end
    end
    -- Last device
    if cur then
        table.insert(devices, cur)
    end

    return devices
end

--- Filter devices: only those that are audio-related OR paired.
-- Unnamed BLE beacons are dropped.
-- @treturn table filtered device list
function BTManager:listAudioDevices()
    local all = self:listDevices()
    local result = {}
    local audio_icons = {
        ["audio-headphones"] = true,
        ["audio-headset"] = true,
        ["audio-card"] = true,
        ["audio-speakers"] = true,
    }
    for _, dev in ipairs(all) do
        -- Keep: has an audio icon, OR is paired, OR has a name
        if audio_icons[dev.icon] or dev.paired or (dev.name and dev.name ~= "") then
            table.insert(result, dev)
        end
    end
    -- Sort: connected first, then paired, then by name
    table.sort(result, function(a, b)
        if a.connected ~= b.connected then return a.connected end
        if a.paired ~= b.paired then return a.paired end
        return (a.name or "") < (b.name or "")
    end)
    return result
end

-----------------------------------------------------------------------
-- Device operations
-----------------------------------------------------------------------

--- Convert a MAC address to a D-Bus object path.
-- @string address e.g. "C0:86:B3:D9:35:A9"
-- @treturn string e.g. "/org/bluez/hci0/dev_C0_86_B3_D9_35_A9"
local function mac_to_path(address)
    return ADAPTER_PATH .. "/dev_" .. address:gsub(":", "_")
end

--- Pair with a device.
-- Prefers bluetoothctl (which has a built-in pairing agent for "Just
-- Works" SSP) over raw D-Bus Device1.Pair (which requires an external
-- agent that we don't have).  Falls back to D-Bus if bluetoothctl is
-- not available.
-- @string address  MAC address
-- @treturn bool success
-- @treturn string error message (if any)
function BTManager:pair(address)
    logger.dbg("BTManager: pairing with", address)

    -- Always trust the device so auto-connect works on future boots
    local path = mac_to_path(address)
    set_property(path, DEVICE_IFACE, "Trusted", "variant:boolean:true")

    if has_bluetoothctl then
        -- bluetoothctl handles the NoInputNoOutput agent internally,
        -- which is required for pairing with audio devices ("Just Works").
        --
        -- We write a small shell script to /tmp and pipe it into
        -- bluetoothctl.  Using printf instead of echo -e because Kobo's
        -- busybox ash does not interpret \n in echo -e.  Each command
        -- needs a small delay so bluetoothctl can process it.
        logger.dbg("BTManager: pairing via bluetoothctl")
        local script = string.format(
            "{ "
            .. "printf 'power on\\n'; sleep 1; "
            .. "printf 'agent NoInputNoOutput\\n'; sleep 0.5; "
            .. "printf 'default-agent\\n'; sleep 0.5; "
            .. "printf 'pairable on\\n'; sleep 0.5; "
            .. "printf 'trust %s\\n'; sleep 0.5; "
            .. "printf 'pair %s\\n'; sleep 6; "
            .. "printf 'quit\\n'; "
            .. "} | bluetoothctl 2>&1",
            address, address)
        local h = io.popen(script)
        local out = h and h:read("*a") or ""
        if h then h:close() end
        logger.dbg("BTManager: bluetoothctl pair output:", out:sub(1, 500))

        -- Verify pairing succeeded via D-Bus property
        local prop_out = get_property(path, DEVICE_IFACE, "Paired")
        if prop_out:match("boolean true") then
            return true
        end
        -- Check for known errors in output
        local err = out:match("Failed to pair: (.-)\n") or
                    out:match("org%.bluez%.Error%.([%w]+)") or
                    "Pairing did not complete"
        logger.warn("BTManager: bluetoothctl pairing failed:", err)
        return false, err
    end

    -- Fallback: raw D-Bus (may fail without a registered agent)
    logger.dbg("BTManager: pairing via D-Bus (no bluetoothctl)")
    local out, ok = dbus(dbus_cmd(path, DEVICE_IFACE .. ".Pair"))
    if not ok then
        local err = out:match("Error[^\n]*") or "Pairing failed (no agent)"
        return false, err
    end
    return true
end

--- Connect to a (paired) device.
-- @string address  MAC address
-- @treturn bool success
-- @treturn string error message (if any)
function BTManager:connect(address)
    detectStack()
    logger.dbg("BTManager: connecting to", address)
    local path = mac_to_path(address)
    local out, ok = dbus(dbus_cmd(path, DEVICE_IFACE .. ".Connect"))
    if not ok then
        local err = out:match("Error[^\n]*") or "Connection failed"
        return false, err
    end

    if bt_stack == "mtk" then
        -- MTK: Wait for A2DP profile to come up.  Device1.Connect returns
        -- as soon as the ACL link is established, but mtkbtmwrpcaudiosink
        -- isn't usable until btservice sets up the A2DP channel.  Poll for
        -- up to 5 seconds.
        for attempt = 1, 10 do
            os.execute("sleep 0.5")
            local probe = io.popen(
                "timeout 2 gst-launch-1.0 audiotestsrc num-buffers=1 ! audio/x-raw,format=S16LE,rate=48000,channels=2 ! mtkbtmwrpcaudiosink 2>&1; echo __RC:$?"
            )
            local pout = probe and probe:read("*a") or ""
            if probe then probe:close() end
            if pout:match("PLAYING") or pout:match("PREROLLED") or pout:match("__RC:0") then
                logger.dbg("BTManager: A2DP audio sink ready after", attempt * 0.5, "s")
                return true
            end
            logger.dbg("BTManager: A2DP not ready yet, attempt", attempt)
        end
        logger.warn("BTManager: D-Bus connect OK but A2DP audio sink not ready after 5s")
        return true, "Connected but audio may not be ready yet"
    else
        -- BlueZ: the A2DP transport is set up asynchronously after
        -- Device1.Connect returns.  Give it a moment to settle.
        os.execute("sleep 2")
        logger.dbg("BTManager: BlueZ device connected, A2DP profile settling")
        return true
    end
end

--- Disconnect a device.
-- @string address  MAC address
-- @treturn bool success
function BTManager:disconnect(address)
    logger.dbg("BTManager: disconnecting", address)
    local path = mac_to_path(address)
    local _, ok = dbus(dbus_cmd(path, DEVICE_IFACE .. ".Disconnect"))
    return ok
end

--- Remove (un-pair) a device.
-- @string address  MAC address
-- @treturn bool success
function BTManager:remove(address)
    logger.dbg("BTManager: removing", address)
    local path = mac_to_path(address)
    local _, ok = dbus(dbus_cmd(ADAPTER_PATH, ADAPTER_IFACE .. ".RemoveDevice",
        string.format('objpath:"%s"', path)))
    return ok
end

--- Check if a specific device is connected.
-- @string address  MAC address
-- @treturn bool
function BTManager:isConnected(address)
    local path = mac_to_path(address)
    local out = get_property(path, DEVICE_IFACE, "Connected")
    return out:match("boolean true") ~= nil
end

--- Get the name of a device.
-- @string address  MAC address
-- @treturn string name (may be "")
function BTManager:getDeviceName(address)
    local path = mac_to_path(address)
    local out = get_property(path, DEVICE_IFACE, "Name")
    return out:match('string "(.-)"') or ""
end

--- Get the local adapter address (our MAC).
-- @treturn string MAC address, or "" if not powered
function BTManager:getAdapterAddress()
    local out = get_property(ADAPTER_PATH, ADAPTER_IFACE, "Address")
    return out:match('string "(.-)"') or ""
end

-----------------------------------------------------------------------
-- Stack introspection (for ttsengine / bugreport)
-----------------------------------------------------------------------

--- Return the detected BT stack type.
-- @treturn string "mtk" or "bluez" (triggers detection if needed)
function BTManager:getStackType()
    detectStack()
    return bt_stack
end

--- Return the GStreamer BT audio sink element name, if any.
-- @treturn string|nil e.g. "mtkbtmwrpcaudiosink", or nil for BlueZ
function BTManager:getGstBtSink()
    detectStack()
    return gst_bt_sink
end

return BTManager
