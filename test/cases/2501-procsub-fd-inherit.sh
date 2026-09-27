# A <()/>() pipe end (/dev/fd/63, …) is open in the shell while its command runs, and
# every process bash forks meanwhile inherits it: an external run by a function or a
# pipeline stage under `f > >(…)` sees 63 too, and a later <() child sees an earlier one's.
# (curse runs those stages and jobs in-process: only its own procsub job must not see its
# own end.) A >() on a function DEFINITION is drained after each call (compiled: once hung).
fds() { ls /proc/self/fd | grep -v '^[0-3]$' | tr '\n' ' '; echo "."; }
f() { ls /proc/self/fd | grep -v '^[0-3]$' | tr '\n' ' '; echo "."; }
f > >(cat); wait
{ ls /proc/self/fd | grep -v '^[0-3]$' | tr '\n' ' '; echo "."; } > >(cat); wait
cat <(f) <(f)
g() { f; } > >(cat)
g; wait; g; wait
fds
for ((i = 0; i < 150; i++)); do x=$(f > >(cat)); y=$(g); done
echo "$x | $y"; fds
