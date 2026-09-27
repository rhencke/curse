/* Triage sandbox: run one shell on one script under the fuzz harness's sandbox.
 *   unshare -Ur sbx DIR SCRIPT CMD [ARGS...]    ("@S" in ARGS = the script's sandbox path)
 * DIR becomes a private tmpfs (everything else read-only), the script is copied to
 * DIR/s.sh, cwd is DIR/w, env is PATH=DIR/nobin TMPDIR=DIR/tmp LC_ALL=C HOME= XDG_CACHE_HOME= (+ any
 * SBX_ENV_*=v passed through as *=v), stdin /dev/null, the harness's rlimits. */
#include "sandbox.h"

int main(int argc, char **argv)
{
  char s[4096], nb[4096], buf[65536];
  int in, out, i;
  ssize_t n;
  char *keep[32]; int nk = 0;
  extern char **environ;
  if (argc < 4) { fprintf(stderr, "usage: sbx DIR SCRIPT CMD [ARGS...]\n"); return 111; }
  for (i = 0; environ[i] && nk < 31; i++)
    if (!strncmp(environ[i], "SBX_ENV_", 8)) keep[nk++] = strdup(environ[i] + 8);
  in = open(argv[2], O_RDONLY);
  if (in < 0) sbx_die("open script");
  n = read(in, buf, sizeof buf);
  close(in);
  sbx_enter(argv[1]);
  snprintf(s, sizeof s, "%s/s.sh", argv[1]);
  out = open(s, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (out < 0 || (n > 0 && write(out, buf, n) != n)) sbx_die("write script");
  close(out);
  sbx_reset_cwd(argv[1]);
  snprintf(nb, sizeof nb, "%s/nobin", argv[1]);
  clearenv();
  setenv("PATH", nb, 1);
  setenv("LC_ALL", "C", 1);
  setenv("HOME", "", 1);
  setenv("XDG_CACHE_HOME", "", 1);
  snprintf(nb, sizeof nb, "%s/tmp", argv[1]);
  setenv("TMPDIR", nb, 1);
  for (i = 0; i < nk; i++) putenv(keep[i]);
  sbx_limits();
  in = open("/dev/null", O_RDONLY); dup2(in, 0); close(in);
  for (i = 4; i < argc; i++) if (!strcmp(argv[i], "@S")) argv[i] = s;
  execv(argv[3], argv + 3);
  sbx_die("exec");
  return 111;
}
