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

# GStreamer BT sink
GST_BT_SINK="n/a"
if command -v gst-inspect-1.0 >/dev/null 2>&1; then
    if capture gst-inspect-1.0 mtkbtmwrpcaudiosink | grep -q Factory; then
        GST_BT_SINK="available"
    else
        GST_BT_SINK="not found"
    fi
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
  bt_available: ${BT_AVAILABLE}
  gst_bt_sink: ${GST_BT_SINK}
  tmp_writable: ${TMP_WRITABLE}

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
