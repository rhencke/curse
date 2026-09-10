# cursed — the per-user resident curse

A warm, resident LuaJIT process that serves `sh -c '…'` requests over a unix
socket, forking a worker per request. The point: a worker inherits the warm heap
and hot JIT traces via copy-on-write `fork()`, so it runs shell work *faster than
a freshly-`exec`'d shell* — the fixed cost of loading curse's runtime and warming
the JIT is paid once, then amortized across every invocation. This is what makes
curse worth it for high-count bursty workloads (`make` builds, `./configure`,
boot) rather than one-shot use, where a fresh process can never amortize warmup.

## Pieces

- **`curse-client.c`** — the tiny, fast front end a `/bin/sh` symlink points at.
  Connects to the user's `cursed`, hands over `argv` + cwd + `environ` and its own
  stdin/stdout/stderr (via `SCM_RIGHTS`, so the script's I/O *is* the caller's, no
  proxying), waits for the exit status, exits with it. Must start faster than
  dash, so it's minimal C. Build: `cc -O2 -o curse daemon/curse-client.c`.
- **`../lua/daemon.lua`** — the server. Loads the bytecode bundle, listens,
  `accept → recvmsg → fork worker → keep accepting`. Workers send their own exit
  status back and `_exit`; the parent reaps them opportunistically (no zombies,
  no blocking), so parallel `make -j` recipes run concurrently.

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
(read-only/short-`$XDG_RUNTIME_DIR`), the client `execvp`s a fallback
(`$CURSE_FALLBACK`, default `dash`; a shipped curse points it at the standalone
one-shot binary) with the same argv. Nothing ever breaks because the daemon is
absent — early boot before the user session exists just runs one-shot.

## Wire protocol (local socket, same host → host-endian u32)

Request (client → daemon), with fds 0,1,2 attached as `SCM_RIGHTS`:

    u32 magic = "CURS"
    u32 nargs;  nargs × (u32 len, bytes)      -- argv
    u32 cwdlen, bytes                         -- getcwd()
    u32 nenv;   nenv  × (u32 len, bytes)      -- environ (KEY=VALUE)

Response (daemon → client): `int32 status`, then close.

## Gotchas / current limits

- **`sun_path` is 108 bytes** incl. NUL. The daemon refuses (not truncates) a
  socket path that doesn't fit — keep `$XDG_RUNTIME_DIR` short (it is: `/run/user/<uid>`).
- The worker inherits the caller's cwd/env/fds, but **not yet** umask, process
  group/session, or rlimits — fine for `sh -c` batch use, needs work for job
  control / interactive use.
- Bare external-command stdout is currently captured-then-re-emitted (correct
  bytes, but not zero-copy / no live interleaving) — an optimization for later.
- No on-demand autostart yet: start `cursed` once per session (a systemd user
  unit with socket activation is the intended production form).

## Run it

    cc -O2 -o dist/curse daemon/curse-client.c
    luajit lua/build.lua                       # dist/curse.bc
    CURSE_IDLE=300 luajit lua/daemon.lua &     # self-exits after 300s idle
    ./dist/curse -c 'echo hi; echo $((2+3))'
