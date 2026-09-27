# A readonly assignment error jumps to the top level as bash's do_assignment_statements
# does, the same under -c as in a script: a standalone `r=3` (direct or through a
# nameref) abandons the rest of the LINE (DISCARD), a command prefix `r=3 cmd` is reported
# and the command still runs. In posix mode a standalone one, or a special builtin's
# prefix, exits the shell (FORCE_EOF: status 1, 127 for a -c string); any other prefix
# abandons the line (before the command's redirections).
run() { "$THIS_SH" -c "$1" 2>&1 | sed 's/^[^:]*: line/line/'; echo "st=${PIPESTATUS[0]}"; }
run 'readonly r=1; r=3; echo a$?
echo b'
run 'readonly r=1; r=3 echo x; echo a$?
echo b'
run 'readonly r=1; declare -n nr=r; nr=3; echo a
echo b'
run 'readonly r=1; f(){ r=3; echo in; }; f; echo a
echo b'
run 'readonly r=1; r=3 $empty; echo a$?
echo b'
run 'set -o posix; readonly r=1; r=3 true; echo a$?
echo b'
run 'set -o posix; readonly r=1; r=3 true >f1; echo a$?
echo b; ls f1'
run 'set -o posix; readonly r=1; r=3 :; echo a$?
echo b'
run 'set -o posix; readonly r=1; r=3; echo a$?
echo b'
run 'set -o posix; readonly r=1; declare -n nr=r; nr=3; echo a
echo b'
run 'readonly r=1; for ((i = 0; i < 200; i++)); do r=$i true; done 2>/dev/null; echo loop $?
for ((i = 0; i < 200; i++)); do if ((i == 199)); then r=$i; fi; x=$i; done; echo no
echo "after $x"'
run 'set -o posix; readonly r=1; for ((i = 0; i < 200; i++)); do if ((i == 199)); then r=$i true; fi; done; echo no
echo after'
# the same in this script (not -c)
exec 2>&1
readonly r=1
r=3; echo "not reached"
r=3 echo prefix; echo "a$?"
for ((i = 0; i < 200; i++)); do r=$i true; done 2>/dev/null; echo "loop $?"
for ((i = 0; i < 200; i++)); do if ((i == 199)); then r=$i; fi; done; echo "not reached"
echo end
