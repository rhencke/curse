# overrides: #### kill -15 %% kills current job
# oil spec/builtin-kill.test.sh case 16, made deterministic. Upstream kills the job, echoes,
# and reads `wait %%` from the NEXT line; bash 5.2.21 reads each script line through
# shell_getc, whose notify_and_cleanup marks a job SIGTERM killed as notified (not printed:
# DONT_REPORT_SIGTERM) and deletes it — if SIGCHLD has reaped it by then. So `wait %%` says
# 143 only while the dying `sleep` is slower than bash reading two lines; a few ms of
# builtins between (`x=0; while [ $x -lt 3000 ]; do x=$((x+1)); done`) and bash itself says
# "%%: no such job", 127. Here the kill, the echo and the first wait share a line, so no
# notify_and_cleanup runs between them: 143 by construction. Everything upstream checks is
# still checked: `kill -15 %%` succeeds, `wait %%` returns the TERM status, and the job is
# then gone (no such job, 127).

sleep 0.5 &
pid=$!
kill -15 %%; echo kill=$?; wait %%; echo wait=$?

# no such job
wait %%
echo wait=$?
