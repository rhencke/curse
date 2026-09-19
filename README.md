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

curse runs on stock LuaJIT plus a small, tracked patch set. Meson pins LuaJIT to
an exact upstream commit ([`subprojects/luajit.wrap`](subprojects/luajit.wrap))
and, at `meson setup`, applies curse's C-mods from
[`subprojects/packagefiles/luajit/`](subprojects/packagefiles/luajit/):

- **[`curse.patch`](subprojects/packagefiles/luajit/curse.patch)** — patches `luajit.c`
  and the JIT core. It adds three things:
  - an **optionally-embedded bytecode bundle** (`curse_load_bundle`): the runtime
    modules are baked into the binary as a weak-linked C array, so `require()`
    resolves them from memory with no file open and no source parse;
  - **shell-name dispatch**: when the binary is invoked under a shell name
    (`sh`/`bash`/`dash`/`ash`/`rbash`, or a login `-name`) with the bundle
    embedded, the whole argv is routed to curse's sh CLI
    ([`lua/run.lua`](lua/run.lua)) — so a `sh` symlink to the static binary is a
    **drop-in `/bin/sh`**. (Invoked as `curse` itself it stays plain luajit, for
    dev / bytecode / build use.)
  - **destructive JIT-loop preemption** (`-DCURSE_SIG_DESTRUCTIVE`): on a signal,
    a running JIT loop's back-edge is overwritten with a jump to the exit stub and
    restored the instant it exits — so signals and `trap` are delivered even inside
    hot compiled loops, at **zero steady-state cost** (the hot loop stays
    byte-identical to stock LuaJIT).
- **[`lib_cursesys.c`](subprojects/packagefiles/luajit/src/lib_cursesys.c)** — a
  direct-syscall system library (e.g. reads `/etc/passwd` itself, so the static
  binary needs no glibc NSS / `dlopen`).
- **[`lib_cursesig.c`](subprojects/packagefiles/luajit/src/lib_cursesig.c)** — the
  async signal handler that schedules the VM hook running the shell's trap.

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

Needs [Meson](https://mesonbuild.com) + [Ninja](https://ninja-build.org), a C
toolchain (`cc`, `make`, `ar`), `git`, GNU `readline` (for the interactive REPL),
and network access for the one-time LuaJIT clone.

```sh
meson setup build
meson compile -C build     # -Dpgo=true    for the PGO release build (instrument -> train -> rebuild)
                           # -Dnative=false for portable binaries (no -march=native)
```

Meson pins + fetches LuaJIT, applies curse's C-mods, drives LuaJIT's own Makefile
via [`tools/build-luajit-vm.sh`](tools/build-luajit-vm.sh), then bundles the Lua
runtime ([`lua/build.lua`](lua/build.lua), run on the just-built luajit) and links
everything. Outputs land in `build/`:

- **`build/luajit`** — dynamic; loads `dist/curse.bc` from disk. For the daemon,
  the spec harness, and dev.
- **`build/curse`** — fully static, module bundle **embedded**. Self-contained
  (no `dist/` or `lua/` needed) — the shippable one-shot binary; symlink `sh` → it
  for a drop-in `/bin/sh`.
- **`build/curse-client`** — the tiny static daemon front end.

`meson test -C build` runs the unit + conformance suites (see **Tests** below); the bash/oil
conformance corpora are fetched at setup as subprojects. `ninja -C build fetch-real`
downloads the real-world diff-test scripts.

## Run

```sh
# Self-contained static binary — it's the shell when invoked as `sh` (symlink it):
ln -s "$PWD/build/curse" /tmp/sh && /tmp/sh -c 'echo hi; echo $((2 + 3))'

# Or drive the CLI directly on the dynamic luajit (picks up dist/curse.bc if present):
build/luajit lua/run.lua script.sh              # run a script
build/luajit lua/run.lua -c 'for ((i=0;i<3;i++)); do echo $i; done'
build/luajit lua/run.lua script.sh interp       # force a tier: interp | compiled | tiered (default)
build/luajit lua/run.lua -i                      # interactive REPL (readline)

# Resident daemon + client (full setup in daemon/README.md):
CURSE_BUNDLE=build/curse.bc build/luajit lua/daemon.lua &   # self-exits on idle ($CURSE_IDLE)
build/curse-client -c 'echo hi'                 # client talks to the daemon
```

Leading shell options (`-e`, `-u`, `-x`, `-o NAME`, `-O NAME`, `--rcfile`,
`--norc`) are accepted before `-c`/the script, as in bash.

## Tests

`meson test -C build --suite unit` runs the fast tiered-execution suites (`test_tier`,
`test_nested`, `test_funcs`, `test_forin`, `test_cache`) on the built luajit.

**Conformance harness** — [`test/conformance/run.sh`](test/conformance/run.sh)
runs each test under **bash** (the oracle), **dash** (where it supports the test),
and curse's three tiers (**interp / compiled / tiered**), scoring each shell's
agreement with bash on stdout + exit status **and its summed run time** (bash vs
dash vs curse's tiers). Parallelism is bounded (`--jobs`, default gentle — each
tier spawns work; use `--jobs 1` for clean timing). Three corpora:

- **`cases`** — [`test/cases/`](test/cases/), curse's own scripts (no download).
- **`bash`** — GNU bash's own `tests/*.tests` suite.
- **`oil`** — the [Oils](https://oils.pub) `spec/*.test.sh` cases that target bash
  (bash listed in `compare_shells`, minus oil-only / `N-I bash` cases).

The `bash` and `oil` corpora are **Meson subprojects** — bash from the GNU release
tarball + `source_hash` ([`subprojects/bash.wrap`](subprojects/bash.wrap), pinned
to match the host oracle), oil from a pinned git commit
([`subprojects/oil.wrap`](subprojects/oil.wrap), since no Oils release tarball
ships the spec tests). Meson fetches them **at setup** (required by default — a
fetch failure is a hard error, not a silent skip) and finds the shells it needs
(`bash`, `dash`, `timeout`), so the whole suite just runs — no flags, nothing to prep:

```sh
meson setup build          # fetches bash (tarball) + oil (git) corpora; checks bash/dash/timeout
meson compile -C build
meson test -C build                 # unit + conformance (cases + bash + oil)
meson test -C build --suite unit    # just the fast unit tests
meson test -C build --suite conformance -v    # just the conformance scoreboards
```

`-Dconformance=disabled` skips the corpus fetch (lean/offline build); `=auto` makes
it best-effort (non-fatal offline). For a tight loop, run the harness directly:
`test/conformance/run.sh --corpus oil --jobs 4 arith`.

- **[`test/real/`](test/real/)** — end-to-end real-world scripts under `docker diff`
  ([`diff.sh`](test/real/diff.sh)). **[`lua/spec.lua`](lua/spec.lua)** — the older
  single-tier Oils runner, scored against the recorded golden files.

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
  build.lua         amalgamate modules -> curse.bc (+ curse_bundle.c)
  b_*.lua           builtins (cd, export, read, trap, printf, getopts, jobs, …)
daemon/           curse-client.c (the tiny static front end) + design doc
subprojects/      Meson deps: LuaJIT (luajit.wrap + curse's C-mods in packagefiles/)
                    and the conformance corpora (bash.wrap tarball, oil.wrap git)
tools/            build-luajit-vm.sh (Meson-driven VM build), run-lua.sh
meson.build       the build: fetch LuaJIT -> patched VM -> bundle -> curse + client
test/
  cases/            curse's own conformance scripts (vs real bash)
  conformance/      run.sh — the bash/dash/curse×3 harness
  real/             real-world end-to-end scripts (docker diff)
reference/        upstream bash + Oils sources (gitignored) — porting + test source
build/            Meson build dir (gitignored): luajit, curse, curse-client, curse.bc
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
