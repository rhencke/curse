/* curse: asynchronous, preemptive signal handling for the shell.
 *
 * LuaJIT forbids running Lua from an async C signal handler, so the handler does
 * only async-signal-safe work: record which signal fired AND schedule a VM debug
 * hook (lua_sethook) — exactly LuaJIT's own Ctrl-C mechanism (laction in luajit.c).
 * The hook fires at the next VM safepoint, in a SAFE Lua context, and runs THAT
 * signal's trap directly (no pending queue, no draining, no polling — the VM
 * delivers the trap).
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
#include <signal.h>
#include <string.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/time.h>

static volatile sig_atomic_t curse_sig_num;  /* the signal to deliver at the next safepoint */
static volatile pid_t curse_sig_pid;         /* pid that scheduled the hook (fork guard) */

extern lua_State *curse_globalL(void);  /* luajit.c */

/* Scheduled hook: runs at the next VM safepoint in a safe Lua context. Removes
 * itself (one-shot) BEFORE running Lua, then calls curse's trap runner with the
 * signal number. Errors/exit from the trap propagate normally (Lua's error
 * unwinding), so `trap 'exit' INT` exits — we deliberately do NOT pcall.
 *
 * A forked child inherits both the scheduled hook and curse_sig_num; without a
 * guard it would fire the PARENT's pending trap at its first instruction (before
 * it can reset its dispositions). So the hook is a no-op unless it runs in the
 * process that scheduled it — the child's inherited hook just clears itself. */
static void curse_sig_hook(lua_State *L, lua_Debug *ar)
{
  int s;
  (void)ar;
  lua_sethook(L, (lua_Hook)0, 0, 0);
  if (getpid() != curse_sig_pid) { curse_sig_num = 0; return; } /* inherited across fork: skip */
  s = (int)curse_sig_num;
  curse_sig_num = 0;
  lua_getglobal(L, "__curse_sigrun");
  if (lua_isfunction(L, -1)) {
    lua_pushinteger(L, s);
    lua_call(L, 1, 0);
  } else {
    lua_pop(L, 1);
  }
}

static void curse_sig_onsignal(int s)
{
  lua_State *L;
  curse_sig_num = s;
  curse_sig_pid = getpid();
  /* Schedule the trap for the next safepoint (laction pattern). Count=1 fires on
   * the next VM instruction; call/ret masks make blocking-syscall returns fire it
   * promptly. The hook removes itself, so this is a one-shot per signal. */
  L = curse_globalL();
  if (L) lua_sethook(L, curse_sig_hook,
                     LUA_MASKCALL | LUA_MASKRET | LUA_MASKCOUNT, 1);
#ifdef CURSE_SIG_DESTRUCTIVE
  /* A pure-compute JIT loop never reaches a VM safepoint, so the scheduled hook
   * above won't fire inside it. Destructively patch the running trace's back-edge
   * to force a side-exit (reverted the instant the exit fires). See lj_trace.c. */
  { extern void curse_sig_patch_trace(void); curse_sig_patch_trace(); }
#endif
}

/* Install curse's async handler for signal `s` (no SA_RESTART -> blocking syscalls
 * EINTR). */
int curse_sig_catch(int s)
{
  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_handler = curse_sig_onsignal;
  sigemptyset(&sa.sa_mask);
  sa.sa_flags = 0;
  return sigaction(s, &sa, (struct sigaction *)0);
}

/* Restore the default disposition for `s`. */
int curse_sig_default(int s)
{
  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_handler = SIG_DFL;
  return sigaction(s, &sa, (struct sigaction *)0);
}

/* Ignore `s` (bash `trap '' SIG`). */
int curse_sig_ignore(int s)
{
  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_handler = SIG_IGN;
  return sigaction(s, &sa, (struct sigaction *)0);
}

/* Discard a pending scheduled trap: clear the recorded signal and remove the VM
 * hook. A forked child calls this AFTER restoring its default dispositions, so a
 * signal it caught in the fork→reset window (e.g. `cmd & ; kill -SIG $!`) does not
 * fire a spurious trap once the child is running. */
void curse_sig_clearpending(void)
{
  lua_State *L = curse_globalL();
  curse_sig_num = 0;
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
 * runs, the scheduler arms a one-shot CPU-time timer (ITIMER_VIRTUAL: only time
 * actually spent computing counts); its handler raises a flag that the job checks
 * at every loop head (interp and compiled code), yielding back to the scheduler.
 * A JIT trace hoists that check out of its loop, so the handler also patches the
 * running trace's back-edge to force the exit (as a trap signal does). SA_RESTART:
 * the tick must not EINTR the job's syscalls. */
static volatile int curse_preempt_flag;

static void curse_preempt_onsignal(int s)
{
  (void)s;
  curse_preempt_flag = 1;
#ifdef CURSE_SIG_DESTRUCTIVE
  { extern void curse_sig_patch_trace(void); curse_sig_patch_trace(); }
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
  memset(&it, 0, sizeof it);
  it.it_value.tv_sec = usec / 1000000;
  it.it_value.tv_usec = usec % 1000000;
  return setitimer(ITIMER_VIRTUAL, &it, (struct itimerval *)0);
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
