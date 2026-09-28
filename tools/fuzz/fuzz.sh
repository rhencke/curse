#!/bin/bash
# AFL++ fuzzing of curse (tools/fuzz/README.md). Normally run by meson:
#   meson compile -C build fuzz          a campaign, then triage of what it found
#   meson compile -C build fuzz-triage   triage everything in the persistent queue again
# or directly (the env meson sets is derived from the repo layout otherwise):
#   fuzz.sh campaign | triage [SINCE] | seeds | run NAME SECONDS MUTATOR MODE
#
# Env knobs:
#   FUZZ_SECONDS    campaign wall time (default: -Dfuzz_seconds, 1800)
#   FUZZ_INSTANCES  up to 2 of MUTATOR:MODE (default "gram:tiered byte:tiered"), MUTATOR
#                   gram|byte, MODE one of
#                     tiered|interp|compiled   scripts, one tier (oracle: Lua-internal errors)
#                     tiers                    scripts, interp vs compiled vs tiered in the loop
#                     arith|pexp|printf|glob|read|regex|parse
#                                              a targeted in-process fuzzer, differential
#                                              against a persistent bash 5.2.21 in the loop
#   FUZZ_JOBS       parallel triage jobs (default 2)
#   FUZZ_TRIAGE_MAX differential checks per triage: a random sample of the new queue entries (600)
#   FUZZ_WORK       persistent state (default BUILD/fuzz-work): seeds/, out/NAME/ (AFL
#                   queue, reused by the next campaign), triage/, gram-hangs/
set -u
here=$(cd "$(dirname "$0")" && pwd)
: "${FUZZ_ROOT:=$(cd "$here/../.." && pwd)}"
: "${FUZZ_BIN:=$FUZZ_ROOT/build/tools/fuzz}"
: "${FUZZ_LUAJIT:=$FUZZ_ROOT/build/luajit}"
: "${FUZZ_CURSE:=$FUZZ_ROOT/build/curse}"
: "${FUZZ_WORK:=$FUZZ_ROOT/build/fuzz-work}"
: "${FUZZ_ORACLE:=$FUZZ_ROOT/build/test/oracle/bash}"
: "${FUZZ_BASH_SRC:=$FUZZ_ROOT/subprojects/bash-5.2.21}"
: "${FUZZ_OIL_SPEC:=$FUZZ_ROOT/subprojects/oil/spec}"
export FUZZ_ROOT FUZZ_BIN FUZZ_LUAJIT FUZZ_CURSE FUZZ_WORK FUZZ_ORACLE
TARGETS="arith pexp printf glob read regex parse deparse"
is_target() { case " $TARGETS " in *" $1 "*) return 0 ;; esac; return 1; }
W=$FUZZ_WORK
mkdir -p "$W"

die() { echo "fuzz: $*" >&2; exit 1; }
say() { echo "fuzz: $*"; }

# Run a command as pid 1's child in a fresh user+pid namespace: a stray `kill -1` or an
# orphaned background job of a fuzzed script stays inside it, and dies with it. The
# namespace's init reaps orphans and forwards SIGTERM (the deadline) to the command.
in_ns() {
  unshare -Urpf --mount-proc --kill-child=TERM \
    bash -c 'trap "kill -INT \$p 2>/dev/null" TERM; "$@" & p=$!; while kill -0 $p 2>/dev/null; do wait $p; done; wait $p' ns-init "$@"
}

# (__AFL_DEFER_FORKSRV: the harness starts its forkserver late, after loading curse, and
# claims the whole map then; afl-fuzz notices that by itself, afl-cmin/afl-showmap don't
# and would read only the ~180 bytes of C edges)
afl_env() {
  export __AFL_DEFER_FORKSRV=1 AFL_SKIP_CPUFREQ=1 AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 AFL_NO_AFFINITY=1 \
    AFL_NO_UI=1 AFL_MAP_SIZE=262144 AFL_SKIP_CRASHES=1 AFL_QUIET=1 AFL_AUTORESUME=1 \
    AFL_FORKSRV_INIT_TMOUT=20000
}

dicts() { # [MODE]: a targeted fuzzer's own dictionary (its input language), else the shell's
  if [ -f "$here/dicts/${1:-}.dict" ]; then printf '%s\n' -x "$here/dicts/$1.dict"; return; fi
  [ -s "$W/auto.dict" ] || "$here/mkdict.sh" "$FUZZ_BASH_SRC" > "$W/auto.dict" 2>/dev/null || : > "$W/auto.dict"
  printf '%s\n' -x "$here/sh.dict"
  [ -s "$W/auto.dict" ] && printf '%s\n' -x "$W/auto.dict"
}

# ---- seeds: small scripts from the in-tree cases, the oil spec and bash's tests, cmin'd
seeds() {
  local raw=$W/seeds-raw
  rm -rf "$raw" "$W/seeds.tmp"; mkdir -p "$raw"
  python3 - "$FUZZ_ROOT/test/cases" "$FUZZ_OIL_SPEC" "$FUZZ_BASH_SRC/tests" "$raw" <<'PY'
import glob, hashlib, os, re, sys
cases, oil, btests, out = sys.argv[1:]
seen = set()
def emit(tag, data):
    if not data.strip() or len(data) > 1500:
        return
    h = hashlib.sha1(data).hexdigest()[:12]
    if h not in seen:
        seen.add(h)
        open(os.path.join(out, f"{tag}-{h}.sh"), "wb").write(data)
for f in sorted(glob.glob(cases + "/*.sh")):
    emit("tc", open(f, "rb").read())
# oil spec cases (## STDOUT:/## STDERR:/... metadata, same rules as
# test/conformance/run.sh's build_oil awk): a block is opened by ANY `## ...STDOUT:` or
# `## ...STDERR:` header (incl. shell-qualified ones like `## OK bash STDOUT:` or
# `## N-I zsh STDOUT:`) and closed by `## END`/`## OK`/`## BUG`/`## N-I`; the opener is
# checked BEFORE the closer since a qualified header matches both (run.sh: matching the
# closer first would leave the block never opened, leaking its expected-output lines --
# e.g. `world6` -- into the snippet as CODE). Every other `## ` line (`## status:`,
# `## stdout-json:`, `## code:`, `## compare_shells:`, ...) is single-line metadata,
# dropped on its own.
OIL_OPEN = re.compile(rb"^## .*(STDOUT|STDERR):[ \t]*$")
OIL_CLOSE = re.compile(rb"^## (END|OK|BUG|N-I)")
def strip_oil_meta(part):
    inblock = False
    code = []
    for line in part.split(b"\n"):
        if OIL_OPEN.match(line):
            inblock = True
        elif OIL_CLOSE.match(line):
            inblock = False
        elif inblock or line.startswith(b"## "):
            pass
        else:
            code.append(line)
    return b"\n".join(code)
for f in sorted(glob.glob(oil + "/*.test.sh")):
    for part in re.split(rb"(?m)^#### .*$", open(f, "rb").read())[1:]:
        body = strip_oil_meta(part)
        emit("oil", body.strip(b"\n") + b"\n")
for f in sorted(glob.glob(btests + "/*.sub")):
    emit("bt", open(f, "rb").read())
PY
  say "seeds: $(ls "$raw" | wc -l) candidates, minimising (afl-cmin, tiered coverage)"
  mkdir -p "$W/sbx/cmin"
  afl_env
  FUZZ_SBX=$W/sbx/cmin FUZZ_MODE=tiered in_ns afl-cmin -T 2 -m none -t 5000 -i "$raw" -o "$W/seeds.tmp" -- "$FUZZ_BIN/harness" > "$W/cmin.log" 2>&1 ||
    die "afl-cmin failed (see $W/cmin.log)"
  rm -rf "$W/seeds" "$raw"
  mv "$W/seeds.tmp" "$W/seeds"
  say "seeds: $(ls "$W/seeds" | wc -l) kept in $W/seeds"
}

# The harness environment of a MODE (fuzz.sh run, sig.sh): prints NAME=VALUE lines
mode_env() { # MODE
  case $1 in
    tiered|interp|compiled) echo "FUZZ_MODE=$1" ;;
    tiers) printf '%s\n' FUZZ_MODE=tiered FUZZ_ORACLE=tiers "FUZZ_KNOWN=$here/known.tsv" ;;
    *) is_target "$1" || die "mode: tiered|interp|compiled|tiers|${TARGETS// /|}, not $1"
       printf '%s\n' "FUZZ_TARGET=$1" "FUZZ_TARGETS_LUA=$here/targets.lua" "FUZZ_BASH=$FUZZ_ORACLE" ;;
  esac
}

# ---- one afl-fuzz instance, in the foreground, for SECONDS
run() { # NAME SECONDS MUTATOR MODE
  local name=$1 secs=$2 mut=$3 mode=$4
  mode_env "$mode" > /dev/null || exit 1
  local out=$W/out/$name sbx=$W/sbx/$name seeds=$W/seeds harness=$FUZZ_BIN/harness tmo=2000
  mkdir -p "$out" "$sbx" "$W/gram-hangs"
  if is_target "$mode" && [ "$mode" != parse ] && [ "$mode" != deparse ]; then
    seeds=$here/seeds/$mode        # (hand-written, in the target's own language)
  else
    [ -d "$W/seeds" ] || seeds     # (scripts: tiers, parse and the tier modes)
  fi
  if is_target "$mode"; then
    harness=$FUZZ_BIN/harness-target tmo=4000   # (persistent; bash may take BASH_TMOUT x2)
    [ -x "$FUZZ_ORACLE" ] || die "mode $mode needs the bash 5.2.21 oracle ($FUZZ_ORACLE)"
  fi
  [ "$mode" = tiers ] && tmo=6000  # (three runs of every input)
  afl_env
  export FUZZ_SBX=$sbx
  local -a extra=() menv=()
  mapfile -t menv < <(mode_env "$mode") || exit 1
  case $mut in
    gram)
      export AFL_CUSTOM_MUTATOR_LIBRARY=$FUZZ_BIN/gram_mutator.so GRAM_LUAJIT=$FUZZ_LUAJIT \
        GRAM_ROOT=$FUZZ_ROOT GRAM_STATS=$out/gram_stats GRAM_HANGS=$W/gram-hangs GRAM_TARGET=$mode ;;
    byte) unset AFL_CUSTOM_MUTATOR_LIBRARY ;;
    *) die "mutator: gram or byte, not $mut" ;;
  esac
  mapfile -t extra < <(dicts "$mode")
  # (afl-fuzz -V ends the run itself, stats written; the timeout is only a safety net)
  timeout -s TERM -k 60 "$((secs + 300))" env "${menv[@]}" bash -c "$(declare -f in_ns); in_ns \"\$@\"" in_ns \
    afl-fuzz -V "$secs" -i "$seeds" -o "$out" -t "$tmo" -m none "${extra[@]}" -- "$harness" \
    > "$W/$name.log" 2>&1
  return 0
}

# ---- triage: crash signatures + differential signatures, bucketed against known.tsv
bucket() { # SIG FILE -> ID, ID:FIXED (matched a since-fixed finding's *-fixed field: a
           # likely regression or variant, reported instead of silently bucketed), or NEW
  local sig=$1 f=$2 id field re re2 base hit
  while IFS=$'\t' read -r id field re re2; do
    case $id in ''|'#'*) continue ;; esac
    base=${field%-fixed}; hit=0
    case $base in
      sig) printf '%s\n' "$sig" | grep -qE -- "$re" && hit=1 ;;
      src) grep -qaE -- "$re" "$f" && hit=1 ;;
      both) printf '%s\n' "$sig" | grep -qE -- "$re" && grep -qaE -- "$re2" "$f" && hit=1 ;;
    esac
    [ "$hit" -eq 1 ] && { [ "$base" != "$field" ] && echo "$id:FIXED" || echo "$id"; return; }
  done < "$here/known.tsv"
  echo NEW
}

triage() { # [SINCE-FILE]: only entries newer than it
  local since=${1:-} t=$W/triage/$(date +%Y%m%d-%H%M%S)
  local jobs=${FUZZ_JOBS:-2} max=${FUZZ_TRIAGE_MAX:-600}
  mkdir -p "$t"
  local newer=(); [ -n "$since" ] && newer=(-newer "$since")
  find "$W"/out/*/default/crashes -type f -name 'id:*' "${newer[@]}" 2>/dev/null > "$t/crashes.list"
  # (a random sample: the newest entries tend to be one family, the latest favoured parent's)
  # (the queue differential runs scripts: not the targeted fuzzers' queues, whose inputs are
  # in their own languages and were already compared with bash in the loop)
  find "$W"/out/*/default/queue -maxdepth 1 -type f -name 'id:*' "${newer[@]}" 2>/dev/null |
    grep -vE "/out/[a-z]+-(${TARGETS// /|})/" > "$t/queue.all"
  shuf -n "$max" "$t/queue.all" > "$t/queue.list"
  say "triage: $(wc -l < "$t/crashes.list") crash inputs, $(wc -l < "$t/queue.list") of $(wc -l < "$t/queue.all") new queue entries sampled -> $t"
  xargs -r -d '\n' -n 1 -P "$jobs" "$here/sig.sh" < "$t/crashes.list" > "$t/crash-sigs.tsv"
  if [ -x "$FUZZ_ORACLE" ]; then
    xargs -r -d '\n' -n 1 -P "$jobs" bash -c 'printf "%s\t%s\n" "$1" "$("$0" "$1" -q)"' "$here/cmp.sh" < "$t/queue.list" > "$t/diff.tsv"
  else
    say "triage: no bash oracle at $FUZZ_ORACLE (-Dconformance=disabled?): differential skipped"
    : > "$t/diff.tsv"
  fi
  # group: signature -> count, smallest input, bucket
  {
    awk -F'\t' '{print "crash\t" $3 "\t" $1 "\t" $2}' "$t/crash-sigs.tsv"
    awk -F'\t' '$2 != "AGREE" {print "diff\t" $3 "\t" 0 "\t" $1}' "$t/diff.tsv" |
      while IFS=$'\t' read -r k s _ f; do printf '%s\t%s\t%s\t%s\n' "$k" "$s" "$(stat -c %s "$f")" "$f"; done
  } | sort -t$'\t' -k1,2 -k3,3n | awk -F'\t' '
      { key = $1 "\t" $2; n[key]++; if (!(key in best)) best[key] = $4 }
      END { for (k in n) print n[k] "\t" k "\t" best[k] }' | sort -t$'\t' -k2,2 -k1,1rn > "$t/groups.tsv"
  local agree=$(awk -F'\t' '$2 == "AGREE"' "$t/diff.tsv" | wc -l) total=$(wc -l < "$t/diff.tsv")
  : > "$t/summary.txt"
  while IFS=$'\t' read -r n k s f; do
    printf '%s\t%s\t%s\t%s\t%s\n' "$(bucket "$s" "$f")" "$k" "$n" "$s" "$f"
  done < "$t/groups.tsv" | sort -t$'\t' -k1,1 -k2,2 > "$t/buckets.tsv"
  {
    echo "== fuzz triage ($t)"
    echo "crash inputs: $(wc -l < "$t/crashes.list"), signatures: $(awk -F'\t' '$2=="crash"' "$t/buckets.tsv" | wc -l)"
    echo "differential: $total checked, $agree agree with bash, $(awk -F'\t' '$2=="diff"' "$t/buckets.tsv" | wc -l) signatures"
    echo "-- NEW (not in tools/fuzz/known.tsv): kind count signature -> smallest input"
    awk -F'\t' '$1=="NEW" {printf "  %-5s %4d  %s\n        %s\n", $2, $3, $4, $5}' "$t/buckets.tsv"
    # A *-fixed known.tsv entry still matched: its pattern is usually just a loose bash-
    # error substring, so this could be the same bug back, or an unrelated NEW one wearing
    # the same generic wording. Never silently bucketed -- surfaced for a human to check.
    echo "-- regression or variant of a FIXED finding (known.tsv): kind count signature -> smallest input"
    awk -F'\t' '$1 ~ /:FIXED$/ {id=$1; sub(/:FIXED$/, "", id); printf "  %-5s %4d  regression or variant of %s (fixed): %s\n        %s\n", $2, $3, id, $4, $5}' "$t/buckets.tsv"
    echo "-- known buckets: id kind signatures inputs"
    awk -F'\t' '$1!="NEW" && $1 !~ /:FIXED$/ {s[$1 " " $2]++; c[$1 " " $2]+=$3} END {for (k in s) printf "  %-14s %4d %5d\n", k, s[k], c[k]}' "$t/buckets.tsv" | sort
    if ls "$W/gram-hangs" 2>/dev/null | grep -q .; then
      echo "-- inputs the grammar mutator's parser pass hung or died on: $W/gram-hangs ($(ls "$W/gram-hangs" | wc -l))"
    fi
  } | tee "$t/summary.txt"
}

campaign() {
  command -v afl-fuzz > /dev/null || die "afl-fuzz not on PATH"
  [ -x "$FUZZ_BIN/harness" ] || die "no harness in $FUZZ_BIN (build the fuzz target via meson)"
  local secs=${FUZZ_SECONDS:-${FUZZ_DEFAULT_SECONDS:-1800}}
  local inst=${FUZZ_INSTANCES:-gram:tiered byte:tiered} n=0 pids=() spec
  local avail=$(df -Pk "$W" | awk 'NR==2 {print $4}')
  [ "${avail:-0}" -gt 1048576 ] || die "less than 1 GB free under $W"
  [ -d "$W/seeds" ] || seeds
  touch "$W/.campaign-start"
  for spec in $inst; do
    n=$((n + 1)); [ $n -le 2 ] || die "at most 2 instances (FUZZ_INSTANCES=$inst)"
    local mut=${spec%%:*} mode=${spec#*:}
    say "instance $spec for ${secs}s: queue $W/out/$mut-$mode, log $W/$mut-$mode.log"
    run "$mut-$mode" "$secs" "$mut" "$mode" &
    pids+=($!)
  done
  # (each instance is bounded by its own timeout; this wait is bounded by theirs)
  wait "${pids[@]}"
  for spec in $inst; do
    local s=$W/out/${spec%%:*}-${spec#*:}/default/fuzzer_stats
    [ -f "$s" ] && say "$spec: $(awk -F' *: *' '$1 ~ /^(execs_done|execs_per_sec|corpus_count|edges_found|saved_crashes|saved_hangs)$/ {printf "%s=%s ", $1, $2}' "$s")"
  done
  triage "$W/.campaign-start"
}

case ${1:-campaign} in
  campaign) campaign ;;
  triage) triage "${2:-}" ;;
  seeds) seeds ;;
  run) shift; run "$@" ;;
  *) die "usage: fuzz.sh campaign | triage [SINCE-FILE] | seeds | run NAME SECONDS gram|byte MODE" ;;
esac
