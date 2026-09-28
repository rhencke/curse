/* curse: asynchronous, preemptive signal handling for the shell.
 *
 * LuaJIT forbids running Lua from an async C signal handler, so the handler does
 * only async-signal-safe work: record which signal fired AND schedule a VM debug
 * hook (lua_sethook) — exactly LuaJIT's own Ctrl-C mechanism (laction in luajit.c).
 * The hook fires at the next VM safepoint, in a SAFE Lua context, and runs the trap
 * of every signal recorded meanwhile, lowest signal number first (no polling — the
 * VM delivers the traps).
 *
 * The handler is installed WITHOUT SA_RESTART, so a blocking syscall (read/waitpid)
 * returns EINTR the instant the signal arrives; control returns to the interpreter,
 * the scheduled hook fires, and the trap runs — true preemption of long-running and
 * blocking commands, replacing the old sigprocmask-block + sigtimedwait-poll hack.
 *
 * curse_sig_catch/default/ignore are registered in lib_cursesys.c's curse_syms
 * table, so ffi.C resolves them via lj_clib.c's static fallback in both the dynamic
 * and the fully static binary (neither exports internal symbols to dlsym). */
#include "lua.h"
#include "lj_obj.h"
#include <signal.h>
#include <string.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/time.h>
#include <time.h>

/* The signals delivered and not yet run: one flag per signal, so signals arriving
 * back to back (HUP, USR1, USR2 before the next safepoint) each run their trap --
 * a single "last signal" slot lost all but one. Drained in ascending signal number,
 * as bash's run_pending_traps walks pending_traps[]. */
#define CURSE_NSIG 65
static volatile sig_atomic_t curse_sig_pend[CURSE_NSIG];
static volatile pid_t curse_sig_pid;         /* pid that scheduled the hook (fork guard) */
static volatile sig_atomic_t curse_sig_down; /* the VM is being closed: curse_sig_shutdown */
/* Did the last delivery of each signal come from this process itself -- the kernel on
 * its behalf (SI_KERNEL: RLIMIT_CPU's SIGXCPU) or a SI_USER send whose sender is us
 * (a write's SIGPIPE / SIGXFSZ: send_sig(sig, current))? curse_sig_fromself. */
static volatile sig_atomic_t curse_sig_self[CURSE_NSIG];

extern lua_State *curse_globalL(void);  /* luajit.c */

/* Take the lowest pending signal (0: none). Called with all signals blocked. */
static int curse_sig_take(void)
{
  int s;
  for (s = 1; s < CURSE_NSIG; s++) {
    if (curse_sig_pend[s]) { curse_sig_pend[s] = 0; return s; }
  }
  return 0;
}

static void curse_sig_hook(lua_State *L, lua_Debug *ar);
static void curse_kick_disarm(int s);

/* Scheduled hook: runs at the next VM safepoint in a safe Lua context. Removes
 * itself (one-shot) BEFORE running Lua, then calls curse's trap runner once per
 * pending signal, lowest first. Errors/exit from a trap propagate (Lua's error
 * unwinding), so `trap 'exit' INT` exits: the call is protected only to decide what
 * becomes of the signals still pending -- an `exit` drops them (the shell is ending,
 * as bash's exit_shell never returns to run_pending_traps); any other unwind
 * (`return`/`break` out of the trap) leaves them pending and schedules the hook
 * again, as bash's pending_traps outlive the longjmp.
 *
 * A forked child inherits both the scheduled hook and the pending set; without a
 * guard it would fire the PARENT's pending trap at its first instruction (before
 * it can reset its dispositions). So the hook is a no-op unless it runs in the
 * process that scheduled it -- the child's inherited hook just clears itself. */
static void curse_sig_hook(lua_State *L, lua_Debug *ar)
{
  int s, n;
  sigset_t all, old;
  (void)ar;
  /* Remove this hook with signals blocked: a signal arriving in the middle of it
   * would set the hook again (curse_sig_onsignal) only to have this removal's
   * read-modify-write of g->hookmask drop it. Blocked, it is delivered once this is
   * done and schedules a fresh hook. */
  sigfillset(&all);
  sigprocmask(SIG_BLOCK, &all, &old);
  lua_sethook(L, (lua_Hook)0, 0, 0);
#ifdef CURSE_SIG_DESTRUCTIVE
  /* Back in the interpreter: undo the preemption patches (a trace reaching the
   * interpreter through a patched tail jmp's trampoline skips lj_trace_exit). */
  { extern void curse_sig_unpatch_all(void); curse_sig_unpatch_all(); }
#endif
  if (getpid() != curse_sig_pid) { /* inherited across fork: drop the parent's */
    for (s = 1; s < CURSE_NSIG; s++) curse_sig_pend[s] = 0;
    sigprocmask(SIG_SETMASK, &old, (sigset_t *)0);
    return;
  }
  sigprocmask(SIG_SETMASK, &old, (sigset_t *)0);
  /* The traps run as ordinary code, not as a hook: a signal arriving while one runs
   * fires its own hook INSIDE it, nested -- as bash's run_pending_traps runs a pending
   * trap at the running handler's next command. (callhook only skips a hook while
   * HOOK_ACTIVE; it is set again before returning to callhook, which clears it.) */
  hook_leave(G(L));
  for (;;) {
    sigprocmask(SIG_BLOCK, &all, &old);
    s = curse_sig_take();
    if (s) curse_kick_disarm(s);  /* (taken: no re-kick for it) */
    sigprocmask(SIG_SETMASK, &old, (sigset_t *)0);
    if (s == 0) break;
    lua_getglobal(L, "__curse_sigrun");
    if (!lua_isfunction(L, -1)) { lua_pop(L, 1); continue; }
    lua_pushinteger(L, s);
    if (lua_pcall(L, 1, 0, 0) != 0) {
      int isexit = 0;
      if (lua_istable(L, -1)) {
        lua_getfield(L, -1, "__curse_exit");
        isexit = !lua_isnil(L, -1);
        lua_pop(L, 1);
      }
      sigprocmask(SIG_BLOCK, &all, &old);
      for (n = 0, s = 1; s < CURSE_NSIG; s++) {
        if (curse_sig_pend[s]) { if (isexit) curse_sig_pend[s] = 0; else n = 1; }
      }
      if (n) lua_sethook(L, curse_sig_hook, LUA_MASKCALL | LUA_MASKRET | LUA_MASKCOUNT, 1);
      sigprocmask(SIG_SETMASK, &old, (sigset_t *)0);
      lua_error(L); /* (hook left, as an unprotected call's error would leave it) */
    }
  }
  hook_enter(G(L));
}

/* The re-kick: a signal whose hook has not run CURSE_KICK_US after it arrived is
 * delivered to the running code again. The handler can land where neither of its
 * mechanisms reaches the code about to run: during a trace compile (lj_dispatch_ins ->
 * lj_trace_ins) no trace runs to patch, and the count hook it re-arms (hookcount = 1)
 * is past its check for this instruction -- which, the compile done, is the JLOOP that
 * enters the new trace: an inverted loop then never returns to a VM safepoint and the
 * trap is lost (test_sigpreempt "inverted" under load: pending set, hook installed,
 * trace running, nothing patched). So each caught signal also arms a one-shot POSIX
 * timer that raises the SAME signal with a cookie in si_value (SI_TIMER): that
 * delivery only re-schedules the hook and re-patches the code running now -- and only
 * while the signal is still pending, never a second trap. It backs off (2ms, 10ms,
 * 50ms, then every 100ms) while the signal stays pending (a C call that retries EINTR
 * itself keeps the hook from running meanwhile). A timer is per signal (its number is
 * fixed at creation) and per process (POSIX timers are not inherited across fork:
 * curse_sig_catch creates the child's own); the hook disarms the one it takes, and a
 * signal leaving curse's handler (curse_sig_default/ignore) takes any kick queued. */
#define CURSE_KICK_COOKIE 0x63727365  /* "crse" */
static timer_t curse_kick_timer[CURSE_NSIG];
static pid_t curse_kick_pid[CURSE_NSIG];
static volatile sig_atomic_t curse_kick_n[CURSE_NSIG];

static void curse_kick_arm(int s)
{
  static const long us[4] = { 2000, 10000, 50000, 100000 };
  struct itimerspec it;
  int k = (int)curse_kick_n[s];
  long u;
  if (curse_kick_pid[s] != getpid()) return;
  u = us[k < 3 ? k : 3];
  if (k < 3) curse_kick_n[s] = k + 1;
  memset(&it, 0, sizeof it);
  it.it_value.tv_sec = u / 1000000;
  it.it_value.tv_nsec = (u % 1000000) * 1000;
  timer_settime(curse_kick_timer[s], 0, &it, (struct itimerspec *)0);
}

static void curse_kick_disarm(int s)
{
  struct itimerspec it;
  if (curse_kick_pid[s] != getpid()) return;
  memset(&it, 0, sizeof it);
  timer_settime(curse_kick_timer[s], 0, &it, (struct itimerspec *)0);
}

static void curse_sig_schedule(void)
{
  lua_State *L = curse_globalL();
  /* Schedule the trap for the next safepoint (laction pattern). Count=1 fires on
   * the next VM instruction; call/ret masks make blocking-syscall returns fire it
   * promptly. The hook removes itself, so this is a one-shot per signal. */
  if (L) lua_sethook(L, curse_sig_hook,
                     LUA_MASKCALL | LUA_MASKRET | LUA_MASKCOUNT, 1);
#ifdef CURSE_SIG_DESTRUCTIVE
  /* A pure-compute JIT loop never reaches a VM safepoint, so the scheduled hook
   * above won't fire inside it. Destructively patch the running code's loop heads
   * and trace links to force an exit (reverted the instant the interpreter is
   * reached). See lj_trace.c. */
  { extern void curse_sig_patch_trace(void); curse_sig_patch_trace(); }
#endif
}

/* Before `s` leaves curse's handler (trap reset or ignored): no re-kick may reach
 * the new disposition -- disarm, and take a kick already queued (a real `s` queued
 * with it arrived while trapped: it is recorded as caught). */
static void curse_kick_quiesce(int s)
{
  sigset_t one, old;
  siginfo_t si;
  struct timespec zero = { 0, 0 };
  if (s <= 0 || s >= CURSE_NSIG || curse_kick_pid[s] != getpid()) return;
  sigemptyset(&one);
  sigaddset(&one, s);
  sigprocmask(SIG_BLOCK, &one, &old);
  curse_kick_disarm(s);
  /* (already blocked: a pending one is its blocker's -- the scheduler keeps SIGPIPE
   * blocked and takes the EPIPE writes' SIGPIPE itself -- never a trap's) */
  while (!sigismember(&old, s) && sigtimedwait(&one, &si, &zero) == s) {
    if (!(si.si_code == SI_TIMER && si.si_value.sival_int == CURSE_KICK_COOKIE)) {
      curse_sig_pend[s] = 1;
      curse_sig_pid = getpid();
      curse_sig_schedule();
    }
  }
  sigprocmask(SIG_SETMASK, &old, (sigset_t *)0);
}

static void curse_sig_onsignal(int s, siginfo_t *si, void *uc)
{
  (void)uc;
  if (s <= 0 || s >= CURSE_NSIG || curse_sig_down) return;
  if (si && si->si_code == SI_TIMER && si->si_value.sival_int == CURSE_KICK_COOKIE) {
    /* The re-kick: nothing new arrived. */
    if (curse_sig_pend[s] && curse_sig_pid == getpid()) {
      curse_sig_schedule();
      curse_kick_arm(s);
    }
    return;
  }
  curse_sig_self[s] = si && (si->si_code == SI_KERNEL
                              || (si->si_code == SI_USER && si->si_pid == getpid()));
  curse_sig_pend[s] = 1;
  curse_sig_pid = getpid();
  curse_sig_schedule();
  curse_kick_n[s] = 0;
  curse_kick_arm(s);
}

int curse_sig_fromself(int s)
{
  return s > 0 && s < CURSE_NSIG && curse_sig_self[s];
}

/* Is `s` delivered and its hook not yet run -- and drop it (the shell took it at the
 * failed write itself: runtime.lua M.sync_write_error, when a JIT trace kept the hook
 * from running first). */
int curse_sig_pending(int s)
{
  return s > 0 && s < CURSE_NSIG && curse_sig_pend[s] && curse_sig_pid == getpid();
}

void curse_sig_drop(int s)
{
  sigset_t all, old;
  if (s <= 0 || s >= CURSE_NSIG) return;
  sigfillset(&all);
  sigprocmask(SIG_BLOCK, &all, &old);
  curse_sig_pend[s] = 0;
  curse_kick_disarm(s);
  sigprocmask(SIG_SETMASK, &old, (sigset_t *)0);
}

/* What curse last made of each signal's disposition: 0 not known yet, 1 SIG_DFL,
 * 2 curse's handler standing in for SIG_DFL (curse_sig_emulate), 3 caught (a trap),
 * 4 ignored. Every change goes through curse_sig_catch/default/ignore. */
static signed char curse_disp[CURSE_NSIG];


/* Install curse's async handler for signal `s` (no SA_RESTART -> blocking syscalls
 * EINTR), and its re-kick timer. */
int curse_sig_catch(int s)
{
  struct sigaction sa;
  if (s > 0 && s < CURSE_NSIG && curse_kick_pid[s] != getpid()) {
    struct sigevent ev;
    memset(&ev, 0, sizeof ev);
    ev.sigev_notify = SIGEV_SIGNAL;
    ev.sigev_signo = s;
    ev.sigev_value.sival_int = CURSE_KICK_COOKIE;
    if (timer_create(CLOCK_MONOTONIC, &ev, &curse_kick_timer[s]) == 0)
      curse_kick_pid[s] = getpid();
  }
  memset(&sa, 0, sizeof sa);
  sa.sa_sigaction = curse_sig_onsignal;
  sigemptyset(&sa.sa_mask);
  sa.sa_flags = SA_SIGINFO;
  if (sigaction(s, &sa, (struct sigaction *)0) != 0) return -1;
  if (s > 0 && s < CURSE_NSIG) curse_disp[s] = 3;
  return 0;
}

/* Restore the default disposition for `s`. */
int curse_sig_default(int s)
{
  struct sigaction sa;
  curse_kick_quiesce(s);
  memset(&sa, 0, sizeof sa);
  sa.sa_handler = SIG_DFL;
  if (sigaction(s, &sa, (struct sigaction *)0) != 0) return -1;
  if (s > 0 && s < CURSE_NSIG) curse_disp[s] = 1;
  return 0;
}

/* Ignore `s` (bash `trap '' SIG`). */
int curse_sig_ignore(int s)
{
  struct sigaction sa;
  curse_kick_quiesce(s);
  memset(&sa, 0, sizeof sa);
  sa.sa_handler = SIG_IGN;
  if (sigaction(s, &sa, (struct sigaction *)0) != 0) return -1;
  if (s > 0 && s < CURSE_NSIG) curse_disp[s] = 4;
  return 0;
}

/* The signals a process raises against ITSELF -- a write's SIGPIPE (dead reader) and
 * SIGXFSZ (past RLIMIT_FSIZE), RLIMIT_CPU's SIGXCPU -- must end only the in-process
 * subshell that caused them (a forked subshell dies alone; stress-attack S5/S21/S24).
 * With the default disposition the kernel would kill the whole shell, so while such a
 * signal's disposition is SIG_DFL curse's handler stands in for it: the shell decides
 * (runtime.lua M.sync_signal) -- the running in-process subshell dies by it (or runs its
 * own trap), and outside of one the shell itself dies by it, as SIG_DFL would. A
 * trapped or ignored signal is left alone. Returns 1 when `s` is (now) emulated.
 * Costs no syscall once the disposition is known (curse_disp). */
int curse_sig_emulate(int s)
{
  if (s <= 0 || s >= CURSE_NSIG) return 0;
  if (curse_disp[s] == 0) {
    struct sigaction cur;
    if (sigaction(s, (struct sigaction *)0, &cur) != 0) return 0;
    curse_disp[s] = cur.sa_handler == SIG_DFL ? 1 : cur.sa_handler == SIG_IGN ? 4 : 3;
  }
  if (curse_disp[s] == 1 && curse_sig_catch(s) == 0) curse_disp[s] = 2;
  return curse_disp[s] == 2;
}

int curse_sig_emulated(int s)
{
  return s > 0 && s < CURSE_NSIG && curse_disp[s] == 2;
}

/* Discard a pending scheduled trap: clear the recorded signal and remove the VM
 * hook. A forked child calls this AFTER restoring its default dispositions, so a
 * signal it caught in the fork→reset window (e.g. `cmd & ; kill -SIG $!`) does not
 * fire a spurious trap once the child is running. */
void curse_sig_clearpending(void)
{
  lua_State *L = curse_globalL();
  int s;
  for (s = 1; s < CURSE_NSIG; s++) curse_sig_pend[s] = 0;
  if (L) lua_sethook(L, (lua_Hook)0, 0, 0);
}

/* Block (hold != 0) or unblock ALL signals. curse's baseline is fully unblocked, so
 * this is used only to bracket a fork + the child's disposition reset: the parent
 * blocks before fork, and both parent and child unblock after (the child once its
 * dispositions are set). Prevents `cmd & ; kill -SIG $!` from delivering the signal
 * to the child before it resets — the classic fork/signal race (bash blocks too). */
void curse_sig_hold(int hold)
{
  sigset_t all;
  sigfillset(&all);
  sigprocmask(hold ? SIG_BLOCK : SIG_UNBLOCK, &all, (sigset_t *)0);
}

/* Preemption of in-process background jobs (curse runs `&` as coroutines). A job
 * that computes without blocking never yields, so the shell and its other jobs
 * would starve (`while :; do :; done & sleep 1; kill $!` would hang). While a job
 * runs -- and while the foreground shell runs with jobs alive -- the scheduler arms a
 * one-shot timer (SIGVTALRM); its handler raises a flag that the running code checks
 * at every loop head and function entry (interp and compiled code), yielding back to
 * the scheduler.
 * A JIT trace hoists that check out of its loop, so the handler also patches the
 * running trace's loop head to force the exit (as a trap signal does). SA_RESTART:
 * the tick must not EINTR the job's syscalls. */
static volatile int curse_preempt_flag;

static void curse_preempt_onsignal(int s)
{
  (void)s;
  if (curse_sig_down) return;
  curse_preempt_flag = 1;
#ifdef CURSE_SIG_DESTRUCTIVE
  /* Only the running loop's head: the flag is re-read at every loop head,
   * i.e. at every root trace entry, so a side trace linking back to its root
   * sees it anyway -- and no VM hook is scheduled here to undo a tail-jmp patch. */
  { extern void curse_sig_patch_trace_mode(int); curse_sig_patch_trace_mode(0); }
#endif
}

int *curse_preempt_flagp(void)
{
  return (int *)&curse_preempt_flag;
}

/* Arm (usec > 0) or disarm (0) the slice. The handler is (re)installed over the
 * default disposition (a daemon worker resets dispositions between requests); a
 * script's own `trap … VTALRM` or `trap '' VTALRM` keeps the signal, and there are
 * no slices (-1). */
static timer_t curse_preempt_timer;
static pid_t curse_preempt_tpid;
int curse_preempt_arm(long usec)
{
  struct itimerval it;
  if (usec > 0) {
    struct sigaction cur;
    if (sigaction(SIGVTALRM, (struct sigaction *)0, &cur) != 0) return -1;
    if (cur.sa_handler != curse_preempt_onsignal) {
      struct sigaction sa;
      if (cur.sa_handler != SIG_DFL) return -1;
      memset(&sa, 0, sizeof sa);
      sa.sa_handler = curse_preempt_onsignal;
      sigemptyset(&sa.sa_mask);
      sa.sa_flags = SA_RESTART;
      if (sigaction(SIGVTALRM, &sa, (struct sigaction *)0) != 0) return -1;
    }
  }
  /* A CLOCK_MONOTONIC POSIX timer delivering SIGVTALRM: an hrtimer, so a slice of
   * 1ms is 1ms (ITIMER_VIRTUAL/PROF are only checked at the scheduler tick, 4ms and
   * more). One per process: a forked child has none (curse_preempt_tpid). */
  if (curse_preempt_tpid != getpid()) {
    struct sigevent ev;
    memset(&ev, 0, sizeof ev);
    ev.sigev_notify = SIGEV_SIGNAL;
    ev.sigev_signo = SIGVTALRM;
    if (usec <= 0) return 0;  /* (nothing armed in this process) */
    if (timer_create(CLOCK_MONOTONIC, &ev, &curse_preempt_timer) != 0) {
      memset(&it, 0, sizeof it);  /* (no POSIX timers: the CPU-time itimer) */
      it.it_value.tv_sec = usec / 1000000;
      it.it_value.tv_usec = usec % 1000000;
      return setitimer(ITIMER_VIRTUAL, &it, (struct itimerval *)0);
    }
    curse_preempt_tpid = getpid();
  }
  {
    struct itimerspec ts;
    memset(&ts, 0, sizeof ts);
    ts.it_value.tv_sec = usec / 1000000;
    ts.it_value.tv_nsec = (usec % 1000000) * 1000;
    return timer_settime(curse_preempt_timer, 0, &ts, (struct itimerspec *)0);
  }
}

/* The trapped signals the Lua side HOLDS to raise again later (runtime.lua: one that
 * arrives while an in-process subshell, a $(...) body, a module load or a foreground
 * command runs -- set 0 -- or while a scheduler task runs -- set 1). Trap-running code
 * (inside the VM hook) adds to them; ordinary code takes them -- and the hook can
 * preempt ordinary code at ANY VM instruction. A Lua read-check-clear of a shared
 * table (`if held then local d = held; held = nil ...`) was split by a trap that took
 * the set itself (its own $(...) ended and flushed), leaving the outer taker to index
 * nil ("attempt to index local 'd'", stress-attack S1) -- or to run a held signal
 * twice. One C call is one step the hook can't split (it fires only between VM
 * instructions, and the async handler never touches these), so each operation here is
 * atomic w.r.t. every trap. Inherited across fork, as the Lua table was. */
static uint64_t curse_held_set[2];

void curse_held_add(int set, int s)
{
  if (set >= 0 && set < 2 && s > 0 && s < CURSE_NSIG)
    curse_held_set[set] |= (uint64_t)1 << (s - 1);
}

/* Take (clear and return) the lowest held signal of `set`; 0: none. */
int curse_held_take(int set)
{
  uint64_t m;
  if (set < 0 || set >= 2 || !(m = curse_held_set[set])) return 0;
  curse_held_set[set] = m & (m - 1);
  return __builtin_ctzll(m) + 1;
}

/* Take the whole set: out[s] = 1 for each held signal s (1..64); returns how many. A
 * flush takes them all at once, as bash's run_pending_traps walks the pending set: a
 * trap it runs that flushes in turn (its compile's hold ending) finds nothing left to
 * run ahead of the others. */
int curse_held_takeall(int set, unsigned char *out)
{
  uint64_t m;
  int s, n = 0;
  if (set < 0 || set >= 2) return 0;
  m = curse_held_set[set];
  curse_held_set[set] = 0;
  for (s = 1; s < CURSE_NSIG; s++) {
    out[s] = (unsigned char)((m >> (s - 1)) & 1);
    n += out[s];
  }
  return n;
}

int curse_held_any(int set)
{
  return set >= 0 && set < 2 && curse_held_set[set] != 0;
}

/* The VM is about to be closed (luajit.c main, once an error escaped the shell or a
 * Lua program ended): no handler may touch it again. lua_close frees the global state
 * and unmaps the allocator's arenas and the machine code, while a signal storm keeps
 * arriving (and each caught signal still pending re-kicks itself, up to every 100ms):
 * the handler's lua_sethook on the freed globalL (g->hookmask, lj_dispatch_update's
 * dispatch table) and its trace patching wrote into freed/unmapped memory -- the
 * SIGSEGV that followed a Lua error escaping the shell (stress-attack S1). Every
 * signal stays blocked until the process exits (its failure status stands), the
 * timers are disarmed, and the handlers turn inert. */
void curse_sig_shutdown(void)
{
  sigset_t all;
  struct itimerval it;
  int s;
  sigfillset(&all);
  sigprocmask(SIG_BLOCK, &all, (sigset_t *)0);
  curse_sig_down = 1;
  for (s = 1; s < CURSE_NSIG; s++) curse_kick_disarm(s);
  if (curse_preempt_tpid == getpid()) {
    struct itimerspec ts;
    memset(&ts, 0, sizeof ts);
    timer_settime(curse_preempt_timer, 0, &ts, (struct itimerspec *)0);
  }
  memset(&it, 0, sizeof it);
  setitimer(ITIMER_VIRTUAL, &it, (struct itimerval *)0);
}

/* printf's floating conversions the way bash does them: the argument parsed as a long
 * double (strtold, in the current LC_NUMERIC) and formatted with the `L` length
 * modifier. LuaJIT's FFI has no long double, so `fmt` (e.g. "%.20Lf") and the number's
 * text go through here. Returns snprintf's result; *end_ok is 1 when strtold consumed
 * all of `num`, 0 when only a prefix (bash still prints that value), -1 when none. */
int curse_ldfmt(char *out, int n, const char *fmt, const char *num, int *end_ok)
{
  char *end;
  long double v = strtold(num, &end);
  if (end_ok) *end_ok = end == num ? -1 : (*end == '\0' ? 1 : 0);
  return snprintf(out, (size_t)n, fmt, v);
}

/* ---- FIFO opens that must not block the whole shell -------------------------
 * open(2) of a named FIFO blocks until the other end is opened -- and in curse that
 * other end may be a background job running in this very process, which can only
 * run while the shell waits at a scheduling point. Linux can't report a writer's
 * (or reader's) arrival to poll() (a FIFO opened O_NONBLOCK for reading polls
 * nothing until data or the first writer's close), so a helper thread does the
 * blocking open and signals an eventfd when it returns: the shell waits for that --
 * running the jobs meanwhile -- and its open returns exactly when bash's would.
 * The helper opens in a private copy of the fd table (unshare(CLONE_FILES)), emptied
 * first, so it never holds a pipe end of the shell open and its fd never lands in the
 * shell's table behind the shell's back (a concurrent dup2 of the shell or of a job
 * could collide with it). It also runs with a private cwd and umask
 * (unshare(CLONE_FS)): the shell's in-process jobs chdir/umask the process whenever
 * they run, so the path resolves against a directory fd of the REQUESTING shell's cwd
 * (openat), taken on the main thread at the call -- the same fd the FIFO check used --
 * and the umask is that shell's too; the fd is passed back over a socketpair (SCM_RIGHTS) and
 * installed by the shell itself, like any open. The helper blocks every signal: the
 * shell's handlers must only ever run on the main thread. A wait the shell abandons
 * (a trap exits) cancels it. */
#include <pthread.h>
#include <fcntl.h>
#include <errno.h>
#include <stdint.h>
#include <sys/eventfd.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/stat.h>
#ifndef O_PATH
#define O_PATH 010000000  /* (Linux; <fcntl.h> hides it without _GNU_SOURCE) */
#endif

struct curse_aopen {
  pthread_t th;
  char *path;
  int flags, mode, efd, sv[2];
  int dirfd;         /* the requesting shell's cwd (O_PATH), >= minfd */
  mode_t um;         /* ... and its umask */
  int err;  /* the open's errno; -1: no private fd table (open directly) */
};

static void *curse_aopen_run(void *p)
{
  struct curse_aopen *a = (struct curse_aopen *)p;
  uint64_t one = 1;
  int fd, old, efd = a->efd, k[3], i, j, t;
  unsigned from = 0;
  k[0] = efd; k[1] = a->sv[1]; k[2] = a->dirfd;
  for (i = 0; i < 3; i++)  /* (the fds kept, in order) */
    for (j = i + 1; j < 3; j++)
      if (k[j] < k[i]) { t = k[i]; k[i] = k[j]; k[j] = t; }
  if (syscall(SYS_unshare, 0x00000400 | 0x00000200 /* CLONE_FILES|CLONE_FS */) != 0) {
    a->err = -1;
  } else {
    for (i = 0; i < 3; i++) {
      if ((unsigned)k[i] > from) syscall(SYS_close_range, from, (unsigned)k[i] - 1, 0);
      from = (unsigned)k[i] + 1;
    }
    syscall(SYS_close_range, from, ~0U, 0);
    umask(a->um);
    fd = openat(a->dirfd, a->path, a->flags, a->mode);  /* (a cancellation point: _abandon) */
    pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &old);
    a->err = fd < 0 ? errno : 0;
    if (fd >= 0) {
      struct msghdr m;
      struct iovec io;
      char b = 0;
      union { struct cmsghdr h; char buf[CMSG_SPACE(sizeof(int))]; } u;
      memset(&m, 0, sizeof m); memset(&u, 0, sizeof u);
      io.iov_base = &b; io.iov_len = 1;
      m.msg_iov = &io; m.msg_iovlen = 1;
      m.msg_control = u.buf; m.msg_controllen = sizeof u.buf;
      CMSG_FIRSTHDR(&m)->cmsg_level = SOL_SOCKET;
      CMSG_FIRSTHDR(&m)->cmsg_type = SCM_RIGHTS;
      CMSG_FIRSTHDR(&m)->cmsg_len = CMSG_LEN(sizeof(int));
      memcpy(CMSG_DATA(CMSG_FIRSTHDR(&m)), &fd, sizeof(int));
      if (sendmsg(a->sv[1], &m, 0) < 0) a->err = errno;
      close(fd);  /* (the one in flight keeps the FIFO open) */
    }
  }
  if (write(efd, &one, sizeof one) < 0) { /* (can't fail) */ }
  return 0;
}

static int curse_fd_high(int fd, int minfd)
{
  int h;
  if (fd < 0) return -1;
  h = fcntl(fd, F_DUPFD_CLOEXEC, minfd);
  close(fd);
  return h;
}

/* Start opening `path` -- when it names a FIFO: returns a handle and its eventfd
 * (close-on-exec, >= minfd) in *efd, or NULL (then the caller opens directly) with
 * *efd = -2 when `path` is no FIFO (or can't be stat'ed). The FIFO check and the open
 * both resolve `path` against one fd of the caller's cwd, taken here. */
void *curse_aopen_start(const char *path, int flags, int mode, int minfd, int *efd)
{
  struct curse_aopen *a;
  pthread_attr_t at;
  sigset_t all, old;
  struct stat st;
  int r, sv[2], dfd;
  *efd = -1;
  dfd = curse_fd_high(open(".", O_PATH | O_DIRECTORY | O_CLOEXEC), minfd);
  if (dfd < 0) return 0;
  if (fstatat(dfd, path, &st, 0) != 0 || !S_ISFIFO(st.st_mode)) {
    close(dfd);
    *efd = -2;
    return 0;
  }
  a = (struct curse_aopen *)calloc(1, sizeof *a);
  if (!a) { close(dfd); return 0; }
  a->dirfd = dfd;
  a->um = umask(0); umask(a->um);  /* (the helpers have their own: no race) */
  a->path = strdup(path);
  a->flags = flags; a->mode = mode;
  a->efd = curse_fd_high(eventfd(0, EFD_CLOEXEC), minfd);
  a->sv[0] = a->sv[1] = -1;
  if (socketpair(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0, sv) == 0) {
    a->sv[0] = curse_fd_high(sv[0], minfd);
    a->sv[1] = curse_fd_high(sv[1], minfd);
  }
  if (!a->path || a->efd < 0 || a->sv[0] < 0 || a->sv[1] < 0) goto fail;
  pthread_attr_init(&at);
  pthread_attr_setstacksize(&at, 65536);
  sigfillset(&all);
  pthread_sigmask(SIG_BLOCK, &all, &old);  /* (inherited by the helper) */
  r = pthread_create(&a->th, &at, curse_aopen_run, a);
  pthread_sigmask(SIG_SETMASK, &old, (sigset_t *)0);
  pthread_attr_destroy(&at);
  if (r != 0) goto fail;
  *efd = a->efd;
  return a;
fail:
  close(a->dirfd);
  if (a->efd >= 0) close(a->efd);
  if (a->sv[0] >= 0) close(a->sv[0]);
  if (a->sv[1] >= 0) close(a->sv[1]);
  free(a->path); free(a);
  return 0;
}

static void curse_aopen_free(struct curse_aopen *a)
{
  pthread_join(a->th, (void **)0);  /* (it has signalled or been cancelled: ending) */
  close(a->efd); close(a->sv[0]); close(a->sv[1]); close(a->dirfd);
  free(a->path); free(a);
}

/* After its eventfd became readable: the opened fd (installed now, the lowest free
 * one, as open's), or -1 with errno set. Frees the handle. */
int curse_aopen_result(void *h)
{
  struct curse_aopen *a = (struct curse_aopen *)h;
  int fd = -1, e = a->err;
  if (e < 0) {  /* (no private table: a plain open, on the main thread) */
    fd = openat(a->dirfd, a->path, a->flags, a->mode);
    e = fd < 0 ? errno : 0;
  } else if (e == 0) {
    struct msghdr m;
    struct iovec io;
    char b;
    union { struct cmsghdr h; char buf[CMSG_SPACE(sizeof(int))]; } u;
    memset(&m, 0, sizeof m);
    io.iov_base = &b; io.iov_len = 1;
    m.msg_iov = &io; m.msg_iovlen = 1;
    m.msg_control = u.buf; m.msg_controllen = sizeof u.buf;
    if (recvmsg(a->sv[0], &m, (a->flags & O_CLOEXEC) ? MSG_CMSG_CLOEXEC : 0) < 0) {
      e = errno;
    } else if (CMSG_FIRSTHDR(&m) && CMSG_FIRSTHDR(&m)->cmsg_type == SCM_RIGHTS) {
      memcpy(&fd, CMSG_DATA(CMSG_FIRSTHDR(&m)), sizeof(int));
    } else {
      e = EIO;
    }
  }
  curse_aopen_free(a);
  if (fd < 0) errno = e;
  return fd;
}

/* The shell no longer waits for it (a trap exited, the job was killed): cancel the
 * open (a cancellation point; one past it just ends, its fd dropped with the pair). */
void curse_aopen_abandon(void *h)
{
  struct curse_aopen *a = (struct curse_aopen *)h;
  pthread_cancel(a->th);
  curse_aopen_free(a);
}
