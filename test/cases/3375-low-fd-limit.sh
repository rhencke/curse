# Under a small `ulimit -n` bash still runs pipelines, $(…) and process substitutions: it
# needs only a few fds at a time. curse (in-process stages, captures, pidfds) ran out:
# pipelines hung, a $(…) result went to stdout, `cat <(…) <(…) <(…) <(…)` said
# "/dev/fd/5: No such file or directory" (stress-attack S20). The limit is now the
# script's (virtual): shown by `ulimit -n`, enforced on its redirections and `{v}` fds,
# given to every program it runs. Each run is bounded by a KILL-timeout.
r() { timeout -s KILL 5 $THIS_SH -c "$1" 2>&1 | sed -E 's/^[^ ]*: (line [0-9]+: )?/E: /'; }
r 'ulimit -n 20; for i in 1 2 3; do x=$(echo $i | cat | cat | cat); echo "$x"; done; echo end'
r 'ulimit -n 12; y=$(echo a | cat | cat | cat | cat | cat | cat | cat | cat); echo "[$y] $?"'
r 'ulimit -n 10; cat <(echo p1) <(echo p2) <(echo p3) <(echo p4); echo "st $?"'
r 'ulimit -n 40; echo <(true) <(true); ulimit -n; ulimit -Hn; sh -c "ulimit -n; ulimit -Hn"'
r 'ulimit -n 20; exec 25> /dev/null; echo "past it=$?"; exec 19> /dev/null; echo "below it=$?"; echo x >&19; echo "write=$?"'
r 'ulimit -n 10; exec {v}> /dev/null; echo "v=$v"'
r 'ulimit -n 12; exec {a}> /dev/null {b}> /dev/null {c}> /dev/null; echo "$a $b $c"'
r 'ulimit -n 30; ulimit -n 40; echo "raise=$?"; ulimit -Sn 25; ulimit -Sn 31; echo "soft over hard=$?"; ulimit -n'
r '( ulimit -n 15; ulimit -n; exec 16> /dev/null ); echo "after the subshell=$(ulimit -n)"; exec 16> /dev/null; echo "st $?"'
r 'f() { ulimit -n 16; x=$(echo f | cat | cat); echo "function $x"; }; f; eval "ulimit -n 14; echo eval \$(echo e | cat)"'
r 'ulimit -n 16; trap "echo trap \$(echo t | cat | cat)" USR1; kill -USR1 $$'
r 'ulimit -n 20; n=0; for ((i = 0; i < 150; i++)); do x=$(echo $i | cat | cat); [ "$x" = "$i" ] && n=$((n + 1)); done; echo "loop $n"'
