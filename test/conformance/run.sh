#!/usr/bin/env bash
# Conformance harness. Runs each test under bash (the oracle), dash, and curse via
# its resident daemon (cursed: a warm worker + content-hashed compile cache —
# curse's real production path), scoring each shell's agreement with bash on
# stdout + exit status.
#
# Corpora (any present are run; pick with --corpus):
#   cases  test/cases/*.sh              curse's own hand-written conformance scripts
#   bash   subprojects/bash-*/tests/*.tests GNU bash's suite    (Meson subproject)
#   oil    subprojects/oil/spec/*.test.sh   Oils spec cases that target bash
#                                            (Meson subproject)
#
# STDERR is compared too, for the cases corpus (curse's own scripts; --stderr CORPORA or
# H_STDERR picks others, --stderr none turns it off): after the shell's stdout and status
# match bash's, its stderr must match bash's once both are normalised — the script path
# and $0, THIS_SH, the unit's cwd/TMPDIR, mktemp names and `time` figures. Numbers that
# vary between runs (pids — curse's synthetic ones ≥4194305 included —, times) are matched
# as for stdout: bash is rerun, and a line bash itself varies on matches with its digit runs
# masked. A difference is a FAIL with reason `stderr`. dash's stderr is never compared (its
# wording is not bash's), and dash is scored only where it supports the test: a dash parse
# error (status 2) where bash parsed fine counts N/A, not fail.
#
# KNOWN DIFFERENCES: test/conformance/known-diffs lists, one per line with its reason (for a
# real curse bug, the queue entry that tracks it), `CORPUS TESTID stderr` (that test's
# stderr differs: not compared as a failure) or `CORPUS TESTID SHELL` (that shell's FAIL is
# scored KNOWN). The list is a ratchet: an entry that no longer differs is STALE, which
# fails the run until it is removed.
#
# EXIT STATUS: 1 when any curse run FAILs (output, status, stderr or timeout), or when the
# ORACLE timed out on a `cases` test (curse's own case with no oracle to score it is a
# broken case, not a pass); otherwise 0. (An oracle timeout in the bash/oil suites is
# reported, not failed: those tests are upstream's.) Setup errors (no oracle, …) exit 2.
#
# The harness starts a PRIVATE cursed (its own $XDG_RUNTIME_DIR socket + a persistent
# $XDG_CACHE_HOME) and runs curse through the C client, scored as two shells: curse-cold
# (an empty per-test compile cache: interpret, OSR, store the .bc) then curse-hot (the
# same test again, loading that .bc) — curse's real amortized path, not cold start.
#
# PARALLELISM — bounded on purpose. Each test runs its shells SEQUENTIALLY; only
# --jobs test units run at once (default: min(nproc/2, 4)); the daemon's worker pool
# is capped to match (CURSE_WORKERS). Override: --jobs N / JOBS=N.
#
# TIME LIMITS — a guard against hangs, never what a test is scored on: --timeout (10s),
# raised per test by test/conformance/timeouts (tests that need longer even alone) and
# scaled by the current load. A run is TIMED OUT when it exits 124 having used the whole
# limit (a script's own `exit 124` returns sooner). A timed-out ORACLE scores the test
# OTIMEOUT for every shell — neither pass nor fail, the shells aren't run — counted as
# "(oracle N, M t/o)" and listed under ORACLE TIMED OUT; a timed-out shell is a FAIL with
# reason `timeout`, apart from `output`/`status` diffs, in the scoreboard, -v, --results
# and H_DIFF_DIR; a timed-out bash RERUN is discarded, never taken as a bash output.
#
# The scoreboard reports a per-shell success rate AND summed per-run wall time
# (bash vs dash vs curse). Under --jobs>1 absolute times inflate from CPU contention
# — the shell-to-shell ratios stay fair; use --jobs 1 for clean numbers.
#
# Usage:
#   test/conformance/run.sh [--corpus cases|bash|oil|all] [--jobs N] [--timeout S]
#                           [--shells a,b,c] [--results FILE] [--oracle BASH] [--stderr CORPORA|none]
#                           [-v|--verbose] [FILTER...]
#   --shells: from dash, curse-cold, curse-hot (the daemon, cold then warm cache) and
#   curse-interp (lua/run.lua SCRIPT interp: the tree-walking interpreter alone, no OSR —
#   what OSR would otherwise hide from curse-cold).
#   --oracle / H_ORACLE: the oracle bash; default build/test/oracle/bash (meson builds it
#   from the vendored 5.2.21). Its $BASH_VERSION must be 5.2.21(…), or nothing runs.
#   FILTER: substrings; only test files whose name matches one are run.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# ---- internal worker: run ONE unit (all shells) and write its result rows ----
if [ "${1:-}" = --run-unit ]; then
  workdir="$2"; id="$3"
  IFS=$'\t' read -r corpus testid script srcdir < "$workdir/units/$id"
  cwd="$workdir/cwd/$id"; res="$workdir/res/$id.tsv"; : > "$res"

  # TMPDIR is the unit's own directory too (beside its cwd, not in it: a glob or `ls` of the
  # cwd must not see temp files). Tests create temp files and dirs — `mktemp -d`,
  # ${TMPDIR:-/tmp}/c$$ — and a test killed by the time limit, or one that simply never
  # removes them, left them in the real /tmp: three shell runs per test, every corpus run
  # (thousands of tmp.* dirs had piled up). prep() wipes it per run; the workdir cleanup
  # removes it with the rest.
  tmpd="$workdir/tmp/$id"
  prep() {  # (re)create an isolated cwd (and TMPDIR) for one shell run
    rm -rf "$cwd" "$tmpd"; mkdir -p "$cwd" "$tmpd"
    if [ "$srcdir" != - ]; then cp -a "$srcdir/." "$cwd/"; runscript="$cwd/$(basename "$script")";
    else runscript="$script"; fi
  }
  one() {  # $1 shell -> prints stdout, returns status (124: killed by the time limit)
    local sh="$1"
    case "$sh" in
      # stdin < /dev/null so a `read`/`select` with no input gets EOF instead of
      # blocking (which, in the daemon, would hang a persistent worker until timeout).
      # THIS_SH is the shell's full path, as bash's own suite runs it: tests copy it
      # (`cp ${THIS_SH} $TMPDIR/sh`) and write it into `#!${THIS_SH}` lines, which a bare
      # name can't satisfy — the oracle would fail those checks by itself.
      # (every shell gets the SAME environment as curse's run below — XDG_*, CURSE_FALLBACK
      # — or a test that lists it, `env | grep HOME`, would differ by the harness alone)
      # TMP and HOME point into the unit's own cwd, as oil's spec runner provides $TMP:
      # tests that `cd $TMP` or `cd ~` then create and delete files would otherwise
      # race each other (and every shell) in the real home directory.
      # PATH starts with the ORACLE's directory (it holds only `bash`) for every shell:
      # a test that runs `bash` by name gets the pinned 5.2.21 oracle, never the host's.
      bash)  ( cd "$cwd" && PATH="$H_ORACLE_DIR:$PATH" TMP="$cwd" HOME="$cwd" TMPDIR="$tmpd" XDG_RUNTIME_DIR="$H_XDG_RUNTIME" XDG_CACHE_HOME="$ucache" CURSE_FALLBACK="$H_FALLBACK" \
                 THIS_SH="$H_ORACLE" timeout "$lim" "$H_ORACLE" "$runscript" </dev/null ) ;;
      dash)  ( cd "$cwd" && PATH="$H_ORACLE_DIR:$PATH" TMP="$cwd" HOME="$cwd" TMPDIR="$tmpd" XDG_RUNTIME_DIR="$H_XDG_RUNTIME" XDG_CACHE_HOME="$ucache" CURSE_FALLBACK="$H_FALLBACK" \
                 THIS_SH="$(command -v dash)" timeout "$lim" dash "$runscript" </dev/null ) ;;
      # curse via the resident daemon: the C client hands the script to cursed, which
      # tiers on a cache miss (interp -> OSR + store .bc) or loads the .bc on a hit.
      # THIS_SH=client so bash-suite self-reinvokes hit the daemon too; fallback fails
      # loudly so a dropped daemon can't masquerade as dash. The daemon reads the
      # CLIENT's env per request, so $ucache (per-unit) selects the compile cache:
      # first curse run misses (cold), second hits (hot).
      curse) ( cd "$cwd" && PATH="$H_ORACLE_DIR:$PATH" TMP="$cwd" HOME="$cwd" TMPDIR="$tmpd" XDG_RUNTIME_DIR="$H_XDG_RUNTIME" XDG_CACHE_HOME="$ucache" \
                 CURSE_FALLBACK="$H_FALLBACK" THIS_SH="$H_THIS_SH" \
                 timeout "$lim" "$H_CLIENT" "$runscript" </dev/null ) ;;
      # curse's interpreter alone (no daemon, no OSR), from the built bundle; a script that
      # runs $THIS_SH gets curse run directly too (the static build/curse, tiered), not the daemon
      curse-interp) ( cd "$cwd" && PATH="$H_ORACLE_DIR:$PATH" TMP="$cwd" HOME="$cwd" TMPDIR="$tmpd" XDG_RUNTIME_DIR="$H_XDG_RUNTIME" XDG_CACHE_HOME="$ucache" \
                 CURSE_FALLBACK="$H_FALLBACK" THIS_SH="$H_THIS_SH_DIRECT" CURSE_BUNDLE="$H_BUNDLE" \
                 timeout "$lim" "$H_LUAJIT" "$H_REPO_LUA/run.lua" "$runscript" interp </dev/null ) ;;
    esac
  }

  # microseconds since epoch, no fork (EPOCHREALTIME, bash 5+); date fallback.
  now_us() { local t=${EPOCHREALTIME:-}; if [ -n "$t" ]; then t=${t/,/.}; echo $(( ${t%.*} * 1000000 + 10#${t#*.} )); else date +%s%6N; fi; }
  # This unit's time limit: the --timeout (default 10s), or the test's own entry in
  # test/conformance/timeouts when that's longer — tests that SLEEP for most of their
  # run (bash's jobs.tests: ~62s) can't finish in the default no matter how fast the
  # shell is. The same limit applies to the oracle and every shell.
  lim=$H_TIMEOUT
  if [ -n "${H_TIMEOUTS:-}" ] && [ -f "$H_TIMEOUTS" ]; then
    t=$(awk -v c="$corpus" -v t="$testid" '$1==c && $2==t {print $3; exit}' "$H_TIMEOUTS")
    [ -n "$t" ] && [ "$t" -gt "$lim" ] && lim=$t
  fi
  # ...scaled by how oversubscribed the machine is right now: under N runnable tasks per
  # CPU a CPU-bound test takes ~N times as long (bash's ifs-posix.tests: 3.3s alone, >10s
  # beside two more suites and four busy loops on 4 CPUs — the ORACLE timed out). The
  # limit is only a guard against hangs; what a test is scored on is its output and
  # status, and a run that does hit the limit is reported as a timeout, never as a diff.
  # (1-minute load average / CPUs, rounded up, capped at 4x; H_NPROC set by the driver)
  if [ -r /proc/loadavg ] && [ "${H_NPROC:-0}" -gt 0 ]; then
    read -r l1 _ < /proc/loadavg; l1=${l1%.*}
    f=$(( (l1 + H_NPROC - 1) / H_NPROC )); [ "$f" -lt 1 ] && f=1; [ "$f" -gt 4 ] && f=4
    lim=$(( lim * f ))
  fi
  # run_shell SH: one run of SH in a fresh cwd. Sets R_OUT, R_ST, R_DUR (us) and R_TO
  # (1 when the time limit killed it). Capture stdout to a FILE, not "$(...)": command
  # substitution waits for EOF from EVERY holder of the pipe, so a lingering child (a
  # curse daemon worker's forked subshell, a bash `sleep 5 &`) would hang the read.
  # EVERY run gets its OWN capture file: a process outliving its run — a background job,
  # or the daemon worker of a curse client that `timeout` killed (it runs on until the
  # daemon's dead-client sweep kills it) — keeps its fd on that file, and with one reused
  # path (`>` truncates the same inode) whatever it still wrote would land in the NEXT
  # shell's output.
  # quiesce FILE: after a run the time limit KILLED, stop what it left running. timeout(1)
  # kills only the process it started — bash's background children live on, and for curse
  # the daemon worker serving the killed client runs on until the daemon's dead-client
  # sweep (≤1s) kills it, its own children after it. The next shell's run reuses this
  # unit's cwd and TMPDIR PATHS (the same paths for every shell, as tests may print them),
  # so a leftover writing there would corrupt that run. Everything whose cwd is inside
  # this unit's private dirs, or that still holds its capture file open, belongs to this
  # run: kill it, and repeat until nothing is left (bounded: 5 rounds).
  quiesce() {
    local k p c fd pids
    for k in 1 2 3 4 5; do
      pids=()
      for p in /proc/[0-9]*; do
        p=${p#/proc/}; [ "$p" = "$$" ] || [ "$p" = "$BASHPID" ] && continue
        c=$(readlink "/proc/$p/cwd" 2>/dev/null) || continue
        case "$c" in "$cwd"|"$cwd"/*|"$tmpd"|"$tmpd"/*) pids+=("$p"); continue ;; esac
        for fd in /proc/$p/fd/*; do
          [ "$(readlink "$fd" 2>/dev/null)" = "$1" ] && { pids+=("$p"); break; }
        done
      done
      [ ${#pids[@]} -eq 0 ] && return 0
      kill -9 "${pids[@]}" 2>/dev/null; sleep 0.1
    done
  }
  nrun=0
  run_shell() {
    nrun=$((nrun + 1)); local f="$ofile.$nrun" s
    # (9>&-: the shared-paths lock below is the harness's, not the test's)
    prep; s=$(now_us); one "$1" >"$f" 2>"$f.err" 9>&-; R_ST=$?; R_DUR=$(( $(now_us) - s ))
    # (stop the clock BEFORE reading the output: that cat is a fork+exec, and the
    # oracle's time excludes it)
    { R_OUT=$(cat "$f" 2>/dev/null); } 2>/dev/null  # (bash drops a NUL byte: quietly)
    # (a NUL byte is kept, spelled \0: $(…) would drop it, with a warning on OUR stderr)
    R_ERR=""; [ -n "$cmp_err" ] && R_ERR=$(sed "${norm_sed[@]}" "$f.err" 2>/dev/null | sed "s/\x0/\\\\0/g")
    # timeout(1) exits 124 when it killed the command; a script exiting 124 by itself
    # before the limit is not a timeout
    R_TO=0; [ "$R_ST" -eq 124 ] && [ "$R_DUR" -ge $(( lim * 1000000 )) ] && { R_TO=1; quiesce "$f"; }
  }
  ofile="$workdir/o.$id"
  ucache="$workdir/uc/$id"; mkdir -p "$ucache"   # per-unit compile cache: cold miss, then hot hit
  # A NONDETERMINISTIC oracle: some tests print a value that differs between any two bash
  # runs — $RANDOM (seeded from time ^ pid ^ ppid: lib/sh/random.c genseed) or $PPID (the
  # pid of the fresh `timeout` each run gets) — so no second run, bash's included, can
  # reproduce the first byte-for-byte. Only when a shell MISMATCHES, re-run bash (up to
  # 3x); if bash's own output varied, the lines both bash runs agree on must still match
  # exactly, and a varying line matches when it's equal with every digit run masked — or
  # the shell's output equals one of bash's own runs verbatim (a race in bash itself).
  # (A rerun the time limit killed is no evidence of anything: it is ignored.)
  bchecked=""; b2out=""; b2st=""
  oracle_varies() {
    if [ -z "$bchecked" ]; then
      bchecked=1; local k
      for k in 0 1 2; do
        run_shell bash
        # (bash_produces reuses these reruns: a slow test isn't rerun more than 8 times)
        bruns[k]=$R_OUT; bsts[k]=$R_ST; berrs[k]=$R_ERR; [ "$R_TO" -eq 1 ] && { bsts[k]=timeout; continue; }
        b2st=$R_ST; b2out=$R_OUT
        [ "$b2out" != "$bout" ] && break
      done
    fi
    [ -n "$b2st" ] && [ "$b2out" != "$bout" ] && [ "$b2st" -eq "$bst" ]
  }
  bash_produces() {  # does bash, rerun (≤8x, only for a mismatch), ever print exactly $1 / exit $2?
    local k o st
    for ((k = 0; k < 8; k++)); do
      if [ -n "${bruns[k]+x}" ]; then o=${bruns[k]}; st=${bsts[k]}
      else run_shell bash; o=$R_OUT; st=$R_ST; [ "$R_TO" -eq 1 ] && st=timeout
        bruns[k]=$o; bsts[k]=$st; berrs[k]=$R_ERR; fi
      [ "$st" != timeout ] && [ "$o" = "$1" ] && [ "$st" -eq "$2" ] && return 0
    done
    return 1
  }
  bruns=(); bsts=(); berrs=()
  nondet_match() {  # $1 out [$2 bash's  $3 bash rerun's]: equal to bash's up to the digits of lines bash itself varies on
    local -a A B C; local k
    mapfile -t A <<<"${2-$bout}"; mapfile -t B <<<"${3-$b2out}"; mapfile -t C <<<"$1"
    [ ${#A[@]} -eq ${#B[@]} ] && [ ${#A[@]} -eq ${#C[@]} ] || return 1
    for ((k = 0; k < ${#A[@]}; k++)); do
      if [ "${A[k]}" = "${B[k]}" ]; then [ "${C[k]}" = "${A[k]}" ] || return 1
      else
        [ "${A[k]//+([0-9])/N}" = "${B[k]//+([0-9])/N}" ] && [ "${C[k]//+([0-9])/N}" = "${A[k]//+([0-9])/N}" ] || return 1
      fi
    done
  }
  # err_matches ERR: the shell's (normalised) stderr is bash's — verbatim, or as one of
  # bash's reruns (≤8, only on a mismatch; shared with bash_produces), or equal up to the
  # digit runs of the lines two bash runs differ on (pids, times).
  err_matches() {
    [ "$1" = "$berr" ] && return 0
    local k
    for ((k = 0; k < 8; k++)); do
      if [ -z "${bruns[k]+x}" ]; then run_shell bash; bruns[k]=$R_OUT; bsts[k]=$R_ST; berrs[k]=$R_ERR
        [ "$R_TO" -eq 1 ] && bsts[k]=timeout; fi
      [ "${bsts[k]}" = timeout ] && continue
      [ "$1" = "${berrs[k]}" ] && return 0
      [ "${berrs[k]}" != "$berr" ] && nondet_match "$1" "$berr" "${berrs[k]}" && return 0
      [ "$k" -ge 2 ] && [ "${berrs[k]}" = "$berr" ] && [ "${berrs[k-1]}" = "$berr" ] && return 1  # bash is stable here
    done
    return 1
  }
  shopt -s extglob
  # result row: corpus \t shell \t verdict \t duration_us \t testid \t why
  # verdict: PASS | FAIL | NA (dash can't parse it) | OTIMEOUT — the ORACLE hit the time
  # limit: its output is truncated, so there is nothing to score against. Neither a pass
  # nor a fail (the shells aren't even run); the scoreboard counts and lists these.
  # (The oracle's own row is ORACLE, or ORACLE-TIMEOUT.)
  # why (for a FAIL — the scoreboard counts them, -v lists them; OTIMEOUT's is
  # oracle-timeout):
  #   timeout         the shell hit the time limit (bash finished in time): FAIL outright,
  #                   never matched against bash reruns
  #   status          stdout matched, exit status didn't
  #   output          exit status matched, stdout didn't
  #   output+status   neither
  #   stderr          stdout and status matched, (normalised) stderr didn't
  emit_row() {  # $1 shell  $2 out  $3 status  $4 duration_us  $5 timed-out -> verdict row
    local v=FAIL why=-
    if [ "$btimeout" -eq 1 ]; then v=OTIMEOUT why=oracle-timeout
    elif [ "$5" -eq 1 ]; then why=timeout
    elif [ "$1" = dash ] && [ "$3" -eq 2 ] && [ "$bst" -ne 2 ]; then v=NA
    elif [ "$2" = "$bout" ] && [ "$3" -eq "$bst" ]; then v=PASS
    elif [ "$3" -eq "$bst" ] && oracle_varies && nondet_match "$2"; then v=PASS
    # (…or bash itself can produce exactly this output: a race in bash, e.g. `a & b`'s order)
    elif bash_produces "$2" "$3"; then v=PASS
    elif [ "$2" = "$bout" ]; then why=status
    elif [ "$3" -eq "$bst" ]; then why=output
    else why=output+status; fi
    # stderr: only once stdout + status agree, for curse, where the corpus compares it
    if [ "$v" = PASS ] && [ -n "$cmp_err" ] && [ "$1" != dash ] && ! err_matches "$6"; then
      if [ -n "$known_err" ]; then why=stderr-known; err_differed=1; else v=FAIL why=stderr; fi
    fi
    [ "$v" != PASS ] && [ "$1" != dash ] && any_nonpass=1
    # a known difference (known-diffs): KNOWN, not FAIL; one that PASSes now is stale
    case " $known_shells " in *" $1 "*)
      if [ "$v" = FAIL ]; then v=KNOWN; elif [ "$v" = PASS ]; then echo "$corpus $testid $1" >> "$workdir/stale/$id"; fi ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$corpus" "$1" "$v" "$4" "$testid" "$why" >> "$res"
    # H_DIFF_DIR=dir: keep a failing test's expected (bash) and actual output + statuses
    if { [ "$v" = FAIL ] || [ "$v" = KNOWN ] || [ "$why" = stderr-known ]; } && [ -n "${H_DIFF_DIR:-}" ]; then
      printf '%s\n[status %s]\n' "$bout" "$bst" > "$H_DIFF_DIR/$testid.expected"
      printf '%s\n[status %s%s; %s]\n' "$2" "$3" "$( [ "$5" -eq 1 ] && echo ", TIMED OUT after ${lim}s")" "$why" > "$H_DIFF_DIR/$testid.$1"
      [ -n "$cmp_err" ] && { printf '%s\n' "$berr" > "$H_DIFF_DIR/$testid.expected.err"; printf '%s\n' "$6" > "$H_DIFF_DIR/$testid.$1.err"; }
    fi
  }
  # A test that uses a FIXED path outside its own dirs — /tmp/redir-test (bash redir.tests),
  # /tmp/oil-spec-test/pwd (oil builtin-cd#14: mkdir, cd, rmdir), /tmp/bash-dir-a — shares
  # it with every other harness run on the machine: one run's rmdir lands between another's
  # mkdir and cd, and both report a wrong answer that no rerun reproduces. Hold a
  # machine-wide lock (a fixed path, on purpose) for the whole unit, so such tests never
  # overlap across concurrent harness runs. Found by scanning the test (and, for the bash
  # suite, the .sub files it runs, two levels deep) for a literal /tmp or /var/tmp path,
  # ignoring the ${TMPDIR:=/tmp}-style defaults that TMPDIR (set per unit) overrides.
  scan=("$script")
  if [ "$srcdir" != - ]; then
    for sub in $(grep -o '[A-Za-z0-9_.-]*\.sub' "$script" 2>/dev/null | sort -u); do
      [ -f "$srcdir/$sub" ] || continue; scan+=("$srcdir/$sub")
      for sub2 in $(grep -o '[A-Za-z0-9_.-]*\.sub' "$srcdir/$sub" 2>/dev/null | sort -u); do
        [ -f "$srcdir/$sub2" ] && scan+=("$srcdir/$sub2")
      done
    done
  fi
  if sed -E 's#TMPDIR:?[-=]/(var/)?tmp##g' "${scan[@]}" 2>/dev/null \
       | grep -qE '(^|[^A-Za-z0-9_.}])/(var/)?tmp($|[^A-Za-z0-9_.-])' && command -v flock >/dev/null; then
    exec 9>>/tmp/curse-harness-shared-paths.lock && flock 9
  fi

  # Is stderr compared for this unit? (its corpus is in H_STDERR, and it isn't opted out)
  # (and what is known to differ: test/conformance/known-diffs)
  known=$( [ -f "$H_KNOWN" ] && awk -v c="$corpus" -v t="$testid" '$1==c && $2==t {print $3}' "$H_KNOWN")
  known_err=""; known_shells=" "; err_differed=""; any_nonpass=""
  for k in $known; do [ "$k" = stderr ] && known_err=1 || known_shells+="$k "; done
  cmp_err=""
  case ",$H_STDERR," in *",$corpus,"*) cmp_err=1 ;; esac
  runscript_n=$script; [ "$srcdir" != - ] && runscript_n="$cwd/$(basename "$script")"
  # norm_err FILE: a run's stderr, normalised (see the header): the paths every shell sees
  # differently or randomly — the script ($0), THIS_SH, the unit's cwd/TMPDIR/workdir,
  # mktemp names — and `time`'s figures. (Literal sed patterns: the paths are escaped.)
  sedq() { printf '%s' "$1" | sed 's/[][\\/.*^$]/\\&/g'; }
  norm_sed=(-e "s/$(sedq "$runscript_n")/\$0/g" -e "s/$(sedq "$H_ORACLE")/THIS_SH/g" -e "s/$(sedq "$H_THIS_SH")/THIS_SH/g" -e "s/$(sedq "$H_THIS_SH_DIRECT")/THIS_SH/g"
            -e "s/$(sedq "$tmpd")/TMPDIR/g" -e "s/$(sedq "$cwd")/CWD/g" -e "s/$(sedq "$workdir")/WORKDIR/g"
            -e 's/tmp\.[A-Za-z0-9]\{10\}/tmp.XXXXXXXXXX/g' -e 's/[0-9][0-9]*m[0-9][0-9]*[.,][0-9][0-9]*s/TIME/g')
  run_shell bash; bst=$R_ST; bdur=$R_DUR; bout=$R_OUT; btimeout=$R_TO; berr=$R_ERR
  # curse-cold MUST precede curse-hot (SHELLS order guarantees it): cold misses the
  # empty per-unit cache and tiers (interp -> OSR + store .bc); hot then loads the .bc.
  for sh in ${H_SHELLS//,/ }; do
    case "$sh" in
      bash) printf '%s\tbash\t%s\t%s\t%s\t%s\n' "$corpus" "$( [ "$btimeout" -eq 1 ] && echo ORACLE-TIMEOUT || echo ORACLE)" "$bdur" "$testid" "$( [ "$btimeout" -eq 1 ] && echo "timeout@${lim}s" || echo -)" >> "$res" ;;
      dash|curse-cold|curse-hot)
        run=$sh; [ "$sh" = dash ] || run=curse
        # (no oracle to score against: don't spend another time limit per shell on it)
        if [ "$btimeout" -eq 1 ]; then emit_row "$sh" "" 0 0 0 ""; continue; fi
        run_shell "$run"
        emit_row "$sh" "$R_OUT" "$R_ST" "$R_DUR" "$R_TO" "$R_ERR" ;;
      curse-interp)
        if [ "$btimeout" -eq 1 ]; then emit_row "$sh" "" 0 0 0 ""; continue; fi
        run_shell "$sh"
        emit_row "$sh" "$R_OUT" "$R_ST" "$R_DUR" "$R_TO" "$R_ERR" ;;
    esac
  done
  # a known stderr difference that no curse shell showed is stale
  [ -n "$known_err" ] && [ -n "$cmp_err" ] && [ "$btimeout" -eq 0 ] && [ -z "$err_differed" ] && [ -z "$any_nonpass" ] && echo "$corpus $testid stderr" >> "$workdir/stale/$id"
  # Free this unit's files now, not at the end of the whole run: a bash-suite unit's cwd is
  # a full copy of the suite (~3 MB), so a run held ~240 MB of tmpfs until it finished (and
  # forever, when it was killed) — six parallel suites alone took over a gigabyte of /tmp.
  [ -n "${H_KEEP:-}" ] || rm -rf "$cwd" "$tmpd" "$ucache" "$ofile".*
  exit 0
fi

# ------------------------------- driver --------------------------------------
CORPUS=all; JOBS="${JOBS:-}"; H_TIMEOUT="${TIMEOUT:-10}"; VERBOSE=0; H_STDERR="${H_STDERR-cases}"
SHELLS_SEL=""; FILTERS=(); BASH_DIR=""; OIL_DIR=""; RESULTS=""; ORACLE="${H_ORACLE:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --corpus)   CORPUS="$2"; shift 2 ;;
    --jobs)     JOBS="$2"; shift 2 ;;
    --timeout)  H_TIMEOUT="$2"; shift 2 ;;
    --shells)   SHELLS_SEL="$2"; shift 2 ;;
    --bash-dir) BASH_DIR="$2"; shift 2 ;;   # bash suite tests/ dir (Meson subproject)
    --oil-dir)  OIL_DIR="$2"; shift 2 ;;    # oil spec/ dir (Meson subproject)
    --oracle)   ORACLE="$2"; shift 2 ;;     # the oracle bash (default: the in-tree 5.2.21 build)
    --results)  RESULTS="$2"; shift 2 ;;
    --stderr)   H_STDERR="$2"; [ "$H_STDERR" = none ] && H_STDERR=""; shift 2 ;;  # corpora whose stderr is compared    # keep the raw per-test rows (corpus\tshell\tverdict\tduration_us\ttestid\twhy)
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help) sed -n '2,/^set -uo/{/^set -uo/d;p}' "$0"; exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do FILTERS+=("$1"); shift; done ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) FILTERS+=("$1"); shift ;;
  esac
done

case "$H_TIMEOUT" in ''|*[!0-9]*) echo "error: --timeout/TIMEOUT must be whole seconds: $H_TIMEOUT" >&2; exit 2 ;; esac
# THE ORACLE: bash 5.2.21 built from the vendored bash subproject (meson builds it at
# build/test/oracle/bash; --oracle PATH or H_ORACLE to point elsewhere). curse is
# bug-for-bug compatible with exactly that release, and the bash corpus is its own suite;
# the host's bash (another 5.2.x, with distro patches) would silently mix two versions.
# Its version is CHECKED before anything runs — no fallback to any other bash.
ORACLE_VERSION=5.2.21
[ -n "$ORACLE" ] || ORACLE="$REPO/build/test/oracle/bash"
case "$ORACLE" in /*) ;; *) ORACLE="$PWD/$ORACLE" ;; esac
[ -x "$ORACLE" ] || { echo "error: no oracle bash at $ORACLE — build it: meson compile -C build oracle-bash (or pass --oracle PATH)" >&2; exit 2; }
ORACLE_BASH_VERSION=$("$ORACLE" -c 'echo "$BASH_VERSION"' </dev/null 2>/dev/null)
case "$ORACLE_BASH_VERSION" in "$ORACLE_VERSION("*) ;;
  *) echo "error: oracle $ORACLE is bash '${ORACLE_BASH_VERSION:-?}', not $ORACLE_VERSION — curse is scored against bash $ORACLE_VERSION only" >&2; exit 2 ;;
esac
[ "$(basename "$ORACLE")" = bash ] || { echo "error: the oracle must be named 'bash' (its directory goes first on PATH): $ORACLE" >&2; exit 2; }
H_ORACLE=$ORACLE; H_ORACLE_DIR=$(dirname "$ORACLE")
LUAJIT="${CURSE_LUAJIT:-$REPO/build/luajit}"
BUNDLE="$REPO/build/curse.bc"
[ -x "$LUAJIT" ] || { echo "error: no built luajit at $LUAJIT — run 'meson compile -C build' first." >&2; exit 1; }

# Corpus dirs: explicit --bash-dir/--oil-dir (Meson passes the subproject trees),
# else auto-discover a fetched subproject, else the legacy reference/ path.
[ -n "$BASH_DIR" ] || { BASH_DIR="$(ls -d "$REPO"/subprojects/bash-*/tests 2>/dev/null | head -1)"; [ -n "$BASH_DIR" ] || BASH_DIR="$REPO/reference/bash/tests"; }
[ -n "$OIL_DIR" ]  || { for d in "$REPO/subprojects/oil/spec" "$REPO/reference/oil/spec"; do [ -d "$d" ] && { OIL_DIR="$d"; break; }; done; [ -n "$OIL_DIR" ] || OIL_DIR="$REPO/reference/oil/spec"; }

# Default jobs: min(nproc/2, 4). Deliberately gentle.
if [ -z "$JOBS" ]; then n=$(nproc 2>/dev/null || echo 4); JOBS=$(( n/2 )); [ "$JOBS" -lt 1 ] && JOBS=1; [ "$JOBS" -gt 4 ] && JOBS=4; fi

# Which shells: bash always (oracle); dash only if present; curse (via daemon) always.
avail=(bash)
command -v dash >/dev/null 2>&1 && avail+=(dash)
avail+=(curse-cold curse-hot)   # curse via daemon: cold (tiered miss) then hot (.bc hit)
if [ -n "$SHELLS_SEL" ]; then SHELLS="bash,$SHELLS_SEL"; else SHELLS="$(IFS=,; echo "${avail[*]}")"; fi

# Bound runaway output so one misbehaving test can't fill the disk. The per-unit `timeout`
# only kills the curse CLIENT; the resident daemon worker holds the client's output fd
# (dup'd onto its stdout) and keeps running — so a script that writes without end (e.g. a
# mishandled `cat </dev/zero | true`, which should SIGPIPE but doesn't) writes UNBOUNDED to
# the capture file, past any wall-clock timeout (observed: 91 GB). RLIMIT_FSIZE makes the
# kernel raise SIGXFSZ the moment any output file crosses the cap, killing the writer —
# bash/dash, or a daemon worker (which the pool then replenishes). Inherited by every child
# (the daemon launched below, and the xargs-spawned --run-unit workers). 256 MiB is ~256x
# the largest real spec output; override with H_FSIZE_KB (KiB) if a legit test needs more.
ulimit -f "${H_FSIZE_KB:-262144}" 2>/dev/null || true

workdir="$(mktemp -d "${TMPDIR:-/tmp}/curse-conf.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT
mkdir -p "$workdir/units" "$workdir/cwd" "$workdir/res" "$workdir/snip" "$workdir/bin" "$workdir/stale"

# curse runs through its resident daemon — the real warm path. Start a PRIVATE
# cursed: own $XDG_RUNTIME_DIR socket, a PERSISTENT $XDG_CACHE_HOME so the
# content-hashed compile cache survives across runs (build stamp keeps it safe
# against a rebuilt curse), and a worker pool capped to --jobs.
H_XDG_RUNTIME="$workdir/xdg"; mkdir -p "$H_XDG_RUNTIME"; chmod 700 "$H_XDG_RUNTIME"
H_XDG_CACHE="$workdir/cache"; mkdir -p "$H_XDG_CACHE"   # daemon default; workers override per-unit ($ucache)
H_CLIENT="$REPO/build/curse-client"
# THIS_SH for curse is the client under the name `bash`, as the oracle's is: tests that
# print its basename (type.tests: `hash -p /tmp/$SHBASE $SHBASE`) then compare equal.
H_THIS_SH="$workdir/bin/bash"; mkdir -p "$workdir/bin"; ln -sf "$H_CLIENT" "$H_THIS_SH"
# A fallback that FAILS loudly, so a dropped daemon shows up as curse errors, never a
# silent dash run masquerading as curse.
H_FALLBACK="$workdir/bin/no-daemon"
# THIS_SH for curse-interp: curse run directly, no daemon — the static self-contained
# build/curse, also named `bash` (a symlink: no /bin/sh launcher in between, which would
# drop exported functions' BASH_FUNC_f%% variables from the environment)
H_THIS_SH_DIRECT="$workdir/bin/direct/bash"; mkdir -p "$workdir/bin/direct"; ln -sf "$REPO/build/curse" "$H_THIS_SH_DIRECT"
printf '#!/bin/sh\necho "curse: daemon unavailable" >&2\nexit 127\n' > "$H_FALLBACK"; chmod +x "$H_FALLBACK"
DAEMON_PID=""; XARGS_PID=""
# Kill the daemon's ENTIRE process subtree — not just its direct worker children, but
# any grandchildren a worker forked (subshells/pipelines/background) that outlived the
# request. STOP the parent FIRST so its waitpid loop can't respawn a worker mid-kill.
# On INT/TERM too, so an interrupted harness never leaks the pool.
killtree() { local p="$1" c; for c in $(pgrep -P "$p" 2>/dev/null); do killtree "$c"; done; kill -9 "$p" 2>/dev/null; }
cleanup() {
  trap - EXIT INT TERM HUP
  # Stop the unit workers FIRST: removing the workdir while units still run let them
  # recreate files in it (their next capture file), so rm -rf failed with ENOTEMPTY and
  # left a stale curse-conf.* behind (seen: two such dirs holding only an o.NNNN file).
  [ -n "$XARGS_PID" ] && killtree "$XARGS_PID"
  if [ -n "$DAEMON_PID" ]; then
    kill -STOP "$DAEMON_PID" 2>/dev/null
    killtree "$DAEMON_PID"
  fi
  rm -rf "$workdir"
}
# (HUP too: a run whose terminal or session goes away must still clean up)
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP
case "$SHELLS" in *curse-interp*)
  [ -x "$REPO/build/curse" ] || { echo "error: no static curse at $REPO/build/curse (curse-interp's THIS_SH) — run 'meson compile -C build'." >&2; exit 1; } ;;
esac
case "$SHELLS" in *curse*)
  [ -x "$H_CLIENT" ] || { echo "error: no curse-client at $H_CLIENT — run 'meson compile -C build'." >&2; exit 1; }
  [ -f "$BUNDLE" ]   || { echo "error: no bundle at $BUNDLE — run 'meson compile -C build'." >&2; exit 1; }
  env XDG_RUNTIME_DIR="$H_XDG_RUNTIME" XDG_CACHE_HOME="$H_XDG_CACHE" CURSE_BUNDLE="$BUNDLE" \
    CURSE_WORKERS="$JOBS" CURSE_IDLE=3600 "$LUAJIT" "$REPO/lua/daemon.lua" >"${H_DAEMON_LOG:-/dev/null}" 2>&1 &
  DAEMON_PID=$!
  disown "$DAEMON_PID" 2>/dev/null || true   # cleanup kills it by pid; keep job-control quiet
  sock="$H_XDG_RUNTIME/curse.sock"
  timeout 10 sh -c 'until [ -S "$1" ]; do :; done' _ "$sock" \
    || { echo "error: cursed socket $sock never appeared (daemon failed to start)" >&2; exit 1; }
;; esac

matches() {  # name matches any FILTER (or no filters)
  [ ${#FILTERS[@]} -eq 0 ] && return 0
  local f; for f in "${FILTERS[@]}"; do [[ "$1" == *"$f"* ]] && return 0; done; return 1
}

uid=0
add_unit() {  # corpus testid script srcdir
  uid=$((uid+1)); printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" > "$workdir/units/$uid"
}

# ---- corpus: cases (curse's own) ----
build_cases() {
  local f; for f in "$REPO"/test/cases/*.sh; do [ -e "$f" ] || continue
    matches "$(basename "$f")" || continue; add_unit cases "$(basename "$f")" "$f" -; done
}
# ---- corpus: bash suite (each *.tests is a self-contained script) ----
build_bash() {
  local d="$BASH_DIR" f
  [ -d "$d" ] || { echo "note: bash suite absent at $d (configure with -Dconformance=true, or --bash-dir); skipping." >&2; return; }
  for f in "$d"/*.tests; do [ -e "$f" ] || continue
    matches "$(basename "$f")" || continue; add_unit bash "$(basename "$f")" "$f" "$d"; done
}
# ---- corpus: oil spec (extract bash-targeting cases into snippet scripts) ----
build_oil() {
  local d="$OIL_DIR" f
  [ -d "$d" ] || { echo "note: oil spec absent at $d (configure with -Dconformance=true, or --oil-dir); skipping." >&2; return; }
  for f in "$d"/*.test.sh; do [ -e "$f" ] || continue
    local base; base="$(basename "$f" .test.sh)"; matches "$base" || continue
    # awk: only files whose `## compare_shells:` names bash; one snippet per ####
    # case, dropping ## metadata and every ## …STDOUT:/…STDERR: expected-output block;
    # skip cases marked `## N-I bash` (bash doesn't implement -> not a bash target).
    # An expected-output block is opened by ANY `## …STDOUT:`/`## …STDERR:` header,
    # INCLUDING a shell-qualified one like `## N-I zsh STDOUT:` or `## OK dash STDOUT:`.
    # Matching that opener BEFORE the `## (END|OK|BUG|N-I)` closer is essential: a
    # qualified header matches both, and if the closer wins the block never opens, so
    # its lines leak into the snippet as CODE — e.g. `yes ^` (the `yes` command) then
    # spews forever, ballooning the captured output to gigabytes. (Fixed: was a real
    # disk-exhaustion bug that corrupted ~28% of oil snippets with stray expected text.)
    awk -v OUT="$workdir/snip" -v B="$base" '
      /^## compare_shells:/ { if ($0 ~ /bash/) targets=1 }
      /^#### / { flush(); n++; code=""; skip=0; incase=1; inblock=0; title=substr($0, 6); next }
      !incase { next }
      /^## .*(STDOUT|STDERR):[ \t]*$/ { if ($0 ~ /^## N-I bash/) skip=1; inblock=1; next }
      /^## (END|OK|BUG|N-I)/ { if ($0 ~ /^## N-I bash/) skip=1; inblock=0; next }
      inblock { next }
      /^## / { next }
      { code = code $0 "\n" }
      END { flush() }
      function flush(   p) {
        if (incase && !skip && targets && code != "") {
          p = OUT "/" B "__" n ".sh"; printf "%s", code > p; close(p); print n "\t" p "\t" title
        }
      }' "$f" > "$workdir/oil.idx"
    # NB: read via process substitution, NOT `awk | while` — a pipe runs the loop
    # in a subshell and loses the uid increments (the whole unit list).
    while IFS=$'\t' read -r n snip title; do
      # A deterministic replacement for a case whose expected output depends on scheduling
      # (each override file says why and what it keeps). Its `# overrides: #### TITLE` line must
      # name this case, so a renumbered upstream spec can never swap in the wrong test.
      ov="$REPO/test/conformance/overrides/oil/$base#$n.sh"
      if [ -f "$ov" ]; then
        if [ "$(sed -n 's/^# overrides: #### //p' "$ov" | head -1)" != "$title" ]; then
          echo "error: $ov overrides \"$(sed -n 's/^# overrides: #### //p' "$ov" | head -1)\", but $base#$n is \"$title\"" >&2
          exit 2
        fi
        cp "$ov" "$snip"
      fi
      add_unit oil "$base#$n" "$snip" -
    done < "$workdir/oil.idx"
  done
}

case "$CORPUS" in
  cases) build_cases ;;
  bash)  build_bash ;;
  oil)   build_oil ;;
  all)   build_cases; build_bash; build_oil ;;
  *) echo "unknown corpus: $CORPUS" >&2; exit 2 ;;
esac
total=$uid
if [ "$total" -eq 0 ]; then
  # A specific corpus requested but its source isn't fetched -> exit 77, which
  # Meson reports as SKIP (not a spurious pass), with a hint to fetch it.
  case "$CORPUS" in
    bash) [ -d "$BASH_DIR" ] || { echo "SKIP: bash corpus absent ($BASH_DIR) — fetch: meson subprojects download bash"; exit 77; } ;;
    oil)  [ -d "$OIL_DIR" ]  || { echo "SKIP: oil corpus absent ($OIL_DIR) — fetch: meson subprojects download oil";  exit 77; } ;;
  esac
  echo "no tests selected."; exit 0
fi

echo "harness: $total tests × [${SHELLS//,/ }]  (jobs=$JOBS, timeout=${H_TIMEOUT}s, oracle bash $ORACLE_BASH_VERSION)"
export H_TIMEOUT H_SHELLS="$SHELLS" H_TIMEOUTS="$REPO/test/conformance/timeouts" H_NPROC="$(nproc 2>/dev/null || echo 0)"
export H_CLIENT H_THIS_SH H_THIS_SH_DIRECT H_XDG_RUNTIME H_XDG_CACHE H_FALLBACK H_ORACLE H_ORACLE_DIR H_STDERR
export H_KNOWN="$REPO/test/conformance/known-diffs" H_LUAJIT="$LUAJIT" H_BUNDLE="$BUNDLE" H_REPO_LUA="$REPO/lua"
# (in the background + wait, so an interrupt reaches cleanup at once and it can stop them)
seq 1 "$total" | xargs -P "$JOBS" -I{} "$0" --run-unit "$workdir" {} &
XARGS_PID=$!
wait "$XARGS_PID"; XARGS_PID=""

# ------------------------------ scoreboard -----------------------------------
echo
cat "$workdir"/res/*.tsv > "$workdir/all.tsv" 2>/dev/null
[ -n "$RESULTS" ] && cp "$workdir/all.tsv" "$RESULTS" 2>/dev/null   # preserve raw per-test rows for analysis
awk -F'\t' '
  { seen_corpus[$1]=1; seen_shell[$2]=1; dur[$1,$2]+=$4
    if($3 ~ /^ORACLE/){oracle[$1]++; if($3!="ORACLE") oto[$1]++}
    else if($3=="OTIMEOUT"){ot[$1,$2]++}
    else {tot[$1,$2]++; c[$1,$2,$3]++; if($3=="FAIL") why[$1,$2,$6]++} }
    # (a KNOWN row — test/conformance/known-diffs — counts as not passing, shown apart)
  END {
    ns=split("bash dash curse-cold curse-hot curse-interp", order, " ")
    printf "%-16s", "corpus"
    for(i=1;i<=ns;i++) if(seen_shell[order[i]]) printf "%-18s", order[i]
    printf "\n"
    for(cp in seen_corpus){
      printf "%-16s", cp
      for(i=1;i<=ns;i++){ s=order[i]; if(!seen_shell[s]) continue
        if(s=="bash"){ printf "%-18s", "(oracle "oracle[cp] (oto[cp] ? ", "oto[cp]" t/o" : "") ")"; continue }
        p=c[cp,s,"PASS"]+0; t=tot[cp,s]+0; na=c[cp,s,"NA"]+0
        pct = t>0 ? sprintf("%d%%", 100*p/t) : "-"
        kn=c[cp,s,"KNOWN"]+0
        printf "%-18s", sprintf("%d/%d %s%s%s", p, t, pct, na>0?" ("na" n/a)":"", kn>0?" ("kn" known)":"")
      }
      printf "\n"
      # summed per-run wall time across the corpus (bash included) — compare shells
      printf "%-16s", "  time"
      for(i=1;i<=ns;i++){ s=order[i]; if(!seen_shell[s]) continue
        printf "%-18s", sprintf("%.2fs", dur[cp,s]/1000000)
      }
      printf "\n"
      # why the FAILs failed (see emit_row): a timeout is not a wrong answer, and an
      # oracle timeout is no fault of the shell under test: never mix them up
      for(i=1;i<=ns;i++){ s=order[i]; if(!seen_shell[s]) continue
        line=""
        for(k in why) { split(k, kk, SUBSEP); if(kk[1]==cp && kk[2]==s) line=line sprintf(" %s=%d", kk[3], why[k]) }
        if(line!="") printf "  %s fails:%s\n", s, line
      }
    }
  }' "$workdir/all.tsv"

# An oracle run that timed out scores nothing (OTIMEOUT: its output is truncated) — say so
# loudly, every time, so a too-short limit can't hide as a pass or a fail.
if awk -F'\t' '$3=="ORACLE-TIMEOUT"{f=1} END{exit !f}' "$workdir/all.tsv"; then
  echo; echo "ORACLE TIMED OUT (bash took the whole limit; not scored — raise --timeout, or give the test an entry in test/conformance/timeouts):"
  awk -F'\t' '$3=="ORACLE-TIMEOUT"{sub(/^timeout@/, "", $6); print "  "$1"\t"$5"\t(limit "$6")"}' "$workdir/all.tsv" | sort
fi

if [ "$VERBOSE" -eq 1 ]; then
  echo; echo "failures (shell disagreed with bash):"
  # every curse failure; dash's (hundreds: it isn't bash) only up to 100
  awk -F'\t' '$3=="FAIL" && $2!="dash"{print "  "$1"\t"$2"\t"$5"\t("$6")"}' "$workdir/all.tsv" | sort
  awk -F'\t' '$3=="FAIL" && $2=="dash"{print "  "$1"\t"$2"\t"$5"\t("$6")"}' "$workdir/all.tsv" | sort \
    | awk 'NR <= 100 { print } END { if (NR > 100) print "  … and " NR - 100 " more dash failures (see --results)" }'
  # (awk, not head: head exits after 100 lines, sort dies of SIGPIPE, and under pipefail the
  # harness itself exited 141 — meson reported the whole corpus as FAILED)
fi

# ------------------------------ exit status ----------------------------------
# Any curse FAIL (output, status, stderr, timeout) fails the run; so does an oracle timeout
# on one of curse's own cases (no score = a broken case). dash never decides it.
nfail=$(awk -F'\t' '$2 ~ /^curse/ && $3=="FAIL"' "$workdir/all.tsv" | wc -l)
noto=$(awk -F'\t' '$1=="cases" && $3=="ORACLE-TIMEOUT"' "$workdir/all.tsv" | wc -l)
if [ "$(awk -F'\t' '$3=="KNOWN"' "$workdir/all.tsv" | wc -l)" -gt 0 ] || [ -n "$(ls "$workdir/stale")" ]; then
  echo; echo "known differences (test/conformance/known-diffs):"
  awk -F'\t' '$3=="KNOWN"{print "  "$1"\t"$2"\t"$5"\t("$6")"}' "$workdir/all.tsv" | sort
  awk -F'\t' '$6=="stderr-known"{print "  "$1"\t"$2"\t"$5"\t(stderr)"}' "$workdir/all.tsv" | sort
fi
nstale=$(cat "$workdir"/stale/* 2>/dev/null | wc -l)
if [ "$nstale" -gt 0 ]; then
  echo; echo "STALE known differences (they match bash now: remove them from test/conformance/known-diffs):"
  cat "$workdir"/stale/* | sort | sed 's/^/  /'
fi
if [ "$nfail" -gt 0 ] || [ "$noto" -gt 0 ] || [ "$nstale" -gt 0 ]; then
  echo; echo "FAILED: $nfail curse run(s) failed$( [ "$noto" -gt 0 ] && echo ", $noto cases test(s) the oracle timed out on")$( [ "$nstale" -gt 0 ] && echo ", $nstale stale known difference(s)")"
  [ "$VERBOSE" -eq 1 ] || awk -F'\t' '$2 ~ /^curse/ && $3=="FAIL"{print "  "$1"\t"$2"\t"$5"\t("$6")"}' "$workdir/all.tsv" | sort
  exit 1
fi
exit 0
