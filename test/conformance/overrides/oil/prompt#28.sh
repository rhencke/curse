# overrides: #### \j for number of jobs
# oil spec/prompt.test.sh case 28, made deterministic. Upstream kills the job and runs `fg`
# at once (the next line); whether `fg` still finds the job running is a race in bash
# 5.2.21 itself: the kill returns before the process has died, and bash learns of its death
# only when SIGCHLD arrives (sigchld_handler -> waitchld, at any moment). Seen dead by `fg`
# (start_job's DEADJOB: "fg: job has terminated") or by the reader's notify_and_cleanup
# first (the job deleted: "fg: current: no such job"), "sleep 5" is never printed — about 1
# run in 200 of the oracle's, on the kill's line or the next. Here the job cannot die before
# fg continues it: it is stopped first (and seen stopped: /proc says T, and an external
# command's wait lets SIGCHLD report the stop), then sent SIGTERM with `kill PID` (a plain
# kill(2): no SIGCONT with it, unlike `kill %1` on a stopped job), which stays pending in the
# stopped process. `fg` prints "sleep 5", continues it, and it dies of the TERM. Everything
# upstream checks is still checked: \j counts 0, then 1 with the job running, then 0 once fg
# has waited for it.
set -m # enable job control
PS1='foo \j bar'
echo "${PS1@P}" | egrep -q 'foo 0 bar'
echo matched=$?
sleep 5 &
echo "${PS1@P}" | egrep -q 'foo 1 bar'
echo matched=$?
kill -STOP %%
n=0
until read -r _ _ s _ < /proc/$!/stat; [ "$s" = T ] || [ $((n += 1)) -gt 200000 ]; do :; done
kill $!
/bin/true
fg
echo "${PS1@P}" | egrep -q 'foo 0 bar'
echo matched=$?
