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
 * Oracle (b), FUZZ_ORACLE=tiers: the input runs in interp, compiled AND tiered (a low
 * CURSE_HOT_LOOP, FUZZ_TIER_HOT, so the tiered switch happens on small inputs) in three
 * workers, and their stdout / stderr / status, masked as cmp.sh masks them, must agree
 * (inputs matching a known.tsv NOISE src rule are only run, not compared).
 *
 * Oracle (c), FUZZ_TARGET=NAME: a targeted in-process fuzzer (targets.lua, bashco.h): the
 * input is a small text in one subsystem's language, run by an already-initialised curse
 * in the child and by a persistent bash 5.2.21 coprocess; any difference aborts.
 *
 * A disagreement bumps a map slot per disagreement kind before abort(), so AFL keeps one
 * crash per kind instead of deduplicating them into whichever came first.
 *
 * Env: FUZZ_SBX=DIR (sandbox mount point, required), FUZZ_MODE=tiered|interp|compiled,
 *      FUZZ_NOCOV=1 (no hook, JIT on), FUZZ_GENCOV=1, FUZZ_KEEPOUT=1 (triage: keep the
 *      script's stdout/stderr visible), FUZZ_ORACLE=tiers, FUZZ_KNOWN=known.tsv (NOISE
 *      rules), FUZZ_TIER_HOT (3), FUZZ_TARGET=arith|pexp|printf|glob|read|regex|parse,
 *      FUZZ_TARGETS_LUA=targets.lua, FUZZ_BASH=the bash 5.2.21 oracle, FUZZ_BASH_TMOUT_MS,
 *      FUZZ_TLOOP (harness-target's inputs per process), FUZZ_OVERRIDE=mod=FILE,... (engine
 *      modules from source: planted-bug checks), FUZZ_BENCH=N [FUZZ_BENCH_PERSIST=1],
 *      FUZZ_TIMING=1. */
#include "sandbox.h"
#include "bashco.h"
#include <regex.h>
#include <signal.h>
#include <stdint.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/prctl.h>
#include <time.h>
#include <sys/random.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#ifndef __AFL_INIT
#define __AFL_INIT() do {} while (0)
#define __AFL_LOOP(n) (__afl_loop_once++ == 0)
static int __afl_loop_once;
#endif
#if defined(PERSIST) || defined(TPERSIST)
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

static int errfd = -1, savederr = -1, keepout, persist, nooracle, tiers;
static const char *target;
static int timing;
static pid_t child_pid;
static char *input; static size_t inlen;

static int lua_internal(const char *buf, size_t n)
{
  size_t at = 0;
  int b;
  for (b = 0; BAD[b]; b++) {
    char *hit = memmem(buf, n, BAD[b], strlen(BAD[b]));
    /* (the script's own text echoed back is not an engine message) */
    if (hit && !memmem(input, inlen, BAD[b], strlen(BAD[b]))) return 1;
  }
  return lua_pos(buf, n, &at);
}

static void check_stderr(void)
{
  static char buf[1 << 16];
  ssize_t n;
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
  if (lua_internal(buf, n)) goto bad;
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
  "-- FUZZ_OVERRIDE=name=FILE,...: engine modules from source files instead of the bundle\n"
  "-- (a planted-bug check without rebuilding the harness: README 'Checking an oracle')\n"
  "for name, path in (os.getenv('FUZZ_OVERRIDE') or ''):gmatch('([%w_]+)=([^,]+)') do\n"
  "  package.preload[name] = assert(loadfile(path)); package.loaded[name] = nil\n"
  "end\n"
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

static void cov_map_init(void)
{
  if (!(cov_on && (fuzz_area() || covdebug))) return;
  covmap = fuzz_area() ? fuzz_area() : calloc(1, 262144);
  { uint32_t sz = fuzz_map_size() ? fuzz_map_size() : 65536, p2 = 1;
    while (p2 * 2 <= sz) p2 *= 2;
    covmask = p2 - 1; }
}

/* run the script (SBX/s.sh) in MODE here; the fds are set up. Exits, except in persist mode. */
static void worker_run(const char *sbx, const char *mode)
{
  char path[4096];
  snprintf(path, sizeof path, "%s/s.sh", sbx);
  child_pid = getpid();
  if (!persist) atexit(check_stderr);
  cov_map_init();
  if (covmap) __real_lua_sethook(globalL, cov_hook, LUA_MASKLINE, 0);
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

/* ---- oracle (b)/(c) shared: disagreement reports ----------------------------------------- */
static void kind_edge(unsigned kind)
{ /* (a map slot of its own per disagreement kind: AFL keeps one crash per kind) */
  if (covmap) covmap[(0xC0DE0000u + kind * 2654435761u) & covmask]++;
}

/* the first line where A and B differ (for the report and sig.sh's signature) */
static void first_diff(const char *a, size_t al, const char *b, size_t bl)
{
  size_t i = 0, ls = 0, ae, be;
  while (i < al && i < bl && a[i] == b[i]) { if (a[i] == '\n') ls = i + 1; i++; }
  for (ae = ls; ae < al && a[ae] != '\n'; ae++);
  for (be = ls; be < bl && b[be] != '\n'; be++);
  if (ae - ls > 300) ae = ls + 300;
  if (be - ls > 300) be = ls + 300;
  dprintf(savederr, "FUZZ-ORACLE < %.*s\nFUZZ-ORACLE > %.*s\n", (int)(ae - ls), a + ls, (int)(be - ls), b + ls);
}

static void dump(const char *what, const char *b, size_t n)
{
  dprintf(savederr, "---- %s (%zu bytes)\n", what, n);
  (void)!write(savederr, b, n > 4000 ? 4000 : n);
  if (n && b[(n > 4000 ? 4000 : n) - 1] != '\n') dprintf(savederr, "\n");
}

/* ---- oracle (b): interp vs compiled vs tiered ---------------------------------------------- */
static regex_t noise_re[64], job_re;
static int n_noise, job_re_ok;

static void load_noise(const char *path)
{ /* known.tsv lines "NOISE<TAB>src<TAB>ERE" */
  FILE *f = path ? fopen(path, "r") : 0;
  char line[4096];
  if (!f) { if (path) fprintf(stderr, "harness: FUZZ_KNOWN %s: %s\n", path, strerror(errno)); return; }
  while (fgets(line, sizeof line, f) && n_noise < 64) {
    char *id = strtok(line, "\t\n"), *field = strtok(0, "\t\n"), *re = strtok(0, "\t\n");
    if (!id || !field || !re || strcmp(id, "NOISE") || strcmp(field, "src")) continue;
    if (regcomp(&noise_re[n_noise], re, REG_EXTENDED | REG_NOSUB) == 0) n_noise++;
    else fprintf(stderr, "harness: bad NOISE regex: %s\n", re);
  }
  fclose(f);
}

static int noisy_input(void)
{
  static char s[1 << 16];
  size_t i, n = inlen < sizeof s - 1 ? inlen : sizeof s - 1;
  int k;
  for (i = 0; i < n; i++) s[i] = input[i] ? input[i] : ' ';
  s[n] = 0;
  for (k = 0; k < n_noise; k++) if (regexec(&noise_re[k], s, 0, 0, 0) == 0) return 1;
  return 0;
}

/* cmp.sh's masks: `time`/`times` figures -> T, digit runs of 4+ (pids) -> N, job status
 * lines compared as a sorted set at the end */
static int cmpstr(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }
static size_t mask(const char *in, size_t n, char *out, size_t cap)
{
  static char line[8192];
  static char *jobs[512];
  static char jb[1 << 16];
  size_t o = 0, i = 0, jn = 0, jo = 0, k;
  if (!job_re_ok) job_re_ok = regcomp(&job_re, "^\\[[0-9N]+\\][-+ ] +(Running|Done|Stopped|Terminated|Exit|Killed)", REG_EXTENDED | REG_NOSUB) == 0 ? 1 : -1;
  while (i < n) {
    size_t l = 0;
    while (i < n && l < sizeof line - 2) {
      char c = in[i];
      if (c >= '0' && c <= '9') {
        size_t j = i, d, e;
        while (j < n && in[j] >= '0' && in[j] <= '9') j++;
        /* NmN.NNNs */
        d = j;
        if (d < n && in[d] == 'm') {
          e = d + 1; while (e < n && in[e] >= '0' && in[e] <= '9') e++;
          if (e > d + 1 && e < n && (in[e] == '.' || in[e] == ',')) {
            size_t f = e + 1; while (f < n && in[f] >= '0' && in[f] <= '9') f++;
            if (f > e + 1 && f < n && in[f] == 's') { line[l++] = 'T'; i = f + 1; continue; }
          }
        }
        if (j - i >= 4) { line[l++] = 'N'; i = j; continue; }
        while (i < j && l < sizeof line - 2) line[l++] = in[i++];
        continue;
      }
      line[l++] = c; i++;
      if (c == '\n') break;
    }
    line[l] = 0;
    if (job_re_ok == 1 && jn < 512 && jo + l + 1 < sizeof jb && !memchr(line, 0, l) && regexec(&job_re, line, 0, 0, 0) == 0) {
      memcpy(jb + jo, line, l + 1); jobs[jn++] = jb + jo; jo += l + 1;
    } else if (o + l < cap) { memcpy(out + o, line, l); o += l; }
  }
  qsort(jobs, jn, sizeof *jobs, cmpstr);
  for (k = 0; k < jn; k++) { size_t l = strlen(jobs[k]); if (o + l < cap) { memcpy(out + o, jobs[k], l); o += l; } }
  return o;
}

static void tiers_run(const char *sbx)
{
  static volatile int *tst;
  static const char *TM[3] = { "interp", "compiled", "tiered" };
  static char raw[1 << 20], m[3][2][1 << 17];
  size_t ml[3][2];
  int st[3], i, s, fds[3][2];
  for (i = 0; i < 3; i++) {
    pid_t w;
    int ws = 0;
    for (s = 0; s < 2; s++) {
      int fd = memfd_create("fuzztier", MFD_CLOEXEC), hi = fcntl(fd, F_DUPFD_CLOEXEC, 210);
      if (hi >= 0) { close(fd); fd = hi; }
      fds[i][s] = fd;
    }
    /* Each worker in a pid namespace of its own, as run_one's (tiny init as pid 1, the
     * worker as pid 2): what one tier's run leaves behind dies before the next runs. The
     * init hands the worker's wait status back through a shared page. */
    if (!tst) tst = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (tst == MAP_FAILED) sbx_die("mmap");
    *tst = -1;
    w = fork();
    if (w == 0) {
      int ns = getenv_ns && unshare(CLONE_NEWPID) == 0, cs = 0;
      pid_t in;
      prctl(PR_SET_PDEATHSIG, SIGKILL);
      in = fork();
      if (in == 0 && ns) {  /* the namespace's init */
        pid_t w2;
        prctl(PR_SET_PDEATHSIG, SIGKILL);
        w2 = fork();
        if (w2 > 0) {
          while (waitpid(w2, &cs, 0) < 0 && errno == EINTR);
          *tst = cs;
          _exit(0);  /* (as pid 1: the kernel kills the rest of the namespace) */
        }
        if (w2 < 0) _exit(111);
        fs_pid = 0;
      }
      if (in == 0) {  /* the worker */
        prctl(PR_SET_PDEATHSIG, SIGKILL);
        setpgid(0, 0);
        sbx_reset_cwd(sbx);
        dup2(fds[i][0], 1);
        dup2(fds[i][1], 2);
        errfd = fds[i][1];
        worker_run(sbx, TM[i]);
      }
      if (in < 0) _exit(111);
      while (waitpid(in, &cs, 0) < 0 && errno == EINTR);
      if (!ns) *tst = cs;
      _exit(0);
    }
    while (waitpid(w, &ws, 0) < 0 && errno == EINTR);
    ws = *tst != -1 ? *tst : SIGKILL;  /* (no status: killed from outside, not a crash) */
    if (WIFSIGNALED(ws)) {
      int sg = WTERMSIG(ws);
      if (sg == SIGABRT || sg == SIGSEGV || sg == SIGBUS || sg == SIGILL || sg == SIGFPE || sg == SIGSYS) {
        dprintf(savederr, "FUZZ-ORACLE tiers: the %s worker crashed (signal %d)\n", TM[i], sg);
        abort();
      }
    }
    st[i] = WIFEXITED(ws) ? WEXITSTATUS(ws) : 128 + WTERMSIG(ws);
    if (st[i] == 128 + SIGKILL || st[i] == 128 + SIGXCPU) _exit(0);  /* (out of time: not comparable) */
    for (s = 0; s < 2; s++) {
      ssize_t n = pread(fds[i][s], raw, sizeof raw, 0);
      if (n < 0) n = 0;
      if ((size_t)n >= sizeof raw) _exit(0);  /* (more than 1 MB: not comparable) */
      ml[i][s] = mask(raw, (size_t)n, m[i][s], sizeof m[i][s]);
    }
  }
  for (i = 1; i < 3; i++) {
    static const char *SN[3] = { "out", "err", "status" };
    int bad = -1;
    if (ml[i][0] != ml[0][0] || memcmp(m[i][0], m[0][0], ml[0][0])) bad = 0;
    else if (ml[i][1] != ml[0][1] || memcmp(m[i][1], m[0][1], ml[0][1])) bad = 1;
    else if (st[i] != st[0]) bad = 2;
    if (bad < 0) continue;
    dprintf(savederr, "FUZZ-ORACLE tiers: %s %s differs from interp\n", TM[i], SN[bad]);
    if (bad < 2) first_diff(m[0][bad], ml[0][bad], m[i][bad], ml[i][bad]);
    else dprintf(savederr, "FUZZ-ORACLE < status %d\nFUZZ-ORACLE > status %d\n", st[0], st[i]);
    for (s = 0; s < 3; s++) {
      char what[64];
      snprintf(what, sizeof what, "%s status %d, stdout", TM[s], st[s]); dump(what, m[s][0], ml[s][0]);
      snprintf(what, sizeof what, "%s stderr", TM[s]); dump(what, m[s][1], ml[s][1]);
    }
    kind_edge((unsigned)((i - 1) * 3 + bad));
    abort();
  }
  _exit(0);
}

/* ---- oracle (c): a targeted in-process fuzzer vs the persistent bash ----------------------- */
/* One input. Fork mode (loops == 0): the child exits when done. Persistent mode: the
 * shell runs one input after another in this process (each inside curse's own
 * `( ... )`, which is what isolates them), returning after each. */
static int tgt_ofd = -1;
static void target_iter(int loops)
{
  static char cout[BCO_OUTCAP + 1], bout[BCO_OUTCAP + 16];
  const char *snip;
  size_t slen, clen, blen = 0;
  int cst = 0, bst = 0, k;
  uint32_t id;
  long t0 = bco_now_us();
#define TDONE() do { if (!loops) _exit(0); lua_settop(globalL, 0); return; } while (0)
  if (!loops) lua_gc(globalL, LUA_GCSTOP, 0);  /* (short-lived child: rlimit AS bounds it) */
  lua_settop(globalL, 0);
  lua_pushcfunction(globalL, lua_traceback);
  lua_getglobal(globalL, "__T");
  lua_getfield(globalL, -1, "build");
  lua_pushlstring(globalL, input, inlen);
  if (lua_pcall(globalL, 1, 1, 1) != 0) {
    dprintf(savederr, "FUZZ-ORACLE escaped: %s\n", lua_tostring(globalL, -1));
    abort();
  }
  if (!lua_isstring(globalL, -1)) TDONE();  /* (not an input of this target's language) */
  snip = lua_tolstring(globalL, -1, &slen);
  id = bco_send(snip, slen);
  if (!id) { dprintf(savederr, "FUZZ: the bash broker is gone\n"); TDONE(); }
  if (tgt_ofd < 0) {
    int fd;
    { int f; for (f = 3; f < 128; f++) close(f); }
    fd = open("/dev/null", O_RDWR); dup2(fd, 0); close(fd);
    tgt_ofd = memfd_create("fuzztgt", MFD_CLOEXEC);
    { int hi = fcntl(tgt_ofd, F_DUPFD_CLOEXEC, 210); if (hi >= 0) { close(tgt_ofd); tgt_ofd = hi; } }
    dup2(tgt_ofd, 1); dup2(tgt_ofd, 2);
    child_pid = getpid();
    cov_map_init();
  } else {
    if (ftruncate(tgt_ofd, 0) != 0 || lseek(tgt_ofd, 0, SEEK_SET) != 0) sbx_die("reset output");
  }
  prev_loc = 0;
  if (covmap) __real_lua_sethook(globalL, cov_hook, LUA_MASKLINE, 0);
  lua_getfield(globalL, 2, "run");
  lua_pushvalue(globalL, -2);
  if (lua_pcall(globalL, 1, 1, 1) != 0) {
    dprintf(savederr, "FUZZ-ORACLE escaped: %s\n", lua_tostring(globalL, -1));
    abort();
  }
  if (getpid() != child_pid) _exit(0);  /* (a forked copy of the shell came back here) */
  cst = (int)lua_tointeger(globalL, -1);
  fflush(NULL);
  __real_lua_sethook(globalL, 0, 0, 0);
  { ssize_t n = pread(tgt_ofd, cout, sizeof cout - 1, 0); clen = n > 0 ? (size_t)n : 0; }
  if (lua_internal(cout, clen)) {
    dprintf(savederr, "FUZZ-ORACLE stderr:\n"); (void)!write(savederr, cout, clen);
    abort();
  }
  { long t1 = bco_now_us();
  k = bco_recv(id, bout, &blen, &bst);
  if (timing) dprintf(savederr, "TIMING curse %ld us, then bash wait %ld us\n", t1 - t0, bco_now_us() - t1); }
  if (k != BCO_OK) {  /* (bash hung / died / flooded: not comparable) */
    if (keepout) dprintf(savederr, "FUZZ: no bash answer (kind %d)\n", k);
    TDONE();
  }
  if (clen >= BCO_OUTCAP || blen >= BCO_OUTCAP) TDONE();  /* (truncated) */
  if (keepout) { dump("bash", bout, blen); dump("curse", cout, clen); dprintf(savederr, "status bash %d curse %d\n", bst, cst); }
  if (cst == bst && clen == blen && !memcmp(cout, bout, clen)) TDONE();
  k = (clen != blen || memcmp(cout, bout, clen)) ? 0 : 1;
  dprintf(savederr, "FUZZ-ORACLE target %s: %s differs from bash\n", target, k == 0 ? "output" : "status");
  if (k == 0) first_diff(bout, blen, cout, clen);
  else dprintf(savederr, "FUZZ-ORACLE < status %d\nFUZZ-ORACLE > status %d\n", bst, cst);
  dprintf(savederr, "---- snippet\n%.*s\n", (int)slen, snip);
  dump("bash", bout, blen);
  dump("curse", cout, clen);
  dprintf(savederr, "status bash %d curse %d\n", bst, cst);
  kind_edge(16 + (unsigned)k);
  abort();
#undef TDONE
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
  if (tiers && !persist && !noisy_input()) { cov_map_init(); tiers_run(sbx); }
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
  worker_run(sbx, mode);
}

/* the targeted fuzzer's environment, the same as bashco.h gives bash (+ AFL's own vars
 * until __AFL_INIT has read them: KEEPAFL) */
static void target_env(int keepafl)
{
  static char *keep[64];
  int nk = 0, i;
  extern char **environ;
  if (keepafl)
    for (i = 0; environ[i] && nk < 63; i++)
      if (!strncmp(environ[i], "AFL_", 4) || !strncmp(environ[i], "__AFL", 5)) keep[nk++] = strdup(environ[i]);
  set_env();
  setenv("TZ", "UTC", 1);
  for (i = 0; i < nk; i++) putenv(keep[i]);
}

static void target_setup(const char *sbx, const char *src, size_t srclen, const char *bash)
{
  lua_State *L = globalL;
  static char drv[4200];
  char nonce[33];
  unsigned char rnd[16];
  const char *txt;
  size_t tl;
  int i, fd;
  if (getrandom(rnd, sizeof rnd, 0) != sizeof rnd) sbx_die("getrandom");
  for (i = 0; i < 16; i++) snprintf(nonce + 2 * i, 3, "%02x", rnd[i]);
  snprintf(drv, sizeof drv, "%s/drv", sbx);
  if (luaL_loadbuffer(L, src, srclen, "=fuzz-targets") || lua_pcall(L, 0, 1, 0)) {
    fprintf(stderr, "harness: targets.lua: %s\n", lua_tostring(L, -1)); exit(111);
  }
  lua_setglobal(L, "__T");
  lua_getglobal(L, "__T");
  lua_getfield(L, -1, "driver");
  lua_pushstring(L, nonce);
  if (lua_pcall(L, 1, 1, 0)) { fprintf(stderr, "harness: driver: %s\n", lua_tostring(L, -1)); exit(111); }
  txt = lua_tolstring(L, -1, &tl);
  fd = open(drv, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0 || write(fd, txt, tl) != (ssize_t)tl) sbx_die("write driver");
  close(fd);
  lua_settop(L, 0);
  sbx_reset_cwd(sbx);
  target_env(1);
  lua_getglobal(L, "__T");
  lua_getfield(L, -1, "setup");
  lua_pushstring(L, target);
  lua_pushstring(L, drv);
  if (lua_pcall(L, 2, 0, 0)) { fprintf(stderr, "harness: setup %s: %s\n", target, lua_tostring(L, -1)); exit(111); }
  lua_settop(L, 0);
  fflush(NULL);
  /* (a full collection now, none in the child: a GC cycle in a fork child sweeps -- and so
   * copies -- the whole inherited heap, which cost more than the input's own work) */
  lua_gc(L, LUA_GCCOLLECT, 0);
  bco_start(bash, sbx, drv, nonce);
}

static void one(const char *sbx, const char *mode)
{
  if (target) target_iter(0);
  else run_one(sbx, mode);
}

int main(int argc, char **argv)
{
  const char *sbx = getenv("FUZZ_SBX"), *mode = getenv("FUZZ_MODE");
  const char *ms = getenv("FUZZ_MAP_SIZE");
  const char *tbash = 0, *bench = getenv("FUZZ_BENCH");  /* (read now: target_setup clears the env) */
  int bench_p = !!getenv("FUZZ_BENCH_PERSIST");
  char *tsrc = 0;
  size_t tsrclen = 0;
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
  tiers = getenv("FUZZ_ORACLE") && !strcmp(getenv("FUZZ_ORACLE"), "tiers");
  target = getenv("FUZZ_TARGET");
  timing = !!getenv("FUZZ_TIMING");
  if (target && !*target) target = 0;
  if (tiers) {
    load_noise(getenv("FUZZ_KNOWN"));
    /* (read by tier.lua as it loads: the tiered worker compiles a loop after this many passes) */
    setenv("CURSE_HOT_LOOP", getenv("FUZZ_TIER_HOT") ? getenv("FUZZ_TIER_HOT") : "3", 1);
  }
  if (target) {
    const char *tp = getenv("FUZZ_TARGETS_LUA");
    FILE *f;
    tbash = getenv("FUZZ_BASH");
    if (!tp || !tbash) { fprintf(stderr, "harness: FUZZ_TARGET needs FUZZ_TARGETS_LUA and FUZZ_BASH\n"); return 111; }
    if (!(f = fopen(tp, "rb"))) { fprintf(stderr, "harness: %s: %s\n", tp, strerror(errno)); return 111; }
    tsrc = malloc(1 << 20);
    tsrclen = fread(tsrc, 1, 1 << 20, f);
    fclose(f);
  }
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
  if (target) target_setup(sbx, tsrc, tsrclen, tbash);
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
  if (bench) {  /* per-exec cost of the fork-server path: N forks of one input */
    int i, n = atoi(bench);
    static char bb[1 << 16]; ssize_t r; struct timespec a, b;
    if (target) target_env(0); else set_env();
    inlen = 0;
    while (inlen < sizeof bb && (r = read(0, bb + inlen, sizeof bb - inlen)) > 0) inlen += r;
    input = bb;
    if (cov_on) covdebug = 1;
    clock_gettime(CLOCK_MONOTONIC, &a);
    if (target && bench_p) {  /* (harness-target's loop: one child, N inputs) */
      pid_t p = fork(); int st;
      if (p == 0) { for (i = 0; i < n; i++) target_iter(1); _exit(0); }
      while (waitpid(p, &st, 0) < 0 && errno == EINTR);
      if (WIFSIGNALED(st)) dprintf(savederr, "BENCH child signal %d\n", WTERMSIG(st));
    } else
    for (i = 0; i < n; i++) {
      pid_t p = fork(); int st;
      if (p == 0) one(sbx, mode);
      while (waitpid(p, &st, 0) < 0 && errno == EINTR);
    }
    clock_gettime(CLOCK_MONOTONIC, &b);
    dprintf(savederr, "BENCH mode=%s%s%s%s cov=%d n=%d us/exec=%.0f\n", target ? "target:" : tiers ? "tiers:" : "",
            target ? target : mode, bench_p ? " persistent" : "", tiers ? "" : "", cov_on, n,
            ((b.tv_sec - a.tv_sec) * 1e6 + (b.tv_nsec - a.tv_nsec) / 1e3) / n);
    return 0;
  }
#ifdef TPERSIST
  /* harness-target: AFL++ persistent mode for the targeted fuzzers. The forkserver child
   * runs FUZZ_TLOOP (1000) inputs before AFL forks a fresh one: a fork child pays a page
   * fault per heap page it touches (most of a small input's cost), a loop pays them once.
   * Each input still runs inside curse's own `( ... )` (targets.lua), which is what keeps
   * one input's shell state from the next; the triage re-run (harness-plain, one fork per
   * input) tells a finding that needs the loop's history from one that doesn't. */
  if (target) {
    int iters = getenv("FUZZ_TLOOP") ? atoi(getenv("FUZZ_TLOOP")) : 1000;
    unsigned char *tb;
    __AFL_INIT();
    target_env(0);
    tb = __AFL_FUZZ_TESTCASE_BUF;
    while (__AFL_LOOP(iters > 0 ? iters : 1000)) {
      inlen = __AFL_FUZZ_TESTCASE_LEN;
      input = (char *)tb;
      target_iter(1);
    }
    return 0;
  }
#endif
  __AFL_INIT();
  if (target) target_env(0); else set_env();
  { /* the input: stdin (AFL's .cur_input fd -- works despite the private mount ns) */
    static char buf[1 << 16];
    ssize_t n;
    inlen = 0;
    while (inlen < sizeof buf && (n = read(0, buf + inlen, sizeof buf - inlen)) > 0) inlen += n;
    input = buf;
  }
  one(sbx, mode);
#endif
  return 0;
}
