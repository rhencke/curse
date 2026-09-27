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
#include "lj_obj.h"
#include <signal.h>
#include <string.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/time.h>
#include <time.h>

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
  sigset_t all, old;
  (void)ar;
  /* Take the signal and remove this hook with signals blocked: a signal arriving in
   * the middle of it would set the hook again (curse_sig_onsignal) only to have this
   * removal's read-modify-write of g->hookmask drop it — or be counted here and fire
   * the hook once more with nothing to run. Blocked, it is delivered once this is
   * done and schedules a fresh hook. */
  sigfillset(&all);
  sigprocmask(SIG_BLOCK, &all, &old);
  lua_sethook(L, (lua_Hook)0, 0, 0);
#ifdef CURSE_SIG_DESTRUCTIVE
  /* Back in the interpreter: undo the preemption patches (a trace reaching the
   * interpreter through a patched tail jmp's trampoline skips lj_trace_exit). */
  { extern void curse_sig_unpatch_all(void); curse_sig_unpatch_all(); }
#endif
  s = (int)curse_sig_num;
  curse_sig_num = 0;
  sigprocmask(SIG_SETMASK, &old, (sigset_t *)0);
  if (getpid() != curse_sig_pid || s == 0) return; /* inherited across fork (or none): skip */
  lua_getglobal(L, "__curse_sigrun");
  if (lua_isfunction(L, -1)) {
    lua_pushinteger(L, s);
    /* The trap runs as ordinary code, not as a hook: a signal arriving while it runs
     * fires its own hook INSIDE it, nested — as bash's run_pending_traps runs a pending
     * trap at the running handler's next command. (callhook only skips a hook while
     * HOOK_ACTIVE; it is set again before returning to callhook, which clears it.) */
    hook_leave(G(L));
    lua_call(L, 1, 0);
    hook_enter(G(L));
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
   * above won't fire inside it. Destructively patch the running code's loop heads
   * and trace links to force an exit (reverted the instant the interpreter is
   * reached). See lj_trace.c. */
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
 * could collide with it); the fd is passed back over a socketpair (SCM_RIGHTS) and
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

struct curse_aopen {
  pthread_t th;
  char *path;
  int flags, mode, efd, sv[2];
  int err;  /* the open's errno; -1: no private fd table (open directly) */
};

static void *curse_aopen_run(void *p)
{
  struct curse_aopen *a = (struct curse_aopen *)p;
  uint64_t one = 1;
  int fd, old, efd = a->efd, so = a->sv[1];
  int lo = efd < so ? efd : so, hi = efd < so ? so : efd;
  if (syscall(SYS_unshare, 0x00000400 /* CLONE_FILES */) != 0) {
    a->err = -1;
  } else {
    if (lo > 0) syscall(SYS_close_range, 0, (unsigned)lo - 1, 0);
    if (hi > lo + 1) syscall(SYS_close_range, (unsigned)lo + 1, (unsigned)hi - 1, 0);
    syscall(SYS_close_range, (unsigned)hi + 1, ~0U, 0);
    fd = open(a->path, a->flags, a->mode);  /* (a cancellation point: _abandon) */
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
      if (sendmsg(so, &m, 0) < 0) a->err = errno;
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

/* Start opening `path`; returns a handle and its eventfd (close-on-exec, >= minfd)
 * in *efd, or NULL (then the caller opens directly). */
void *curse_aopen_start(const char *path, int flags, int mode, int minfd, int *efd)
{
  struct curse_aopen *a = (struct curse_aopen *)calloc(1, sizeof *a);
  pthread_attr_t at;
  sigset_t all, old;
  int r, sv[2];
  if (!a) return 0;
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
  if (a->efd >= 0) close(a->efd);
  if (a->sv[0] >= 0) close(a->sv[0]);
  if (a->sv[1] >= 0) close(a->sv[1]);
  free(a->path); free(a);
  return 0;
}

static void curse_aopen_free(struct curse_aopen *a)
{
  pthread_join(a->th, (void **)0);  /* (it has signalled or been cancelled: ending) */
  close(a->efd); close(a->sv[0]); close(a->sv[1]);
  free(a->path); free(a);
}

/* After its eventfd became readable: the opened fd (installed now, the lowest free
 * one, as open's), or -1 with errno set. Frees the handle. */
int curse_aopen_result(void *h)
{
  struct curse_aopen *a = (struct curse_aopen *)h;
  int fd = -1, e = a->err;
  if (e < 0) {  /* (no private table: a plain open) */
    fd = open(a->path, a->flags, a->mode);
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
