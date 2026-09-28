# Fuzzing curse with AFL++

    meson compile -C build fuzz          # one campaign (default 30 min), then triage
    FUZZ_SECONDS=3600 meson compile -C build fuzz
    FUZZ_INSTANCES="gram:tiered gram:compiled" meson compile -C build fuzz
    FUZZ_INSTANCES="gram:tiers" meson compile -C build fuzz      # the in-loop tier oracle
    FUZZ_INSTANCES="gram:arith byte:pexp" meson compile -C build fuzz   # targeted fuzzers
    meson compile -C build fuzz-triage   # re-triage the whole persistent queue
    meson compile -C build fuzz-docker   # the same campaign in a hardened container

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
  tmpfs cwd and `$TMPDIR`, empty `PATH` (builtins only), rlimits (5 s CPU, 1 MB files, 2 GB AS,
  256 processes), and every instance runs inside its own user+pid namespace (`fuzz.sh
  in_ns`; `afl-fuzz -V` ends it on time), so `kill -1`, orphaned jobs and stray signals
  stay inside it. Each exec's script also gets a pid namespace of its own (a tiny init as
  pid 1, the script as pid 2, so `kill $$` still works): whatever it leaves running -- a
  `/bin/sh` fork bomb, a job ignoring signals -- dies with the exec instead of starving the
  next one (about 0.25 ms per exec; `FUZZ_NO_EXEC_NS=1` turns it off).
- **Instances**: at most two (`FUZZ_INSTANCES`, default `gram:tiered byte:tiered`), each
  `MUTATOR:MODE`. `gram` = the grammar-aware custom mutator below plus AFL's own havoc;
  `byte` = AFL's byte-level mutators only. MODE is a tier (`tiered` `interp` `compiled`:
  scripts, the Lua-internal oracle above), `tiers` (scripts, the tier oracle below), or a
  targeted fuzzer (`arith` `pexp` `printf` `glob` `read` `regex` `parse` `deparse`, below).
  Script modes use `sh.dict` and a dictionary extracted from bash's sources (`mkdict.sh`:
  parse.y tokens, builtin names, shopt/set -o names); a targeted fuzzer uses
  `dicts/MODE.dict`.
- **State** lives in `build/fuzz-work/` and persists: `seeds/` (built once: small cases
  from `test/cases`, the oil spec and bash's `tests/*.sub`, minimised with `afl-cmin`),
  `out/MUTATOR-MODE/` (AFL's queue; the next campaign resumes it), `triage/DATE/`.
  A campaign refuses to start with less than 1 GB free.
  (A targeted fuzzer's queue is in its own language: triage signs its crashes but runs
  no `cmp.sh` over its queue -- the loop already compared every input with bash.)
- **Triage** (after every campaign, over what it added): each crash input is re-run
  through `harness-plain` and reduced to a signature (`sig.sh`: the escaped error with
  bundle lines mapped to `module:line`); a random sample of `FUZZ_TRIAGE_MAX` (600) new queue
  entries each run through `cmp.sh`: bash 5.2.21 vs curse interp / compiled / tiered /
  the static binary, same sandbox. Signatures are grouped (count + smallest input) and
  bucketed with `known.tsv` (tools/fuzz/findings.md IDs, bash UB, nondeterminism); anything
  unmatched is printed as **NEW**. The summary is `triage/DATE/summary.txt`;
  `buckets.tsv` has every group.

`cmp.sh` masks: the sandbox script path, digit runs of 4+ (pids, `$!`), coproc pids,
`time`/`times` figures, and the order of job-status lines. A disagreement where every run
has bash's status and lines in another order is signed `order-only:` (known.tsv buckets it
as NOISE when the script has an async construct). Inputs using `$RANDOM`, `jobs`, `$!`, `times`
etc. are bucketed as NOISE rather than reported.

## In-loop oracles

The Lua-internal oracle only sees curse break its own rules. Two more oracles run inside
the fuzz loop, so AFL's coverage feedback steers toward *disagreements*, not just crashes;
each aborts with a report on stderr and a map slot of its own per disagreement kind (AFL
keeps one crash per kind instead of deduplicating them into the first), and `sig.sh`
folds the report into a signature (`tiers:compiled:out|< …|> …`,
`target:arith:output|< bash line|> curse line`).

### The tier oracle (`MODE` `tiers`, harness `FUZZ_ORACLE=tiers`)

Each input runs in three workers -- interp, compiled, tiered -- and their stdout, stderr
and status must agree after `cmp.sh`'s masks (digit runs of 4+, `time` figures, job
lines as a sorted set). The tiered worker runs with `CURSE_HOT_LOOP=FUZZ_TIER_HOT` (3),
so the interpreter-to-compiled switch (OSR, hot functions, fragments) happens on the
small inputs a fuzzer makes, not only on 100-pass loops. Inputs matching a known.tsv
`NOISE src` rule (`$RANDOM`, `jobs`, `$!`, …) are only run, not compared. No bash in the
loop: every tier must equal the interpreter (bash is compared later by triage's `cmp.sh`).
Cost: three runs per input (host, per exec: 2.5 ms plain, 9.1 ms with the tier oracle).

### Targeted in-process fuzzers (`MODE` = a target, harness `FUZZ_TARGET=NAME`)

A small input language per subsystem, run by curse IN the fuzz process and by a
persistent bash 5.2.21 over a pipe, compared byte for byte (merged stdout+stderr, and the
status). No shell or process startup per input: curse's shell is set up once before the
forkserver starts (all modules loaded, a shared prelude of variables run), and
`harness-target` is the harness in AFL++ persistent mode -- one forkserver child runs
`FUZZ_TLOOP` (1000) inputs, each inside curse's own `( … )`, which is what keeps one
input's shell state from the next. (A fork per input costs more than the input: the
child faults in every heap page it touches. A crash is re-run by triage in
`harness-plain`, one fork per input; one that doesn't reproduce there needed the loop's
history -- a state leak across curse's `( )`, itself a bug.)

| target | input (`targets.lua` has the exact formats) | what runs, both sides |
|---|---|---|
| `arith` | an expression (data), or `=EXPR` | `echo "$(( $__e ))"` / `x=$__e; $(( x ))`, then `declare -p` of the variables |
| `pexp` | the words of one command: `${…}` operators, quoting, arrays, substrings, `@Q/@E/@A/@K`… | `__w WORDS` (each field as `<…>`), then `declare -p` |
| `printf` | line 1 a format, then one argument per line (data) | `printf -- "$f" args…` and `printf -v` |
| `glob` | line 1 a pattern, line 2 a string (data) | `[[ == ]]`, `case`, `# ## % %% / // /# /%` with `&` |
| `read` | line 1 `U` / `=IFS`, line 2 options (`-r -s -a -d C -n N -N N`), then the data | `read` from a here-string, and unquoted/quoted field splitting |
| `regex` | line 1 `v RE` (data) or `l RHS` (literal shell text after `=~`), line 2 a string | `[[ $s =~ … ]]`, status, `BASH_REMATCH` |
| `parse` | a script | `( eval $'set -n\n'"$q" )`: syntax OK/error, message, line; nothing runs |
| `deparse` | a script | as `parse`, then (when it parses) `declare -f` of it as a function body |

Any input may start with a line `#@ extglob nocasematch utf8 posix …` (options set first).
Inputs outside a target's language are skipped (not compared): see "sandbox" below. The
`gram` mutator has a small generator per language (`GRAM_TARGET`; `parse`/`deparse` get
the script mutator); seeds are `seeds/TARGET/` (hand-written), or the script seeds.

**The bash side** (`bashco.h`): a broker process, forked before the forkserver, owns ONE
bash per instance and restarts it when it dies, hangs (`FUZZ_BASH_TMOUT_MS`, 1000 per
request) or floods (1 MB). Children talk to it over a SEQPACKET socket; replies carry the
request id, so a child AFL killed mid-request leaves a stale reply the next child
discards. Each request runs as `( eval "$__q" ) </dev/null 2>&1` in the driver file (the
same file name on both sides: error prefixes and line numbers match), ending with a
sentinel carrying a random per-instance nonce that exists only in the driver's text.
Kept deterministic and side-effect free by: a fresh subshell per request; a fixed
environment (`PATH` an empty dir, `LC_ALL=C`, `TZ=UTC`, `HOME=`); inputs that name
`$RANDOM`, `$$`, `BASHPID`, `SECONDS`, `PPID`, `$_`, `LINENO`, the shells' own variables
(`${!B*}`, `$BASH…`), or `%(…)T` without explicit times are skipped (`targets.lua` NOISE).

**Sandbox** for the bash side, on top of the harness's (read-only mount tree, private
tmpfs, rlimits; the harness now also has its own network namespace): bash is pid 1 of
its own pid and network namespaces (afl-fuzz and the fuzz child are invisible to it; no
`/dev/tcp`); the driver's prelude disables `kill exec ulimit suspend wait fg bg disown
enable` and turns on restricted mode (`set -r`: no output redirection, `cd`, `PATH`
changes, command names with `/`); data reaches it only as `$'\xHH'` words, and the two
code-shaped languages (`pexp`, `regex l`) are refused unless curse's parser reads them as
exactly one `__w …` / `[[ … ]]` command with no redirection, and no `$(`, backquote, `<(`
or `>(` appears anywhere in the text.

Exec rates (host, one input repeated, coverage hook on; `FUZZ_BENCH=N
[FUZZ_BENCH_PERSIST=1]`): persistent 1.1-1.7 ms/exec (arith 0.9, pexp 1.2, printf 1.1,
glob 1.3, read 1.7, regex 1.1, parse 1.9 ms); a fork per input 2.4-4.5 ms. bash's side is
most of it: its `( … )` fork alone is ~0.45 ms on this host.

### Checking an oracle (planted bugs)

`FUZZ_OVERRIDE=module=FILE,…` loads engine modules from source files instead of the
embedded bundle, so a deliberately broken copy can be checked without rebuilding:

    cp lua/interp.lua /tmp/i.lua   # then break `<<` in it: % 64 -> % 63
    printf '1<<63' | unshare -Ur env FUZZ_SBX=$PWD/sbx FUZZ_TARGET=arith \
      FUZZ_TARGETS_LUA=tools/fuzz/targets.lua FUZZ_BASH=build/test/oracle/bash \
      FUZZ_OVERRIDE=interp=/tmp/i.lua build/tools/fuzz/harness-plain    # -> abort, the diff

## Docker (`fuzz-docker`): one contained, globally budgeted campaign

    meson compile -C build fuzz-docker
    FUZZ_DOCKER_OUT=~/fuzz-out FUZZ_SECONDS=3600 FUZZ_INSTANCES="gram:tiered gram:compiled" \
      meson compile -C build fuzz-docker
    tools/fuzz/docker/run.sh exec CMD...   # any command in the same container (probes)

`docker/run.sh` builds `curse-fuzz:latest` (`docker/Dockerfile`: Debian trixie by digest,
AFL++ 4.21c from apt, the same release as the host so the meson-built harness, luajit,
curse and bash oracle run unchanged) and runs `fuzz.sh campaign` (or `triage`, `seeds`)
inside it. `FUZZ_SECONDS`, `FUZZ_INSTANCES`, `FUZZ_JOBS`, `FUZZ_TRIAGE_MAX`, `GRAM_*`
pass through. State (seeds, queues, triage) is `FUZZ_DOCKER_OUT` (default `FUZZ_WORK`,
`build/fuzz-work`), mounted at `/fuzz-work`: the next run resumes its queues.

**One budget for the whole host.** All instances of a campaign share one container; the
container name is fixed (`curse-fuzz`) and `run.sh` takes `flock -n` on
`FUZZ_DOCKER_OUT/.lock`: a second `fuzz-docker` (same or another output dir, another
agent) is refused with a message, never queued or started alongside.

| limit | why |
|---|---|
| `--cpus 2` (cgroup `cpu.max 200000 100000`) | the host always keeps 2 of its 4 cores |
| `--cpu-shares 128` (`cpu.weight` 5) | yields to other containers/services even inside the cap (the user and system slices still split an overcommitted host evenly: the cap is what guarantees the 2 cores); `AFL_NO_AFFINITY=1`, no core pinning |
| `--memory 4g --memory-swap 4g` | no swap; an OOM stays inside the container's cgroup |
| `--pids-limit 2048` | fork bombs (the effective process cap; `--ulimit nproc=8192` is per host uid, so only a backstop) |
| `--ulimit nofile=4096 fsize=1G core=0` | fd exhaustion, one runaway file, core dumps |
| `--read-only`, `--tmpfs /tmp:size=256m`, `--network none` | the only writable host path is `FUZZ_DOCKER_OUT`; the repo and the build are mounted read-only |
| `--user UID:GID --cap-drop ALL --security-opt no-new-privileges` | no capability is added back: none is needed (below) |
| `--security-opt seccomp=docker/seccomp.json` | Docker 26.1.5's default profile plus one rule, below |
| host `timeout` + `--stop-timeout 30` + `--init` | `FUZZ_SECONDS` + 300 s + `FUZZ_DOCKER_SLACK` (3600: seeds, triage); a container still there afterwards is killed by its name |
| in-container watchdog | the container ends if `/fuzz-work` exceeds 3 GB (`FUZZ_DOCKER_MAXKB`); `fuzz.sh`'s 1 GB free-space check stays |

**The per-exec sandbox still applies inside.** A fuzzed script must not be able to touch
AFL's queue either, so `sandbox.h` (read-only mount tree, private tmpfs) and `fuzz.sh
in_ns` (user+pid namespace: `kill -1`, orphans) keep working in the container. They need
`unshare`, `mount` and `mount_setattr`, which Docker's default seccomp profile allows only
with `CAP_SYS_ADMIN`; `seccomp.json` allows those three syscalls without it. That grants
nothing by itself: the kernel still requires `CAP_SYS_ADMIN` in the user namespace that
owns the target, which the (capability-less, non-root) container user only has in the
namespaces it creates itself, so it can only mount inside its own fresh mount namespace.
AppArmor stays `docker-default`. The container runs as the host user, not root: mapping
uid 0 into a new user namespace would need `CAP_SETFCAP`. Two things differ from the
host: `in_ns` gets no private `/proc` (`FUZZ_NS_PROC=0`: Docker over-mounts parts of
`/proc` and the kernel refuses a fresh proc mount in a user namespace while anything in it
is hidden; the pid namespace, which is what contains `kill -1`, doesn't need it), and
triage (`cmp.sh`, `sig.sh`) runs each shell in its own user+pid namespace too, on the host
as well: the bash oracle's real `kill -9 -1` otherwise reaches every process of the user.

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
| `harness.c`, `afl_glue.c`, `sandbox.h`, `build.sh` | the AFL harness (+ `harness-target`, persistent; `harness-plain`) |
| `targets.lua`, `bashco.h` | the targeted fuzzers: input languages -> snippets, the persistent bash |
| `seeds/TARGET/`, `dicts/TARGET.dict` | their hand-written seeds and dictionaries |
| `sbx.c` | runs bash / the static curse in the same sandbox (triage) |
| `gram_mutator.c`, `gram.lua` | the grammar-aware custom mutator |
| `cmp.sh`, `sig.sh`, `bundle-line.sh` | differential check, crash signature, bundle line map |
| `known.tsv` | known-issue buckets for triage (its `NOISE src` rules also gate the tier oracle) |
| `docker/Dockerfile`, `docker/run.sh`, `docker/seccomp.json` | the `fuzz-docker` container, its limits, the seccomp profile |
| `sh.dict`, `mkdict.sh` | dictionaries |
