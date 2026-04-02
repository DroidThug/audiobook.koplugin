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
        for prop in btEnabled btPowerState BTstate; do
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

    # Kindle audio subsystem probing: identify what audio path Amazon
    # exposes when BT headphones are connected (speakerless models).
    KINDLE_DEV_SND=$(ls -la /dev/snd/ 2>/dev/null || echo "not found")
    KINDLE_APLAY_L=$(aplay -l 2>&1 | head -15 || echo "n/a")
    KINDLE_APLAY_LP=$(aplay -L 2>&1 | head -20 || echo "n/a")
    KINDLE_PROC_ASOUND_PCM=$(cat /proc/asound/pcm 2>/dev/null || echo "not found")
    KINDLE_AUDIO_PROCS=$(ps 2>/dev/null | grep -iE 'audio|alsa|pulse|btfd|a2dp|bluez|sound' | grep -v grep | head -10 || echo "none")
    KINDLE_PULSEAUDIO=$(capture pactl info 2>/dev/null | head -10)
    [ -z "$KINDLE_PULSEAUDIO" ] && KINDLE_PULSEAUDIO="not available"
    KINDLE_PA_SINKS=$(capture pactl list sinks short 2>/dev/null)
    [ -z "$KINDLE_PA_SINKS" ] && KINDLE_PA_SINKS="none"
    KINDLE_LIPC_AUDIO=$(capture lipc-probe com.lab126.audio 2>/dev/null | head -20)
    [ -z "$KINDLE_LIPC_AUDIO" ] && KINDLE_LIPC_AUDIO="not found"
    KINDLE_LIPC_AUDIO_SVCS=$(capture lipc-probe -l 2>/dev/null | grep -iE 'audio|sound|media|player' | head -5)
    [ -z "$KINDLE_LIPC_AUDIO_SVCS" ] && KINDLE_LIPC_AUDIO_SVCS="none"
    KINDLE_AUDIO_BINS=""
    for b in aplay paplay mpv mplayer play madplay mpg123 ffplay sox; do
        loc=$(command -v "$b" 2>/dev/null || true)
        [ -n "$loc" ] && KINDLE_AUDIO_BINS="${KINDLE_AUDIO_BINS}    ${b}: ${loc}\n"
    done
    [ -z "$KINDLE_AUDIO_BINS" ] && KINDLE_AUDIO_BINS="    (none found)\n"
    KINDLE_SND_MODULES=$(lsmod 2>/dev/null | grep -i snd | head -10 || echo "n/a")
    KINDLE_ASOUND_CONF=$(cat /etc/asound.conf 2>/dev/null | head -10 || echo "not found")

    # btfd A2DP reverse-engineering: understand how Amazon routes
    # BT audio so we can inject PCM data into the same path.
    KINDLE_BTFD_PID=$(pidof btfd 2>/dev/null || echo "not running")
    KINDLE_BTFD_CMDLINE="n/a"
    KINDLE_BTFD_FDS="n/a"
    KINDLE_BTFD_SOCKETS="n/a"
    KINDLE_BTFD_MAPS="n/a"
    if echo "$KINDLE_BTFD_PID" | grep -qE '^[0-9]+$'; then
        KINDLE_BTFD_CMDLINE=$(cat /proc/$KINDLE_BTFD_PID/cmdline 2>/dev/null | tr '\0' ' ' || echo "n/a")
        KINDLE_BTFD_FDS=$(ls -la /proc/$KINDLE_BTFD_PID/fd/ 2>/dev/null | head -30 || echo "n/a")
        KINDLE_BTFD_SOCKETS=$(cat /proc/$KINDLE_BTFD_PID/net/unix 2>/dev/null | head -20 || echo "n/a")
        KINDLE_BTFD_MAPS=$(cat /proc/$KINDLE_BTFD_PID/maps 2>/dev/null | grep -iE 'audio|alsa|pulse|blue|a2dp|sbc|socket|pipe' | head -20 || echo "n/a")
    fi
    KINDLE_HCI_DEVS=$(ls -la /dev/hci* 2>/dev/null || echo "none")
    KINDLE_SYS_BT=$(ls -la /sys/class/bluetooth/ 2>/dev/null || echo "none")
    KINDLE_HCICONFIG=$(hciconfig -a 2>/dev/null | head -20 || echo "not available")
    KINDLE_DBUS_RUNNING=$(pidof dbus-daemon 2>/dev/null || echo "not running")
    KINDLE_DBUS_BLUEZ=$(dbus-send --system --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.ListNames 2>/dev/null | grep -i blue | head -5 || echo "no bluez on dbus")
    KINDLE_BT_SOCKETS=$(cat /proc/net/unix 2>/dev/null | grep -iE 'bt|audio|a2dp|blue|sbc' | head -15 || echo "none")
    KINDLE_LIPC_TTS_PROPS=$(capture lipc-probe com.lab126.kaf.TTSService 2>/dev/null | head -15)
    [ -z "$KINDLE_LIPC_TTS_PROPS" ] && KINDLE_LIPC_TTS_PROPS="not found"
    KINDLE_LIPC_AUDIO_PLAYER=$(capture lipc-probe com.lab126.audioPlayer 2>/dev/null | head -15)
    [ -z "$KINDLE_LIPC_AUDIO_PLAYER" ] && KINDLE_LIPC_AUDIO_PLAYER="not found"

    # audiomgrd: Amazon's audio manager daemon (discovered in v0.1.5.24 report)
    KINDLE_AUDIOMGRD_PID=$(pidof audiomgrd 2>/dev/null || echo "not running")
    KINDLE_AUDIOMGRD_CMDLINE="n/a"
    KINDLE_AUDIOMGRD_FDS="n/a"
    KINDLE_AUDIOMGRD_MAPS="n/a"
    if echo "$KINDLE_AUDIOMGRD_PID" | grep -qE '^[0-9]+$'; then
        KINDLE_AUDIOMGRD_CMDLINE=$(cat /proc/$KINDLE_AUDIOMGRD_PID/cmdline 2>/dev/null | tr '\0' ' ' || echo "n/a")
        KINDLE_AUDIOMGRD_FDS=$(ls -la /proc/$KINDLE_AUDIOMGRD_PID/fd/ 2>/dev/null | head -30 || echo "n/a")
        KINDLE_AUDIOMGRD_MAPS=$(cat /proc/$KINDLE_AUDIOMGRD_PID/maps 2>/dev/null | grep -iE 'audio|alsa|snd|pcm|mixer|pipe|socket|hw' | head -20 || echo "n/a")
    fi
    # LIPC services discovered in v0.1.5.24 report
    KINDLE_LIPC_PLAYERMGR=$(capture lipc-probe com.lab126.playermgr 2>/dev/null | head -20)
    [ -z "$KINDLE_LIPC_PLAYERMGR" ] && KINDLE_LIPC_PLAYERMGR="not found"
    KINDLE_LIPC_AUDIOMGRD=$(capture lipc-probe com.lab126.audiomgrd 2>/dev/null | head -20)
    [ -z "$KINDLE_LIPC_AUDIOMGRD" ] && KINDLE_LIPC_AUDIOMGRD="not found"
    # v0.1.5.27: capture actual playermgr/audiomgrd state values
    KINDLE_PLAYERMGR_INPLAYBACK=$(lipc-get-prop com.lab126.playermgr InPlayback 2>/dev/null || echo "n/a")
    KINDLE_PLAYERMGR_TTS_STATE=$(lipc-get-prop com.lab126.playermgr TTS_State 2>/dev/null || echo "n/a")
    KINDLE_AUDIOMGRD_OUTPUT_CONNECTED=$(lipc-get-prop com.lab126.audiomgrd audioOutputConnected 2>/dev/null || echo "n/a")
    KINDLE_AUDIOMGRD_CURRENT_OUTPUT=$(lipc-get-prop com.lab126.audiomgrd audioCurrentOutput 2>/dev/null || echo "n/a")
    KINDLE_AUDIOMGRD_VOLUME=$(lipc-get-prop com.lab126.audiomgrd speakerVolume 2>/dev/null || echo "n/a")
    # Full ALSA config (v0.1.5.24 showed dmix0 on hw:0,0)
    KINDLE_ASOUND_CONF_FULL=$(cat /etc/asound.conf 2>/dev/null || echo "not found")
    KINDLE_DEV_SND_FULL=$(ls -la /dev/snd/ 2>/dev/null || echo "empty")
    # All LIPC services for discovery
    KINDLE_LIPC_ALL_SERVICES=$(capture lipc-probe -l 2>/dev/null | head -40)
    [ -z "$KINDLE_LIPC_ALL_SERVICES" ] && KINDLE_LIPC_ALL_SERVICES="n/a"

    # v0.1.5.28: LIPC playback smoke test -- generate tiny silence WAV and try Open+Play
    KINDLE_LIPC_TEST=$(
        dd if=/dev/zero bs=1 count=4410 2>/dev/null | {
            printf 'RIFF'
            printf '\x6e\x11\x00\x00'
            printf 'WAVE'
            printf 'fmt '
            printf '\x10\x00\x00\x00'
            printf '\x01\x00'
            printf '\x01\x00'
            printf '\x22\x56\x00\x00'
            printf '\x44\xac\x00\x00'
            printf '\x02\x00'
            printf '\x10\x00'
            printf 'data'
            printf '\x4a\x11\x00\x00'
            cat
        } > /tmp/.lipc_test.wav 2>&1
        echo "wav_size=$(wc -c < /tmp/.lipc_test.wav 2>/dev/null)"
        echo "open=$(lipc-set-prop com.lab126.playermgr Open '/tmp/.lipc_test.wav' 2>&1)"
        echo "play=$(lipc-set-prop com.lab126.playermgr Play '' 2>&1)"
        sleep 0.2 2>/dev/null || usleep 200000 2>/dev/null
        echo "inplayback=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
        echo "stop=$(lipc-set-prop com.lab126.playermgr Stop '' 2>&1)"
        rm -f /tmp/.lipc_test.wav
    )
    [ -z "$KINDLE_LIPC_TEST" ] && KINDLE_LIPC_TEST="failed"

    KINDLE_SECTION="  kindle_lipc_available: yes
  kindle_bt_service: ${KINDLE_BT_SERVICE}
  kindle_bt_prop: ${KINDLE_BT_PROP:-n/a}
  kindle_bt_enabled: ${KINDLE_BT_ENABLED:-unknown}
  kindle_bt_paired: ${KINDLE_BT_PAIRED}
  kindle_bt_connected: ${KINDLE_BT_CONNECTED}
  kindle_dev_snd: ${KINDLE_DEV_SND}
  kindle_aplay_l: ${KINDLE_APLAY_L}
  kindle_aplay_L: ${KINDLE_APLAY_LP}
  kindle_proc_asound_pcm: ${KINDLE_PROC_ASOUND_PCM}
  kindle_audio_procs: ${KINDLE_AUDIO_PROCS}
  kindle_pulseaudio: ${KINDLE_PULSEAUDIO}
  kindle_pa_sinks: ${KINDLE_PA_SINKS}
  kindle_lipc_audio: ${KINDLE_LIPC_AUDIO}
  kindle_lipc_audio_svcs: ${KINDLE_LIPC_AUDIO_SVCS}
  kindle_audio_bins:
$(printf '%b' "$KINDLE_AUDIO_BINS")  kindle_snd_modules: ${KINDLE_SND_MODULES}
  kindle_asound_conf: ${KINDLE_ASOUND_CONF}
  kindle_btfd_pid: ${KINDLE_BTFD_PID}
  kindle_btfd_cmdline: ${KINDLE_BTFD_CMDLINE}
  kindle_btfd_fds: ${KINDLE_BTFD_FDS}
  kindle_btfd_sockets: ${KINDLE_BTFD_SOCKETS}
  kindle_btfd_maps: ${KINDLE_BTFD_MAPS}
  kindle_hci_devs: ${KINDLE_HCI_DEVS}
  kindle_sys_bt: ${KINDLE_SYS_BT}
  kindle_hciconfig: ${KINDLE_HCICONFIG}
  kindle_dbus_running: ${KINDLE_DBUS_RUNNING}
  kindle_dbus_bluez: ${KINDLE_DBUS_BLUEZ}
  kindle_bt_sockets: ${KINDLE_BT_SOCKETS}
  kindle_lipc_tts_props: ${KINDLE_LIPC_TTS_PROPS}
  kindle_lipc_audio_player: ${KINDLE_LIPC_AUDIO_PLAYER}
  kindle_audiomgrd_pid: ${KINDLE_AUDIOMGRD_PID}
  kindle_audiomgrd_cmdline: ${KINDLE_AUDIOMGRD_CMDLINE}
  kindle_audiomgrd_fds: ${KINDLE_AUDIOMGRD_FDS}
  kindle_audiomgrd_maps: ${KINDLE_AUDIOMGRD_MAPS}
  kindle_lipc_playermgr: ${KINDLE_LIPC_PLAYERMGR}
  kindle_lipc_audiomgrd: ${KINDLE_LIPC_AUDIOMGRD}
  kindle_playermgr_inplayback: ${KINDLE_PLAYERMGR_INPLAYBACK}
  kindle_playermgr_tts_state: ${KINDLE_PLAYERMGR_TTS_STATE}
  kindle_audiomgrd_output_connected: ${KINDLE_AUDIOMGRD_OUTPUT_CONNECTED}
  kindle_audiomgrd_current_output: ${KINDLE_AUDIOMGRD_CURRENT_OUTPUT}
  kindle_audiomgrd_volume: ${KINDLE_AUDIOMGRD_VOLUME}
  kindle_asound_conf_full: ${KINDLE_ASOUND_CONF_FULL}
  kindle_dev_snd_full: ${KINDLE_DEV_SND_FULL}
  kindle_lipc_all_services: ${KINDLE_LIPC_ALL_SERVICES}
  kindle_lipc_test: ${KINDLE_LIPC_TEST}"
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
