/*
 * MBROLA wrapper for audiobook.koplugin (Kobo/Kindle)
 *
 * Replaces the shell script wrapper to avoid /bin/sh subprocess issues
 * when espeak-ng (loaded via bundled ld-linux) calls execlp("mbrola").
 *
 * This binary resolves relative voice database names to full paths,
 * then execs the real mbrola binary through the bundled glibc linker.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <libgen.h>
#include <limits.h>
#include <signal.h>

int main(int argc, char *argv[])
{
	char exe_path[PATH_MAX];
	ssize_t len = readlink("/proc/self/exe", exe_path, sizeof(exe_path) - 1);
	if (len == -1) {
		perror("readlink /proc/self/exe");
		return 127;
	}
	exe_path[len] = '\0';

	char *exe_dir = dirname(strdup(exe_path));

	char real_mbrola[PATH_MAX];
	char bundled_linker[PATH_MAX];
	char bundled_lib_path[PATH_MAX];
	char plugin_share[PATH_MAX];

	snprintf(real_mbrola, sizeof(real_mbrola), "%s/mbrola.bin", exe_dir);
	snprintf(bundled_linker, sizeof(bundled_linker),
			 "%s/../lib/ld-linux-armhf.so.3", exe_dir);
	snprintf(bundled_lib_path, sizeof(bundled_lib_path),
			 "%s/../lib", exe_dir);
	snprintf(plugin_share, sizeof(plugin_share),
			 "%s/../share", exe_dir);

	/* Resolve voice path for first positional (non-flag) argument.
	 * Skip option flags and their values (e.g. -v 1.0). */
	int voice_done = 0;
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "-v") == 0 || strcmp(argv[i], "--volume") == 0) {
			i++; /* skip the option value */
			continue;
		}
		if (argv[i][0] == '-')
			continue; /* skip other flags */
		if (!voice_done) {
			if (strchr(argv[i], '/') == NULL) {
				char vp[PATH_MAX];
				snprintf(vp, sizeof(vp), "%s/mbrola/%s/%s",
						 plugin_share, argv[i], argv[i]);
				argv[i] = vp; /* safe: we're about to exec */
			}
			voice_done = 1;
		}
	}

	char *new_argv[argc + 4];
	new_argv[0] = bundled_linker;
	new_argv[1] = "--library-path";
	new_argv[2] = bundled_lib_path;
	new_argv[3] = real_mbrola;
	for (int i = 1; i < argc; i++)
		new_argv[i + 3] = argv[i];
	new_argv[argc + 3] = NULL;

	/* mbrowrap.c sets SIGTERM (and others) to SIG_IGN before execlp("mbrola").
	 * execv preserves SIG_IGN, so the real mbrola would ignore SIGTERM and
	 * mbrowrap's stop_mbrola() would hang forever in waitpid().
	 * Reset all catchable signals to default before exec. */
	struct sigaction sa;
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = SIG_DFL;
	for (int sig = 1; sig < NSIG; sig++)
		sigaction(sig, &sa, NULL);

	execv(bundled_linker, new_argv);
	perror("execv");
	return 127;
}
