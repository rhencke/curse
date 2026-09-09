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
2. **Compiled** (`emit.lua` → Lua source → `load()`) — transpiled Lua that can be
   **entered at any safepoint** via a `goto`-dispatch keyed by a resume
   descriptor. Because scripts often have no functions, the switch must work
   mid-top-level-loop, not just at call boundaries — so a loop's back-edge is a
   resume entry, and it continues off the live induction variable in `sh`.

`tier.lua` orchestrates: interpret; when compiled is ready, the safepoint hook
unwinds and we call `compiled(sh, resume)` — on-stack replacement into compiled
code from exactly where the interpreter was. Proven bit-identical for switches
before / mid / after the loop (`test_tier.lua`).

## Status

Subset so far (the arith-loop spine): scalar assignments, `echo`/`:`/`true`/
`false`, `for (( init; cond; step ))`, `while (( cond ))`, `$(( … ))`, `$var` /
`${var}`, 64-bit int arithmetic (`+ - * / % == != < <= > >= && || ! ++ -- +=`…).

### Done
- **Native-locals emit** — a liftable arithmetic loop compiles to a per-loop
  closure with native int64 locals, seeded from `sh` on entry and written back on
  exit. ~1 ns/iter, ~640× the interpreter, matching the hand-written POC, and OSR
  into it (mid-loop resume seeds the locals from `sh`'s live state) stays
  bit-identical. Non-liftable loops fall back to sh-direct.

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
