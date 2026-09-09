#!/usr/bin/env bash
# Compare the LuaJIT backend to the JS/Node AOT backend and bash, in the
# curse-dev container (node 24, bash 5.2.37) + a built LuaJIT.
#   ./x bash /work/lua/bench.sh [script.sh ...]     (defaults to bench/arith.sh)
# Needs $CURSE_LUAJIT (default /work/.bench-lua/luajit).
set -u
LJ="${CURSE_LUAJIT:-/work/.bench-lua/luajit}"
CLI=/work/src/cli/curse.mts
RUNS=${RUNS:-6}
cd /work

now_ns() { date +%s%N; }
best_ms() {  # best-of-RUNS wall ms
  local best=99999999 t0 t1 d
  for ((r = 0; r < RUNS; r++)); do
    t0=$(now_ns); "$@" >/dev/null 2>&1; t1=$(now_ns)
    d=$(( (t1 - t0) / 1000000 )); (( d < best )) && best=$d
  done
  echo "$best"
}
x() { awk "BEGIN{ if ($2>0) printf \"%.1f\", $1/$2; else print \"-\" }"; }

scripts=("$@"); [ ${#scripts[@]} -eq 0 ] && scripts=(/work/bench/arith.sh)

echo "backend perf — execute wall-time, best of $RUNS (ms), and xbash / xjs"
printf '%-16s | %8s %8s %8s %8s %8s\n' "script" "bash" "curse-JS" "lua-int" "lua-comp" "lua-tier"
printf '%-16s | %8s %8s %8s %8s %8s\n' "------" "----" "--------" "-------" "--------" "--------"

for s in "${scripts[@]}"; do
  name=$(basename "$s")
  mts="/tmp/$name.mts"
  node "$CLI" transpile "$s" > "$mts" 2>/dev/null

  b=$(best_ms bash "$s")
  js=$(best_ms node "$mts")
  li=$(best_ms "$LJ" lua/run.lua "$s" interp)
  lc=$(best_ms "$LJ" lua/run.lua "$s" compiled)
  lt=$(CURSE_LUAJIT="$LJ" best_ms "$LJ" lua/run.lua "$s" tiered)

  printf '%-16s | %8s %8s %8s %8s %8s\n' "$name" "$b" "$js" "$li" "$lc" "$lt"
  printf '%-16s | %8s %8s %8s %8s %8s   (xbash)\n' "" "1.0" "$(x "$b" "$js")" "$(x "$b" "$li")" "$(x "$b" "$lc")" "$(x "$b" "$lt")"
  printf '%-16s | %8s %8s %8s %8s %8s   (xJS)\n'   "" "$(x "$js" "$b")" "1.0" "$(x "$js" "$li")" "$(x "$js" "$lc")" "$(x "$js" "$lt")"
done

echo
echo "bare startup, best of $RUNS (ms):"
printf ':\n' > /tmp/e.sh; printf '' > /tmp/e.mjs; printf '' > /tmp/e.lua
printf '  bash %s   node %s   luajit %s\n' \
  "$(best_ms bash /tmp/e.sh)" "$(best_ms node /tmp/e.mjs)" "$(best_ms "$LJ" /tmp/e.lua)"
