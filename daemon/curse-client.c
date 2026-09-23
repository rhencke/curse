/* curse-client: the tiny, fast front end that a `/bin/sh` symlink points at.
 *
 * It connects to the current user's resident `cursed` (a warm LuaJIT process),
 * hands over argv + cwd + environ and its own stdin/stdout/stderr (via
 * SCM_RIGHTS, so the script's I/O IS the caller's — no proxying), waits for the
 * exit status, and exits with it. If the daemon isn't there (not started, or a
 * different/read-only environment), it falls back to running the script directly
 * so nothing ever breaks — the daemon is pure speedup, never a dependency.
 *
 * Per-user by design: the socket lives in $XDG_RUNTIME_DIR (mode 0700, owned by
 * the user, cleaned on logout), so there is no cross-user surface and no
 * privilege drop to get wrong. See daemon/README.
 *
 * Startup must beat dash, so this is deliberately minimal C: no libc init beyond
 * the basics, one connect, one sendmsg, one read — and built STATIC so exec pays
 * no dynamic loader (ld.so costs ~0.185ms/invocation, measured).
 *
 *   cc -O2 -s -static -o curse daemon/curse-client.c
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <signal.h>
#include <stdint.h>

#define CURSE_MAGIC 0x43555253u /* "CURS" */

/* Auto-start the resident daemon in the background so FUTURE invocations are warm.
 * $CURSE_DAEMON is the launch command (e.g. "luajit /path/lua/daemon.lua"); unset
 * -> no daemon, we just fall back. Double-fork + setsid so the daemon is reparented
 * to init (not our child — no zombie, outlives us), with stdio detached to
 * /dev/null. We never wait: THIS request still falls back below while the daemon
 * warms up. Racing clients that all spawn one are harmless — the daemon's flock
 * single-instance guard lets exactly one win. */
static void spawn_daemon(void) {
    const char *cmd = getenv("CURSE_DAEMON");
    if (!cmd || !*cmd) return;
    pid_t pid = fork();
    if (pid != 0) return;              /* parent or fork failure: carry on to fallback */
    setsid();
    pid = fork();
    if (pid != 0) _exit(0);           /* intermediate exits; grandchild reparents to init */
    int nul = open("/dev/null", O_RDWR);
    if (nul >= 0) { dup2(nul, 0); dup2(nul, 1); dup2(nul, 2); if (nul > 2) close(nul); }
    execl("/bin/sh", "sh", "-c", cmd, (char *)NULL);
    _exit(127);
}

/* No daemon reachable: run the script in curse ITSELF — the self-contained one-shot
 * binary (a shell when invoked under a shell name). The goal is to REPLACE bash/dash,
 * so we never defer to them; curse always runs its own scripts, warm or cold.
 * $CURSE_FALLBACK overrides the curse binary path/name (default "curse"); argv is
 * passed UNCHANGED, so argv[0]'s shell name (e.g. "sh") puts curse into shell mode. */
static void fallback(char **argv) {
    const char *prog = getenv("CURSE_FALLBACK");
    if (!prog || !*prog) prog = "curse";
    execvp(prog, argv);
    /* If curse itself can't exec, mimic the shell's not-found status. */
    _exit(127);
}

/* Append a length-prefixed byte field to buf; returns new length (or -1 if it
 * wouldn't fit). All integers are host-endian uint32 (client and daemon are the
 * same machine — this is a local socket). */
static long put_u32(char *buf, long off, long cap, uint32_t v) {
    if (off < 0 || off + 4 > cap) return -1;
    memcpy(buf + off, &v, 4);
    return off + 4;
}
static long put_bytes(char *buf, long off, long cap, const char *s, uint32_t n) {
    off = put_u32(buf, off, cap, n);
    if (off < 0 || off + (long)n > cap) return -1;
    memcpy(buf + off, s, n);
    return off + n;
}

int main(int argc, char **argv, char **envp) {
    const char *rt = getenv("XDG_RUNTIME_DIR");
    if (!rt || !*rt) fallback(argv); /* no per-user runtime dir -> no daemon */

    char path[512];
    if ((size_t)snprintf(path, sizeof path, "%s/curse.sock", rt) >= sizeof path)
        fallback(argv);

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) fallback(argv);

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    if (strlen(path) >= sizeof addr.sun_path) fallback(argv);
    strcpy(addr.sun_path, path);
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) < 0) {
        close(fd);
        spawn_daemon(); /* not running -> start it for next time */
        fallback(argv); /* and run THIS request directly (daemon warms in the background) */
    }

    /* Build the request: magic, argv, cwd, environ. */
    static char buf[1 << 16];
    long off = 0, cap = sizeof buf;
    off = put_u32(buf, off, cap, CURSE_MAGIC);
    off = put_u32(buf, off, cap, (uint32_t)argc);
    for (int i = 0; i < argc && off >= 0; i++)
        off = put_bytes(buf, off, cap, argv[i], (uint32_t)strlen(argv[i]));
    char cwd[4096];
    if (off >= 0) {
        if (!getcwd(cwd, sizeof cwd)) cwd[0] = '\0';
        off = put_bytes(buf, off, cap, cwd, (uint32_t)strlen(cwd));
    }
    int nenv = 0;
    for (char **e = envp; *e; e++) nenv++;
    off = put_u32(buf, off, cap, (uint32_t)nenv);
    for (int i = 0; i < nenv && off >= 0; i++)
        off = put_bytes(buf, off, cap, envp[i], (uint32_t)strlen(envp[i]));
    /* Trailer: the signals this process ignores (bit n-1 = signal n). The script must
     * inherit them (ignored at entry stays ignored), but the worker doesn't share our
     * dispositions — so send them. */
    uint32_t sigign = 0;
    for (int s = 1; s < 32; s++) {
        struct sigaction sa;
        if (s != SIGKILL && s != SIGSTOP && sigaction(s, NULL, &sa) == 0 && sa.sa_handler == SIG_IGN)
            sigign |= 1u << (s - 1);
    }
    off = put_u32(buf, off, cap, sigign);
    /* Trailer: the other fds the script inherits (3..63, open and not close-on-exec, not
     * our own socket) — `cmd 3<&0` must see fd 3 — sent after 0,1,2 with their numbers. */
    int extra[64];
    int nextra = 0;
    for (int f = 3; f < 64; f++) {
        if (f == fd) continue;
        int fl = fcntl(f, F_GETFD);
        if (fl >= 0 && !(fl & FD_CLOEXEC)) extra[nextra++] = f;
    }
    off = put_u32(buf, off, cap, (uint32_t)nextra);
    for (int i = 0; i < nextra && off >= 0; i++)
        off = put_u32(buf, off, cap, (uint32_t)extra[i]);
    if (off < 0) { close(fd); fallback(argv); } /* request too big -> run directly */

    /* Send the request with fds 0,1,2 (then the extras) attached as SCM_RIGHTS data. */
    struct iovec iov = { buf, (size_t)off };
    union {
        char b[CMSG_SPACE(67 * sizeof(int))];
        struct cmsghdr align;
    } ctrl;
    memset(&ctrl, 0, sizeof ctrl);
    struct msghdr msg;
    memset(&msg, 0, sizeof msg);
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = ctrl.b;
    msg.msg_controllen = CMSG_SPACE((3 + nextra) * sizeof(int));
    struct cmsghdr *cm = CMSG_FIRSTHDR(&msg);
    cm->cmsg_level = SOL_SOCKET;
    cm->cmsg_type = SCM_RIGHTS;
    cm->cmsg_len = CMSG_LEN((3 + nextra) * sizeof(int));
    int passfds[67] = { 0, 1, 2 };
    for (int i = 0; i < nextra; i++) passfds[3 + i] = extra[i];
    memcpy(CMSG_DATA(cm), passfds, (3 + nextra) * sizeof(int));

    if (sendmsg(fd, &msg, 0) < 0) { close(fd); fallback(argv); }

    /* Read the exit status (int32). If the daemon dies mid-run, treat as 127. */
    int32_t status = 127;
    ssize_t got = 0, want = sizeof status;
    char *p = (char *)&status;
    while (got < want) {
        ssize_t r = read(fd, p + got, want - got);
        if (r <= 0) break;
        got += r;
    }
    close(fd);
    return (got == want) ? (status & 0xff) : 127;
}
