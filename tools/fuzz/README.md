# Fuzzing curse with AFL++

    meson compile -C build fuzz          # one campaign (default 30 min), then triage
    FUZZ_SECONDS=3600 meson compile -C build fuzz
    FUZZ_INSTANCES="gram:tiered gram:compiled" meson compile -C build fuzz
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
| `harness.c`, `afl_glue.c`, `sandbox.h`, `build.sh` | the AFL harness (+ `harness-plain`) |
| `sbx.c` | runs bash / the static curse in the same sandbox (triage) |
| `gram_mutator.c`, `gram.lua` | the grammar-aware custom mutator |
| `cmp.sh`, `sig.sh`, `bundle-line.sh` | differential check, crash signature, bundle line map |
| `known.tsv` | known-issue buckets for triage |
| `docker/Dockerfile`, `docker/run.sh`, `docker/seccomp.json` | the `fuzz-docker` container, its limits, the seccomp profile |
| `sh.dict`, `mkdict.sh` | dictionaries |
