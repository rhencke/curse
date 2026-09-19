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
