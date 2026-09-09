# curse — LuaJIT backend (tiered execution) — WORK IN PROGRESS

A second implementation of curse targeting **LuaJIT**, alongside the reference
TypeScript/Node implementation in `../src` (which stays authoritative for
conformance and is the oracle for parity). Motivation, from the POC
(`../.bench-lua`, gitignored):

- LuaJIT **starts in ~1ms** — faster than bash (2ms), vs Node's ~34ms floor
  (the one axis the TS/Node backend loses to bash on).
- LuaJIT runs a hot arithmetic loop **~2700× faster than bash** and **~33×
  faster than the Node/BigInt AOT**, and **exact 64-bit arithmetic is free**:
  `int64` cdata (FFI) wraps like bash and LuaJIT sinks the boxing in traces, so
  correctness costs nothing (unlike JS `BigInt`).
- Lua strings are byte arrays — exactly bash's storage model (raw-byte fidelity
  that the JS Unicode-string model can't do comes for free).

## Architecture: interpret, then switch (tiered / OSR)

Two tiers share **one `sh` runtime table**, so handoff transfers no state:

1. **Interpreter** (`interp.lua`) — a tree-walker that starts instantly and runs
   statement-by-statement like bash. Bash-competitive (~1.8× faster than bash on
   the arith loop). At every **safepoint** — a top-level statement boundary and
   every loop back-edge — it calls a hook.
2. **Compiled** (`emit.lua` → Lua source → `load()`) — transpiled Lua as a
   **flattened control-flow graph dispatched on a program counter**:
   `run(sh, pc)` seeds lifted vars then `while true do if pc==N then …; pc=M …`.
   Because control flow is flattened, run() can be ENTERED AT ANY pc — the cond
   check of any loop, **at any nesting depth** — and following the pc transitions
   reconstructs the full continuation (inner loop exits → outer step → outer cond
   → …). That is general on-stack replacement; it works mid-loop for loops nested
   in loops and in `if` branches, which scripts-without-functions need. LuaJIT
   traces the hot pc path to machine code with ~zero dispatch overhead (measured
   1.01× native nested `while`). Vars used only arithmetically are lifted to
   native int64 locals, seeded from `sh` on entry / written back on exit.

`tier.lua` orchestrates: interpret; the safepoint hook reports a loop id or a
statement index; on handoff the driver maps it to a pc (`mod.loopPc`/`stmtPc`)
and calls `mod.run(sh, pc)` — OSR into compiled code from exactly where the
interpreter was. Proven bit-identical for switches before / mid / after a
top-level loop (`test_tier.lua`), a nested inner loop (`test_nested.lua`), and a
loop inside an `if`.

## Status

Subset so far: scalar assignments, `echo`/`:`/`true`/`false`, `for ((;;))`,
`while (())`, `for NAME in WORDS`, `if/elif/else/fi` (with `(())` conds),
**functions** (`name(){…}` / `function name`), `return`, `local`, positional
params (`$1..$9`, `$@`, `$*`, `$#`, `$?`), `$(( … ))`, `$var` / `${var}`, 64-bit
int arithmetic. Functions gate OSR: the tier hands off only at top-level
safepoints (calldepth 0), so a hot loop calling a function switches at the loop
(function runs compiled each call); a hot loop inside a once-called function
stays on the interpreter (still faster than bash). Function bodies emit
sh-direct; with functions present the top level is sh-direct too (a lifted
global would go stale inside a function) — refinable.

### Done
- **pc-dispatch CFG + native-locals** — the compiled module is a flattened
  program-counter dispatch (see above) with arithmetic vars lifted to int64
  locals. ~1 ns/iter, ~425× the interpreter, matching the hand-written POC.
  General OSR: resuming mid-loop works at any nesting depth (nested loops, loops
  inside `if`) with bit-identical results.

- **Background compile** — `tier.run_background(script)` spawns a *detached*
  `luajit lua/transpile.lua` that writes `out.lua` (temp + atomic rename); the
  interpreter polls at safepoints and jumps in the instant it lands. On the arith
  bench it interprets ~2048 iterations (~1ms) while transpiling, then switches
  mid-loop and finishes compiled — total ~0.003s vs bash 0.811s (~270×), result
  identical, no functions involved. Demo: `luajit lua/demo_background.lua
  bench/arith.sh` (set `CURSE_LUAJIT` to the luajit binary).

### Next
- Grow the grammar toward the TS parser (functions, `if`, `case`, `for x in`,
  pipelines, redirections, real commands); `for x in LIST` OSR needs the expanded
  list + index persisted in `sh`.
- Wire the shared conformance harness for TS-vs-Lua parity.
- Port the parser to Lua fully (transpile-time startup ~1ms too).

## Running

Needs a `luajit` binary (build: `git clone https://github.com/LuaJIT/LuaJIT &&
cd LuaJIT && make`). Then:

    luajit lua/test_tier.lua
