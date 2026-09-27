#@ guards: job control in a script (set -m): SIGSTOP/SIGCONT of jobs, fg/bg, `jobs -s`/`jobs -r`, kill %N, wait on a stopped job, and jobs still STOPPED when the shell exits (none may be left behind: the kernel's orphaned-pgrp SIGHUP+SIGCONT must reach them) — the stopped-job root causes of b491008/512b4fd and test 2200-sig-jobs; and $! naming a real process externals can see
#@ timeout: 30
set -m
f=${TMPDIR:-/tmp}/jc.$$; mkfifo "$f"; exec 3<>"$f"; rm -f "$f"
# until `jobs -s` (stopped) or `jobs -r` (running) lists job $2 — state changes arrive
# asynchronously (SIGCHLD), so poll with a bound
# (jobs are named by a unique word of their command, %?WORD: job NUMBERS depend on when
# the previous job left the table, which is asynchronous even in bash)
jstate() { local k; for ((k = 0; k < 300; k++)); do [ -n "$(jobs $1 "%?$2" 2>/dev/null)" ] && return 0; /bin/sleep 0.01; done; return 1; }
/bin/sleep 5 & p=$!
echo "\$! of an external job is a real process: $(ps -o pid= -p $p >/dev/null && echo yes || echo no)"
kill %?5; wait %?5
{ echo r >&3; exec /bin/sleep 31; } & read -r _ <&3
kill -STOP %?31; jstate -s 31 && echo "stopped"
jobs -s | sed 's/^[^ ]* *//; s/  */ /g'
kill -CONT %?31; jstate -r 31 && echo "continued"
jobs -s | wc -l | tr -d ' '
kill %?31; wait %?31; echo "killed st=$?"
echo "-- a stopped job continued with bg, then brought to the foreground"
{ read -r x <&3; echo "job got $x"; exit 5; } &
kill -STOP %?exit; jstate -s exit && echo stopped
bg %?exit >/dev/null; jstate -r exit && echo "running again"
echo go >&3
fg %?exit >/dev/null; echo "fg st=$?"
echo "-- wait on a stopped job returns 128+SIGSTOP (job control on)"
{ echo r >&3; exec /bin/sleep 32; } & read -r _ <&3
kill -STOP %?32; jstate -s 32 && echo stopped
wait %?32; echo "wait stopped st=$?"
kill -KILL %?32
echo "-- jobs stopped when a (sub)shell exits are not left behind"
# (each job says "ready" once it runs — after its setpgid — before it is stopped: a STOP
# landing between fork and setpgid leaves the child in the script's own process group,
# which never becomes orphaned, so even bash would leave it stopped forever)
( set -m
  { echo r >&3; exec /bin/sleep 33; } & read -r _ <&3; kill -STOP %?33
  { echo r >&3; exec /bin/sleep 34; } & read -r _ <&3; kill -STOP %?34
  exit 0 )
echo "subshell exited"
exec 3>&-
"$STH" probe
