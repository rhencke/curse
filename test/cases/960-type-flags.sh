# type: -t, -p/-P, -a, -ap, combined flags
myfunc() { echo hi; }

# -t reports one word, function taking priority
type -t myfunc
type -t while
type -t cd
type -t env
type -t no_such_cmd_zz; echo "t-rc=$?"

# -p prints a path only for files (nothing for function/builtin/keyword)
echo "p-func=[$(type -p myfunc)]"
echo "p-builtin=[$(type -p cd)]"
type -p env

# -ap (combined) prints only paths of all matches
echo "ap-func=[$(type -ap myfunc)]"
echo "ap-builtin=[$(type -ap cd)]"

# long form: single match, then -a for all matches in order
# (a plain `type myfunc` would also print the function's source, not covered here)
type while
type cd
type -a echo
type -a while

# not found
type no_such_cmd_zz 2>/dev/null; echo "rc=$?"
