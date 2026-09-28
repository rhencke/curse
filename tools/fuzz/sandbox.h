/* Sandbox shared by the AFL harness and the triage runner (sbx).
 * Needs to run as root inside a user namespace (`unshare -Ur ...`): makes a private
 * mount namespace (and network namespace), turns the WHOLE mount tree read-only (a fuzzed `> /some/path`
 * gets EROFS), mounts a small tmpfs on DIR (the only writable place), and makes
 * DIR/w (the script's cwd), DIR/tmp ($TMPDIR: the shells' own temp files -- with / read-only
 * and no writable $TMPDIR, curse and bash both fall back to other code paths) and
 * DIR/nobin (an empty $PATH: builtins only). */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <linux/mount.h>

#ifndef SYS_mount_setattr
#define SYS_mount_setattr 442
#endif

static void sbx_die(const char *what)
{
  fprintf(stderr, "sandbox: %s: %s\n", what, strerror(errno));
  _exit(111);
}

static void sbx_enter(const char *dir)
{
  struct mount_attr ma;
  char p[4096];
  /* (a network namespace of its own too: nothing fuzzed reaches a network, /dev/tcp included) */
  if (unshare(CLONE_NEWNS | CLONE_NEWNET) != 0) sbx_die("unshare(CLONE_NEWNS|CLONE_NEWNET) (run under `unshare -Ur`)");
  if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) != 0) sbx_die("make-rprivate");
  memset(&ma, 0, sizeof ma);
  ma.attr_set = MOUNT_ATTR_RDONLY;
  if (syscall(SYS_mount_setattr, AT_FDCWD, "/", AT_RECURSIVE, &ma, sizeof ma) != 0)
    sbx_die("mount_setattr ro");
  if (mount("tmpfs", dir, "tmpfs", MS_NOSUID | MS_NODEV, "size=16m,mode=0755") != 0)
    sbx_die("mount tmpfs");
  snprintf(p, sizeof p, "%s/w", dir); mkdir(p, 0755);
  snprintf(p, sizeof p, "%s/nobin", dir); mkdir(p, 0755);
  snprintf(p, sizeof p, "%s/tmp", dir); mkdir(p, 01777);
}

static void sbx_limits(void)
{
  struct rlimit r;
  r.rlim_cur = r.rlim_max = 5;                 setrlimit(RLIMIT_CPU, &r);   /* orphans die too */
  r.rlim_cur = r.rlim_max = 1 << 20;           setrlimit(RLIMIT_FSIZE, &r);
  r.rlim_cur = r.rlim_max = 0;                 setrlimit(RLIMIT_CORE, &r);
  r.rlim_cur = r.rlim_max = (rlim_t)2 << 30;   setrlimit(RLIMIT_AS, &r);
}

/* Empty DIR/w (the previous exec's files) without following symlinks. */
static void sbx_rm_tree(int dfd)
{
  char buf[8192];
  int pass;
  for (pass = 0; pass < 64; pass++) {  /* (bounded: an undeletable entry can't spin us) */
    long n = syscall(SYS_getdents64, dfd, buf, sizeof buf), off;
    if (n <= 0) break;
    for (off = 0; off < n;) {
      struct { unsigned long long ino; long long off; unsigned short reclen; unsigned char type; char name[]; } *d = (void *)(buf + off);
      off += d->reclen;
      if (!strcmp(d->name, ".") || !strcmp(d->name, "..")) continue;
      if (unlinkat(dfd, d->name, 0) != 0) {
        int sub = openat(dfd, d->name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        if (sub >= 0) { fchmod(sub, 0700); sbx_rm_tree(sub); close(sub); }
        unlinkat(dfd, d->name, AT_REMOVEDIR);
      }
    }
    lseek(dfd, 0, SEEK_SET);
  }
}

static void sbx_reset_cwd(const char *dir)
{
  char p[4096];
  int fd;
  snprintf(p, sizeof p, "%s/tmp", dir);
  fd = open(p, O_RDONLY | O_DIRECTORY);
  if (fd >= 0) { sbx_rm_tree(fd); close(fd); }
  snprintf(p, sizeof p, "%s/w", dir);
  chdir("/");
  fd = open(p, O_RDONLY | O_DIRECTORY);
  if (fd >= 0) { fchmod(fd, 0755); sbx_rm_tree(fd); close(fd); }
  else mkdir(p, 0755);
  if (chdir(p) != 0) sbx_die("chdir w");
}
