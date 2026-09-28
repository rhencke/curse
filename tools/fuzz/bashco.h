/* The bash side of the targeted fuzzers' differential (harness.c FUZZ_TARGET): ONE
 * persistent bash 5.2.21 per fuzzer instance, answering one request per input.
 *
 *   forkserver ──(SOCK_SEQPACKET socketpair, inherited by every fuzz child)── broker
 *                                                                              │ pipes
 *                                                  bash DRV  (pid 1 of its own pid+net ns)
 *
 * The broker is forked BEFORE the forkserver starts (so it outlives every fuzz child) and
 * owns bash: it restarts it when it dies, hangs (BCO_TMOUT_MS per request) or floods
 * (more than BCO_MAXOUT bytes). A fuzz child sends [u32 id][snippet]; the broker writes
 * the snippet + NUL to bash's stdin, reads bash's merged stdout+stderr up to the driver's
 * sentinel "\0\1NONCE:STATUS\n" (NONCE: random per instance, only in the driver file's
 * text -- never in a variable a snippet could print) and replies
 * [u32 id][u8 kind][i32 status][output]. Replies carry the request id: a child that AFL
 * killed mid-request leaves a stale reply in the socket, which the next child discards.
 *
 * bash's side is sandboxed like the fuzz child and then some: the harness's read-only
 * mount namespace + private tmpfs (sandbox.h), its own PID namespace (the fuzz child and
 * afl-fuzz are invisible; nothing it starts survives it) and network namespace (no
 * /dev/tcp), empty PATH (no externals), a fixed environment (PATH LC_ALL HOME TMPDIR TZ),
 * rlimits; the driver's prelude disables kill/exec/ulimit/suspend/wait/fg/bg/disown/enable
 * and turns on restricted mode (set -r: no output redirection, cd, PATH, slashes in
 * command names); every request runs in a fresh subshell `( eval "$__q" ) </dev/null`,
 * so no request sees another's state. targets.lua only ever builds snippets that pass
 * data as $'\xHH' words or (pexp/regex literal forms) that curse's parser reads as ONE
 * simple command / [[ ]] with no command or process substitution anywhere. */
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>

#define BCO_MAXREQ   65536
#define BCO_OUTCAP   60000        /* reply payload cap (a SEQPACKET message fits) */
#define BCO_MAXOUT   (1 << 20)    /* more than this from bash: flood, restart */
enum { BCO_OK = 0, BCO_TIMEOUT = 1, BCO_DIED = 2, BCO_FLOOD = 3, BCO_NOBASH = 4 };

static int bco_sock = -1, bco_tmo = 1000;
static uint32_t *bco_seq;         /* MAP_SHARED: request ids across fuzz children */

static long bco_now_ms(void)
{
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1000L + t.tv_nsec / 1000000L;
}

static long bco_now_us(void)
{
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1000000L + t.tv_nsec / 1000L;
}

/* ---- the broker ---------------------------------------------------------------------- */
static pid_t bco_pid = -1;        /* the intermediate (its child is bash, pid 1 of a new ns) */
static int bco_in = -1, bco_out = -1;

static void bco_kill(void)
{
  if (bco_pid > 0) {
    int st;
    kill(bco_pid, SIGKILL);       /* (bash: PDEATHSIG=KILL on the intermediate; the ns goes with it) */
    while (waitpid(bco_pid, &st, 0) < 0 && errno == EINTR);
  }
  if (bco_in >= 0) close(bco_in);
  if (bco_out >= 0) close(bco_out);
  bco_pid = -1; bco_in = bco_out = -1;
}

static int bco_spawn(const char *bash, const char *dir, const char *drv)
{
  int pi[2], po[2];
  if (pipe2(pi, O_CLOEXEC) || pipe2(po, O_CLOEXEC)) return -1;
  bco_pid = fork();
  if (bco_pid < 0) return -1;
  if (bco_pid == 0) {
    pid_t g;
    int st;
    prctl(PR_SET_PDEATHSIG, SIGKILL);
    if (unshare(CLONE_NEWPID | CLONE_NEWNET) != 0) _exit(126);
    g = fork();
    if (g == 0) {
      char w[4096], nb[4096], tmp[4096];
      char *argv[] = { "bash", (char *)drv, 0 };
      char *envp[7];
      struct rlimit r;
      prctl(PR_SET_PDEATHSIG, SIGKILL);
      dup2(pi[0], 0); dup2(po[1], 1); dup2(po[1], 2);
      { int f; for (f = 3; f < 256; f++) close(f); }
      snprintf(w, sizeof w, "%s/w", dir);
      if (chdir(w) != 0) _exit(126);
      snprintf(nb, sizeof nb, "PATH=%s/nobin", dir);
      snprintf(tmp, sizeof tmp, "TMPDIR=%s/tmp", dir);
      envp[0] = nb; envp[1] = "LC_ALL=C"; envp[2] = "HOME="; envp[3] = tmp; envp[4] = "TZ=UTC";
      envp[5] = "XDG_CACHE_HOME="; envp[6] = 0;  /* (= harness.c target_env) */
      /* (CPU: the bash itself only reads and forks; each request's subshell gets its own 5 s) */
      r.rlim_cur = r.rlim_max = 5;                 setrlimit(RLIMIT_CPU, &r);
      r.rlim_cur = r.rlim_max = 1 << 20;           setrlimit(RLIMIT_FSIZE, &r);
      r.rlim_cur = r.rlim_max = 0;                 setrlimit(RLIMIT_CORE, &r);
      r.rlim_cur = r.rlim_max = (rlim_t)1 << 30;   setrlimit(RLIMIT_AS, &r);
      execve(bash, argv, envp);
      _exit(127);
    }
    if (g < 0) _exit(126);
    while (waitpid(g, &st, 0) < 0 && errno == EINTR);
    _exit(0);
  }
  close(pi[0]); close(po[1]);
  bco_in = pi[1]; bco_out = po[0];
  fcntl(bco_in, F_SETFL, O_NONBLOCK);
  fcntl(bco_out, F_SETFL, O_NONBLOCK);
  return 0;
}

/* one request: write the snippet, read up to the sentinel */
static int bco_ask(const char *bash, const char *dir, const char *drv, const char *nonce,
                   const char *req, size_t rlen, char *out, size_t *olen, int *status)
{
  static char buf[BCO_MAXOUT + 64];
  char sent[64];
  size_t n = 0, off = 0, sl = (size_t)snprintf(sent, sizeof sent, "%c%c%s:", 0, 1, nonce);
  long dl = bco_now_ms() + bco_tmo;
  if (bco_pid < 0 && bco_spawn(bash, dir, drv) != 0) return BCO_NOBASH;
  while (off <= rlen) {  /* (the request + its NUL) */
    struct pollfd p = { bco_in, POLLOUT, 0 };
    long left = dl - bco_now_ms();
    ssize_t w;
    if (left <= 0) { bco_kill(); return BCO_TIMEOUT; }
    if (poll(&p, 1, (int)left) <= 0) continue;
    w = off < rlen ? write(bco_in, req + off, rlen - off) : write(bco_in, "", 1);
    if (w < 0) { if (errno == EAGAIN || errno == EINTR) continue; bco_kill(); return BCO_DIED; }
    off += w;
  }
  for (;;) {
    struct pollfd p = { bco_out, POLLIN, 0 };
    long left = dl - bco_now_ms();
    ssize_t r;
    char *s;
    if (n >= sl + 2 && (s = memmem(buf, n, sent, sl))) {
      char *nl = memchr(s + sl, '\n', buf + n - (s + sl));
      if (nl) {
        *status = atoi(s + sl);
        *olen = (size_t)(s - buf);
        if (*olen > BCO_OUTCAP) *olen = BCO_OUTCAP;  /* (the caller treats a full cap as truncated) */
        memcpy(out, buf, *olen);
        if (nl + 1 != buf + n) { bco_kill(); return BCO_DIED; }  /* (bytes after it: desync) */
        return BCO_OK;
      }
    }
    if (left <= 0) { bco_kill(); return BCO_TIMEOUT; }
    if (poll(&p, 1, (int)left) <= 0) continue;
    r = read(bco_out, buf + n, BCO_MAXOUT - n);
    if (r < 0) { if (errno == EAGAIN || errno == EINTR) continue; bco_kill(); return BCO_DIED; }
    if (r == 0) { bco_kill(); return BCO_DIED; }
    n += r;
    if (n >= BCO_MAXOUT) { bco_kill(); return BCO_FLOOD; }
  }
}

static void bco_broker(int sock, const char *bash, const char *dir, const char *drv, const char *nonce)
{
  static char req[BCO_MAXREQ + 8], rep[BCO_OUTCAP + 16];
  signal(SIGPIPE, SIG_IGN);
  signal(SIGCHLD, SIG_DFL);
  for (;;) {
    ssize_t n = recv(sock, req, sizeof req, 0);
    size_t olen = 0;
    int st = 0, k;
    if (n == 0) break;                     /* the forkserver (and every child) is gone */
    if (n < 0) { if (errno == EINTR) continue; break; }
    if (n < 4) continue;
    k = bco_ask(bash, dir, drv, nonce, req + 4, (size_t)n - 4, rep + 9, &olen, &st);
    memcpy(rep, req, 4);
    rep[4] = (char)k;
    memcpy(rep + 5, &st, 4);
    (void)!send(sock, rep, 9 + olen, MSG_NOSIGNAL);
  }
  bco_kill();
  _exit(0);
}

/* In the harness, before the forkserver: the broker, the shared id counter. */
static void bco_start(const char *bash, const char *dir, const char *drv, const char *nonce)
{
  int sp[2], hi;
  pid_t b;
  const char *t = getenv("FUZZ_BASH_TMOUT_MS");
  if (t && atoi(t) > 0) bco_tmo = atoi(t);
  bco_seq = mmap(0, 4096, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
  if (bco_seq == MAP_FAILED || socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, sp) != 0) sbx_die("broker socket");
  b = fork();
  if (b < 0) sbx_die("fork broker");
  if (b == 0) {
    close(sp[0]);
    prctl(PR_SET_PDEATHSIG, SIGKILL);
    bco_broker(sp[1], bash, dir, drv, nonce);
  }
  close(sp[1]);
  hi = fcntl(sp[0], F_DUPFD_CLOEXEC, 220);   /* (off the fds a script can see) */
  if (hi >= 0) { close(sp[0]); sp[0] = hi; }
  bco_sock = sp[0];
}

/* In a fuzz child: send now, collect later (bash works while curse runs). */
static uint32_t bco_send(const char *snip, size_t len)
{
  static char req[BCO_MAXREQ + 8];
  uint32_t id = __sync_add_and_fetch(bco_seq, 1);
  if (len > BCO_MAXREQ) len = BCO_MAXREQ;
  memcpy(req, &id, 4);
  memcpy(req + 4, snip, len);
  if (send(bco_sock, req, len + 4, MSG_NOSIGNAL) < 0) return 0;
  return id;
}

/* -> kind (BCO_*), or -1: no reply in time (the broker is busy with a stale request) */
static int bco_recv(uint32_t id, char *out, size_t *olen, int *status)
{
  static char rep[BCO_OUTCAP + 16];
  long dl = bco_now_ms() + 2 * bco_tmo + 500;  /* (a stale request ahead of ours, then ours) */
  for (;;) {
    struct pollfd p = { bco_sock, POLLIN, 0 };
    long left = dl - bco_now_ms();
    ssize_t n;
    uint32_t rid;
    if (left <= 0) return -1;
    if (poll(&p, 1, (int)left) <= 0) continue;
    n = recv(bco_sock, rep, sizeof rep, 0);
    if (n <= 0) { if (n < 0 && errno == EINTR) continue; return -1; }
    if (n < 9) continue;
    memcpy(&rid, rep, 4);
    if (rid != id) continue;                   /* (a stale reply for a killed child) */
    memcpy(status, rep + 5, 4);
    *olen = (size_t)n - 9;
    memcpy(out, rep + 9, *olen);
    return rep[4];
  }
}
