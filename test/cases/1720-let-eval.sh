# let / eval, from bash's builtins/let.def and eval.def: let skips a leading
# `--`, needs an expression, stops at the first failing one and returns on the
# LAST value; its args are already-expanded text. eval joins its args with
# spaces, `eval` / `eval ''` succeed (resetting $?), `-x` is an invalid option
# but `eval -- -x` runs it; syntax errors are status 2; return/exit/aliases
# and $LINENO inside the evaluated text.
e() { sed 's/^.*line [0-9]*: //'; }
let 2>&1 | e; let; echo "noarg st=$?"
let -- 2>&1 | e; echo "dd st=${PIPESTATUS[0]}"
let -- 'x=3'; echo "st=$? x=$x"
let -1; echo "neg st=$?"
let 1 0; echo "last0 st=$?"
let 0 1; echo "last1 st=$?"
y=7; let 'z=$y+1'; echo "z=$z"
let 'q = 2, r = q * 3'; echo "q=$q r=$r"
let "w=1" "w+=1" "w*=5"; echo "w=$w"
let 'arr[2]=5' 'arr[3]=arr[2]+1'; echo "${arr[*]}"
let x=1/0 2>&1 | e; echo "div st=${PIPESTATUS[0]}"
let 'm = 1 ? 2 : 3'; echo "m=$m"
let -x 2>&1 | e; echo "letx st=${PIPESTATUS[0]}"
let '' 2>&1 | e; echo "empty st=${PIPESTATUS[0]}"
let ' ' 2>&1 | e; echo "blank st=${PIPESTATUS[0]}"
v=3; let v++ v++; echo "v=$v"
false; eval; echo "eval-noarg st=$?"
false; eval ''; echo "eval-empty st=$?"
false; eval ' '; echo "eval-blank st=$?"
false; eval 'echo "in: $?"'; echo "eval-q st=$?"
eval -- echo dd; eval -- -x 2>&1 | e
eval -x 2>&1 | e; echo "evalx st=${PIPESTATUS[0]}"
eval 'echo a;' ' echo b'; eval echo '"c  d"'
eval 'if' 2>&1 | e; echo "syn st=${PIPESTATUS[0]}"
eval 'echo ok; )' 2>&1 | e; echo "syn2 st=${PIPESTATUS[0]}"
f() { eval 'return 4'; echo no; }; f; echo "evret st=$?"
eval 'x1=1
x2=2'; echo "$x1$x2"
eval "$(printf 'echo %s\n' l1 l2)"
alias ll='echo aliased'; eval 'll'; eval 'shopt -s expand_aliases; alias kk="echo kk"
kk'
eval 'echo $LINENO'; eval '
echo $LINENO'
( eval 'exit 5'; echo no ); echo "sub st=$?"
eval 'false' || echo "or-false"
eval 'echo one; false; echo two'; echo "last st=$?"
eval eval eval echo nested
