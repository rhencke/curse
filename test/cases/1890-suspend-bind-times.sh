# suspend / bind / times in a non-interactive shell, from bash's builtins/
# suspend.def, bind.def, times.def: suspend without job control (not -f: that
# really stops the shell), bind without
# line editing (warnings, statuses, options), times' format (values masked)
# and its argument handling.
e() { sed 's/^.*line [0-9]*: //'; }
suspend 2>&1 | e; echo "st=${PIPESTATUS[0]}"
suspend -x 2>&1 | e; echo "x st=${PIPESTATUS[0]}"
suspend a 2>&1 | e; echo "a st=${PIPESTATUS[0]}"
bind 2>&1 | e; echo "bind st=${PIPESTATUS[0]}"
bind -l 2>&1 | head -3 | e; echo "l st=${PIPESTATUS[0]}"
bind '"\C-x": accept-line' 2>/dev/null; echo "set st=$?"
bind -q accept-line 2>&1 | e; echo "q st=${PIPESTATUS[0]}"
bind -x 2>&1 | e; echo "x st=${PIPESTATUS[0]}"
bind -z 2>&1 | e; echo "z st=${PIPESTATUS[0]}"
bind -v 2>&1 | head -2 | e
times | sed 's/[0-9.]*s/Ns/g'; echo "times st=$?"
times x 2>&1 | sed 's/[0-9.]*s/Ns/g' | e; echo "tx st=${PIPESTATUS[0]}"
times -x 2>&1 | e; echo "t-x st=${PIPESTATUS[0]}"
