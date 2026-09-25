# kill.def / wait.def / jobs.def / fg_bg.def (+ get_job_spec in builtins/common.c,
# kill_pid in jobs.c): option parsing, signal-spec decoding, job specs
# (%N %+ %- %% %str %?str, ambiguity), statuses and diagnostics.
# PIDs are normalized away; every background job is waited on or reaped before
# anything about it is printed.
e() { "$@" 2>&1 | sed -e 's/^.*line [0-9]*: //' -e 's/[0-9][0-9][0-9][0-9]*/N/g'; echo "st=${PIPESTATUS[0]}"; }
n() { sed -e 's/^.*line [0-9]*: //' -e 's/[0-9][0-9][0-9][0-9]*/N/g' err; }
# (no pipeline: job specs must be resolved by this shell, not a subshell)
j() { "$@" >out 2>err; echo "st=$?"; cat out; n; }
# wait until the shell has reaped background pid $1
reaped() { local i=0; while kill -0 "$1" 2>/dev/null && [ $i -lt 300 ]; do i=$((i+1)); sleep 0.01; done; }

# --- kill -l / -L: case-insensitive names, trap pseudo-signals, options after -l
e kill -l hup sigint SiGqUiT
e kill -l EXIT DEBUG ERR RETURN
e kill -l -- 9
e kill -l 0x9
e kill -l ''
e kill -L -9 | head -1
e kill -l -INT | head -1
e kill -l -l | head -1

# --- kill: -sNAME / -nNUM glued forms, only the FIRST -sigspec is an option
e kill -sTERM 99999999
e kill -n9 99999999
e kill -sigterm 99999999
e kill -sTERM
e kill -0 -CONT $$
e kill -
e kill --help | head -1
e kill -? 1
e kill -s EXIT 99999999
# pids that do not fit a pid_t are not pids
e kill -0 99999999999
e kill -0 9999999999999999999999
# CONTINUE_AFTER_KILL_ERROR: status is 0 if any target succeeded
e kill -0 99999999 $$
e kill -0 abc $$
e kill -0 %7 $$
set -o posix
e kill -SIGTERM 99999999
e kill -l SIGINT
set +o posix

# --- job specs
sleep 5 & sleep 6 &
j kill -0 %?5
j kill -0 %?SLEEP
j kill -0 %sleep
j kill -0 %sl
j kill -0 %%junk
j kill -0 %+junk
j kill -0 %
j kill -0 %2 %1 %3
j jobs %1
j jobs %-
j jobs %?6
j jobs %sleep
j jobs %1 %9
j jobs -l -x echo
kill %1 %2; wait %1; echo "w1=$?"; wait %2; echo "w2=$?"
sleep 1 | cat &
j kill -0 %cat
kill %1; wait %1; echo "pipe=$?"
j jobs %1

# --- Done / Exit N / killed entries in `jobs`, and kill of a finished job
(exit 3) & p=$!; reaped $p
true & p=$!; reaped $p
# (whether bash still marks an already-reaped job current (+) races its SIGCHLD handling:
# the markers here are left out)
jobs >out; sed 's/^\(\[[0-9]*\]\)[+-]/\1 /' out
jobs; echo "listed once"
(exit 4) & p=$!; reaped $p
kill %1; echo "kill-done=$?"
kill -0 %1; echo "kill0-done=$?"
wait %1; echo "wait-done=$?"

# --- wait
e wait 12abc
e wait -p 1bad
(exit 2) & b=$!
wait 12abc $b 2>err; echo "badpid-stops=$?"; n
wait $b; echo "b=$?"
v=keep; wait -p v; echo "v=${v-unset}"
v=keep; wait -p v 99999999 2>/dev/null; echo "v2=${v-unset}"
v=keep; wait -n -p v 2>/dev/null; echo "v3=${v-unset}"
# a trapped signal interrupts wait: status 128+sig, then the trap runs
trap 'echo got-usr1' USR1
sleep 1 & s=$!
{ sleep 0.1; kill -USR1 $$; } &
wait $s; echo "intr=$?"
kill $s; wait $s; echo "s=$?"
trap - USR1
wait
# async commands start with SIGINT ignored (no job control)
(trap -p INT) &
wait
e fg
e bg %1
