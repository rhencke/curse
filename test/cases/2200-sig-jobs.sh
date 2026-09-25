# sig.c + jobs.c (notify_of_job_status, wait_for, wait_for_single_pid, bgpids),
# with execute_cmd.c async-signal setup and subst.c's comsub SIGINT relay:
# termsig messages for children killed by signals (bare "Terminated", the
# "line N: PID Killed  cmd" form, when bash stays silent), death by a signal
# (EXIT trap first, 128+n), SIGQUIT ignored by the shell but not by subshells,
# signals ignored at entry, SIGINT ignored in async commands, SIGPIPE with PIPE
# ignored, wait/disown/jobs corners, %job as a command, the CHLD trap.
# All diagnostics go to ./msgs (append mode) and are printed, normalized, by m.
exec 2>>msgs
m() { sed -e 's/^.*\(line [0-9]*:\) [0-9]* /\1 PID /' -e 's/^[^ ]*: line [0-9]*: //' \
        -e 's/[0-9][0-9][0-9][0-9]*/N/g' msgs; : >msgs; }
S=${THIS_SH:-bash}
r() { local i=0; while kill -0 "$1" 2>/dev/null && [ $i -lt 50 ]; do i=$((i+1)); sleep 0.01; done; }

# --- foreground child killed: TERM is bare, INT/PIPE silent, others line+pid+cmd
sh -c 'kill -TERM $$'; echo "term=$?"; m
sh -c 'kill -INT $$'; echo "int=$?"; sh -c 'kill -PIPE $$'; echo "pipe=$?"; m
sh -c 'kill -KILL $$'; echo "kill=$?"; m
sh -c 'kill -HUP $$' 2>/dev/null; echo "hup=$?"; m
sh -c 'ulimit -c 0; kill -SEGV $$'; echo "segv=$?"; m
sh -c 'kill -USR1 $$' | cat; echo "lhs=${PIPESTATUS[*]}"; m
cat </dev/null | sh -c 'kill -USR1 $$'; echo "rhs=${PIPESTATUS[*]}"; m
set -o pipefail; sh -c 'kill -KILL $$' | cat; echo "pf=$?"; set +o pipefail; m
# a signal the shell traps (or ignores) is reported bare (or not at all)
trap 'echo usr1' USR1; sh -c 'kill -USR1 $$'; echo "tr=$?"; trap - USR1; m
trap '' USR2; sh -c 'kill -USR2 $$'; echo "ign=$?"; trap - USR2; m
# the message is written with the function's redirections still active
f() { sh -c 'kill -KILL $$'; }; f 2>/dev/null; echo "f=$?"; m
x=$(sh -c 'kill -KILL $$'; echo "in=$?"); echo "cs [$x]"; m
( sh -c 'kill -KILL $$'; echo "in=$?" ); m

# --- subshells killed by a signal: EXIT trap runs first; SIGKILL runs nothing
( trap 'echo sub-exit' EXIT; kill -TERM $BASHPID; echo no ); echo "a=$?"; m
( trap 'echo sub-exit' EXIT; kill -HUP $BASHPID; echo no ); echo "b=$?"; m
( trap 'echo sub-exit' EXIT; kill -KILL $BASHPID; echo no ); echo "c=$?"; m
( kill -QUIT $BASHPID; echo no ); echo "quit=$?"; m
trap 'echo parent' USR1; ( kill -USR1 $BASHPID; echo no ); echo "d=$?"; trap - USR1; m
x=$(trap 'echo cs-exit' EXIT; kill -HUP $BASHPID; echo no); echo "cs=$? [$x]"; m

# --- a child shell killed by a signal: EXIT trap, 128+n; QUIT is ignored
for s in TERM HUP USR1 ALRM PIPE QUIT; do
  $S -c "trap 'echo exit-trap' EXIT; kill -$s \$\$; echo survived-$s"; echo "$s=$?"
done 2>/dev/null
# signals ignored at entry stay ignored; trap can't change them, -p shows them
trap '' USR1 TERM
$S -c 'trap -p; trap "echo x" USR1; trap - TERM; kill -USR1 $$; kill -TERM $$; echo alive'
trap - USR1 TERM

# --- async commands ignore SIGINT and SIGQUIT (not a backgrounded function)
( trap -p INT; kill -INT $BASHPID; kill -QUIT $BASHPID; echo survived ) & wait $!; echo "bg=$?"
( trap - INT; kill -INT $BASHPID; echo no ) & wait $!; echo "bg2=$?"
sh -c 'kill -INT $$; echo sh-survived' & wait $!; echo "bg3=$?"
g() { kill -INT $BASHPID; echo no; }; g & wait $!; echo "bgfn=$?"; m

# --- background job killed: reported at wait (not TERM, not a trapped signal)
sleep 5 & kill -KILL $!; wait $!; echo "w=$?"; m
sleep 5 & kill $!; wait $!; echo "w=$?"; m
trap 'echo usr2' USR2; sh -c 'kill -USR2 $$' & wait $!; echo "w=$?"; trap - USR2; m
# ...or as soon as it is reaped; the reported job leaves the table
sleep 5 & p=$!; kill -KILL $p; r $p; /bin/true; echo reaped; jobs; m | sed "s/line [0-9]*/line N/"

# --- SIGPIPE: ignored PIPE turns into a write error, status 1
{ printf '%070000d\n' 0; echo "after=$?" >&2; } | head -c1 >/dev/null; echo "p=${PIPESTATUS[*]}"; m
trap '' PIPE
{ printf '%070000d\n' 0; echo "after=$?" >&2; } | head -c1 >/dev/null; echo "p=${PIPESTATUS[*]}"; m
{ echo "$(printf '%070000d' 0)"; echo "after=$?" >&2; } | head -c1 >/dev/null; echo "p=${PIPESTATUS[*]}"; m
trap - PIPE

# --- the CHLD trap runs for async jobs too
c=0; trap 'c=$((c+1))' CHLD; (exit 1) & wait; true; /bin/true; trap - CHLD; echo "chld=$c"

# --- wait: subshells have no children/bgpids of their parent; posix mode forgets
(exit 4) & p=$!; wait $p; echo "p=$?"
( wait $p; echo "sub=$?" ); x=$(wait $p; echo "cs=$?"); echo "$x"; m
sleep 1 & q=$!; ( wait $q; echo "subwait=$?" ); kill $q; wait $q; echo "q=$?"; m
set -o posix; (exit 3) & p=$!; wait $p; wait $p; echo "posix=$?"; set +o posix; m
sh -c 'sleep 0.05; exit 3' & p=$!; disown; wait $p; echo "disowned=$?"
( sleep 0.01 & jobs; jobs -n; wait ) | sed 's/[0-9]\{3,\}/N/'; m

# --- %job as a command (fg/bg without job control)
sleep 5 & p=$!; %sleep; echo "pct=$?"; %1 2>&1 | sed 's/^.*line [0-9]*: //'; kill $p; wait $p; echo "p=$?"; m

# --- a comsub killed by SIGINT makes the shell SIGINT itself (trap runs; else dies)
trap 'echo int-trap' INT; x=$(kill -INT $BASHPID); echo "csint=$?"; trap - INT; m
x=$(sh -c 'kill -INT $$'); echo "not reached"
