#!/bin/sh
# Standalone bug report generator for audiobook.koplugin.
# Run this via SSH or KOReader's terminal emulator when the plugin
# menu is not accessible.
#
# Usage:
#   sh /path/to/audiobook.koplugin/generate-report.sh
#
# The report is saved to the device's root storage (same location as
# the in-app report) and also printed to stdout.

set -e

PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Helpers ──────────────────────────────────────────────────────────

capture() {
    # Run a command with a timeout, return stdout trimmed. Empty on failure.
    if command -v timeout >/dev/null 2>&1; then
        timeout 3 "$@" 2>/dev/null || true
    else
        "$@" 2>/dev/null || true
    fi
}

file_exists() { [ -e "$1" ]; }

bool() { if "$@" 2>/dev/null; then echo "yes"; else echo "no"; fi; }

# ── Plugin version ───────────────────────────────────────────────────

PLUGIN_VERSION="unknown"
if [ -f "$PLUGIN_DIR/_meta.lua" ]; then
    v=$(grep 'version' "$PLUGIN_DIR/_meta.lua" | head -1 | sed 's/.*"\(.*\)".*/\1/')
    [ -n "$v" ] && PLUGIN_VERSION="$v"
fi

# ── Detect platform ─────────────────────────────────────────────────

PLATFORM="unknown"
if [ -f /etc/rc.d/functions ]; then
    PLATFORM="kindle"
elif [ -f /bin/kobo_config.sh ]; then
    PLATFORM="kobo"
elif [ -d /sys/class/android_usb ] || command -v getprop >/dev/null 2>&1; then
    PLATFORM="android"
elif [ "$(uname -s)" = "Linux" ]; then
    PLATFORM="linux"
fi

# ── Pick save location ──────────────────────────────────────────────

case "$PLATFORM" in
    kobo)      SAVE_DIR="/mnt/onboard" ;;
    kindle)    SAVE_DIR="/mnt/us" ;;
    android)   SAVE_DIR="/sdcard" ;;
    *)         SAVE_DIR="${HOME:-/tmp}" ;;
esac

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")
FILENAME="audiobook-bug-report-$(date -u +"%Y%m%d-%H%M%S" 2>/dev/null || date +"%Y%m%d-%H%M%S").txt"

# ── Collect info ─────────────────────────────────────────────────────

UNAME=$(capture uname -a)
ARCH=$(capture uname -m)
MODEL="unknown"
case "$PLATFORM" in
    kobo)
        [ -f /bin/kobo_config.sh ] && MODEL=$(capture sh -c '. /bin/kobo_config.sh; echo "$PRODUCT"')
        ;;
    kindle)
        [ -f /proc/usid ] && MODEL=$(capture cat /proc/usid)
        ;;
    android)
        MODEL="$(capture getprop ro.product.brand) $(capture getprop ro.product.model)"
        ;;
esac

# KOReader version
KOREADER_VERSION="unknown"
for d in \
    "$(dirname "$PLUGIN_DIR")/../../" \
    "$(dirname "$PLUGIN_DIR")/../" \
    "/mnt/onboard/.adds/koreader/" \
    "/mnt/us/koreader/" \
    "/sdcard/koreader/"
do
    if [ -f "${d}git-rev" ]; then
        KOREADER_VERSION=$(head -1 "${d}git-rev")
        break
    fi
done

# Bundled binaries
HAS_BUNDLED_ESPEAK=$(bool file_exists "$PLUGIN_DIR/espeak-ng/bin/espeak-ng")
HAS_BUNDLED_PIPER=$(bool file_exists "$PLUGIN_DIR/piper/piper")
PIPER_MODELS="none"
if ls "$PLUGIN_DIR/piper/"*.onnx >/dev/null 2>&1; then
    PIPER_MODELS=$(ls "$PLUGIN_DIR/piper/"*.onnx 2>/dev/null | xargs -n1 basename | tr '\n' ', ' | sed 's/,$//' | sed 's/, $//')
fi

# TTS commands
TTS_CMDS=""
for cmd in espeak-ng espeak piper pico2wave flite festival; do
    loc=$(command -v "$cmd" 2>/dev/null || true)
    [ -n "$loc" ] && TTS_CMDS="${TTS_CMDS}    ${cmd}: ${loc}\n"
done
[ -z "$TTS_CMDS" ] && TTS_CMDS="    (none found)\n"

# Audio players
PLAYER_CMDS=""
for cmd in aplay paplay mpv mplayer play gst-launch-1.0; do
    loc=$(command -v "$cmd" 2>/dev/null || true)
    [ -n "$loc" ] && PLAYER_CMDS="${PLAYER_CMDS}    ${cmd}: ${loc}\n"
done
[ -z "$PLAYER_CMDS" ] && PLAYER_CMDS="    (none found)\n"

# ALSA
ALSA_CARDS="not available"
[ -f /proc/asound/cards ] && ALSA_CARDS=$(cat /proc/asound/cards 2>/dev/null || echo "not available")

# Bluetooth
BT_AVAILABLE=$(bool sh -c 'command -v bluetoothctl >/dev/null || command -v hcitool >/dev/null || [ -d /sys/class/bluetooth ]')

# BT adapter
BT_HCI_DEVICES=$(ls -1 /sys/class/bluetooth/ 2>/dev/null || echo "none")

# Paired / connected devices
# Older BlueZ (< 5.65) doesn't support "devices Paired" and outputs
# "Too many arguments".  Try paired-devices first (works on all versions).
BT_PAIRED="n/a"
BT_CONNECTED="n/a"
BT_ADAPTER_INFO="n/a"
BT_SLEEP_TEST="n/a"
if command -v bluetoothctl >/dev/null 2>&1; then
    BT_PAIRED=$(capture bluetoothctl paired-devices)
    # Fallback: if paired-devices isn't supported, try devices list
    if [ -z "$BT_PAIRED" ] || echo "$BT_PAIRED" | grep -qi "invalid\|error"; then
        BT_PAIRED=$(capture bluetoothctl devices | head -10)
    fi
    [ -z "$BT_PAIRED" ] && BT_PAIRED="none"
    BT_CONNECTED=$(capture bluetoothctl info 2>/dev/null | grep -E 'Device|Name|Connected|Paired')
    [ -z "$BT_CONNECTED" ] && BT_CONNECTED="none"
    BT_ADAPTER_INFO=$(capture bluetoothctl show 2>/dev/null | grep -E 'Powered|Pairable|Discoverable|Controller')
    [ -z "$BT_ADAPTER_INFO" ] && BT_ADAPTER_INFO="unavailable"
    # Test fractional sleep support
    if sleep 0.1 2>/dev/null; then BT_SLEEP_TEST="ok"; else BT_SLEEP_TEST="unsupported"; fi
fi

# hcitool fallback
BT_HCITOOL_CON="n/a"
if command -v hcitool >/dev/null 2>&1; then
    BT_HCITOOL_CON=$(capture hcitool con)
    [ -z "$BT_HCITOOL_CON" ] && BT_HCITOOL_CON="none"
fi

# Kobo BT daemon
BT_DAEMON=$(pidof mtkbtmwrpc 2>/dev/null || pidof bluetoothd 2>/dev/null || echo "not running")

# GStreamer BT sink
GST_BT_SINK="n/a"
GST_AUDIO_SINKS="n/a"
if command -v gst-inspect-1.0 >/dev/null 2>&1; then
    GST_BT_SINK=$(capture gst-inspect-1.0 mtkbtmwrpcaudiosink 2>/dev/null | head -5)
    [ -z "$GST_BT_SINK" ] && GST_BT_SINK="not found"
    GST_AUDIO_SINKS=$(capture sh -c 'gst-inspect-1.0 --list-elements 2>/dev/null | grep -i "sink\|audio" || gst-inspect-1.0 2>/dev/null | grep -i "sink\|audio"')
    [ -z "$GST_AUDIO_SINKS" ] && GST_AUDIO_SINKS="none found"
fi

# Kobo BT abstract socket
BT_SOCKET=$(cat /proc/net/unix 2>/dev/null | grep -i 'kobo\|mtk\|bluetooth' | head -5 || echo "none")

# ALSA PCM devices (may reveal BT sinks not in /proc/asound/cards)
ALSA_PCM_DEVICES="n/a"
if command -v aplay >/dev/null 2>&1; then
    ALSA_PCM_DEVICES=$(capture aplay -L 2>/dev/null | head -20)
    [ -z "$ALSA_PCM_DEVICES" ] && ALSA_PCM_DEVICES="none"
fi

# Kindle BT diagnostics via lipc
KINDLE_SECTION=""
if [ "$PLATFORM" = "kindle" ] && command -v lipc-get-prop >/dev/null 2>&1; then
    KINDLE_BT_SERVICE="none responded"
    KINDLE_BT_PROP=""
    KINDLE_BT_ENABLED=""
    KINDLE_BT_PAIRED="n/a"
    KINDLE_BT_CONNECTED="n/a"
    KINDLE_BT_PROPS=""
    # Probe service+property combinations
    for svc in com.lab126.btfd com.lab126.btService com.lab126.cmd com.lab126.acsbt; do
        for prop in btEnabled btPowerState; do
            val=$(lipc-get-prop "$svc" "$prop" 2>/dev/null)
            if [ -n "$val" ]; then
                KINDLE_BT_SERVICE="$svc"
                KINDLE_BT_PROP="$prop"
                KINDLE_BT_ENABLED="$val"
                KINDLE_BT_PAIRED=$(capture lipc-get-prop "$svc" btPairedDevicesList)
                [ -z "$KINDLE_BT_PAIRED" ] && KINDLE_BT_PAIRED="n/a"
                KINDLE_BT_CONNECTED=$(capture lipc-get-prop "$svc" btConnectedDevices)
                [ -z "$KINDLE_BT_CONNECTED" ] && KINDLE_BT_CONNECTED="n/a"
                break 2
            fi
        done
    done
    if [ "$KINDLE_BT_SERVICE" = "none responded" ]; then
        # List available BT-related lipc services
        KINDLE_LIPC_SERVICES=$(capture lipc-probe -l 2>/dev/null | grep -i 'bt\|blue' | head -5)
        [ -z "$KINDLE_LIPC_SERVICES" ] && KINDLE_LIPC_SERVICES="none"
        # List properties for each known BT service
        for svc in com.lab126.btfd com.lab126.btService com.lab126.cmd com.lab126.acsbt; do
            p=$(lipc-probe "$svc" 2>/dev/null | head -20)
            [ -n "$p" ] && KINDLE_BT_PROPS="${KINDLE_BT_PROPS}    ${svc}: ${p}\n"
        done
    fi
    KINDLE_SECTION="  kindle_lipc_available: yes
  kindle_bt_service: ${KINDLE_BT_SERVICE}
  kindle_bt_prop: ${KINDLE_BT_PROP:-n/a}
  kindle_bt_enabled: ${KINDLE_BT_ENABLED:-unknown}
  kindle_bt_paired: ${KINDLE_BT_PAIRED}
  kindle_bt_connected: ${KINDLE_BT_CONNECTED}"
    [ -n "$KINDLE_LIPC_SERVICES" ] && KINDLE_SECTION="${KINDLE_SECTION}
  kindle_lipc_services: ${KINDLE_LIPC_SERVICES}"
    [ -n "$KINDLE_BT_PROPS" ] && KINDLE_SECTION="${KINDLE_SECTION}
  kindle_bt_props:
$(printf '%b' "$KINDLE_BT_PROPS")"
fi

# Android extras
ANDROID_SECTION=""
if [ "$PLATFORM" = "android" ]; then
    ANDROID_SECTION="  android_version: $(capture getprop ro.build.version.release)
  android_sdk: $(capture getprop ro.build.version.sdk)
  android_brand: $(capture getprop ro.product.brand)
  android_device: $(capture getprop ro.product.model)
  has_tts_helper_dex: $(bool file_exists "$PLUGIN_DIR/android/tts_helper.dex")"
fi

# Resources
MEMINFO=$(head -5 /proc/meminfo 2>/dev/null || echo "not available")
DISK_TMP=$(df -h /tmp 2>/dev/null | tail -1 || echo "not available")
TMP_WRITABLE=$(bool sh -c 'touch /tmp/.audiobook_test && rm /tmp/.audiobook_test')

# Plugin settings (read from LuaSettings file if present)
SETTINGS_SECTION="  (not available -- requires KOReader runtime)"
for d in \
    "$(dirname "$PLUGIN_DIR")/../../settings/" \
    "$(dirname "$PLUGIN_DIR")/../settings/" \
    "/mnt/onboard/.adds/koreader/settings/" \
    "/mnt/us/koreader/settings/" \
    "/sdcard/koreader/settings/"
do
    SETTINGS_FILE="${d}audiobook.lua"
    if [ -f "$SETTINGS_FILE" ]; then
        SETTINGS_SECTION=$(grep -E '(tts_backend|speech_rate|speech_pitch|speech_volume|highlight_style|auto_advance|highlight_words|highlight_sentences|espeak_cold_start|keep_playing_on_lid_close|bt_media_control|piper_model)' "$SETTINGS_FILE" 2>/dev/null | sed 's/^/  /' || echo "  (parse error)")
        break
    fi
done

# ── Build report ─────────────────────────────────────────────────────

REPORT="=== Audiobook Read-Along Bug Report (v${PLUGIN_VERSION}) ===
Generated: ${TIMESTAMP}
Method: generate-report.sh (standalone)

── Device ──
  platform: ${PLATFORM}
  model: ${MODEL}
  arch: ${ARCH}
  uname: ${UNAME}
${ANDROID_SECTION:+${ANDROID_SECTION}
}
── KOReader ──
  koreader_version: ${KOREADER_VERSION}

── Plugin ──
  plugin_version: ${PLUGIN_VERSION}
  plugin_dir: ${PLUGIN_DIR}
  has_bundled_espeak: ${HAS_BUNDLED_ESPEAK}
  has_bundled_piper: ${HAS_BUNDLED_PIPER}
  piper_models: ${PIPER_MODELS}

── Plugin Settings ──
${SETTINGS_SECTION}

── Audio & TTS ──
  tts_in_path:
$(printf '%b' "$TTS_CMDS")  players_in_path:
$(printf '%b' "$PLAYER_CMDS")  alsa_cards: ${ALSA_CARDS}
  alsa_pcm_devices: ${ALSA_PCM_DEVICES}
  bt_available: ${BT_AVAILABLE}
  bt_hci_devices: ${BT_HCI_DEVICES}
  bt_paired_devices: ${BT_PAIRED}
  bt_connected_devices: ${BT_CONNECTED}
  bt_adapter_info: ${BT_ADAPTER_INFO}
  bt_sleep_test: ${BT_SLEEP_TEST}
  bt_hcitool_con: ${BT_HCITOOL_CON}
  bt_daemon: ${BT_DAEMON}
  gst_bt_sink: ${GST_BT_SINK}
  gst_audio_sinks: ${GST_AUDIO_SINKS}
  bt_abstract_socket: ${BT_SOCKET}
${KINDLE_SECTION:+${KINDLE_SECTION}
}  tmp_writable: ${TMP_WRITABLE}

── Resources ──
  meminfo:
$(echo "$MEMINFO" | sed 's/^/    /')
  disk_tmp: ${DISK_TMP}

=== End of Bug Report ==="

# ── Save ─────────────────────────────────────────────────────────────

FILEPATH="${SAVE_DIR}/${FILENAME}"
if ! printf '%s\n' "$REPORT" > "$FILEPATH" 2>/dev/null; then
    # Fallback to /tmp
    FILEPATH="/tmp/${FILENAME}"
    printf '%s\n' "$REPORT" > "$FILEPATH"
fi

# Print to stdout as well
printf '%s\n' "$REPORT"
echo ""
echo "Report saved to: ${FILEPATH}"
