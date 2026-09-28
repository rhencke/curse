#!/bin/bash
# Crash signature of ONE input: re-run it through harness-plain (the fuzz loop's runner,
# no coverage) and fold the oracle's report into a stable one-liner (bundle lines mapped
# to module:line, line numbers and quoted delimiters folded).
#   sig.sh FILE   ->  "SIZE<TAB>FILE<TAB>SIGNATURE"
# Env: FUZZ_BIN, FUZZ_WORK, FUZZ_ROOT, FUZZ_MODE (default: from the queue dir's name).
set -u
f=$1 B=${FUZZ_BIN:?} W=${FUZZ_WORK:?} R=${FUZZ_ROOT:?}
D=$W/sbx/sig; mkdir -p "$D"
# (the mode of the instance that found it: out/MUTATOR-MODE/default/crashes/…)
mode=${FUZZ_MODE:-}
[ -z "$mode" ] && case $f in */out/*-interp/*) mode=interp ;; */out/*-compiled/*) mode=compiled ;; *) mode=tiered ;; esac
# (own user+pid namespace: a `kill -9 -1` reaches only this run)
o=$( (ulimit -f 2048; exec unshare -Urpf --kill-child env FUZZ_SBX="$D" FUZZ_MODE="$mode" timeout -k 2 5 "$B/harness-plain") < "$f" 2>&1 >/dev/null); rc=$?
if [ $rc = 124 ] || [ $rc = 137 ]; then sig="TIMEOUT(5s)"
elif [ $rc != 134 ]; then sig="no-repro(rc=$rc)"
else
  # (escaped: that line; stderr oracle: the first line with a Lua-internal message)
  l=$(printf '%s\n' "$o" | grep -a -m1 'FUZZ-ORACLE escaped:')
  [ -z "$l" ] && l=$(printf '%s\n' "$o" | sed -n '/^FUZZ-ORACLE stderr:/,$p' | sed 1d |
    grep -a -m1 -E 'attempt to |bad argument #|stack traceback|table: 0x|function: 0x|not enough memory|stack overflow|internal error|curse[.:][a-z]|[a-z_]{3,}:[0-9]+:')
  # (a recursion's repeated frames -> one; keep the head and the message)
  # (lines of generated chunks depend on the input, not on the engine path: fold them)
  l=$(printf '%s' "$l" | sed -E 's/(curse:(compiled|eval|line)):[0-9]+/\1:N/g')
  l=$(printf '%s' "$l" | awk '{ n = split($0, t, ": "); o = ""
    for (i = 1; i <= n; i++) { if (t[i] ~ /^[a-z_.:]+:[0-9]+$/) { if (seen[t[i]]++) continue }
      o = o (o == "" ? "" : ": ") t[i] }
    print o }')
  l=$(printf '%s' "$l" | sed -E "s/matching \`.'/matching \`X'/; s#$D/[^ :]*#S#g; s/line [0-9]+/line N/g; s/(curse\.bundle:[0-9]+: )\1+/\1/g")
  for n in $(printf '%s' "$l" | grep -oE 'curse\.bundle:[0-9]+' | cut -d: -f2 | sort -u); do
    l=${l//curse.bundle:$n:/$("$R/tools/fuzz/bundle-line.sh" "$n"):}
  done
  sig=${l:0:200}
fi
printf '%s\t%s\t%s\n' "$(stat -c %s "$f")" "$f" "${sig:-crash signal, no oracle message}"
