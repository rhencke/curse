# overrides: #### kill -15 %- kills previous job
# oil spec/builtin-kill.test.sh case 17, made deterministic as #16 is (see its header).
# Upstream reads `wait %-` from a line of its own after `echo kill=$?`: bash 5.2.21's
# shell_getc notify_and_cleanup, reading that line, deletes the SIGTERM-killed job if
# SIGCHLD has reaped it by then, and `%-` then names the other job (wait=0) — bash itself
# says so with a few builtins before that line. Here the kill, the echo and the wait share
# a line, so no notify_and_cleanup runs between them: 143 by construction. What upstream
# checks is still checked: `kill -15 %-` reaches the previous job and succeeds, and
# `wait %-` returns its TERM status.

sleep 0.1 &  # previous job
sleep 0.2 &  # current job

kill -15 %-; echo kill=$?; wait %-; echo wait=$?

wait
echo done
