# Prefix assignments and a builtin's own writes, from bash's execute_cmd.c
# (execute_builtin) and variables.c: for most builtins a write to a
# prefix-assigned variable reaches the variable beneath and outlives the
# command (`x=2 printf -v x 9` leaves 9; getopts, let); source, eval, unset,
# mapfile, fc and read get a scope of their own that is dropped;
# declare/local/typeset and functions don't propagate either.
x=1; x=2 printf -v x 9; echo "printf: $x"
x=1; x=2 read x <<< 5; echo "read: $x"
x=1; x=2 read -r x <<< 5; echo "read -r: $x"
x=1; x=2 mapfile -t x <<< 5; echo "mapfile: $x ${x[*]}"
OPTARG=keep; set -- -a v; OPTIND=1; OPTARG=tmp getopts a: o; echo "getopts OPTARG: $OPTARG"
x=1; x=2 declare x=7; echo "declare: $x"
x=1; x=2 eval 'x=8'; echo "eval: $x"
x=1; x=2 export x=6; echo "export: $x"
x=1; x=2 unset x; echo "unset: ${x-unset}"
x=1; x=2 let x=4; echo "let: $x"
x=1; x=2 : $((x=3)); echo "colon arith: $x"
x=1; x=2 cd . ; echo "cd: $x"
x=1; x=2 true; echo "true: $x"
f() { x=5; }; x=1; x=2 f; echo "function: $x"
x=1; x=2 source /dev/stdin <<< 'x=11'; echo "source: $x"
x=1; x=2 printf -v y 9; echo "other: $x"
