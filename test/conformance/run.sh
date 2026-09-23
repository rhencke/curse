#!/usr/bin/env bash
# Conformance harness. Runs each test under bash (the oracle), dash, and curse via
# its resident daemon (cursed: a warm worker + content-hashed compile cache —
# curse's real production path), scoring each shell's agreement with bash on
# stdout + exit status.
#
# Corpora (any present are run; pick with --corpus):
#   cases  test/cases/*.sh              curse's own hand-written conformance scripts
#   bash   reference/bash/tests/*.tests GNU bash's suite     (ninja -C build fetch-bash)
#   oil    reference/oil/spec/*.test.sh Oils spec cases that target bash
#                                        (ninja -C build fetch-oil)
#
# stderr is not compared (error wording is a later-milestone concern), matching
# curse's historical conformance metric. dash is scored only where it supports the
# test: a dash parse error (status 2) where bash parsed fine counts N/A, not fail.
#
# The harness starts a PRIVATE cursed (its own $XDG_RUNTIME_DIR socket + a persistent
# $XDG_CACHE_HOME) and runs curse through the C client. Each curse test runs TWICE:
# a warm-up (populate the compile cache + heat the worker), then a MEASURED run that
# hits the warm cache — so timing reflects curse's real amortized path, not cold start.
#
# PARALLELISM — bounded on purpose. Each test runs its shells SEQUENTIALLY; only
# --jobs test units run at once (default: min(nproc/2, 4)); the daemon's worker pool
# is capped to match (CURSE_WORKERS). Override: --jobs N / JOBS=N.
#
# The scoreboard reports a per-shell success rate AND summed per-run wall time
# (bash vs dash vs curse). Under --jobs>1 absolute times inflate from CPU contention
# — the shell-to-shell ratios stay fair; use --jobs 1 for clean numbers.
#
# Usage:
#   test/conformance/run.sh [--corpus cases|bash|oil|all] [--jobs N] [--timeout S]
#                           [--shells a,b,c] [-v|--verbose] [FILTER...]
#   FILTER: substrings; only test files whose name matches one are run.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# ---- internal worker: run ONE unit (all shells) and write its result rows ----
if [ "${1:-}" = --run-unit ]; then
  workdir="$2"; id="$3"
  IFS=$'\t' read -r corpus testid script srcdir < "$workdir/units/$id"
  cwd="$workdir/cwd/$id"; res="$workdir/res/$id.tsv"; : > "$res"

  prep() {  # (re)create an isolated cwd for one shell run
    rm -rf "$cwd"; mkdir -p "$cwd"
    if [ "$srcdir" != - ]; then cp -a "$srcdir/." "$cwd/"; runscript="$cwd/$(basename "$script")";
    else runscript="$script"; fi
  }
  one() {  # $1 shell -> prints stdout, returns status
    local sh="$1"
    case "$sh" in
      # stdin < /dev/null so a `read`/`select` with no input gets EOF instead of
      # blocking (which, in the daemon, would hang a persistent worker until timeout).
      # THIS_SH is the shell's full path, as bash's own suite runs it: tests copy it
      # (`cp ${THIS_SH} $TMPDIR/sh`) and write it into `#!${THIS_SH}` lines, which a bare
      # name can't satisfy — the oracle would fail those checks by itself.
      bash)  ( cd "$cwd" && THIS_SH="$(command -v bash)" timeout "$H_TIMEOUT" bash "$runscript" </dev/null ) ;;
      dash)  ( cd "$cwd" && THIS_SH="$(command -v dash)" timeout "$H_TIMEOUT" dash "$runscript" </dev/null ) ;;
      # curse via the resident daemon: the C client hands the script to cursed, which
      # tiers on a cache miss (interp -> OSR + store .bc) or loads the .bc on a hit.
      # THIS_SH=client so bash-suite self-reinvokes hit the daemon too; fallback fails
      # loudly so a dropped daemon can't masquerade as dash. The daemon reads the
      # CLIENT's env per request, so $ucache (per-unit) selects the compile cache:
      # first curse run misses (cold), second hits (hot).
      curse) ( cd "$cwd" && XDG_RUNTIME_DIR="$H_XDG_RUNTIME" XDG_CACHE_HOME="$ucache" \
                 CURSE_FALLBACK="$H_FALLBACK" THIS_SH="$H_THIS_SH" \
                 timeout "$H_TIMEOUT" "$H_CLIENT" "$runscript" </dev/null ) ;;
    esac
  }

  # microseconds since epoch, no fork (EPOCHREALTIME, bash 5+); date fallback.
  now_us() { local t=${EPOCHREALTIME:-}; if [ -n "$t" ]; then t=${t/,/.}; echo $(( ${t%.*} * 1000000 + 10#${t#*.} )); else date +%s%6N; fi; }
  # Capture stdout to a FILE, not "$(...)": command substitution waits for EOF from
  # EVERY holder of the pipe, so a lingering child (e.g. a curse daemon worker's
  # forked subshell, or a bash `sleep 5 &`) that inherited the fd would hang the read
  # forever. `cat` of a regular file reads the current content and stops at EOF.
  ofile="$workdir/o.$id"
  ucache="$workdir/uc/$id"; mkdir -p "$ucache"   # per-unit compile cache: cold miss, then hot hit
  emit_row() {  # $1 shell  $2 out  $3 status  $4 duration_us  -> verdict row
    local v=FAIL
    if [ "$1" = dash ] && [ "$3" -eq 2 ] && [ "$bst" -ne 2 ]; then v=NA
    elif [ "$2" = "$bout" ] && [ "$3" -eq "$bst" ]; then v=PASS; fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$corpus" "$1" "$v" "$4" "$testid" >> "$res"
  }
  # result row: corpus \t shell \t verdict \t duration_us \t testid
  prep; _s=$(now_us); one bash >"$ofile" 2>/dev/null; bst=$?; bdur=$(( $(now_us) - _s )); bout=$(cat "$ofile" 2>/dev/null)
  # curse-cold MUST precede curse-hot (SHELLS order guarantees it): cold misses the
  # empty per-unit cache and tiers (interp -> OSR + store .bc); hot then loads the .bc.
  for sh in ${H_SHELLS//,/ }; do
    case "$sh" in
      bash) printf '%s\tbash\tORACLE\t%s\t%s\n' "$corpus" "$bdur" "$testid" >> "$res" ;;
      dash|curse-cold|curse-hot)
        run=$sh; [ "$sh" = dash ] || run=curse
        # stop the clock BEFORE emit_row: its "$(cat …)" argument expands first and
        # would bill a fork+exec of cat to this shell (the bash oracle's time excludes it)
        prep; _s=$(now_us); one "$run" >"$ofile" 2>/dev/null; st=$?; dur=$(( $(now_us) - _s ))
        emit_row "$sh" "$(cat "$ofile" 2>/dev/null)" "$st" "$dur" ;;
    esac
  done
  exit 0
fi

# ------------------------------- driver --------------------------------------
CORPUS=all; JOBS="${JOBS:-}"; H_TIMEOUT="${TIMEOUT:-10}"; VERBOSE=0
SHELLS_SEL=""; FILTERS=(); BASH_DIR=""; OIL_DIR=""; RESULTS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --corpus)   CORPUS="$2"; shift 2 ;;
    --jobs)     JOBS="$2"; shift 2 ;;
    --timeout)  H_TIMEOUT="$2"; shift 2 ;;
    --shells)   SHELLS_SEL="$2"; shift 2 ;;
    --bash-dir) BASH_DIR="$2"; shift 2 ;;   # bash suite tests/ dir (Meson subproject)
    --oil-dir)  OIL_DIR="$2"; shift 2 ;;    # oil spec/ dir (Meson subproject)
    --results)  RESULTS="$2"; shift 2 ;;    # keep the raw per-test rows (corpus\tshell\tverdict\tduration_us\ttestid)
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do FILTERS+=("$1"); shift; done ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) FILTERS+=("$1"); shift ;;
  esac
done

LUAJIT="${CURSE_LUAJIT:-$REPO/build/luajit}"
BUNDLE="$REPO/build/curse.bc"
RUN="$REPO/lua/run.lua"
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
mkdir -p "$workdir/units" "$workdir/cwd" "$workdir/res" "$workdir/snip" "$workdir/bin"

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
printf '#!/bin/sh\necho "curse: daemon unavailable" >&2\nexit 127\n' > "$H_FALLBACK"; chmod +x "$H_FALLBACK"
DAEMON_PID=""
# Kill the daemon's ENTIRE process subtree — not just its direct worker children, but
# any grandchildren a worker forked (subshells/pipelines/background) that outlived the
# request. STOP the parent FIRST so its waitpid loop can't respawn a worker mid-kill.
# On INT/TERM too, so an interrupted harness never leaks the pool.
killtree() { local p="$1" c; for c in $(pgrep -P "$p" 2>/dev/null); do killtree "$c"; done; kill -9 "$p" 2>/dev/null; }
cleanup() {
  if [ -n "$DAEMON_PID" ]; then
    kill -STOP "$DAEMON_PID" 2>/dev/null
    killtree "$DAEMON_PID"
  fi
  rm -rf "$workdir"
}
trap cleanup EXIT INT TERM
case "$SHELLS" in *curse*)
  [ -x "$H_CLIENT" ] || { echo "error: no curse-client at $H_CLIENT — run 'meson compile -C build'." >&2; exit 1; }
  [ -f "$BUNDLE" ]   || { echo "error: no bundle at $BUNDLE — run 'meson compile -C build'." >&2; exit 1; }
  env XDG_RUNTIME_DIR="$H_XDG_RUNTIME" XDG_CACHE_HOME="$H_XDG_CACHE" CURSE_BUNDLE="$BUNDLE" \
    CURSE_WORKERS="$JOBS" CURSE_IDLE=3600 "$LUAJIT" "$REPO/lua/daemon.lua" >/dev/null 2>&1 &
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
      /^#### / { flush(); n++; code=""; skip=0; incase=1; inblock=0; next }
      !incase { next }
      /^## .*(STDOUT|STDERR):[ \t]*$/ { if ($0 ~ /^## N-I bash/) skip=1; inblock=1; next }
      /^## (END|OK|BUG|N-I)/ { if ($0 ~ /^## N-I bash/) skip=1; inblock=0; next }
      inblock { next }
      /^## / { next }
      { code = code $0 "\n" }
      END { flush() }
      function flush(   p) {
        if (incase && !skip && targets && code != "") {
          p = OUT "/" B "__" n ".sh"; printf "%s", code > p; close(p); print n "\t" p
        }
      }' "$f" > "$workdir/oil.idx"
    # NB: read via process substitution, NOT `awk | while` — a pipe runs the loop
    # in a subshell and loses the uid increments (the whole unit list).
    while IFS=$'\t' read -r n snip; do
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

echo "harness: $total tests × [${SHELLS//,/ }]  (jobs=$JOBS, timeout=${H_TIMEOUT}s)"
export H_TIMEOUT H_SHELLS="$SHELLS"
export H_CLIENT H_THIS_SH H_XDG_RUNTIME H_XDG_CACHE H_FALLBACK
seq 1 "$total" | xargs -P "$JOBS" -I{} "$0" --run-unit "$workdir" {}

# ------------------------------ scoreboard -----------------------------------
echo
cat "$workdir"/res/*.tsv > "$workdir/all.tsv" 2>/dev/null
[ -n "$RESULTS" ] && cp "$workdir/all.tsv" "$RESULTS" 2>/dev/null   # preserve raw per-test rows for analysis
awk -F'\t' '
  { seen_corpus[$1]=1; seen_shell[$2]=1; dur[$1,$2]+=$4
    if($3!="ORACLE"){tot[$1,$2]++; c[$1,$2,$3]++} else {oracle[$1]++} }
  END {
    ns=split("bash dash curse-cold curse-hot", order, " ")
    printf "%-16s", "corpus"
    for(i=1;i<=ns;i++) if(seen_shell[order[i]]) printf "%-18s", order[i]
    printf "\n"
    for(cp in seen_corpus){
      printf "%-16s", cp
      for(i=1;i<=ns;i++){ s=order[i]; if(!seen_shell[s]) continue
        if(s=="bash"){ printf "%-18s", "(oracle "oracle[cp]")"; continue }
        p=c[cp,s,"PASS"]+0; t=tot[cp,s]+0; na=c[cp,s,"NA"]+0
        pct = t>0 ? sprintf("%d%%", 100*p/t) : "-"
        printf "%-18s", sprintf("%d/%d %s%s", p, t, pct, na>0?" ("na" n/a)":"")
      }
      printf "\n"
      # summed per-run wall time across the corpus (bash included) — compare shells
      printf "%-16s", "  time"
      for(i=1;i<=ns;i++){ s=order[i]; if(!seen_shell[s]) continue
        printf "%-18s", sprintf("%.2fs", dur[cp,s]/1000000)
      }
      printf "\n"
    }
  }' "$workdir/all.tsv"

if [ "$VERBOSE" -eq 1 ]; then
  echo; echo "failures (shell disagreed with bash):"
  awk -F'\t' '$3=="FAIL"{print "  "$1"\t"$2"\t"$5}' "$workdir/all.tsv" | sort | head -100
fi
