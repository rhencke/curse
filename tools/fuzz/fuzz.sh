#!/bin/bash
# AFL++ fuzzing of curse (tools/fuzz/README.md). Normally run by meson:
#   meson compile -C build fuzz          a campaign, then triage of what it found
#   meson compile -C build fuzz-triage   triage everything in the persistent queue again
# or directly (the env meson sets is derived from the repo layout otherwise):
#   fuzz.sh campaign | triage [SINCE] | seeds | run NAME SECONDS MUTATOR MODE
#
# Env knobs:
#   FUZZ_SECONDS    campaign wall time (default: -Dfuzz_seconds, 1800)
#   FUZZ_INSTANCES  up to 2 of MUTATOR:MODE, MUTATOR gram|byte, MODE tiered|interp|compiled
#                   (default "gram:tiered byte:tiered")
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

dicts() {
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
for f in sorted(glob.glob(oil + "/*.test.sh")):
    for part in re.split(rb"(?m)^#### .*$", open(f, "rb").read())[1:]:
        body = b"\n".join(l for l in part.split(b"\n") if not l.startswith(b"## "))
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

# ---- one afl-fuzz instance, in the foreground, for SECONDS
run() { # NAME SECONDS MUTATOR MODE
  local name=$1 secs=$2 mut=$3 mode=$4
  local out=$W/out/$name sbx=$W/sbx/$name
  mkdir -p "$out" "$sbx" "$W/gram-hangs"
  [ -d "$W/seeds" ] || seeds
  afl_env
  export FUZZ_SBX=$sbx FUZZ_MODE=$mode
  local -a extra=()
  case $mut in
    gram)
      export AFL_CUSTOM_MUTATOR_LIBRARY=$FUZZ_BIN/gram_mutator.so GRAM_LUAJIT=$FUZZ_LUAJIT \
        GRAM_ROOT=$FUZZ_ROOT GRAM_STATS=$out/gram_stats GRAM_HANGS=$W/gram-hangs ;;
    byte) unset AFL_CUSTOM_MUTATOR_LIBRARY ;;
    *) die "mutator: gram or byte, not $mut" ;;
  esac
  mapfile -t extra < <(dicts)
  # (afl-fuzz -V ends the run itself, stats written; the timeout is only a safety net)
  timeout -s TERM -k 60 "$((secs + 300))" bash -c "$(declare -f in_ns); in_ns \"\$@\"" in_ns \
    afl-fuzz -V "$secs" -i "$W/seeds" -o "$out" -t 2000 -m none "${extra[@]}" -- "$FUZZ_BIN/harness" \
    > "$W/$name.log" 2>&1
  return 0
}

# ---- triage: crash signatures + differential signatures, bucketed against known.tsv
bucket() { # SIG FILE -> ID or NEW
  local sig=$1 f=$2 id field re re2
  while IFS=$'\t' read -r id field re re2; do
    case $id in ''|'#'*) continue ;; esac
    case $field in
      sig) printf '%s\n' "$sig" | grep -qE -- "$re" && { echo "$id"; return; } ;;
      src) grep -qaE -- "$re" "$f" && { echo "$id"; return; } ;;
      both) printf '%s\n' "$sig" | grep -qE -- "$re" && grep -qaE -- "$re2" "$f" && { echo "$id"; return; } ;;
    esac
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
  find "$W"/out/*/default/queue -maxdepth 1 -type f -name 'id:*' "${newer[@]}" 2>/dev/null > "$t/queue.all"
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
    echo "-- known buckets: id kind signatures inputs"
    awk -F'\t' '$1!="NEW" {s[$1 " " $2]++; c[$1 " " $2]+=$3} END {for (k in s) printf "  %-14s %4d %5d\n", k, s[k], c[k]}' "$t/buckets.tsv" | sort
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
