# Fuzzing curse with AFL++

    meson compile -C build fuzz          # one campaign (default 30 min), then triage
    FUZZ_SECONDS=3600 meson compile -C build fuzz
    FUZZ_INSTANCES="gram:tiered gram:compiled" meson compile -C build fuzz
    meson compile -C build fuzz-triage   # re-triage the whole persistent queue

`fuzz` is a run target, never part of `meson test`. It needs AFL++ (`afl-cc`,
`afl-fuzz`, `afl-cmin`; Debian: `apt install afl++`) when the build dir is configured;
without it the target only prints how to get it. The differential step needs the bash
5.2.21 oracle (the default `-Dconformance=enabled` build has it).

## What runs

- **Harness** (`harness.c`): one LuaJIT state with the embedded curse bundle; AFL's
  deferred forkserver forks per input and the child runs the script the production way
  (`run` module) in `FUZZ_MODE` `tiered` (default), `interp` or `compiled`. Coverage is
  Lua-level: a line hook turns (engine module, line) pairs into AFL edges (the machine
  code is the same VM loop for every script). Oracle: an escaped Lua error, or a
  Lua-internal message on stderr (`attempt to `, tracebacks, `module:line:`), aborts =
  an AFL crash. Each input runs in `sandbox.h`'s sandbox: read-only mount tree, private
  tmpfs cwd and `$TMPDIR`, empty `PATH` (builtins only), rlimits (5 s CPU, 1 MB files, 2 GB AS), and
  every instance runs inside its own user+pid namespace (`fuzz.sh in_ns`; `afl-fuzz -V`
  ends it on time), so `kill -1`,
  orphaned jobs and stray signals stay inside it.
- **Instances**: at most two (`FUZZ_INSTANCES`, default `gram:tiered byte:tiered`):
  `gram` = the grammar-aware custom mutator below plus AFL's own havoc; `byte` = AFL's
  byte-level mutators only. Both use `sh.dict` and a dictionary extracted from bash's
  sources (`mkdict.sh`: parse.y tokens, builtin names, shopt/set -o names).
- **State** lives in `build/fuzz-work/` and persists: `seeds/` (built once: small cases
  from `test/cases`, the oil spec and bash's `tests/*.sub`, minimised with `afl-cmin`),
  `out/MUTATOR-MODE/` (AFL's queue; the next campaign resumes it), `triage/DATE/`.
  A campaign refuses to start with less than 1 GB free.
- **Triage** (after every campaign, over what it added): each crash input is re-run
  through `harness-plain` and reduced to a signature (`sig.sh`: the escaped error with
  bundle lines mapped to `module:line`); a random sample of `FUZZ_TRIAGE_MAX` (600) new queue
  entries each run through `cmp.sh`: bash 5.2.21 vs curse interp / compiled / tiered /
  the static binary, same sandbox. Signatures are grouped (count + smallest input) and
  bucketed with `known.tsv` (tools/fuzz/findings.md IDs, bash UB, nondeterminism); anything
  unmatched is printed as **NEW**. The summary is `triage/DATE/summary.txt`;
  `buckets.tsv` has every group.

`cmp.sh` masks: the sandbox script path, digit runs of 4+ (pids, `$!`), `time`/`times`
figures, and the order of job-status lines. Inputs using `$RANDOM`, `jobs`, `$!`, `times`
etc. are bucketed as NOISE rather than reported.

## The grammar mutator (`gram_mutator.c` + `gram.lua`)

A C shim (`afl_custom_init/fuzz/fuzz_count/splice_optional/describe`) that pipes each
request to a helper process: `build/luajit gram.lua` with curse's **own** parser and
unparser (`lua/parser.lua`, `lua/deparse.lua`, the `declare -f` printer) loaded. There is
no second shell grammar for reading scripts. The helper only parses; it never runs
anything. A request that doesn't come back within `GRAM_TIMEOUT_MS` (1 s) respawns the
helper and saves the input to `fuzz-work/gram-hangs/`: a parser hang is a finding.

Per call it applies one to four operators (the name chain is AFL's queue-file `op:`);
an input curse's parser rejects gets mostly token-level operators:

- **ast-\***, used when curse's parser accepts the script: swap a command subtree for
  one of the same kind from the splice partner or from the pool of subtrees harvested
  from every queue entry (`ast-splice`, `ast-pool`), replace it with a generated one
  (`ast-gen`), wrap it (`ast-wrap-*`), mutate a word (`ast-word`), or duplicate/drop/move a
  statement (`ast-stmt`). Then the tree is printed back.
- **gen-\***: a statement (or a whole script) from a generator that follows bash
  5.2.21's `parse.y`: simple commands with per-builtin argument shapes, pipelines (`|&`,
  `!`, `time -p`), lists, every compound command (`if`, `while`/`until`, both `for`s,
  `select`, `case` with `;;`/`;&`/`;;&` and extglob patterns, `{ }`, `( )`, `(( ))`,
  `[[ ]]`), functions in all three spellings, `coproc`, redirections (incl. `{var}>`,
  `<<<` and here-documents: `<<-`, quoted delimiters, bodies that nearly match),
  every `${…}` operator, `$(( ))`, `$[ ]`, `$( )`, backquotes, `$'…'`, `$"…"`, process
  substitution, arrays and assoc arrays, brace expansion, tildes, globs. Numbers come
  from a boundary set (2^63-1, -2^63, 2^63, `base#digits`, `64#`, invalid bases, octal).
  Every generated loop terminates.
- **wrap-\*** (the script, a line, or a subtree): in a function, `eval '…'`, a sourced
  file, a trap (EXIT, ERR, RETURN, DEBUG, a signal sent to itself), a subshell, `$( )`,
  a pipeline stage, a background job, a coproc, a loop, and **hot** loops: 101-250
  iterations (the tier compiles a loop at 100), bodies that only run after the switch,
  a hot function, hot loops inside a subshell / `$( )` / a pipeline / a job / `eval`, so
  the compiled tier, OSR and fragment compilation run the code, not just the interpreter.
- **pre**: an option/environment preamble: `set -euo pipefail`, `-x`, `-v`, posix mode,
  `shopt` (extglob, nullglob, failglob, nocasematch, globstar, lastpipe, xpg_echo, compat*,
  …), `IFS` (empty, multichar, whitespace + non-whitespace), `LC_ALL`/`LANG` including
  non-UTF-8 locales (ISO-8859-15, EUC-JP, GBK/GB18030 with ASCII trail bytes),
  `declare` attributes (-i -a -A -n -u -l -r -x), namerefs, aliases, traps.
- **tok-\***, on any text, parseable or not: truncate at a token boundary (EOF inside
  each construct) or at any byte, drop/duplicate/swap closers (`fi done esac } ) ]] ))`,
  quotes, backquotes, here-doc delimiters), reserved words at token boundaries,
  lexical ambiguities (`$((`/`$( (`, `((`/`( (`, `$[`, `;;`/`;&`, `<<`/`<<-`/`<<<`,
  `>&`/`&>`, `[[`/`[`, `=~`, extglob `@(`), `\`-newline at any byte, `#` mid-word vs after a
  blank, here-document quirks (tabs before the delimiter, a here-doc inside `$( )`),
  aliases defined to reserved words/openers ahead of their use, extglob toggled on a
  previous line vs the same line, NUL / invalid UTF-8 / CRLF / lone CR / multibyte
  bytes, numbers swapped for boundary values, words from the pool, token-range splices
  from the partner, and **code as data**: the text inside a quoted `eval`/`trap`/`source`
  string is mutated and re-quoted.

`gram_stats` in each gram instance's queue dir has the operator counts and the parse
validity of a sample of outputs (`valid_frac`). `gram.lua ROOT --classify FILE...` gives
the same figure for any set of files; `--sample N SEED < script` prints mutations.

Env: `GRAM_COUNT` (custom mutations per queue entry, 2048: about half the executions, next to havoc; AFL's havoc still runs, set
`AFL_CUSTOM_MUTATOR_ONLY=1` to turn it off), `GRAM_TIMEOUT_MS`.

## Files

| file | what |
|---|---|
| `meson.build` | the `fuzz-harness` / `gram_mutator` / `fuzz` / `fuzz-triage` targets |
| `fuzz.sh` | campaign, `seeds`, `run NAME SECONDS MUTATOR MODE`, `triage [SINCE-FILE]` |
| `harness.c`, `afl_glue.c`, `sandbox.h`, `build.sh` | the AFL harness (+ `harness-plain`) |
| `sbx.c` | runs bash / the static curse in the same sandbox (triage) |
| `gram_mutator.c`, `gram.lua` | the grammar-aware custom mutator |
| `cmp.sh`, `sig.sh`, `bundle-line.sh` | differential check, crash signature, bundle line map |
| `known.tsv` | known-issue buckets for triage |
| `sh.dict`, `mkdict.sh` | dictionaries |
