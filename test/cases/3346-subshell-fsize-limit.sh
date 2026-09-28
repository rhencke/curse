# A file-size limit set in a subshell or $(…) ends only that subshell when a builtin
# writes past it (bash: SIGXFSZ, status 153, reported; the script goes on). curse runs
# them in-process, so the whole script died of SIGXFSZ (stress-attack S24, the S21 class).
# Each run is under a KILL-timeout, like 3317 (through the daemon a caught signal may leave
# the request running).
run() { timeout -s KILL 8 $THIS_SH -c "$1" 2>&1 | sed -E 's/^.*line [0-9]+: +[0-9]+ /E: /'; echo "status ${PIPESTATUS[0]}"; }
run '( ulimit -f 1; printf "%010000d" 0 > big ) 2> /dev/null; echo "subshell: $?"; echo goes on'
run 'x=$(ulimit -f 1; printf "%010000d" 0 > big; echo in) 2> /dev/null; echo "comsub: $? [$x]"; echo goes on'
run '( ulimit -f 1; head -c 10000 /dev/zero > big ) 2> /dev/null; echo "external: $?"'
rm -f big
