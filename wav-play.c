/*
 * wav-play: Minimal WAV file player using ALSA.
 * Bundled with audiobook.koplugin for devices that have an ALSA soundcard
 * and libasound but no aplay binary (e.g. PocketBook).
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

    /* Open ALSA PCM device for playback */
    snd_pcm_t *pcm = NULL;
    int err = snd_pcm_open(&pcm, device, SND_PCM_STREAM_PLAYBACK, 0);
    if (err < 0) {
        if (!quiet) fprintf(stderr, "wav-play: cannot open device '%s': %s\n",
                            device, snd_strerror(err));
        fclose(f);
        return 1;
    }

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
