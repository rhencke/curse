# ulimit, from bash's builtins/ulimit.def: display (one, several with labels,
# -a, -S/-H), setting (both limits by default, -S/-H alone, `hard`/`soft`/
# `unlimited`, overflow "limit out of range", invalid and hex/octal numbers),
# each resource letter taking an optional argument (attached, or the next word
# unless it looks like an option: `-nf` is -n f), the first failure ending it,
# and an in-process subshell's hard limits — also inside its pipeline stages.
e() { sed 's/^.*line [0-9]*: //'; }
ulimit; ulimit -a | md5sum; ulimit -Sa | md5sum; ulimit -Ha | md5sum
ulimit -n; ulimit -Sn; ulimit -Hn; ulimit -f; ulimit -c; ulimit -s | grep -c .
ulimit -n -f; ulimit -nf | md5sum
( ulimit -n 64; ulimit -n; ulimit -Sn; ulimit -Hn | grep -c . )
( ulimit -Sn 32; ulimit -Sn; ulimit -n )
( ulimit -c 0; ulimit -c; ulimit -c unlimited 2>&1 | e; echo "st=${PIPESTATUS[0]}" )
( ulimit -Sc hard; ulimit -Sc; ulimit -Sc soft; ulimit -Sc )
( ulimit -n abc 2>&1 | e; echo "st=${PIPESTATUS[0]}" )
( ulimit -n -5 2>&1 | e; echo "st=${PIPESTATUS[0]}" )
( ulimit -n 1x 2>&1 | e; echo "st=${PIPESTATUS[0]}" )
( ulimit -Q 2>&1 | e; echo "st=${PIPESTATUS[0]}" )
( ulimit -n 64 32 2>&1 | e; echo "st=${PIPESTATUS[0]}" )
( ulimit -f 100; ulimit -f; ulimit -f 0x10 2>&1 | e )
( ulimit -t 5; ulimit -t; ulimit -St )
( ulimit -v 1000000; ulimit -v )
ulimit -P 2>&1 | e; ulimit -k 2>&1 | e; ulimit -b 2>&1 | e
( ulimit -n 99999999999 2>&1 | e; echo "st=${PIPESTATUS[0]}" )
( ulimit -Hn 50; ulimit -Sn 60 2>&1 | e; echo "st=${PIPESTATUS[0]}"; ulimit -n )
( ulimit -n 64 -c 0; ulimit -n -c )
( ulimit -c 99999999999999999999 2>&1 | e; echo "st=${PIPESTATUS[0]}" )
( ulimit -Hc 0; ulimit -Sc 5 2>&1 | e; echo "st=${PIPESTATUS[0]}" )
( ulimit -S -c; ulimit -H -c 1000; ulimit -Hc; ulimit -Sc hard; ulimit -Sc )
