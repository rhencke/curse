# curse

**A bash-compatible shell, implemented in LuaJIT.**

curse runs shell scripts on a *tiered* engine: a tree-walking interpreter starts
instantly and, once a script gets hot, hands off **mid-execution** to transpiled
Lua that LuaJIT traces down to machine code. It runs on a lightly-patched LuaJIT
and ships as a resident per-user daemon fronted by a tiny static client — so the
common case (`sh -c '…'` fired thousands of times by a `make` build, a
`./configure`, or boot) pays curse's startup and JIT warmup **once** and
amortizes it across every invocation, where a freshly-`exec`'d shell never can.

> **History.** curse began as a bash → TypeScript/Node transpiler (hence its
> GPLv3+ lineage from bash's own sources). That prototype has been retired; the
> project is now the LuaJIT implementation under [`lua/`](lua/). A few in-tree
> comments still call "the TS parser" the reference oracle — that's the removed
> prototype, and those notes are being cleaned up.

## Why LuaJIT

- **Starts in ~1 ms** — faster than bash (~2 ms). Startup is the one axis a shell
  can't hide from `make -j`, and LuaJIT wins it outright.
- **Exact 64-bit arithmetic is free.** Integers are `int64` FFI cdata, which wrap
  in two's-complement exactly like bash; LuaJIT sinks the boxing inside traces, so
  correctness costs nothing and a hot arithmetic loop runs orders of magnitude
  faster than bash's.
- **Byte-accurate strings.** Lua strings are byte arrays — precisely bash's storage
  model, with raw-byte fidelity throughout (no Unicode re-encoding surprises).
- **A real JIT under the hot path.** Loops and functions that dominate a script's
  runtime become traced machine code with near-zero dispatch overhead.

## How it works — interpret, then switch (tiered / OSR)

Two tiers share **one `sh` runtime table** ([`lua/runtime.lua`](lua/runtime.lua)),
so the handoff between them transfers no state:

1. **Interpreter** ([`lua/interp.lua`](lua/interp.lua)) — a tree-walker that starts
   with zero warmup and runs statement-by-statement, like bash. At every
   *safepoint* (a top-level statement boundary and every loop back-edge) it calls a
   hook.
2. **Compiled** ([`lua/emit.lua`](lua/emit.lua) → Lua source → `load()`) — the AST
   is transpiled to a **flattened control-flow graph dispatched on a program
   counter** (`run(sh, pc)`). Because control flow is flattened, `run()` can be
   *entered at any pc* — the condition check of any loop, at any nesting depth — and
   following the pc transitions reconstructs the full continuation. That is general
   **on-stack replacement**: the interpreter can jump into compiled code from
   exactly where it was, even mid-loop inside nested loops or an `if`. Variables
   used only arithmetically are lifted to native `int64` locals. LuaJIT then traces
   the hot pc path to machine code.

[`lua/tier.lua`](lua/tier.lua) orchestrates the switch. Compilation can even run in
the background: `tier.run_background` spawns a *detached* transpile while the
interpreter keeps going, then jumps into the compiled module the instant it lands.
A persistent, content-hashed artifact cache ([`lua/cache.lua`](lua/cache.lua))
keys compiled bytecode by the script's bytes (not its path), so repeated workloads
— and pathless `sh -c '…'` — skip recompilation entirely.

See [`lua/README.md`](lua/README.md) for the full tiered-execution write-up.

## The custom LuaJIT

curse runs on stock LuaJIT plus a small, tracked patch set in
[`patches/luajit/`](patches/luajit/), pinned to a specific upstream commit
([`LUAJIT_COMMIT`](patches/luajit/LUAJIT_COMMIT)). The build clones pristine
upstream at that commit and applies:

- **[`curse.patch`](patches/luajit/curse.patch)** — patches `luajit.c` and the JIT
  core. It adds three things:
  - an **optionally-embedded bytecode bundle** (`curse_load_bundle`): the runtime
    modules are baked into the binary as a weak-linked C array, so `require()`
    resolves them from memory with no file open and no source parse;
  - **shell-name dispatch**: when the binary is invoked under a shell name
    (`sh`/`bash`/`dash`/… or a login `-name`) with the bundle embedded, the whole
    argv is routed to curse's sh CLI ([`lua/run.lua`](lua/run.lua)) — making the
    self-contained static binary a **drop-in `/bin/sh`**;
  - **destructive JIT-loop preemption** (`-DCURSE_SIG_DESTRUCTIVE`): on a signal,
    a running JIT loop's back-edge is overwritten with a jump to the exit stub and
    restored the instant it exits — so signals and `trap` are delivered even inside
    hot compiled loops, at **zero steady-state cost** (the hot loop stays
    byte-identical to stock LuaJIT).
- **[`lib_cursesys.c`](patches/luajit/lib_cursesys.c)** — a direct-syscall system
  library (e.g. reads `/etc/passwd` itself, so the static binary needs no glibc NSS
  / `dlopen`).
- **[`lib_cursesig.c`](patches/luajit/lib_cursesig.c)** — the async signal handler
  that schedules the VM hook running the shell's trap.

## The daemon

`cursed` ([`lua/daemon.lua`](lua/daemon.lua)) is a warm, resident LuaJIT process,
**one per user**, that serves requests over a unix socket in `$XDG_RUNTIME_DIR` and
**forks a worker per request**. Each worker inherits the warm heap and hot JIT
traces via copy-on-write `fork()`, so it runs *faster than a freshly-`exec`'d
shell*. The tiny static client [`daemon/curse-client.c`](daemon/curse-client.c)
hands the daemon its argv, cwd, environ, and its own stdin/stdout/stderr (via
`SCM_RIGHTS`, so the script's I/O **is** the caller's — no proxying). Per-user (not
one shared root daemon) makes the whole local-privilege-escalation class *not
exist*; and the daemon is pure speedup — if the socket is missing or unusable the
client `execvp`s a fallback (`$CURSE_FALLBACK`, default `dash`), so nothing ever
breaks when it's absent.

Full design, wire protocol, and current limits: [`daemon/README.md`](daemon/README.md).

## Build

You need a C toolchain (`cc`, `make`, `ar`), `git`, GNU `readline` (for the
interactive REPL), and network access for the one-time LuaJIT clone. A bootstrap
`luajit` is needed to compile the bundle.

```sh
scripts/build-luajit.sh          # (--no-pgo to skip profile-guided opt, --fresh to re-clone)
```

This clones the pinned LuaJIT, applies the curse patches, builds with
`-O3 -march=native` + PGO, and produces (all under the gitignored `.bench-lua/`):

- **`.bench-lua/luajit`** — dynamic; loads `dist/curse.bc` from disk. Used by the
  daemon, the spec harness, and dev.
- **`.bench-lua/curse`** — fully static, with the module bundle **embedded**.
  Self-contained (no `dist/` or `lua/` dir needed) — the shippable one-shot binary
  and drop-in `/bin/sh`.

[`lua/build.lua`](lua/build.lua) produces the bundle itself
(`dist/curse.bc` bytecode + `dist/curse_bundle.c` for embedding).

## Run

```sh
# One-shot, self-contained static binary:
.bench-lua/curse -c 'echo hi; echo $((2 + 3))'

# Or drive the CLI directly on any luajit (picks up dist/curse.bc if present):
luajit lua/run.lua script.sh                 # run a script
luajit lua/run.lua -c 'for ((i=0;i<3;i++)); do echo $i; done'
luajit lua/run.lua script.sh interp          # force a tier: interp | compiled | tiered (default)
luajit lua/run.lua -i                         # interactive REPL (readline)

# Resident daemon + client:
cc -O2 -s -static -o dist/curse daemon/curse-client.c
luajit lua/build.lua                          # -> dist/curse.bc
CURSE_IDLE=300 luajit lua/daemon.lua &        # self-exits after 300s idle
./dist/curse -c 'echo hi'                      # client talks to the daemon
```

Leading shell options (`-e`, `-u`, `-x`, `-o NAME`, `-O NAME`, `--rcfile`,
`--norc`) are accepted before `-c`/the script, as in bash.

## Tests

- **[`test/cases/`](test/cases/)** — curse's own conformance corpus: small bash
  scripts, each checked against **real bash**'s output and exit status (bash is the
  oracle).
- **Oils spec suite** — [`lua/spec.lua`](lua/spec.lua) runs the
  [Oils](https://oils.pub) spec tests as a progress scoreboard:
  ```sh
  test/spec/fetch.sh                  # download Oils' spec/*.test.sh into reference/oil/ (gitignored)
  luajit lua/spec.lua --interp        # or --compiled / --cached; [--diff] [--divergence] [file-substr…]
  ```
- **[`test/real/`](test/real/)** — end-to-end real-world scripts (e.g. `diff.sh`,
  `fetch.sh`).
- **Unit tests** — targeted Lua tests run directly, e.g. `luajit lua/test_tier.lua`
  (also `test_nested`, `test_funcs`, `test_forin`, `test_cache`).

## Layout

```
lua/              the shell
  run.lua           sh CLI entry (-c, script, -i, options); the static binary IS this
  repl.lua          interactive REPL (GNU readline via FFI)
  parser.lua        bash parser -> AST (consumed by both interp and emit)
  interp.lua        tree-walking interpreter (tier 1)
  emit.lua          AST -> flattened pc-dispatch Lua (tier 2, JIT-traced)
  tier.lua          orchestrates interp -> OSR -> compiled
  runtime.lua       the shared `sh` state (scope chain, expansion, int64 arithmetic)
  cache.lua         persistent content-hashed compiled-artifact cache
  daemon.lua        the resident per-user server (cursed)
  build.lua         amalgamate modules -> dist/curse.bc (+ curse_bundle.c)
  b_*.lua           builtins (cd, export, read, trap, printf, getopts, jobs, …)
patches/luajit/   the custom LuaJIT patch + C libs (see above)
daemon/           curse-client.c (the tiny static front end) + design doc
scripts/          build-luajit.sh (reproducible LuaJIT build recipe)
test/
  cases/            conformance scripts (vs real bash)
  spec/             Oils spec-test fetch + runner glue
  real/             real-world end-to-end scripts
reference/        upstream bash + Oils sources (gitignored) — porting + test source
dist/             build output (gitignored): curse.bc, curse_bundle.c
```

## Status

Work in progress. The **interpreter** and its builtins target a broad bash surface;
the **compiled/JIT tier** currently covers the hot subset — scalar assignments,
`for`/`while`/`if`, functions (with inlining), positional parameters, and 64-bit
`$(( … ))` arithmetic — and is growing toward the full grammar. Near-term work:
extend the compiled grammar (real commands, `case`, `for x in LIST`, pipelines,
redirections), wire the shared conformance harness, and complete the parser port.
Details and benchmarks live in [`lua/README.md`](lua/README.md).

## License

**GPLv3+** (see [LICENSE](LICENSE)). curse is a derivative work of **GNU Bash** —
its parser, expansion engine, and AST are ported from bash's `parse.y`,
`subst.c`, and `command.h`, and its conformance corpus reuses bash's own tests. The
Oils spec corpus (Apache-2.0, compatible) is fetched, not redistributed. Upstream
bash and Oils sources are kept locally under `reference/` (gitignored). See
[NOTICE.md](NOTICE.md) for full attribution.
