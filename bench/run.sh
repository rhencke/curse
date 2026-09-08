#!/usr/bin/env bash
# Benchmark: original (bash) vs curse's AOT path, run inside the curse-dev
# container:  ./x bash /work/bench/run.sh
#
# Reports three curse costs separately:
#   transpile  — one-time AOT cost (curse transpile script.sh > out.mts)
#   execute    — running the transpiled .mts under node
#   total      — transpile + execute (a cold one-shot run)
# against bash's single cost (running the .sh).
set -u
CLI=/work/src/cli/curse.mts
RUNS=${RUNS:-5}

now_ns() { date +%s%N; }

# best-of-RUNS wall time in milliseconds for a command
best_ms() {
  local best=99999999 t0 t1 d
  for ((r = 0; r < RUNS; r++)); do
    t0=$(now_ns); "$@" >/dev/null 2>&1; t1=$(now_ns)
    d=$(( (t1 - t0) / 1000000 ))
    (( d < best )) && best=$d
  done
  echo "$best"
}
ratio() { awk "BEGIN{ if ($2>0) printf \"%.2f\", $1/$2; else print \"-\" }"; }

printf '%-10s %8s | %9s %8s %7s | %10s %8s   %s\n' \
  "workload" "bash" "transpile" "execute" "exec x" "total" "total x" "match"
printf '%-10s %8s | %9s %8s %7s | %10s %8s   %s\n' \
  "--------" "----" "---------" "-------" "------" "-----" "-------" "-----"

for sh in /work/bench/arith.sh /work/bench/strings.sh /work/bench/funcs.sh /work/bench/startup.sh; do
  name=$(basename "$sh" .sh)
  mts="/work/bench/$name.mts"

  bms=$(best_ms bash "$sh")
  tms=$(best_ms node "$CLI" transpile "$sh")     # transpile-only
  node "$CLI" transpile "$sh" > "$mts" 2>/dev/null
  ems=$(best_ms node "$mts")                      # execute-only
  tot=$(( tms + ems ))                            # cold total

  ob=$(bash "$sh" 2>/dev/null); on=$(node "$mts" 2>/dev/null)
  [[ "$ob" == "$on" ]] && match="yes" || match="NO"

  # ratios are bash/curse: >1 means curse is faster, <1 means bash is faster
  printf '%-10s %7sms | %8sms %7sms %6sx | %9sms %6sx   %s\n' \
    "$name" "$bms" "$tms" "$ems" "$(ratio "$bms" "$ems")" "$tot" "$(ratio "$bms" "$tot")" "$match"
done
echo
echo "exec x / total x are bash_ms / curse_ms  ( >1 = curse faster, <1 = bash faster )"
