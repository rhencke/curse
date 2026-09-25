# enable, from bash's builtins/enable.def: the listing (the exact builtin set, in
# order; -n disabled, -a all, -s special, -p), disabling (`echo`/`test` then run
# from $PATH; `type`, `shift`, `read` become "command not found") and
# re-enabling, unknown names ("not a shell builtin"), invalid options, and
# `enable -n enable` (only `builtin enable` can undo it).
e() { sed 's/^.*line [0-9]*: //'; }
enable | md5sum; enable | wc -l; enable | head -3
enable -a | md5sum; enable -s; enable -sa | wc -l
enable -n echo test; enable -n; enable -n | wc -l
echo "via $(type -t echo)"; [ 1 = 1 ] && echo "[ still builtin: $(type -t [)"
enable -a | grep -E 'echo|test$'
enable -p -n
enable echo; enable -n
enable nosuch 2>&1 | e; echo "st=${PIPESTATUS[0]}"
enable -n nosuch echo 2>&1 | e; echo "st=${PIPESTATUS[0]}"; enable echo
enable -x 2>&1 | e; echo "st=${PIPESTATUS[0]}"
enable -ns | wc -l; enable -n :; enable -ns; enable :
enable -- echo; echo "dd st=$?"
( 
enable -n type; type ls 2>&1 | sed "s/^.*line [0-9]*: //"
enable -n echo; echo -e "a\\tb"
enable -n printf; printf "%s\n" x
enable -n shift; set -- a b; shift; echo "after shift: $# $?"
enable -n read; read x <<< y 2>&1 | sed "s/^.*line [0-9]*: //"
 )
enable -n enable; enable 2>&1 | e; echo "st=${PIPESTATUS[0]}"; builtin enable enable 2>&1 | e; echo "builtin st=${PIPESTATUS[0]}"
