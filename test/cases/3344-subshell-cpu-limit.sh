# A CPU-time limit set in a subshell ends only that subshell (bash: a process of its own,
# killed when it passes the limit). curse runs the subshell in-process, so the limit is the
# whole shell's: the script itself died of SIGXCPU, status 152; through the daemon the
# request never ended (it wedged the conformance harness), hence the KILL-timeout around
# it (stress-attack S21).
timeout -s KILL 8 $THIS_SH -c '( ulimit -t 1; while :; do :; done ) 2> /dev/null
echo "after the cpu-limited subshell: $?"
echo "the script goes on"'
echo "status $?"
