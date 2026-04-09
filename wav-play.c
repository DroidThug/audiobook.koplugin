/*
 * wav-play: Minimal WAV file player using ALSA.
 * Bundled with audiobook.koplugin for devices that have an ALSA soundcard
 * and libasound but no aplay binary (e.g. PocketBook).
 *
 * On startup, tries to unmute and maximize all ALSA playback mixer controls.
 * This is needed because PocketBook (and similar devices) may have the
 * mixer muted or at zero volume by default.
 *
 * Supports -q (quiet), -D <device> (ALSA PCM device name).
 * Uses only ALSA 0.9.x-era functions for maximum compatibility.
 *
 * Build: $CC -O2 -o wav-play wav-play.c -lasound
 * Cross: armv7l-unknown-linux-gnueabihf-gcc -O2 -o wav-play wav-play.c -lasound
 */
#include <alsa/asoundlib.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/*
 * Try to unmute and maximize all playback mixer controls on the given card.
 * Ignores errors - best-effort only.  Devices that do not need this (or
 * have no mixer) simply return early.
 */
static void setup_mixer(const char *card, int quiet)
{
    snd_mixer_t *mixer = NULL;
    if (snd_mixer_open(&mixer, 0) < 0)
        return;
    if (snd_mixer_attach(mixer, card) < 0) {
        snd_mixer_close(mixer);
        return;
    }
    snd_mixer_selem_register(mixer, NULL, NULL);
    snd_mixer_load(mixer);

    snd_mixer_elem_t *elem;
    for (elem = snd_mixer_first_elem(mixer); elem;
         elem = snd_mixer_elem_next(elem)) {
        if (!snd_mixer_selem_is_active(elem))
            continue;
        if (!snd_mixer_selem_has_playback_volume(elem) &&
            !snd_mixer_selem_has_playback_switch(elem))
            continue;

        /* Unmute */
        if (snd_mixer_selem_has_playback_switch(elem))
            snd_mixer_selem_set_playback_switch_all(elem, 1);

        /* Set volume to maximum */
        if (snd_mixer_selem_has_playback_volume(elem)) {
            long vmin, vmax;
            snd_mixer_selem_get_playback_volume_range(elem, &vmin, &vmax);
            snd_mixer_selem_set_playback_volume_all(elem, vmax);
        }
    }

    snd_mixer_close(mixer);
    if (!quiet)
        fprintf(stderr, "wav-play: mixer initialized on %s\n", card);
}

/* Minimal WAV header (PCM format only) */
struct wav_header {
    char     riff_id[4];      /* "RIFF" */
    uint32_t file_size;
    char     wave_id[4];      /* "WAVE" */
    char     fmt_id[4];       /* "fmt " */
    uint32_t fmt_size;
    uint16_t audio_format;    /* 1 = PCM */
    uint16_t channels;
    uint32_t sample_rate;
    uint32_t byte_rate;
    uint16_t block_align;
    uint16_t bits_per_sample;
};

int main(int argc, char **argv)
{
    const char *device   = "default";
    const char *filename = NULL;
    int quiet = 0;

    /* Parse arguments (aplay-compatible subset) */
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-D") == 0 && i + 1 < argc)
            device = argv[++i];
        else if (strcmp(argv[i], "-q") == 0)
            quiet = 1;
        else if (argv[i][0] != '-')
            filename = argv[i];
    }

    if (!filename) {
        fprintf(stderr, "Usage: wav-play [-q] [-D device] file.wav\n");
        return 1;
    }

    FILE *f = fopen(filename, "rb");
    if (!f) {
        if (!quiet) fprintf(stderr, "wav-play: cannot open %s\n", filename);
        return 1;
    }

    /* Read and validate WAV header */
    struct wav_header hdr;
    if (fread(&hdr, sizeof(hdr), 1, f) != 1
        || memcmp(hdr.riff_id, "RIFF", 4) != 0
        || memcmp(hdr.wave_id, "WAVE", 4) != 0) {
        if (!quiet) fprintf(stderr, "wav-play: not a valid WAV file\n");
        fclose(f);
        return 1;
    }

    if (hdr.audio_format != 1) {
        if (!quiet) fprintf(stderr, "wav-play: only PCM format supported\n");
        fclose(f);
        return 1;
    }

    /* Skip past fmt chunk and any extra chunks to find "data" */
    long data_offset = 12 + 8 + hdr.fmt_size;  /* RIFF header + fmt chunk */
    fseek(f, data_offset, SEEK_SET);

    char     chunk_id[4];
    uint32_t chunk_size = 0;
    while (fread(chunk_id, 4, 1, f) == 1 && fread(&chunk_size, 4, 1, f) == 1) {
        if (memcmp(chunk_id, "data", 4) == 0)
            break;
        fseek(f, chunk_size, SEEK_CUR);
        chunk_size = 0;
    }
    if (chunk_size == 0) {
        if (!quiet) fprintf(stderr, "wav-play: no data chunk found\n");
        fclose(f);
        return 1;
    }

    /* Map bit depth to ALSA format */
    snd_pcm_format_t format;
    switch (hdr.bits_per_sample) {
    case 8:  format = SND_PCM_FORMAT_U8;     break;
    case 16: format = SND_PCM_FORMAT_S16_LE; break;
    case 24: format = SND_PCM_FORMAT_S24_3LE; break;
    case 32: format = SND_PCM_FORMAT_S32_LE; break;
    default:
        if (!quiet) fprintf(stderr, "wav-play: unsupported bit depth %d\n",
                            hdr.bits_per_sample);
        fclose(f);
        return 1;
    }

    /* Unmute and maximize mixer volume (best-effort, needed on PocketBook) */
    setup_mixer(device, quiet);

    /*
     * On PocketBook, the ALSA "default" device may not be defined or may
     * route to a Loopback card.  PocketBook's asound.conf defines named
     * PCM devices for TTS: try tts_sm (softvol->dmix->Loopback, correct
     * PocketBook audio pipeline) before falling back to hardware.
     */
    const char *try_devices[] = { device, "tts_sm", "plughw:0", "hw:0", NULL };
    snd_pcm_t *pcm = NULL;
    int err = -1;
    const char *opened_device = device;
    for (int i = 0; try_devices[i]; i++) {
        if (i > 0 && strcmp(try_devices[i], device) == 0)
            continue;   /* skip duplicate */
        err = snd_pcm_open(&pcm, try_devices[i], SND_PCM_STREAM_PLAYBACK, 0);
        if (err >= 0) {
            opened_device = try_devices[i];
            if (i > 0 && !quiet)
                fprintf(stderr, "wav-play: '%s' failed, using fallback '%s'\n",
                        device, opened_device);
            break;
        }
        if (!quiet)
            fprintf(stderr, "wav-play: cannot open '%s': %s (trying next)\n",
                    try_devices[i], snd_strerror(err));
    }
    if (err < 0) {
        if (!quiet) fprintf(stderr, "wav-play: all devices failed\n");
        fclose(f);
        return 1;
    }

    /* If we fell back to hw:0, ensure its mixer is also set up */
    if (strcmp(opened_device, device) != 0)
        setup_mixer("hw:0", quiet);

    /* Configure hardware params */
    snd_pcm_hw_params_t *params;
    snd_pcm_hw_params_alloca(&params);
    snd_pcm_hw_params_any(pcm, params);
    snd_pcm_hw_params_set_access(pcm, params, SND_PCM_ACCESS_RW_INTERLEAVED);
    snd_pcm_hw_params_set_format(pcm, params, format);
    snd_pcm_hw_params_set_channels(pcm, params, hdr.channels);

    unsigned int rate = hdr.sample_rate;
    snd_pcm_hw_params_set_rate_near(pcm, params, &rate, NULL);

    err = snd_pcm_hw_params(pcm, params);
    if (err < 0) {
        if (!quiet) fprintf(stderr, "wav-play: cannot set params: %s\n",
                            snd_strerror(err));
        snd_pcm_close(pcm);
        fclose(f);
        return 1;
    }

    /* Play PCM data */
    size_t frame_size  = hdr.channels * (hdr.bits_per_sample / 8);
    size_t buf_frames  = 1024;
    unsigned char *buf = malloc(buf_frames * frame_size);
    if (!buf) {
        snd_pcm_close(pcm);
        fclose(f);
        return 1;
    }

    uint32_t remaining = chunk_size;
    while (remaining > 0) {
        size_t to_read = buf_frames * frame_size;
        if (to_read > remaining)
            to_read = remaining;

        size_t n = fread(buf, 1, to_read, f);
        if (n == 0)
            break;
        remaining -= n;

        snd_pcm_sframes_t frames = n / frame_size;
        snd_pcm_sframes_t written = snd_pcm_writei(pcm, buf, frames);
        if (written == -EPIPE) {
            /* Underrun - recover and retry */
            snd_pcm_prepare(pcm);
            written = snd_pcm_writei(pcm, buf, frames);
        }
        if (written < 0) {
            if (!quiet) fprintf(stderr, "wav-play: write error: %s\n",
                                snd_strerror(written));
            break;
        }
    }

    snd_pcm_drain(pcm);
    snd_pcm_close(pcm);
    free(buf);
    fclose(f);
    return 0;
}
