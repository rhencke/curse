# Stress suite

Repeat-under-load tests for the parts of curse that break under timing: signal
handling, the daemon's concurrency, corpus tests that have flaked before, and
agreement between the execution tiers. It is a **separate** Meson suite: a plain
`meson test` does not run it.

```sh
meson test -C build --suite stress -v          # default settings, ~10-20 minutes
test/stress/run.sh                              # the same, with the knobs:
test/stress/run.sh -n 8 -j 3 -l 2 -d 180        # heavier: 8 iterations, 3 at once, 2 busy loops
test/stress/run.sh sig- daemon-sweep            # only tests whose names contain these
test/stress/run.sh --list                       # every test and what it guards
```

| knob | default | meaning |
|---|---|---|
| `-n N` | 4 | iterations per test (a test may scale it: `#@ iters:`) |
| `-j P` | 2 | iterations run in parallel |
| `-l K` | 1 | artificial load: K busy loops run during each test, killed by PID after it |
| `-d S` | 90 | per-test duration cap: no new iteration starts after S seconds (a test may set its own, `#@ duration:`) |
| `-t X` | 1.0 | scale every per-run timeout |
| `-r DIR` | `build/stress-results/<time>` | results dir |
| `-m LIST` | `interp,compiled,tiered,dcold,dwarm` | the curse shells |
| `--oracle PATH` | `$H_ORACLE`, else the in-tree build: `$STRESS_BUILD/test/oracle/bash`, `build/test/oracle/bash` (then the legacy `…/oracle/bash`) | bash **5.2.21** (any other version is refused) |
| `STRESS_SCRATCH` (env) | `${TMPDIR:-/tmp}` | where the per-run scratch dir (`stress.XXXXXX`: helper binary, shims, daemon socket + cache) is made |

## The shells and the comparison

Every script runs in five curse shells: `interp`, `compiled` and `tiered` (`lua/run.lua`
directly), and `dcold` / `dwarm` (the C client against a private daemon the runner starts:
`dcold` with an empty compile cache, `dwarm` the same script again on that cache).
`$THIS_SH` is curse in the same family (the direct runner, or the client), named `bash`.

Deterministic scripts are compared on stdout + exit status with bash 5.2.21, and the
curse shells with each other. Scenarios whose timing is random (signals from a sender at
random intervals, SIGCHLD storms) are written to check their own properties (a trap ran
at least once and at most once per signal sent, no work was lost, no zombie was left) and
print only verdicts, so they compare the same way. The runner checks that a test's oracle
is deterministic: it runs bash twice up front, and a test whose bash output varies is a
`test-bug` failure.

## Invariants, after every test

- Every shell run gets a session of its own (`sthelp run`); a process still in that
  session after the shell exits (an orphan, a stopped job, a zombie) is a failure, and is
  killed. The daemon's session is scanned the same way: nothing but the daemon and its
  workers may remain.
- No fd >= 3 reaches an external: the scripts call `"$STH" probe`, and after each test
  one probe request is sent to every daemon worker at once.
- The test's `$TMPDIR` is empty.
- The private daemon still answers, and its pool has not shrunk (a dead worker must be
  replaced). It may have grown: the daemon forks an overflow worker whenever a connection
  waits while every worker is busy (a worker draining a finished script's background jobs
  counts as busy; nested curse holds one worker while it needs another). Growth beyond
  JOBS+1 workers is a failure unless the test declares `#@ nested: yes` or
  `#@ concurrent: yes`. After any deviation the runner restarts the daemon, so every test
  starts from the same pool.

Nothing is ever found or killed by name (`pkill -f` / `pgrep -f`): processes are tracked by
session id, and the load loops by PID.

## Failures and results

Each failure is one of: `oracle-mismatch`, `tier-mismatch`, `hang` (a run exceeded its
timeout; its session is killed), `crash` (a fatal signal, a Lua internal error or
traceback, the client's `daemon unavailable`, or a failed daemon request),
`invariant`, or `test-bug` (the oracle itself violated an invariant or varied). The runner
exits non-zero on any failure.

`RESULTS/summary.tsv` has a row per test. `RESULTS/<test>/failures` lists every failure;
`first-<kind>/` (e.g. `first-hang/`, `first-tier-mismatch-<script>/` in a driver) keeps the
first failing iteration of each kind whole: the input script, each shell's
`.out`, `.err`, `.st` (status, time, leftover processes) and `.probe`, the oracle's
output, and `diff.*` files. Tests marked `#@ keep: all` (and the not-yet-root-caused
flakes 1979, 2200 and 1820) keep every failing iteration. Corpus replays through the
conformance harness keep its per-repeat rows and the expected/actual output of every
failing test, with unified diffs.

## Tests

`t/*.sh` are scripts run in every shell (header lines `#@ key: value` set `guards`,
`timeout`, `iters`, `modes`, `oracle` (`varies`/`none`), `cwd`, `keep`, `nested`).
`t/*.drv` are drivers: bash sourced into the runner, with its helpers (`runsh`,
`run_script_test`, `replay_conformance`, `start_daemon`, `fail`, …).

| test | guards |
|---|---|
| `sig-trap-contexts` | INT, TERM, HUP, USR1 and USR2 traps fired while the shell is in `read`, `wait`, a redirection being applied (a blocking FIFO open), `$(…)`, a pipeline stage, a subshell, `eval`, a sourced file, a function and a hot compiled loop. External signals are sent only once the shell sleeps in a syscall (`sthelp sendwhen`), so bash's output is fixed. Guards the preemptive signal delivery (VM hook + EINTR) and the in-process subshells. |
| `sig-open-eintr` | A trapped signal interrupting the FIFO open of `$(< f)` or `source f` fails it ("Interrupted system call", status 1) with the trap running after the diagnostic, while a redirection's open is retried after the trap — plain, in `eval`, a function and a sourced file. Guards the async FIFO open's no-retry wait (lib_cursesig.c curse_aopen, rt.open_read). |
| `sig-pseudo-traps` | EXIT, ERR, DEBUG and RETURN traps in the same contexts (compiled-tier DEBUG/RETURN, in-process subshell trap save and restore). |
| `sig-self-kill` | `kill -SIG $$` from inside pipeline stages, subshells, `$(…)` and background jobs: bash runs the parent's trap exactly once, in the parent's context. Also an external signalling a subshell by `$BASHPID`, and no zombie after a trap interrupts the wait for a `$(…)` child. |
| `sig-reentrancy` | Traps that signal themselves or each other (bash runs the new trap nested, at the next command inside the handler), and a trap reset, ignored or replaced while its signal is pending. |
| `sig-chld-wait` | SIGCHLD storms with a CHLD trap; `wait`, `wait PID`, `wait %job` and `wait -n` interrupted by a trap (128+sig, the job still collectable); `read -t` timeouts and partial input. |
| `sig-jobctl` | `set -m` job control: STOP/CONT, `bg`, `fg`, `jobs -s`/`-r`, waiting on a stopped job, jobs left stopped when a shell exits (b491008, 512b4fd, case 2200), and whether `$!` is a real pid. |
| `sig-hammer` | A detached sender hammers `$$` with USR1, USR2 and HUP at random intervals while the shell runs externals, `$(…)`, pipelines, redirections, file reads, `wait` and hot loops. No syscall error may surface (EINTR), no work may be lost, each trap runs between 1 and N times for N signals, and no zombie is left. |
| `sig-preempt` | Asynchronous preemption of JIT loops that never reach a safepoint (the destructive back-edge patch, 4338191): several loop shapes, a loop interrupted many times keeping its count, `exit`/`break`/`return` decided in a trap. |
| `sig-status` | 128+sig statuses of shells killed by signals, EXIT traps before a trapped signal's exit, a blocked shell killed from outside, and PIPESTATUS of signal-killed stages. Nested shells go through `$THIS_SH`, so the daemon's 0x10000 relay is exercised. |
| `bg-start` | A background job starts when `&` runs: a script that busy-waits with builtins only for its effect must see it. |
| `daemon-sweep-race` | The dead-client-sweep race fixed in 207fd83: 12 parallel loops × 250·N `-c 'echo hi'` requests against a 2-worker daemon (before the fix, 8 of 72,000 failed with 127 and no output). |
| `daemon-client-kill` | Clients killed (KILL, TERM, INT, HUP) mid-request while their script runs externals, floods output, blocks in `read`, spins, has background or stopped jobs. The pool must recover, nothing of the abandoned scripts may remain, and the next requests must be served correctly. |
| `daemon-cache-race` | Three daemons sharing one `XDG_CACHE_HOME`, racing cold (empty cache) and warm on the same scripts. Every run must match bash. |
| `daemon-locale-alt` | The multibyte-lexing cache-key fix (207fd83; case 2290 guards it too): the same text in `LC_ALL=C` and `zh_CN.gbk` (trail byte 0x5c), alternating in parallel, as files and as `-c`. |
| `flakes-cases` | Cases 2290, 220, 1979, 2200, 1820, 2350, 1978, 2380 and 2190, repeated in every shell against bash, then through `test/conformance/run.sh`. |
| `flakes-bash` | bash's glob, trap, posixexp, ifs-posix, iquote, new-exp and comsub-posix in the direct shells, then those plus jobs.tests through `test/conformance/run.sh`. |
| `flakes-oil` | Oils background #8, #13 and #18 and shell-grammar #4 in every shell (full diffs kept), and background, builtin-set, builtin-echo, builtin-getopts and shell-grammar through `test/conformance/run.sh`. |
| `tier-agreement` | Random corpus scripts, possibly mutated (wrapped in a function, a subshell, `$(…)`, `eval`, or run 120 times so tiered switches mid-run), must agree across all five shells. The seed is logged (`STRESS_SEED=` reruns it). |

The corpus replays call `test/conformance/run.sh` through its command line only (name
filters and a repeat loop), with bash 5.2.21 first in `PATH` as its oracle.

## sthelp

[`sthelp.c`](sthelp.c) is built by the runner. It handles the process plumbing:
session-isolated runs with timeouts and leftover detection (`run`), detached daemons
(`spawn`), session scans (`scan`, `children`, `killsid`), the fd probe (`probe`),
signal senders (`hammer`, which can detach; `sendwhen`, which waits until the target
sleeps in a syscall) and the load loop (`busy`).
