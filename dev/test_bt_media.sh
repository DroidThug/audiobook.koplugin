#!/bin/sh
# ── BT Media Control Probe Script ─────────────────────────────────────
# Run on a Kobo with a BT headset connected to discover what AVRCP
# input devices and D-Bus interfaces are available.
#
# Usage:  sh test_bt_media.sh
#         sh test_bt_media.sh monitor   (monitors input events — press headset buttons)

echo "=== BT Media Control Probe ==="
echo "Date: $(date)"
echo

echo "── /proc/bus/input/devices ──"
cat /proc/bus/input/devices
echo

echo "── Virtual Input Devices ──"
for f in /sys/devices/virtual/input/input*/name; do
    [ -f "$f" ] && echo "  $(cat "$f"): $f"
done
echo

echo "── /dev/input/ listing ──"
ls -la /dev/input/ 2>/dev/null
echo

echo "── /sys/class/input/ scan (looking for AVRCP/media) ──"
for d in /sys/class/input/event*; do
    [ -d "$d" ] || continue
    name_file="$d/device/name"
    if [ -f "$name_file" ]; then
        name=$(cat "$name_file")
        echo "  $d: $name"
        # Check capabilities
        cap_file="$d/device/capabilities/key"
        if [ -f "$cap_file" ]; then
            echo "    key caps: $(cat "$cap_file")"
        fi
    fi
done
echo

echo "── D-Bus: mtkbtd GetManagedObjects (looking for Media/Player/AVRCP) ──"
dbus-send --system --print-reply \
    --dest=com.kobo.mtk.bluedroid / \
    org.freedesktop.DBus.ObjectManager.GetManagedObjects 2>&1 | \
    grep -i "media\|player\|avrcp\|transport\|control" || echo "  (none found)"
echo

echo "── D-Bus: Introspect /org/bluez/hci0 ──"
dbus-send --system --print-reply \
    --dest=com.kobo.mtk.bluedroid /org/bluez/hci0 \
    org.freedesktop.DBus.Introspectable.Introspect 2>&1 | head -60
echo

echo "── D-Bus: Full ObjectManager dump (first 200 lines) ──"
dbus-send --system --print-reply \
    --dest=com.kobo.mtk.bluedroid / \
    org.freedesktop.DBus.ObjectManager.GetManagedObjects 2>&1 | head -200
echo

echo "── Looking for uinput ──"
ls -la /dev/uinput /dev/input/uinput /dev/misc/uinput 2>/dev/null || echo "  No uinput device found"
echo

# If "monitor" argument is given, monitor input events
if [ "$1" = "monitor" ]; then
    echo "── Monitoring ALL input events ──"
    echo "Press play/pause/next/prev on your BT headset..."
    echo "(Ctrl+C to stop)"
    echo

    # Use evtest if available, otherwise cat + xxd
    if command -v evtest >/dev/null 2>&1; then
        # Monitor all event devices
        for ev in /dev/input/event*; do
            evtest "$ev" &
        done
        wait
    else
        echo "evtest not available, using raw hexdump."
        echo "Look for EV_KEY events (type=0001) with codes:"
        echo "  0x00a3 = KEY_NEXTSONG (163)"
        echo "  0x00a4 = KEY_PLAYPAUSE (164)"
        echo "  0x00a5 = KEY_PREVIOUSSONG (165)"
        echo "  0x00a6 = KEY_STOPCD (166)"
        echo "  0x00c8 = KEY_PLAYCD (200)"
        echo "  0x00c9 = KEY_PAUSECD (201)"
        echo
        for ev in /dev/input/event*; do
            echo "Monitoring $ev..."
            cat "$ev" | xxd -c 24 &
        done
        wait
    fi
fi

echo "=== Probe complete ==="
