#!/bin/bash
# Crash signature of ONE input: re-run it through harness-plain (the fuzz loop's runner,
# no coverage) and fold the oracle's report into a stable one-liner (bundle lines mapped
# to module:line, line numbers and quoted delimiters folded).
#   sig.sh FILE   ->  "SIZE<TAB>FILE<TAB>SIGNATURE"
# Env: FUZZ_BIN, FUZZ_WORK, FUZZ_ROOT, FUZZ_ORACLE (bash, for the targeted fuzzers),
#      FUZZ_MODE (default: from the queue dir's name: tiered interp compiled, tiers, or a
#      targeted fuzzer: arith pexp printf glob read regex parse).
set -u
f=$1 B=${FUZZ_BIN:?} W=${FUZZ_WORK:?} R=${FUZZ_ROOT:?}
here=$R/tools/fuzz
D=$W/sbx/sig; mkdir -p "$D"
# (the mode of the instance that found it: out/MUTATOR-MODE/default/crashes/…)
mode=${FUZZ_MODE:-}
[ -z "$mode" ] && { mode=$(printf '%s' "$f" | sed -nE 's#.*/out/[a-z]+-([a-z]+)/.*#\1#p'); : "${mode:=tiered}"; }
tmo=5
case $mode in
  tiered|interp|compiled) menv=(FUZZ_MODE=$mode) ;;
  tiers) menv=(FUZZ_MODE=tiered FUZZ_ORACLE=tiers FUZZ_KNOWN=$here/known.tsv); tmo=20 ;;
  *) menv=(FUZZ_TARGET=$mode FUZZ_TARGETS_LUA=$here/targets.lua FUZZ_BASH=${FUZZ_ORACLE:?}); tmo=10 ;;
esac
# (the crash re-runs in harness-plain: one fork per input, never the persistent loop -- a
# targeted crash that doesn't reproduce here needed the loop's earlier inputs: no-repro)
# (own user+pid namespace: a `kill -9 -1` reaches only this run)
o=$( (ulimit -f 2048; exec unshare -Urpf --kill-child env FUZZ_SBX="$D" "${menv[@]}" timeout -k 2 $tmo "$B/harness-plain") < "$f" 2>&1 >/dev/null); rc=$?
if [ $rc = 124 ] || [ $rc = 137 ]; then sig="TIMEOUT(${tmo}s)"
elif [ $rc != 134 ]; then sig="no-repro(rc=$rc)"
elif l=$(printf '%s\n' "$o" | grep -a -m1 -E '^FUZZ-ORACLE (tiers:|target )'); [ -n "$l" ]; then
  # in-loop differential: KIND|< expected line|> curse line (digits, the sandbox path folded)
  lt=$(printf '%s\n' "$o" | grep -a -m1 '^FUZZ-ORACLE < ' | cut -c15-)
  gt=$(printf '%s\n' "$o" | grep -a -m1 '^FUZZ-ORACLE > ' | cut -c15-)
  k=$(printf '%s' "$l" | sed -E 's/^FUZZ-ORACLE tiers: ([a-z]+) ([a-z]+) differs.*/tiers:\1:\2/; s/^FUZZ-ORACLE tiers: the ([a-z]+) worker crashed.*/tiers:\1:crash/; s/^FUZZ-ORACLE target ([a-z]+): ([a-z]+) differs.*/target:\1:\2/')
  sig=$(printf '%s|< %s|> %s' "$k" "$lt" "$gt" | sed -E "s#$D/[^ :]*#S#g; s/line [0-9]+/line N/g; s/[0-9]+/N/g")
  sig=${sig:0:240}
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
