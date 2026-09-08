# assignment builtins do not word-split or glob a name=value operand's RHS
touch xa.txt xb.txt

f() { local foo=$1; echo "[$foo]"; }
f "void *"

g() { declare bar=$1; echo "[$bar]"; }
g "a  b  c"

# a glob character in the RHS is literal, not expanded against the filesystem
h() { local pat=$1; echo "[$pat]"; }
h "x*.txt"

# tilde still expands after the = in an assignment word
HOME=/myhome
declare tp=~/sub; echo "[$tp]"

# export / readonly likewise keep the RHS as one field
val="p  q"
export ev=$val; echo "[$ev]"
readonly rv=$val; echo "[$rv]"

# a plain flag before the assignment is unaffected
num="6"
declare -i n=$num; echo "[$n]"

# multiple assignment operands in one command
local2() { local m=$1 k=$2; echo "[$m][$k]"; }
local2 "1  2" "3  4"

rm -f xa.txt xb.txt
