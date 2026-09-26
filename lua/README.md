# lua/ — curse's shell engine

A bash-compatible shell on **LuaJIT**, with two execution tiers that share one runtime.
bash 5.2 is the oracle: the conformance corpora (`test/`) compare every behaviour
byte-for-byte against the system bash.

## Tiers

1. **Interpreter** (`interp.lua`) — a tree-walker that starts instantly. It is the
   warm-up tier: code runs here the first time, while the compiled form doesn't exist yet.
2. **Compiled** (`emit.lua` → Lua source → `load()`) — each program becomes a flattened
   control-flow graph dispatched on a program counter (`run(sh, pc)`), so it can be
   entered at any loop head or statement: on-stack replacement at any nesting depth.
   LuaJIT traces the hot pc paths to machine code; variables used only arithmetically
   are lifted to native int64 locals. Generated code calls only `runtime.lua` — nothing
   is handed back to the interpreter (`tools/delegate-census.lua` keeps that at zero).

`tier.lua` orchestrates: run interpreted, and when a loop or function gets hot, compile
and continue in compiled code from exactly where the interpreter was. Code that only
exists at run time — `eval`/`source` text, `$(…)` bodies, trap handlers, hot functions
defined by interpreted code — compiles as a **fragment** once it recurs (cached by text
and by the runtime state it depends on: trap mode, parse options, aliases). A script
whose parsing depends on run-time state (dynamic aliases, history expansion, `set -v`,
`$"…"` translation) runs in **line mode**: each logical line is compiled as it is read.
Compiled modules are cached on disk (`cache.lua`), so a second run starts compiled.

## Deployment

`daemon.lua` is a pool of persistent worker processes behind a Unix socket; the tiny
static client (`daemon/curse-client.c`) forwards argv, environment, cwd and fds and
relays the exit status. Workers keep compiled modules and fragments warm across
requests. `invoke.lua` implements bash's `main()` (options, startup files, script
handling) for both the daemon and the direct runner (`run.lua`). Subshells, pipelines,
command substitutions and background jobs all run **in-process** (checkpoint/restore
isolation, coroutines over real pipes) — only external commands are spawned.

## Modules

| File | Role |
|---|---|
| `parser.lua` | bash grammar → AST (line-group lexer, heredocs, `[[ ]]`, arithmetic) |
| `interp.lua` | tree-walking interpreter; word expansion shared with the runtime |
| `emit.lua` | compiler: AST → pc-dispatch Lua |
| `runtime.lua` | the `Shell` object and everything compiled code calls (`rt.*`) |
| `tier.lua` | tiering, OSR, fragments, line mode |
| `cache.lua` | on-disk compiled-module cache (keyed by content and build stamp) |
| `b_*.lua` | builtins, each loaded on first use |
| `deparse.lua` | `declare -f` / `type` / job-text printing (print_cmd.c) |
| `hist.lua`, `repl.lua` | history and the interactive reader |
| `smatch.lua` | bash's pattern matcher (sm_loop.c) where a regex can't express it |
| `l10n.lua`, `gettext.lua` | translated diagnostics (bash.mo) and `$"…"` strings |
| `mailcheck.lua` | interactive mail checking |
| `invoke.lua`, `run.lua`, `daemon.lua` | startup, direct runner, daemon |
| `build.lua` | bundles the modules into `curse.bc` |

## Running

Build with Meson (see the top-level README), then:

    meson test -C build                         # unit tests + conformance corpora
    test/conformance/run.sh --corpus cases      # one corpus (cases | oil | bash)
    build/luajit tools/delegate-census.lua      # must report 0 interpreter fallbacks
    test/bench/run.sh                           # microbenchmarks vs bash and dash
