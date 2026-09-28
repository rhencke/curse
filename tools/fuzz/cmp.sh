#!/bin/bash
# Differential check of ONE script in the fuzz sandbox (empty PATH: builtins only,
# read-only fs, private tmpfs cwd, rlimits): the bash 5.2.21 oracle vs curse's interp,
# compiled and tiered modes (harness-plain: the fuzz loop's own runner) and the static
# curse binary (cold start, tiered).
#   cmp.sh SCRIPT       full report (exit 0 = every run agrees with bash)
#   cmp.sh SCRIPT -q    one line: VERDICT<TAB>SIGNATURE   (AGREE when all agree)
# Env: FUZZ_BIN (harness-plain, sbx), FUZZ_CURSE, FUZZ_ORACLE, FUZZ_WORK.
#
# Masking (nondeterminism that is not a bug), applied to every run's stdout+stderr:
#   - the script's sandbox path and a leading `bash: ` -> `S: `
#   - Lua tracebacks: kept out (the first line of the escaped error stays)
#   - runs of 4+ digits -> N (pids, $!, curse's synthetic pids, big counters)
#   - `times`/`time` figures (NmN.NNNs) -> T
#   - job status lines ([n]+ Done/Running/...) are compared as a sorted set, not in order
set -u
S=$1 Q=${2:-}
B=${FUZZ_BIN:?} W=${FUZZ_WORK:?} ORA=${FUZZ_ORACLE:?} CUR=${FUZZ_CURSE:?}
D=$W/sbx/cmp; mkdir -p "$D" "$W/bin"
ln -sf "$CUR" "$W/bin/bash"
T=$(mktemp -d "$W/cmp.XXXXXX")
trap 'rm -rf "$T"' EXIT
mask() {
  sed -i -E "s#^bash: #S: #; s#^$D/s\.sh: #S: #; s#$D/s\.sh#S#g" "$1"
  sed -i -E '/^FUZZ-ORACLE stderr:|^stack traceback|^\t/d; s/^FUZZ-ORACLE escaped: //; s/^.*(curse\.bundle:[0-9]+: )+//' "$1"
  sed -i -E 's/[0-9]+m[0-9]+[.,][0-9]+s/T/g; s/[0-9]{4,}/N/g' "$1"
  { grep -avE '^\[[0-9]+\][-+ ] +(Running|Done|Stopped|Terminated|Exit|Killed)' "$1"
    grep -aE '^\[[0-9]+\][-+ ] +(Running|Done|Stopped|Terminated|Exit|Killed)' "$1" | LC_ALL=C sort; } > "$1.m"
  mv "$1.m" "$1"
}
run() { # name cmd...  (own user+pid namespace: a `kill -9 -1` reaches only that run)
  local n=$1; shift
  (ulimit -f 2048; exec unshare -Urpf --kill-child timeout -k 2 5 "$@") > "$T/$n.out" 2> "$T/$n.err"
  echo $? > "$T/$n.st"
  mask "$T/$n.out"; mask "$T/$n.err"
}
run bash "$B/sbx" "$D" "$S" "$ORA" @S < /dev/null
for m in interp compiled tiered; do
  run $m env FUZZ_SBX="$D" FUZZ_MODE=$m FUZZ_NOCOV=1 FUZZ_KEEPOUT=1 FUZZ_NOORACLE=1 "$B/harness-plain" < "$S"
done
run static "$B/sbx" "$D" "$S" "$W/bin/bash" @S < /dev/null
v="" bad=""
for m in interp compiled tiered static; do
  d=""
  cmp -s "$T/bash.out" "$T/$m.out" || d+="out,"
  cmp -s "$T/bash.err" "$T/$m.err" || d+="err,"
  cmp -s "$T/bash.st" "$T/$m.st" || d+="st,"
  [ -n "$d" ] && { v+="$m:${d%,} "; bad+="$m "; }
done
if [ -n "$Q" ]; then
  if [ -z "$v" ]; then printf 'AGREE\t-\n'; exit 0; fi
  # signature: which runs disagree + the first stderr line where curse (the first
  # disagreeing run) and bash differ, words in quotes/line numbers/digits folded
  m=${bad%% *}
  line=$(diff -a "$T/bash.err" "$T/$m.err" | grep -a -m1 -E '^[<>] ' | cut -c3-)
  [ -z "$line" ] && line=$(diff -a "$T/bash.out" "$T/$m.out" | grep -a -m1 -E '^[<>] ' | sed 's/^\(.\).*/stdout-\1/')
  [ -z "$line" ] && line="status $(cat "$T/$m.st") vs $(cat "$T/bash.st")"
  line=$(printf '%s' "$line" | sed -E "s/line [0-9N]+/line L/g; s/\`[^']*'/\`X'/g; s/[0-9]+/N/g" | cut -c1-160)
  case "$bad" in "interp compiled tiered static ") who=all ;; *) who=${bad% } who=${who// /+} ;; esac
  # (every disagreeing run has bash's status and bash's lines, only in another order:
  # "order-only:" -- the interleaving of async output (jobs, coprocs, process
  # substitutions, pipeline stages) is scheduling, not semantics; known.tsv buckets it
  # when the script has such a construct)
  oo=order-only:
  for m in $bad; do
    cmp -s "$T/bash.st" "$T/$m.st" &&
      cmp -s <(LC_ALL=C sort "$T/bash.out") <(LC_ALL=C sort "$T/$m.out") &&
      cmp -s <(LC_ALL=C sort "$T/bash.err") <(LC_ALL=C sort "$T/$m.err") || oo=
  done
  printf '%s\t%s%s|%s\n' "${v% }" "$oo" "$who" "$line"
  exit 1
fi
for m in bash interp compiled tiered static; do
  echo "---- $m (status $(cat "$T/$m.st"))"
  head -c 1500 "$T/$m.out" | sed 's/^/  out| /'
  head -c 1500 "$T/$m.err" | sed 's/^/  err| /'
done
echo "VERDICT: ${v:-AGREE}"
[ -z "$v" ]
