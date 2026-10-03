/* Preloaded by run.sh. glibc reads LD_LIBRARY_PATH once, when a program
 * starts, so once the program is running the variable can go: the GPU
 * drivers it loads later are still found, and the programs it starts get the
 * environment it was started from. Host programs can't run with the folder:
 * Nix's newer libraries lack symbols they need (libdbus's private ones, for
 * one).
 *
 * Wrappers keep it, so it reaches the program they start: makeWrapper's NAME
 * next to .NAME-wrapped, and shells (run.sh itself, shell wrappers).
 *
 * Keep to old libc functions: host programs started from a wrapper or a
 * shell load this too, with the host's older glibc. */
#define _GNU_SOURCE
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void restore(const char *var, const char *saved) {
  const char *v = getenv(saved);
  if (v && *v)
    setenv(var, v, 1);
  else
    unsetenv(var);
  unsetenv(saved);
}

__attribute__((constructor)) static void host_gpu_scrub(void) {
  char exe[PATH_MAX], wrapped[PATH_MAX + 16];
  ssize_t n = readlink("/proc/self/exe", exe, sizeof exe - 1);
  if (n <= 0)
    return;
  exe[n] = '\0';
  char *slash = strrchr(exe, '/');
  if (!slash)
    return;
  const char *name = slash + 1;
  if (!strcmp(name, "bash") || !strcmp(name, "sh") || !strcmp(name, "dash"))
    return;
  snprintf(wrapped, sizeof wrapped, "%.*s/.%s-wrapped", (int)(slash - exe), exe, name);
  if (access(wrapped, F_OK) == 0)
    return;
  restore("LD_LIBRARY_PATH", "HOST_GPU_LD_LIBRARY_PATH");
  restore("LD_PRELOAD", "HOST_GPU_LD_PRELOAD");
}
