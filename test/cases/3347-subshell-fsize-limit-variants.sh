# A file-size limit a subshell sets ends only that subshell (SIGXFSZ, 153), whatever runs
# the write: a function, eval, a nested subshell; its own XFSZ trap runs (the write fails:
# a write error) and its own ignore makes it a write error; over and over (hot loop). curse
# ran them in-process and the SIGXFSZ ended the whole script (stress-attack S24).
run() { timeout -s KILL 8 $THIS_SH -c "$1" 2>&1 | sed -E 's/^.*line [0-9]+: +[0-9]+ /E: /; s/^[^ ]*: line [0-9]+: /sh: line N: /'; echo "status ${PIPESTATUS[0]}"; }
run 'f() { printf "%010000d" 0 > big; }; ( ulimit -f 1; f ) 2> /dev/null; echo "function: $?"'
run '( ulimit -f 1; eval "printf %010000d 0 > big" ) 2> /dev/null; echo "eval: $?"'
run '( ulimit -f 1; ( printf "%010000d" 0 > big; echo not here ); echo "inner: $?" ); echo "outer: $?"'
run '( trap "t=trapped" XFSZ; ulimit -f 1; printf "%010000d" 0 > big; echo "after the write: $? $t" ); echo "own trap: $?"'
run '( trap "" XFSZ; ulimit -f 1; printf "%010000d" 0 > big; echo "after the write: $?" ); echo "own ignore: $?"'
run 'n=0; for ((k = 0; k < 20; k++)); do ( ulimit -f 1; printf "%010000d" 0 > big ) 2> /dev/null; [ $? = 153 ] && n=$((n + 1)); done; echo "hot loop: $n of 20"; printf "%010000d" 0 > big; echo "parent unlimited: $?"'
rm -f big
