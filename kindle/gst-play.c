/*
 * kindle-gst-play -- Minimal WAV player for Kindle via GStreamer + mixersink
 *
 * Kindle e-readers have GStreamer 0.10 with Amazon's custom 'mixersink' that
 * routes audio through audiomgrd to Bluetooth headphones.  Most Kindles lack
 * 'wavparse', so this helper reads the WAV header in C, strips it, and feeds
 * raw PCM into a GStreamer pipeline:
 *
 *   filesrc location=<raw_pcm_file> ! audio/x-raw-int,<format> ! mixersink
 *
 * Uses dlopen/dlsym -- no GStreamer headers or libraries needed at build time.
 *
 * Cross-compile:
 *   arm-linux-gnueabihf-gcc -O2 -Wall -o gst-play gst-play.c -ldl
 *   (or use: nix-build cross-build-kindle-gst-play.nix)
 *
 * Usage:
 *   gst-play <file.wav>           Play WAV through GStreamer mixersink
 *   gst-play --probe              Check available GStreamer elements
 *   gst-play --version            Print version and exit
 *
 * Exit codes:
 *   0  Success (played to completion)
 *   1  Usage error
 *   2  WAV file error (bad header, unsupported format, I/O)
 *   3  GStreamer error (library not found, init failed, element missing)
 *   4  Playback error (pipeline failed, caps rejected by sink)
 *   5  Interrupted (SIGTERM / SIGINT)
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <signal.h>
#include <dlfcn.h>
#include <errno.h>

/*
 * glibc 2.42 removed the h_errno@GLIBC_PRIVATE symbol that older system
 * libraries (e.g. Kindle's libresolv.so.2 built against glibc 2.20) still
 * reference.  Because gst-play runs through our bundled ld-linux (glibc 2.42),
 * the dynamic linker sees Kindle's old libresolv requesting h_errno@GLIBC_PRIVATE
 * and fails with "undefined symbol".
 *
 * Fix: define a compatibility symbol inside this binary and export it with
 * the GLIBC_PRIVATE version tag via a linker version-script.  The .symver
 * directive makes the linker emit h_errno_compat as h_errno@GLIBC_PRIVATE
 * in the dynamic symbol table, satisfying the old library at runtime.
 */
int h_errno_compat = 0;
__asm__(".symver h_errno_compat, h_errno@GLIBC_PRIVATE");

#define VERSION "0.3.0"

/* ---- GStreamer constants (stable across 0.10 and 1.0) ---- */
#define GST_STATE_NULL    1
#define GST_STATE_PLAYING 4
#define GST_MESSAGE_EOS   (1 << 0)   /* 0.10 and 1.0 */
#define GST_MESSAGE_ERROR (1 << 1)

/* ---- Function pointer types (opaque void* for all GStreamer objects) ---- */
typedef void  (*fn_gst_init)(int *, char ***);
typedef void* (*fn_gst_parse_launch)(const char *, void **);
typedef int   (*fn_gst_element_set_state)(void *, int);
typedef void* (*fn_gst_element_get_bus)(void *);
typedef void* (*fn_gst_bus_poll)(void *, int, int64_t);
typedef void  (*fn_gst_message_parse_error)(void *, void **, char **);
typedef void  (*fn_gst_object_unref)(void *);
typedef void* (*fn_gst_element_factory_find)(const char *);

/* ---- Loaded symbols ---- */
static fn_gst_init                  gst_init_;
static fn_gst_parse_launch          gst_parse_launch_;
static fn_gst_element_set_state     gst_element_set_state_;
static fn_gst_element_get_bus       gst_element_get_bus_;
static fn_gst_bus_poll              gst_bus_poll_;
static fn_gst_message_parse_error   gst_message_parse_error_;
static fn_gst_object_unref          gst_object_unref_;
static fn_gst_element_factory_find  gst_element_factory_find_;

/* ---- Signal handling ---- */
static volatile sig_atomic_t got_signal = 0;
static void *pipeline_g = NULL;

static void on_signal(int sig)
{
    (void)sig;
    got_signal = 1;
    /* Best-effort stop -- gst_element_set_state is not strictly
       async-signal-safe but on a simple embedded pipeline it works
       in practice and prevents audio continuing after kill.       */
    if (pipeline_g && gst_element_set_state_)
        gst_element_set_state_(pipeline_g, GST_STATE_NULL);
}

/* ---- Helpers ---- */
static uint16_t le16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t le32(const uint8_t *p) { return p[0] | (p[1]<<8) | (p[2]<<16) | ((uint32_t)p[3]<<24); }

/*
 * Load GStreamer via dlopen.  Tries 0.10 first (all observed Kindles),
 * then 1.0 as a future-proof fallback.  Returns 0 on success.
 */
static int gst_version_minor = 0;   /* 10 for 0.10, 0 for 1.0 */

static int load_gstreamer(void)
{
    /*
     * Try multiple library names and paths.  Bare names rely on the
     * dynamic linker's search path (--library-path, LD_LIBRARY_PATH,
     * ldconfig cache, /usr/lib).  Absolute paths bypass the search
     * entirely, which helps when the bundled ld-linux's search path
     * doesn't include /usr/lib or the ldconfig cache is incompatible.
     *
     * Indices 0-3: 0.10 names, 4+: 1.0 names.
     */
    const char *names[] = {
        "libgstreamer-0.10.so",
        "libgstreamer-0.10.so.0",
        "/usr/lib/libgstreamer-0.10.so",
        "/usr/lib/libgstreamer-0.10.so.0",
        "libgstreamer-1.0.so",
        "libgstreamer-1.0.so.0",
        "/usr/lib/libgstreamer-1.0.so",
        "/usr/lib/libgstreamer-1.0.so.0",
        NULL
    };
    void *lib = NULL;
    for (int i = 0; names[i]; i++) {
        lib = dlopen(names[i], RTLD_LAZY);
        if (lib) {
            gst_version_minor = (i < 4) ? 10 : 0;
            fprintf(stderr, "gst-play: loaded %s (0.%d)\n",
                    names[i], gst_version_minor);
            break;
        }
    }
    if (!lib) {
        fprintf(stderr, "gst-play: cannot load libgstreamer: %s\n", dlerror());
        /* Print per-name diagnostics so the bug report shows WHY each failed */
        for (int i = 0; names[i]; i++) {
            dlopen(names[i], RTLD_LAZY);
            fprintf(stderr, "  tried %s: %s\n", names[i], dlerror());
        }
        return -1;
    }

    gst_init_                 = dlsym(lib, "gst_init");
    gst_parse_launch_         = dlsym(lib, "gst_parse_launch");
    gst_element_set_state_    = dlsym(lib, "gst_element_set_state");
    gst_element_get_bus_      = dlsym(lib, "gst_element_get_bus");
    gst_bus_poll_             = dlsym(lib, "gst_bus_poll");
    gst_message_parse_error_  = dlsym(lib, "gst_message_parse_error");
    gst_object_unref_         = dlsym(lib, "gst_object_unref");
    gst_element_factory_find_ = dlsym(lib, "gst_element_factory_find");

    if (!gst_init_ || !gst_parse_launch_ || !gst_element_set_state_ ||
        !gst_element_get_bus_) {
        fprintf(stderr, "gst-play: missing core GStreamer symbols\n");
        return -1;
    }
    if (!gst_bus_poll_) {
        fprintf(stderr, "gst-play: gst_bus_poll not found (GStreamer too old?)\n");
        return -1;
    }
    return 0;
}

/* ---- Probe mode ---- */
static int do_probe(void)
{
    /* Report system glibc version (helps diagnose GLIBC_2.34 load failures) */
    const char *(*gnu_get_libc_version_fn)(void) = NULL;
    void *libc_handle = dlopen("libc.so.6", RTLD_LAZY);
    if (libc_handle) {
        gnu_get_libc_version_fn = dlsym(libc_handle, "gnu_get_libc_version");
        if (gnu_get_libc_version_fn)
            printf("glibc=%s\n", gnu_get_libc_version_fn());
        else
            printf("glibc=unknown\n");
    } else {
        printf("glibc=not_found\n");
    }

    if (load_gstreamer() != 0) {
        printf("gstreamer=not_found\n");
        return 3;
    }

    int argc = 0;
    gst_init_(&argc, NULL);
    printf("gstreamer=loaded\n");
    printf("gstreamer_abi=0.%d\n", gst_version_minor);

    if (!gst_element_factory_find_) {
        printf("factory_find=unavailable\n");
        return 0;
    }

    const char *elems[] = {
        "filesrc", "capsfilter", "fdsrc", "fakesrc", "fakesink",
        "mixersink", "ttssrc", "wavparse", "audioconvert", "audioresample",
        NULL
    };
    for (int i = 0; elems[i]; i++) {
        void *f = gst_element_factory_find_(elems[i]);
        printf("%s=%s\n", elems[i], f ? "found" : "not_found");
    }
    return 0;
}

/* ---- Play mode ---- */
static int do_play(const char *wav_path)
{
    /* -- Read and validate the 44-byte WAV header -- */
    FILE *wf = fopen(wav_path, "rb");
    if (!wf) {
        fprintf(stderr, "gst-play: %s: %s\n", wav_path, strerror(errno));
        return 2;
    }

    uint8_t hdr[44];
    if (fread(hdr, 1, 44, wf) != 44) {
        fprintf(stderr, "gst-play: short WAV header\n");
        fclose(wf);
        return 2;
    }
    if (memcmp(hdr, "RIFF", 4) != 0 || memcmp(hdr + 8, "WAVE", 4) != 0) {
        fprintf(stderr, "gst-play: not a WAV file\n");
        fclose(wf);
        return 2;
    }

    uint16_t fmt      = le16(hdr + 20);
    uint16_t channels = le16(hdr + 22);
    uint32_t rate     = le32(hdr + 24);
    uint16_t bits     = le16(hdr + 34);

    if (fmt != 1) {
        fprintf(stderr, "gst-play: not PCM (fmt=%u)\n", fmt);
        fclose(wf);
        return 2;
    }
    if (channels == 0 || channels > 2 || rate == 0 ||
        (bits != 8 && bits != 16)) {
        fprintf(stderr, "gst-play: unsupported: %uch %uHz %ubit\n",
                channels, rate, bits);
        fclose(wf);
        return 2;
    }

    /* -- Copy raw PCM (bytes 44+) to a temp file -- */
    char raw_path[64];
    snprintf(raw_path, sizeof(raw_path), "/tmp/.abgst_%d.pcm", (int)getpid());

    FILE *rf = fopen(raw_path, "wb");
    if (!rf) {
        fprintf(stderr, "gst-play: temp file: %s\n", strerror(errno));
        fclose(wf);
        return 2;
    }

    char buf[4096];
    size_t total = 0, n;
    while ((n = fread(buf, 1, sizeof(buf), wf)) > 0) {
        if (fwrite(buf, 1, n, rf) != n) {
            fprintf(stderr, "gst-play: write: %s\n", strerror(errno));
            fclose(wf);
            fclose(rf);
            unlink(raw_path);
            return 2;
        }
        total += n;
    }
    fclose(wf);
    fclose(rf);

    if (total == 0) {
        fprintf(stderr, "gst-play: empty audio data\n");
        unlink(raw_path);
        return 2;
    }

    /* -- Initialize GStreamer -- */
    if (load_gstreamer() != 0) {
        unlink(raw_path);
        return 3;
    }

    int argc = 0;
    gst_init_(&argc, NULL);

    /* -- Build pipeline description -- */
    char desc[512];
    if (gst_version_minor == 10) {
        /* GStreamer 0.10: audio/x-raw-int with explicit field types */
        snprintf(desc, sizeof(desc),
            "filesrc location=%s ! "
            "audio/x-raw-int,"
            "rate=(int)%u,"
            "channels=(int)%u,"
            "width=(int)%u,"
            "depth=(int)%u,"
            "signed=(boolean)%s,"
            "endianness=(int)1234"
            " ! mixersink",
            raw_path, rate, channels, bits, bits,
            bits == 16 ? "true" : "false");
    } else {
        /* GStreamer 1.0: audio/x-raw with format string */
        const char *format = (bits == 16) ? "S16LE" : "U8";
        snprintf(desc, sizeof(desc),
            "filesrc location=%s ! "
            "audio/x-raw,"
            "format=(string)%s,"
            "rate=(int)%u,"
            "channels=(int)%u,"
            "layout=(string)interleaved"
            " ! mixersink",
            raw_path, format, rate, channels);
    }

    void *error = NULL;
    void *pipeline = gst_parse_launch_(desc, &error);
    if (!pipeline) {
        fprintf(stderr, "gst-play: pipeline creation failed\n");
        unlink(raw_path);
        return 3;
    }

    pipeline_g = pipeline;

    /* -- Install signal handlers -- */
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_signal;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);

    /* -- Start playback -- */
    gst_element_set_state_(pipeline, GST_STATE_PLAYING);

    int ret = 0;

    void *bus = gst_element_get_bus_(pipeline);
    if (bus) {
        /* Wait for EOS or ERROR.  gst_bus_poll is available since 0.10.0.
           Negative timeout = wait forever. */
        void *msg = gst_bus_poll_(bus, GST_MESSAGE_EOS | GST_MESSAGE_ERROR,
                                  (int64_t)(-1));
        if (msg) {
            /* Distinguish EOS from ERROR without reading struct fields:
               gst_message_parse_error() uses g_return_if_fail internally --
               if the message is EOS the assertion fails harmlessly and
               the error output pointer stays NULL. */
            if (gst_message_parse_error_) {
                void *err = NULL;
                gst_message_parse_error_(msg, &err, NULL);
                if (err != NULL)
                    ret = 4;
                /* err leaked intentionally -- process exits shortly */
            }
            /* msg leaked intentionally */
        }
        /* bus leaked intentionally */
    } else {
        /* No bus -- fall back to duration-based sleep */
        uint32_t byte_rate = rate * channels * (bits / 8);
        unsigned int secs = (byte_rate > 0) ? (unsigned)(total / byte_rate) + 2 : 10;
        while (secs > 0 && !got_signal) {
            sleep(1);
            secs--;
        }
    }

    if (got_signal)
        ret = 5;

    /* -- Cleanup -- */
    gst_element_set_state_(pipeline, GST_STATE_NULL);
    /* pipeline leaked intentionally -- OS reclaims on exit */
    unlink(raw_path);

    return ret;
}

/* ---- Entry point ---- */
int main(int argc, char *argv[])
{
    if (argc < 2) {
        fprintf(stderr, "Usage: %s [--probe | --version] <file.wav>\n",
                argv[0]);
        return 1;
    }

    /* Help GStreamer find plugins when running through the bundled ld-linux.
       The 0 flag means "don't overwrite if already set". */
    setenv("GST_PLUGIN_PATH",
           "/usr/lib/gstreamer-0.10:/usr/lib/gstreamer-1.0", 0);

    if (strcmp(argv[1], "--version") == 0) {
        printf("kindle-gst-play %s\n", VERSION);
        return 0;
    }
    if (strcmp(argv[1], "--probe") == 0)
        return do_probe();

    return do_play(argv[1]);
}
