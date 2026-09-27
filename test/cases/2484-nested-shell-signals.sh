# A signal sent to a nested shell ($THIS_SH as a job) is the nested script's: its trap
# runs — also one that stops a hot compiled loop — and `exit N` in it is the job's status;
# an untrapped TERM kills it (128+15). (curse's daemon client forwards the signals it
# receives to the worker running the script; the worker sends its pid first.)
S=${THIS_SH:-bash}
"$S" -c 'trap "echo \"  TERM trap\"; exit 9" TERM; sleep 0.4; echo after' &
p=$!; sleep 0.15; kill -TERM $p; wait $p; echo "trapped TERM: st=$?"
"$S" -c 'sleep 0.4; echo after' &
p=$!; sleep 0.15; kill -TERM $p; wait $p; echo "untrapped TERM: st=$?"
"$S" -c 'trap "stop=1" USR1; stop=0 n=0; while [ $stop = 0 ]; do n=$((n+1)); done; [ $n -ge 150 ] && echo "  loop stopped"' &
p=$!; sleep 0.3; kill -USR1 $p; wait $p; echo "hot loop: st=$?"
"$S" -c 'trap "echo \"  HUP\"" HUP; trap "echo \"  USR2\"" USR2; sleep 0.4; echo end' &
p=$!; sleep 0.1; kill -HUP $p; sleep 0.05; kill -USR2 $p; wait $p; echo "two traps: st=$?"
