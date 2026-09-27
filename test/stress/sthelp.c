/* sthelp — process plumbing for the stress suite (test/stress/run.sh).
 *
 *   sthelp run STATUS TIMEOUT_MS IN OUT ERR -- CMD ARGS...
 *       Run CMD in a NEW SESSION with fds 0/1/2 from IN/OUT/ERR, every other fd
 *       closed, all signal dispositions default and the mask empty. Wait up to
 *       TIMEOUT_MS; on expiry SIGKILL the whole session (hang). Afterwards, any
 *       process still in the session (orphan, stopped job, zombie) is recorded and
 *       killed. STATUS gets lines:  "exit N" | "signal N" | "hang"; "ms N";
 *       "leftover PID STATE COMM" per stray process.  Exit status: 0.
 *   sthelp spawn LOG -- CMD ARGS...   start CMD detached in a new session (stdin
 *       /dev/null, stdout+stderr LOG, other fds closed); print its pid.
 *   sthelp scan SID [EXCLUDE_PID...]  print "PID STATE PPID COMM" for every process
 *       in session SID not excluded.
 *   sthelp children PPID              print the pids whose parent is PPID.
 *   sthelp killsid SID                SIGCONT+SIGKILL every process in session SID.
 *   sthelp probe                      fd-leak probe: append "fd N -> TARGET" for every
 *       open fd >= 3 to $STRESS_PROBE_OUT (nothing when clean).
 *   sthelp hammer PID SIG COUNT MIN_US MAX_US [DONEFILE]   send SIG to PID COUNT times
 *       at random intervals; stop at the first failed kill. Prints the number delivered;
 *       with DONEFILE it DETACHES (returns at once; a child sends) and writes the number
 *       there when done — a sender that starts even while the shell never yields.
 *   sthelp sendwhen PID SIG TIMEOUT_MS SYSCALLS [FIFO]   wait until PID sleeps in a
 *       system call (SYSCALLS: comma-separated x86-64 numbers, or "any") for three
 *       samples in a row, then send SIG; with FIFO, then open it for writing, write
 *       "go" and close (unblocking the target). Exit 0 when sent, 3 when PID never
 *       blocked in time (or is gone) — the caller prints a verdict either way.
 *   sthelp exec CMD ARGS...            exec CMD with every signal disposition default and
 *       an empty mask (a `cmd &` of a non-interactive bash ignores INT and QUIT).
 *   sthelp busy                       spin forever (artificial load).
 *
 * Built with -DST_WRAPPER -DST_LUAJIT=… -DST_REPO=…, it is instead the direct shells'
 * $THIS_SH: under any name it execs `luajit lua/run.lua ARGS…` from the sources, with
 * CURSE_ARGV0 = its own argv[0] (tests copy it to `sh`). A #!/bin/sh wrapper would not do:
 * dash drops environment entries whose names aren't identifiers, such as exported
 * functions' BASH_FUNC_f-g%%.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static long now_ms(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000L + t.tv_nsec / 1000000L;
}

/* /proc/PID/stat: comm may contain spaces/parens — parse from the LAST ')'. */
static int stat_of(int pid, char *state, int *ppid, int *pgrp, int *sid, char *comm, size_t cn) {
    char p[64], buf[1024]; snprintf(p, sizeof p, "/proc/%d/stat", pid);
    int fd = open(p, O_RDONLY | O_CLOEXEC); if (fd < 0) return -1;
    ssize_t n = read(fd, buf, sizeof buf - 1); close(fd); if (n <= 0) return -1; buf[n] = 0;
    char *l = strchr(buf, '('), *r = strrchr(buf, ')'); if (!l || !r) return -1;
    size_t k = (size_t)(r - l - 1); if (k >= cn) k = cn - 1; memcpy(comm, l + 1, k); comm[k] = 0;
    if (sscanf(r + 2, "%c %d %d %d", state, ppid, pgrp, sid) != 4) return -1;
    return 0;
}

typedef void (*proc_cb)(int pid, char st, int ppid, const char *comm, void *u);
static int each_in_session(int sid, proc_cb cb, void *u) {
    DIR *d = opendir("/proc"); if (!d) return 0; struct dirent *e; int n = 0;
    while ((e = readdir(d))) {
        int pid = atoi(e->d_name); if (pid <= 0) continue;
        char st, comm[64]; int ppid, pg, s;
        if (stat_of(pid, &st, &ppid, &pg, &s, comm, sizeof comm) == 0 && s == sid) { n++; if (cb) cb(pid, st, ppid, comm, u); }
    }
    closedir(d); return n;
}

static void close_from3(void) {
#ifdef SYS_close_range
    if (syscall(SYS_close_range, 3, ~0U, 0) == 0) return;
#endif
    for (int fd = 3; fd < 65536; fd++) close(fd);
}

static void clean_signals(void) {
    struct sigaction sa; memset(&sa, 0, sizeof sa); sa.sa_handler = SIG_DFL; sigemptyset(&sa.sa_mask);
    for (int s = 1; s < 65; s++) if (s != SIGKILL && s != SIGSTOP) sigaction(s, &sa, NULL);
    sigset_t m; sigemptyset(&m); sigprocmask(SIG_SETMASK, &m, NULL);
}

static int open_or_die(const char *p, int fl) {
    int fd = open(p, fl, 0644); if (fd < 0) { perror(p); _exit(126); } return fd;
}

static void kill_cb(int pid, char st, int ppid, const char *comm, void *u) {
    (void)st; (void)ppid; (void)comm; (void)u; kill(pid, SIGCONT); kill(pid, SIGKILL);
}
struct lo { FILE *f; int self; };
static void cmdline_of(int pid, char *out, size_t n) {
    char p[64]; snprintf(p, sizeof p, "/proc/%d/cmdline", pid); out[0] = 0;
    int fd = open(p, O_RDONLY | O_CLOEXEC); if (fd < 0) return;
    ssize_t k = read(fd, out, n - 1); close(fd); if (k <= 0) { out[0] = 0; return; }
    for (ssize_t i = 0; i < k; i++) if (!out[i]) out[i] = ' ';
    out[k] = 0; while (k > 0 && out[k - 1] == ' ') out[--k] = 0;
}
static void leftover_cb(int pid, char st, int ppid, const char *comm, void *u) {
    struct lo *l = u; if (pid == l->self) return;
    char cl[160]; cmdline_of(pid, cl, sizeof cl);
    fprintf(l->f, "leftover %d %c ppid=%d %s [%s]\n", pid, st, ppid, comm, cl);
}
static void count_cb(int pid, char st, int ppid, const char *comm, void *u) {
    (void)st; (void)ppid; (void)comm; int *c = u; (void)pid; (*c)++;
}

static int cmd_run(int argc, char **argv) {
    if (argc < 8 || strcmp(argv[7], "--")) { fprintf(stderr, "usage: sthelp run STATUS TIMEOUT_MS IN OUT ERR -- CMD...\n"); return 2; }
    const char *stf = argv[2]; long tmo = atol(argv[3]);
    long t0 = now_ms();
    pid_t pid = fork();
    if (pid < 0) { perror("fork"); return 2; }
    if (pid == 0) {
        setsid();
        int i = open_or_die(argv[4], O_RDONLY), o = open_or_die(argv[5], O_WRONLY | O_CREAT | O_TRUNC),
            e = open_or_die(argv[6], O_WRONLY | O_CREAT | O_TRUNC);
        dup2(i, 0); dup2(o, 1); dup2(e, 2);
        close_from3(); clean_signals();
        execvp(argv[8], argv + 8); perror(argv[8]); _exit(127);
    }
    int pfd = (int)syscall(434, pid, 0); /* pidfd_open */
    int status = 0, done = 0, hang = 0;
    while (!done) {
        long left = tmo - (now_ms() - t0);
        if (left <= 0) { hang = 1; break; }
        if (pfd >= 0) { struct pollfd p = { pfd, POLLIN, 0 }; poll(&p, 1, left > 1000 ? 1000 : (int)left); }
        else usleep(2000);
        pid_t r = waitpid(pid, &status, WNOHANG);
        if (r == pid) done = 1;
    }
    FILE *f = fopen(stf, "w"); if (!f) { perror(stf); return 2; }
    if (hang) {
        /* SIGKILL the session (the shell first: it can't respawn anything after) */
        kill(pid, SIGKILL); each_in_session(pid, kill_cb, NULL); waitpid(pid, &status, 0);
        fprintf(f, "hang\n");
    } else if (WIFEXITED(status)) fprintf(f, "exit %d\n", WEXITSTATUS(status));
    else fprintf(f, "signal %d\n", WTERMSIG(status));
    fprintf(f, "ms %ld\n", now_ms() - t0);
    /* stray processes: give just-exiting ones 300ms to go (orphans reparented to init
     * are reaped by it), then record and kill whatever is still in the session. */
    if (!hang) {
        long ts = now_ms(); int c;
        do { c = 0; each_in_session(pid, count_cb, &c); if (!c) break; usleep(10000); } while (now_ms() - ts < 300);
        struct lo l = { f, getpid() }; each_in_session(pid, leftover_cb, &l);
        each_in_session(pid, kill_cb, NULL);
    }
    fclose(f); return 0;
}

static int cmd_spawn(int argc, char **argv) {
    if (argc < 5 || strcmp(argv[3], "--")) { fprintf(stderr, "usage: sthelp spawn LOG -- CMD...\n"); return 2; }
    int pp[2]; if (pipe2(pp, O_CLOEXEC)) return 2;
    pid_t pid = fork();
    if (pid == 0) {
        setsid();
        int i = open_or_die("/dev/null", O_RDONLY), o = open_or_die(argv[2], O_WRONLY | O_CREAT | O_APPEND);
        dup2(i, 0); dup2(o, 1); dup2(o, 2);
        int w = pp[1]; close(pp[0]);
        for (int fd = 3; fd < 65536; fd++) if (fd != w) close(fd);
        clean_signals();
        execvp(argv[4], argv + 4); _exit(127);
    }
    close(pp[1]); char c; (void)!read(pp[0], &c, 1); /* EOF at exec */
    printf("%d\n", (int)pid); return 0;
}

struct ex { int n; int *pids; };
static void scan_cb(int pid, char st, int ppid, const char *comm, void *u) {
    struct ex *x = u; for (int i = 0; i < x->n; i++) if (x->pids[i] == pid) return;
    char cl[160]; cmdline_of(pid, cl, sizeof cl);
    printf("%d %c %d %s [%s]\n", pid, st, ppid, comm, cl);
}
static int cmd_scan(int argc, char **argv) {
    if (argc < 3) return 2;
    struct ex x = { argc - 3, calloc((size_t)argc, sizeof(int)) };
    for (int i = 3; i < argc; i++) x.pids[i - 3] = atoi(argv[i]);
    each_in_session(atoi(argv[2]), scan_cb, &x); return 0;
}
static int cmd_children(int argc, char **argv) {
    if (argc < 3) return 2;
    int pp = atoi(argv[2]);
    DIR *d = opendir("/proc"); struct dirent *e;
    while ((e = readdir(d))) {
        int pid = atoi(e->d_name); if (pid <= 0) continue;
        char st, comm[64]; int ppid, pg, s;
        if (stat_of(pid, &st, &ppid, &pg, &s, comm, sizeof comm) == 0 && ppid == pp) printf("%d %c %s\n", pid, st, comm);
    }
    closedir(d); return 0;
}
static int cmd_killsid(int argc, char **argv) {
    if (argc < 3) return 2;
    int sid = atoi(argv[2]);
    if (sid <= 1) return 2;
    each_in_session(sid, kill_cb, NULL); return 0;
}

static int cmd_probe(void) {
    int open_fds[256], n = 0;
    for (int fd = 3; fd < 4096 && n < 256; fd++) if (fcntl(fd, F_GETFD) != -1) open_fds[n++] = fd;
    if (!n) return 0;
    const char *out = getenv("STRESS_PROBE_OUT");
    char buf[8192]; size_t off = 0;
    for (int i = 0; i < n; i++) {
        char p[64], t[512]; snprintf(p, sizeof p, "/proc/self/fd/%d", open_fds[i]);
        ssize_t k = readlink(p, t, sizeof t - 1); if (k < 0) k = 0; t[k] = 0;
        off += (size_t)snprintf(buf + off, sizeof buf - off, "fd %d -> %s (probe ppid %d)\n", open_fds[i], t, (int)getppid());
        if (off >= sizeof buf - 600) break;
    }
    int fd = out ? open(out, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644) : 2;
    if (fd >= 0) { (void)!write(fd, buf, off); if (out) close(fd); }
    return 0;
}

static int cmd_hammer(int argc, char **argv) {
    if (argc < 7) return 2;
    int pid = atoi(argv[2]), sig = atoi(argv[3]); long cnt = atol(argv[4]), lo = atol(argv[5]), hi = atol(argv[6]);
    if (pid <= 1) return 2;
    const char *done = argc > 7 ? argv[7] : NULL;
    if (done) { pid_t c = fork(); if (c < 0) return 2; if (c > 0) return 0; }
    srand((unsigned)(getpid() ^ now_ms()));
    long sent = 0;
    for (long i = 0; i < cnt; i++) {
        long us = lo + (hi > lo ? rand() % (hi - lo + 1) : 0);
        if (us > 0) usleep((useconds_t)us);
        if (kill(pid, sig)) break;
        sent++;
    }
    if (done) {
        char tmp[4096]; snprintf(tmp, sizeof tmp, "%s.tmp", done);
        FILE *f = fopen(tmp, "w"); if (f) { fprintf(f, "%ld\n", sent); fclose(f); rename(tmp, done); }
        _exit(0);
    }
    printf("%ld\n", sent); return 0;
}

static int blocked_in(int pid, const char *set) {
    char p[64], buf[256], st, comm[64]; int ppid, pg, sid;
    if (stat_of(pid, &st, &ppid, &pg, &sid, comm, sizeof comm)) return -1;
    if (st != 'S' && st != 'D') return 0;
    snprintf(p, sizeof p, "/proc/%d/syscall", pid);
    int fd = open(p, O_RDONLY | O_CLOEXEC); if (fd < 0) return -1;
    ssize_t n = read(fd, buf, sizeof buf - 1); close(fd); if (n <= 0) return 0; buf[n] = 0;
    if (!strncmp(buf, "running", 7) || buf[0] == '-') return 0;
    if (!strcmp(set, "any")) return 1;
    long nr = atol(buf); char tmp[256]; snprintf(tmp, sizeof tmp, "%s", set);
    for (char *t = strtok(tmp, ","); t; t = strtok(NULL, ",")) if (atol(t) == nr) return 1;
    return 0;
}
static int cmd_sendwhen(int argc, char **argv) {
    if (argc < 6) return 2;
    int pid = atoi(argv[2]), sig = atoi(argv[3]); long tmo = atol(argv[4]); const char *set = argv[5];
    if (pid <= 1) return 2;
    long t0 = now_ms(); int streak = 0, sent = 0;
    while (now_ms() - t0 < tmo) {
        int b = blocked_in(pid, set);
        if (b < 0) break;
        streak = b ? streak + 1 : 0;
        if (streak >= 3) { sent = kill(pid, sig) == 0; break; }
        usleep(2000);
    }
    /* (non-blocking open, retried for 3s: if the shell died or gave up on the fifo, a
     * blocking open would hang this sender forever — and whoever waits for it) */
    if (argc > 6) {
        long t1 = now_ms(); int fd;
        while ((fd = open(argv[6], O_WRONLY | O_NONBLOCK | O_CLOEXEC)) < 0 && errno == ENXIO && now_ms() - t1 < 3000)
            usleep(2000);
        if (fd >= 0) { (void)!write(fd, "go\n", 3); close(fd); } else sent = 0;
    }
    return sent ? 0 : 3;
}

int main(int argc, char **argv) {
#ifdef ST_WRAPPER
    {
        char **nv = calloc((size_t)argc + 2, sizeof *nv);
        nv[0] = ST_LUAJIT; nv[1] = ST_REPO "/lua/run.lua";
        for (int i = 1; i < argc; i++) nv[i + 1] = argv[i];
        setenv("CURSE_ARGV0", argv[0], 1); setenv("CURSE_BUNDLE", "", 1);
        setenv("LUA_PATH", ST_REPO "/lua/?.lua;;", 1);
        execv(ST_LUAJIT, nv); perror(ST_LUAJIT); return 127;
    }
#endif
    if (argc < 2) return 2;
    const char *c = argv[1];
    if (!strcmp(c, "run")) return cmd_run(argc, argv);
    if (!strcmp(c, "spawn")) return cmd_spawn(argc, argv);
    if (!strcmp(c, "scan")) return cmd_scan(argc, argv);
    if (!strcmp(c, "children")) return cmd_children(argc, argv);
    if (!strcmp(c, "killsid")) return cmd_killsid(argc, argv);
    if (!strcmp(c, "probe")) return cmd_probe();
    if (!strcmp(c, "hammer")) return cmd_hammer(argc, argv);
    if (!strcmp(c, "sendwhen")) return cmd_sendwhen(argc, argv);
    if (!strcmp(c, "exec") && argc > 2) { clean_signals(); execvp(argv[2], argv + 2); perror(argv[2]); return 127; }
    if (!strcmp(c, "busy")) { volatile unsigned long x = 0; for (;;) x++; }
    fprintf(stderr, "sthelp: unknown command %s\n", c); return 2;
}
