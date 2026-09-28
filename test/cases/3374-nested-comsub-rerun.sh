# `$(echo $(echo …))` nested 18 deep, run three times: bash forks its way through in a
# blink. curse compiles a comsub body the second time its text is seen, and the emitted
# code grows exponentially with the nesting (15 deep: a 720910-line chunk, "more than
# 65536 constants"), so the loop never finishes in any tier (stress-attack S17). The run
# is bounded by a KILL-timeout: curse did not end on the harness's SIGTERM (S23).
timeout -s KILL 8 $THIS_SH -c 'n=0
for ((r = 0; r < 3; r++)); do y=$(echo $(echo $(echo $(echo $(echo $(echo $(echo $(echo $(echo $(echo $(echo $(echo $(echo $(echo $(echo $(echo $(echo $(echo $(echo 1))))))))))))))))))); n=$((n + y)); done
echo "$n"'
echo "status $?"
