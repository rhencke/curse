#@ guards: a job just killed is still there for the builtins right after the kill (oil prompt#28 under full-gate load): `kill %%; fg` / `kill %%` then `fg` on the next line (top level, a function, eval) print the job's command and wait for it (143), `kill %%; jobs %%` lists it Running — as bash, whose SIGCHLD reaps it only after its builtins ran, decides nearly every time (its own race: about 1 in 1000 here, so the verdict allows 5 misses in 600) — while `wait $!` on the next line, a `kill -0` polling loop, a `read -t` and a busy loop after the kill all see it end (rt.job_signalled / jobs_skip)
#@ timeout: 60
set -m
T=${TMPDIR:-/tmp}/kf.$$
f=${TMPDIR:-/tmp}/kf.fifo.$$; mkfifo "$f"; exec 3<>"$f"; rm -f "$f"
N=150
fn() { sleep 5 & kill %%; fg >/dev/null 2>&1; }
miss=0 waited=0
for ((k = 0; k < N; k++)); do
	sleep 5 & kill %%; fg >/dev/null 2>&1; [ $? = 143 ] || miss=$((miss + 1))
	fn; [ $? = 143 ] || miss=$((miss + 1))
	eval $'sleep 5 &\nkill %%\nfg >/dev/null 2>&1'; [ $? = 143 ] || miss=$((miss + 1))
	sleep 5 & kill %%; jobs %% >"$T" 2>&1; read -r _ s _ <"$T"; [ "$s" = Running ] || miss=$((miss + 1)); wait %% 2>/dev/null
	sleep 5 & kill $!
	wait $!; [ $? = 143 ] && waited=$((waited + 1))
done
[ "$miss" -le 5 ] && echo "kill, then fg / jobs: the job still running: ok" || echo "kill, then fg / jobs: found the job ended $miss times in $((4 * N))"
echo "kill \$!, then wait \$! on the next line: $waited of $N got 143"

echo "-- time in which bash hears SIGCHLD: the job is seen ended"
sleep 5 & p=$!; kill $p; n=0; while kill -0 $p 2>/dev/null && [ $((n += 1)) -lt 2000000 ]; do :; done
[ "$n" -lt 2000000 ] && echo "kill -0 loop: ended" || echo "kill -0 loop: never ended"
wait $p 2>/dev/null
sleep 5 & kill %%; read -t 0.2 -r _ <&3; jobs %% >"$T" 2>&1; read -r _ s _ <"$T"; echo "after read -t: ${s:-gone}"
wait %% 2>/dev/null
sleep 5 & kill %%; s0=${EPOCHREALTIME/[.,]/}; while [ $((${EPOCHREALTIME/[.,]/} - s0)) -lt 200000 ]; do :; done; jobs %% >"$T" 2>&1; read -r _ s _ <"$T"; echo "after a busy loop: ${s:-gone}"
wait %% 2>/dev/null
sleep 5 & kill %%; /bin/true; fg >/dev/null 2>&1; echo "fg after an external: $?"
rm -f "$T"
