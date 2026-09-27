# A job the shell has just killed (set -m): bash sees it end only when SIGCHLD reaps it, so
# builtins right after the kill still find it (fg prints it and waits: stress test
# jobs-kill-then-fg, where bash's own race — about 1 in 1000 — can be allowed for). Here,
# the cases where bash has certainly heard SIGCHLD by the next builtin, so each line is
# fixed: `wait $!` on the next line, a `kill -0` polling loop that must end, `read -t`, a
# busy loop of builtins, an external command run between — each lasting until the process
# has died (ended: /proc says Z, or it is gone — bash reaped it), however slow a loaded
# machine is to run it. And a job stopped before the SIGTERM (seen stopped), which cannot
# die until fg continues it: fg prints it, 143.
set -m
T=$(mktemp)
ended() { local s=; read -r _ _ s _ 2>/dev/null </proc/$1/stat || return 0; [ "$s" = Z ]; }
f=$(mktemp -u); mkfifo "$f"; exec 3<>"$f"; rm -f "$f"
sleep 5 & kill $!
wait $!; echo "wait on the next line: $?"
sleep 5 & p=$!; kill $p; n=0; while kill -0 $p 2>/dev/null && [ $((n += 1)) -lt 2000000 ]; do :; done
[ "$n" -lt 2000000 ] && echo "kill -0 loop: ended" || echo "kill -0 loop: never ended"
wait $p; echo "then wait: $?"
sleep 5 & p=$!; kill %%; n=0; until read -t 0.2 -r _ <&3; ended $p || [ $((n += 1)) -gt 100 ]; do :; done; jobs %% >"$T" 2>&1; read -r _ s _ <"$T"; echo "after read -t: ${s:-gone}"
sleep 5 & p=$!; kill %%; s0=${EPOCHREALTIME/[.,]/}; while [ $((${EPOCHREALTIME/[.,]/} - s0)) -lt 200000 ] || ! ended $p; do :; done; jobs %% >"$T" 2>&1; read -r _ s _ <"$T"; echo "after a busy loop: ${s:-gone}"
W='until [ ! -e /proc/$1 ] || grep -q "^State:.Z" /proc/$1/status 2>/dev/null; do :; done'
sleep 5 & kill %%; /bin/sh -c "$W" _ $!; fg; echo "fg after an external: $?"
f() { sleep 5 & kill %%; /bin/sh -c "$W" _ $!; jobs; echo "in a function: $?"; }
f
eval 'sleep 5 & kill %%; /bin/sh -c "$W" _ $!; fg'; echo "in eval: $?"
sleep 5 &
kill -STOP %%
n=0; until read -r _ _ s _ </proc/$!/stat; [ "$s" = T ] || [ $((n += 1)) -gt 200000 ]; do :; done
kill $!
/bin/true
fg; echo "stopped, TERM pending, fg: $?"
jobs; echo "table empty"
rm -f "$T"
