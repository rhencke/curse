# overrides: #### \j for number of jobs
# oil spec/prompt.test.sh case 28, made deterministic. Upstream kills the job and reads `fg`
# from the NEXT line; bash 5.2.21 reads each script line through shell_getc, whose
# notify_and_cleanup lists a job a signal killed ([1]+ Terminated, job control on) and
# deletes it — if SIGCHLD has reaped it by then. So `fg` prints "sleep 5" only while the
# dying sleep is slower than bash reading the line; a few ms of builtins between (`x=0;
# while [ $x -lt 3000 ]; do x=$((x+1)); done`) and bash itself says "fg: current: no such
# job". Here the kill and the fg share a line, so no notify_and_cleanup runs between them:
# "sleep 5" by construction. Everything upstream checks is still checked: \j counts 0, then
# 1 with the job running, then 0 once fg has waited for it.
set -m # enable job control
PS1='foo \j bar'
echo "${PS1@P}" | egrep -q 'foo 0 bar'
echo matched=$?
sleep 5 &
echo "${PS1@P}" | egrep -q 'foo 1 bar'
echo matched=$?
kill %%; fg
echo "${PS1@P}" | egrep -q 'foo 0 bar'
echo matched=$?
