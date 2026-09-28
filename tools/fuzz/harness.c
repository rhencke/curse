/* AFL++ harness for curse.
 *
 * One LuaJIT state, the embedded curse bundle, every module required up front; then
 * AFL's deferred forkserver (__AFL_INIT) forks per input (or, -DPERSIST, __AFL_LOOP).
 * The child runs the script the production way (the bundled `run` module, dev form
 * `run SCRIPT MODE`), inside sandbox.h's read-only mount namespace.
 *
 * Coverage: Lua-LEVEL edges, not machine code (every script runs the same VM loop).
 * A C line hook maps (engine module, line) -> a map slot and bumps AFL-style edges
 * map[cur ^ prev]++ into AFL's shared map (__afl_area_ptr). Only curse's own modules
 * (chunk names "=runtime", "=interp", ...) count: the compiled tier's emitted chunks
 * mirror the INPUT's shape, not engine behaviour (FUZZ_GENCOV=1 counts them too).
 * The JIT is off while tracing (a line hook never runs inside traces).
 * lua_sethook is --wrap'ed so curse's own one-shot signal hook (lib_cursesig.c) and
 * the coverage hook coexist instead of the former dropping the latter.
 * kill is --wrap'ed: pid -1 (everything the user owns) and the forkserver are refused.
 *
 * Oracle (a): an error escaping the shell (the run pcall fails) or stderr carrying a
 * Lua-internal message (see BAD[]) => abort() => an AFL crash.
 *
 * Env: FUZZ_SBX=DIR (sandbox mount point, required), FUZZ_MODE=tiered|interp|compiled,
 *      FUZZ_NOCOV=1 (no hook, JIT on), FUZZ_GENCOV=1, FUZZ_KEEPOUT=1 (triage: keep the
 *      script's stdout/stderr visible). */
#include "sandbox.h"
#include <signal.h>
#include <stdint.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/prctl.h>
#include <time.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#ifndef __AFL_INIT
#define __AFL_INIT() do {} while (0)
#define __AFL_LOOP(n) (__afl_loop_once++ == 0)
static int __afl_loop_once;
#endif
#ifdef PERSIST
__AFL_FUZZ_INIT();
#endif

extern const unsigned char curse_bundle_bc[];
extern const unsigned int curse_bundle_bc_len;
unsigned char *fuzz_area(void);      /* afl_glue.c */
unsigned int fuzz_map_size(void);
void fuzz_claim_map(unsigned int n);

static lua_State *globalL;
lua_State *curse_globalL(void) { return globalL; }

/* ---- coverage ---------------------------------------------------------------- */
static unsigned char *covmap;
static uint32_t covmask, prev_loc;
static int cov_on, gencov, covdebug;
static unsigned long hookcalls, hooklines;
#define SC 4096
static const char *sc_ptr[SC];
static uint32_t sc_id[SC];   /* 0 = not an engine module (ignored) */

static uint32_t src_id(const char *s)
{
  uintptr_t k = (uintptr_t)s;
  uint32_t i = (uint32_t)((k >> 4) * 2654435761u) & (SC - 1), n;
  for (n = 0; n < 16; n++, i = (i + 1) & (SC - 1)) {
    if (sc_ptr[i] == s) return sc_id[i];
    if (!sc_ptr[i]) break;
  }
  { /* miss: FNV of the chunk name; engine modules are "=name" with [a-z0-9_] only */
    uint32_t h = 2166136261u; const char *p; int mod = s[0] == '=';
    for (p = s; *p && p - s < 64; p++) {
      h = (h ^ (unsigned char)*p) * 16777619u;
      if (p > s && !((*p >= 'a' && *p <= 'z') || (*p >= '0' && *p <= '9') || *p == '_' || *p == '.')) mod = 0;
    }
    if (!mod && !gencov) h = 0;
    else if (!h) h = 1;
    if (n < 16) { sc_ptr[i] = s; sc_id[i] = h; }
    return h;
  }
}

static lua_Hook sig_f;  /* curse's own hook while one is scheduled */
extern void __real_lua_sethook(lua_State *L, lua_Hook f, int mask, int count);

static void cov_hook(lua_State *L, lua_Debug *ar)
{
  hookcalls++;
  if (ar->event == LUA_HOOKLINE) {
    uint32_t id, cur;
    if (!lua_getinfo(L, "S", ar) || !ar->source) return;
    id = src_id(ar->source);
    if (!id) return;
    hooklines++;
    cur = (id ^ ((uint32_t)ar->currentline * 0x9E3779B1u)) & covmask;
    covmap[cur ^ prev_loc]++;
    prev_loc = cur >> 1;
    return;
  }
  if (sig_f) sig_f(L, ar);
}

void __wrap_lua_sethook(lua_State *L, lua_Hook f, int mask, int count)
{
  if (!cov_on || f == cov_hook) { __real_lua_sethook(L, f, mask, count); return; }
  if (!f || !mask) { sig_f = 0; __real_lua_sethook(L, cov_hook, LUA_MASKLINE, 0); return; }
  sig_f = f;
  __real_lua_sethook(L, cov_hook, mask | LUA_MASKLINE, count);
}

/* ---- kill guard -------------------------------------------------------------- */
static pid_t fs_pid;  /* 0 inside the per-exec pid namespace (run_one): no guard needed */
static int getenv_ns = 1;
extern int __real_kill(pid_t, int);
int __wrap_kill(pid_t pid, int sig)
{
  /* Under fuzz.sh's pid namespace (in_ns) pids only grow: 1 = the namespace's init, 2 =
   * afl-fuzz, then the forkserver (fs_pid). Everything at or below fs_pid, and its
   * process groups, is off limits; the fuzz child is its own group, so kill 0 is safe. */
  if ((pid == -1 && fs_pid) || (fs_pid && ((pid > 0 && pid <= fs_pid) || (pid < 0 && -pid <= fs_pid)))) { errno = EPERM; return -1; }
  return __real_kill(pid, sig);
}

/* ---- stderr oracle ----------------------------------------------------------- */
static const char *BAD[] = {
  "attempt to ", "stack traceback", "bad argument #", "internal error", "pipeline stage:",
  "table: 0x", "function: 0x", "cdata<", "userdata: 0x", "curse-nocompile", "C stack overflow",
  "not enough memory", ".lua:", "curse:arith", "curse.bundle:", "curse:compiled:", "curse:eval:", "curse:line:", 0 };
/* also "<module>:<digits>:" (a Lua error position in an engine chunk) */
static int lua_pos(const char *b, size_t n, size_t *at)
{
  size_t i, j;
  for (i = 0; i + 2 < n; i++) {
    if (b[i] != ':' || !(b[i + 1] >= '0' && b[i + 1] <= '9')) continue;
    for (j = i + 1; j < n && b[j] >= '0' && b[j] <= '9'; j++);
    if (j >= n || b[j] != ':') continue;
    if (i == 0 || !((b[i - 1] >= 'a' && b[i - 1] <= 'z') || b[i - 1] == '_')) continue;
    { size_t k = i; while (k > 0 && ((b[k - 1] >= 'a' && b[k - 1] <= 'z') || b[k - 1] == '_' || (b[k - 1] >= '0' && b[k - 1] <= '9'))) k--;
      if (i - k >= 3 && (k == 0 || b[k - 1] == ' ' || b[k - 1] == '\n' || b[k - 1] == '\t')) {
        static const char *mods[] = { "runtime", "interp", "parser", "emit", "tier", "invoke", "cache",
          "smatch", "deparse", "hist", "repl", "run", "l10n", "gettext", "mailcheck", "bundle",
          "compiled", "eval", "line", "arith", "helpdata", 0 };
        int m; size_t L = i - k;
        for (m = 0; mods[m]; m++) if (strlen(mods[m]) == L && !memcmp(b + k, mods[m], L)) { *at = k; return 1; }
        if (L > 2 && b[k] == 'b' && b[k + 1] == '_') { *at = k; return 1; }
      } }
  }
  return 0;
}

static int errfd = -1, savederr = -1, keepout, persist, nooracle;
static pid_t child_pid;
static char *input; static size_t inlen;

static void check_stderr(void)
{
  static char buf[1 << 16];
  ssize_t n;
  size_t at = 0;
  int b;
  if (getpid() != child_pid || errfd < 0) return;
  if (covdebug && savederr >= 0) {
    unsigned i, nz = 0; uint32_t sz = fuzz_map_size() ? fuzz_map_size() : 262144;
    for (i = 0; i < sz && covmap; i++) nz += covmap[i] != 0;
    dprintf(savederr, "COVDEBUG hookcalls=%lu enginelines=%lu nonzero=%u mapsize=%u\n", hookcalls, hooklines, nz, sz);
  }
  fflush(stderr);
  n = pread(errfd, buf, sizeof buf - 1, 0);
  if (n <= 0) return;
  buf[n] = 0;
  if (keepout && persist && savederr >= 0) (void)!write(savederr, buf, n);
  for (b = 0; BAD[b]; b++) {
    char *hit = memmem(buf, n, BAD[b], strlen(BAD[b]));
    /* (the script's own text echoed back is not an engine message) */
    if (hit && !memmem(input, inlen, BAD[b], strlen(BAD[b]))) goto bad;
  }
  if (lua_pos(buf, n, &at)) goto bad;
  return;
bad:
  if (nooracle) return;
  if (savederr >= 0) { dprintf(savederr, "FUZZ-ORACLE stderr:\n"); (void)!write(savederr, buf, n); }
  abort();
}

static int lua_traceback(lua_State *L)
{
  const char *m = lua_tostring(L, 1);
  if (lua_istable(L, 1)) {
    lua_getfield(L, 1, "__fuzz_exit");
    if (!lua_isnil(L, -1)) { lua_pushliteral(L, "__FUZZ_EXIT__"); return 1; }
    lua_pop(L, 1);
  }
  luaL_traceback(L, L, m ? m : "(non-string error)", 1);
  return 1;
}

static const char *INIT =
  "local cov = ...\n"
  "if cov then jit.off() end\n"
  "for _, m in ipairs({'runtime','interp','invoke','parser','tier','emit','cache','smatch','deparse'}) do require(m) end\n"
  "for name in pairs(package.preload) do if name:match('^b_') then pcall(require, name) end end\n"
  "function __fuzz_one(path, mode, persist)\n"
  "  arg = { [0] = 'bash', path, mode }\n"
  "  -- (not require('run'): runtime's require wrapper would hold signals for the whole run)\n"
  "  return package.preload.run('run')\n"
  "end\n";

static char pathbuf[4200], tmpbuf[4200];
static void set_env(void)  /* (after __AFL_INIT: AFL's own vars are read by then) */
{
  clearenv();
  setenv("PATH", pathbuf, 1);
  setenv("TMPDIR", tmpbuf, 1);
  setenv("LC_ALL", "C", 1);
  setenv("HOME", "", 1);             /* (no compile cache: runs must not depend on earlier ones) */
  setenv("XDG_CACHE_HOME", "", 1);
}

static void run_one(const char *sbx, const char *mode)
{
  char path[4096];
  int fd;
  snprintf(path, sizeof path, "%s/s.sh", sbx);
  fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0) sbx_die("write script");
  (void)!write(fd, input, inlen);
  close(fd);
  sbx_reset_cwd(sbx);
  if (!persist) sbx_limits();
  { /* The script must find 3-9 (and beyond) closed, as under a real shell: without this,
     * an fd some ancestor left open and forgot about -- afl-cmin's own list-file fd is
     * the one that bit us, inherited across its exec of afl-showmap and then of us,
     * landing at fd 4/5 -- is visible to the fuzzed script. A generated/mutated script
     * doing `exec 5>...`, `>&4`, or a dup chain onto one of those numbers then reads or
     * WRITES the leaked file instead of getting the clean EBADF a real shell's fd 4/5
     * would give it (observed: afl-cmin's -T parallelism leaks its OWN per-instance
     * queue-list fds this way, and a leaked "redirect" test then appended stray lines to
     * the OTHER instance's list -- afl-cmin misread them as paths: "Unable to access
     * '<content>'"). AFL's own forkserver control fds sit at 198/199, well above this
     * sweep, and our own savederr/errfd (below) are relocated to >=200/>=210 afterward. */
    int fd3; for (fd3 = 3; fd3 < 128; fd3++) close(fd3);
  }
  fd = open("/dev/null", O_RDWR);
  dup2(fd, 0);
  if (!keepout) dup2(fd, 1);
  close(fd);
  errfd = memfd_create("fuzzerr", MFD_CLOEXEC);
  { /* (off the low fds: the script must find 3-9 closed, as under a real shell) */
    int hi = fcntl(errfd, F_DUPFD_CLOEXEC, 210);
    if (hi >= 0) { close(errfd); errfd = hi; }
  }
  dup2(errfd, 2);
  if (!persist) {
    /* A supervisor: the script runs in a worker, and only the worker's death by a
     * CRASH signal (abort -- our oracle --, SEGV, BUS, ILL, FPE, SYS) is passed on to
     * AFL. A script killing itself (`kill -USR1 $$` with no trap) is bash behaviour,
     * not a curse crash. The worker dies with us when AFL kills us on a timeout. */
    /* The worker gets a pid namespace of its own, per exec: whatever the script leaves
     * behind (background jobs, a `/bin/sh` fork bomb, orphans ignoring signals) dies
     * with the exec instead of piling up in the instance's namespace -- where it would
     * starve AFL's next fork (RLIMIT_NPROC, the container's pids limit) and burn CPU.
     * A tiny init (pid 1) runs the worker as pid 2, so the script keeps normal signal
     * semantics (`kill $$` works; pid 1 would ignore it), and hands back the worker's
     * wait status through a shared page. The init dies with us (PDEATHSIG), and the
     * whole namespace with it. */
    static volatile int *wst;
    int ns = 0;
    pid_t w;
    if (!wst) wst = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (wst != MAP_FAILED && getenv_ns && unshare(CLONE_NEWPID) == 0) ns = 1;
    w = fork();
    if (w == 0 && ns) {  /* the namespace's init */
      pid_t w2;
      int st2 = 0;
      prctl(PR_SET_PDEATHSIG, SIGKILL);
      *wst = -1;
      w2 = fork();
      if (w2 > 0) {
        while (waitpid(w2, &st2, 0) < 0 && errno == EINTR);
        *wst = st2;
        _exit(0);  /* (as pid 1: the kernel kills the rest of the namespace) */
      }
      if (w2 < 0) _exit(111);
      fs_pid = 0;  /* (nothing outside this namespace is reachable from here on) */
    }
    if (w > 0) {
      int st = 0;
      while (waitpid(w, &st, 0) < 0 && errno == EINTR);
      if (ns) {
        if (WIFEXITED(st) && WEXITSTATUS(st) == 0 && *wst != -1) st = *wst;
        else if (WIFSIGNALED(st)) st = SIGKILL;  /* (init killed from outside: not a crash) */
      }
      if (keepout && savederr >= 0) {  /* (the worker's stderr, even when a signal ended it) */
        static char eb[1 << 16]; ssize_t en = pread(errfd, eb, sizeof eb, 0);
        if (en > 0) (void)!write(savederr, eb, en);
      }
      if (WIFSIGNALED(st)) {
        int sg = WTERMSIG(st);
        if (sg == SIGABRT || sg == SIGSEGV || sg == SIGBUS || sg == SIGILL || sg == SIGFPE || sg == SIGSYS) abort();
      }
      _exit(WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st));
    }
    prctl(PR_SET_PDEATHSIG, SIGKILL);
    setpgid(0, 0);
  }
  child_pid = getpid();
  if (!persist) atexit(check_stderr);
  if (cov_on && (fuzz_area() || covdebug)) {
    covmap = fuzz_area() ? fuzz_area() : calloc(1, 262144);
    { uint32_t sz = fuzz_map_size() ? fuzz_map_size() : 65536, p2 = 1;
      while (p2 * 2 <= sz) p2 *= 2;
      covmask = p2 - 1; }
    __real_lua_sethook(globalL, cov_hook, LUA_MASKLINE, 0);
  }
  lua_pushcfunction(globalL, lua_traceback);
  lua_getglobal(globalL, "__fuzz_one");
  lua_pushstring(globalL, path);
  lua_pushstring(globalL, mode);
  if (lua_pcall(globalL, 2, 0, -4) != 0) {
    const char *m = lua_tostring(globalL, -1);
    if (!(persist && m && !strcmp(m, "__FUZZ_EXIT__"))) {  /* (persist: our os.exit) */
      if (savederr >= 0) dprintf(savederr, "FUZZ-ORACLE escaped: %s\n", m);
      if (nooracle) exit(1);  /* (the static binary's report + status 1) */
      abort();
    }
  }
  lua_settop(globalL, 0);
  if (persist) {
    fflush(stdout);
    check_stderr();
    close(errfd); errfd = -1;
    prev_loc = 0;
    return;
  }
  exit(0);
}

int main(int argc, char **argv)
{
  const char *sbx = getenv("FUZZ_SBX"), *mode = getenv("FUZZ_MODE");
  const char *ms = getenv("FUZZ_MAP_SIZE");
  lua_State *L;
  (void)argc; (void)argv;
  if (!sbx) { fprintf(stderr, "harness: FUZZ_SBX=DIR required\n"); return 111; }
  if (!mode) mode = "tiered";
  cov_on = !getenv("FUZZ_NOCOV");
  gencov = !!getenv("FUZZ_GENCOV");
  keepout = !!getenv("FUZZ_KEEPOUT");
  covdebug = !!getenv("FUZZ_COVDEBUG");
  nooracle = !!getenv("FUZZ_NOORACLE");
  getenv_ns = !getenv("FUZZ_NO_EXEC_NS");
  sbx_enter(sbx);
  snprintf(pathbuf, sizeof pathbuf, "%s/nobin", sbx);
  snprintf(tmpbuf, sizeof tmpbuf, "%s/tmp", sbx);
  /* (rlimits go on each CHILD in run_one: RLIMIT_CPU on the forkserver itself would
   * kill it with SIGXCPU once its forks add up to 5s) */
  signal(SIGPIPE, SIG_DFL);
  savederr = fcntl(2, F_DUPFD_CLOEXEC, 200);

  L = luaL_newstate();
  globalL = L;
  lua_gc(L, LUA_GCSTOP, 0);
  luaL_openlibs(L);
  if (luaL_loadbuffer(L, (const char *)curse_bundle_bc, curse_bundle_bc_len, "=curse.bundle") || lua_pcall(L, 0, 0, 0)) {
    fprintf(stderr, "harness: bundle: %s\n", lua_tostring(L, -1)); return 111;
  }
  lua_gc(L, LUA_GCRESTART, -1);
  if (luaL_loadbuffer(L, INIT, strlen(INIT), "=fuzzinit")) { fprintf(stderr, "harness: init: %s\n", lua_tostring(L, -1)); return 111; }
  lua_pushboolean(L, cov_on);
  if (lua_pcall(L, 1, 0, 0)) { fprintf(stderr, "harness: init: %s\n", lua_tostring(L, -1)); return 111; }
  fs_pid = getpid();
  fuzz_claim_map(ms ? (unsigned)atoi(ms) : 262144);

#ifdef PERSIST
  /* TRUE persistent mode: the shell runs in THIS process, many inputs per process; os.exit
   * becomes an error the harness catches. Whatever state curse keeps at module level leaks
   * from one input into the next -- AFL's "stability" figure measures how much. */
  luaL_dostring(L, "os.exit = function(c) error({ __fuzz_exit = c or 0 }, 0) end");
  __AFL_INIT();
  set_env();
  {
    unsigned char *buf = __AFL_FUZZ_TESTCASE_BUF;
    persist = 1;
    while (__AFL_LOOP(1000)) {
      inlen = __AFL_FUZZ_TESTCASE_LEN;
      input = (char *)buf;
      run_one(sbx, mode);
    }
  }
#else
  if (getenv("FUZZ_BENCH")) {  /* per-exec cost of the fork-server path: N forks of one input */
    int i, n = atoi(getenv("FUZZ_BENCH"));
    static char bb[1 << 16]; ssize_t r; struct timespec a, b;
    set_env();
    inlen = 0;
    while (inlen < sizeof bb && (r = read(0, bb + inlen, sizeof bb - inlen)) > 0) inlen += r;
    input = bb;
    if (cov_on) covdebug = 1;
    clock_gettime(CLOCK_MONOTONIC, &a);
    for (i = 0; i < n; i++) {
      pid_t p = fork(); int st;
      if (p == 0) run_one(sbx, mode);
      while (waitpid(p, &st, 0) < 0 && errno == EINTR);
    }
    clock_gettime(CLOCK_MONOTONIC, &b);
    dprintf(savederr, "BENCH mode=%s cov=%d n=%d us/exec=%.0f\n", mode, cov_on, n,
            ((b.tv_sec - a.tv_sec) * 1e6 + (b.tv_nsec - a.tv_nsec) / 1e3) / n);
    return 0;
  }
  __AFL_INIT();
  set_env();
  { /* the input: stdin (AFL's .cur_input fd -- works despite the private mount ns) */
    static char buf[1 << 16];
    ssize_t n;
    inlen = 0;
    while (inlen < sizeof buf && (n = read(0, buf + inlen, sizeof buf - inlen)) > 0) inlen += n;
    input = buf;
  }
  run_one(sbx, mode);
#endif
  return 0;
}
