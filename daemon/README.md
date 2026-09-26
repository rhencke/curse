# cursed — the per-user resident curse

A warm, resident LuaJIT process that serves `sh -c '…'` requests over a unix
socket from a pool of persistent warm workers. The point: a worker has curse's
runtime loaded, the compile cache open and hot JIT traces, so it runs shell work
*faster than a freshly-`exec`'d shell* — the fixed cost of loading curse's runtime
and warming the JIT is paid once, then amortized across every invocation. This is what makes
curse worth it for high-count bursty workloads (`make` builds, `./configure`,
boot) rather than one-shot use, where a fresh process can never amortize warmup.

## Pieces

- **`curse-client.c`** — the tiny, fast front end a `/bin/sh` symlink points at.
  Connects to the user's `cursed`, hands over `argv` + cwd + `environ` and its own
  stdin/stdout/stderr (via `SCM_RIGHTS`, so the script's I/O *is* the caller's, no
  proxying), waits for the exit status, exits with it. Must start faster than
  dash, so it's minimal C, built **static** to skip the dynamic loader (ld.so is
  ~0.185 ms of per-invocation startup — measured). Meson builds it as
  `build/curse-client`.
- **`../lua/daemon.lua`** — the server. Loads the bytecode bundle, binds the
  socket, and forks a pool of workers (`$CURSE_WORKERS`) that all block in
  `accept()` on it; the kernel hands each connection to one worker. A worker runs
  the script **in-process** on the caller's fds, sends the exit status back, then
  scrubs the per-request process state (fds, cwd, environ, umask, signal mask,
  rlimits) and loops — no fork per request. The parent only forks to replace a
  crashed or idled-out worker, so parallel `make -j` recipes run concurrently.
  An exclusive `flock` makes it single-instance: racing starts are harmless.

## Per-user, and why not one shared daemon

`cursed` runs **as the user**, one instance per user, socket in
`$XDG_RUNTIME_DIR` (mode 0700, owned by the user, kernel-cleaned on logout). We
still `SO_PEERCRED`-check every peer and reject any uid ≠ ours (defense-in-depth),
and the artifact cache is the per-uid 0700 one.

A single **shared** daemon would have to run privileged, authenticate each caller,
and *drop* to that user in the worker (`setgroups`→`setgid`→`setuid`, exact order)
while rebuilding their whole context. Every step is a classic local-root hole, and
worse, the daemon would parse attacker-controlled scripts **as root before the
fork** — any memory-safety bug in the LuaJIT/FFI parser becomes root RCE for every
local user. That's `sshd`/`sudo`-tier hardening for marginal RAM savings. Per-user
makes the entire privilege-escalation class *not exist*: a bug compromises only an
account its owner already controls. So: per-user, always.

## Fallback — the daemon is speedup, never a dependency

If the socket is missing (daemon not started), refused (crashed), or unusable
(read-only/short-`$XDG_RUNTIME_DIR`), the client `execvp`s a fallback with the
same argv: `$CURSE_FALLBACK`, default `curse` — the self-contained one-shot binary,
so curse still runs the script, just cold. Nothing ever breaks because the daemon
is absent — early boot before the user session exists just runs one-shot.

When the socket is missing and `$CURSE_DAEMON` is set (the command that launches
the daemon, e.g. `luajit /path/lua/daemon.lua`), the client also starts it in the
background (double-fork + `setsid`, stdio on `/dev/null`) so later invocations
are warm; this one still falls back.

## Wire protocol (local socket, same host → host-endian u32)

Request (client → daemon), with fds 0,1,2 attached as `SCM_RIGHTS`:

    u32 magic = "CURS"
    u32 nargs;  nargs × (u32 len, bytes)      -- argv
    u32 cwdlen, bytes                         -- getcwd()
    u32 nenv;   nenv  × (u32 len, bytes)      -- environ (KEY=VALUE)
    u32 sigign                                -- signals ignored at entry (bit n-1 = signal n)
    u32 nextra; nextra × u32                  -- numbers of the other inherited fds (3..63),
                                              -- attached after 0,1,2 in the same SCM_RIGHTS

Response (daemon → client): `int32 status`, then close. Bit `0x10000` set means
the script's shell died by signal `(status >> 8) & 0x7f`; the client then kills
itself with that signal, as bash would have died.

## Gotchas / current limits

- **`sun_path` is 108 bytes** incl. NUL. The daemon refuses (not truncates) a
  socket path that doesn't fit — keep `$XDG_RUNTIME_DIR` short (it is: `/run/user/<uid>`).
- The worker takes the caller's cwd/env/fds/ignored signals, but **not yet** its
  umask, process group/session, or rlimits (it runs with the daemon's) — fine for
  `sh -c` batch use, needs work for job control / interactive use.
- Autostart is the client's `$CURSE_DAEMON` hook above; a systemd user unit with
  socket activation is the intended production form.

## Run it

    meson compile -C build     # build/luajit, build/curse.bc, build/curse-client
    CURSE_BUNDLE=build/curse.bc CURSE_IDLE=300 build/luajit lua/daemon.lua &   # self-exits after 300s idle
    build/curse-client -c 'echo hi; echo $((2+3))'
