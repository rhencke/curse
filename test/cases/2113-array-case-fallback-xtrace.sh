# Array literals and case patterns the compiled renderers can't take natively (a ${x[@]}
# keyed value, a ${…}-op element, a $(…)/${k^^} subscript; a quoted "$@" or word-initial ~
# case pattern) through the shared one-word expanders; `coproc BAD` reported; [[ ]] on
# $BASH_COMMAND; set -x traces export/readonly assignments, and a prefix assignment's
# command traces to the stderr from before its redirections.
i=5 v='1 2 3' x=(3 5 7)
a=($v [i]="${x[@]}"); declare -p a
a=($v [i]=${x[*]}); declare -p a
b=(${x[@]/#/-} "${x[@]/3/t}" [9]=${x[*]:1}); declare -p b
declare -A A; k=kk; A=([$k]=1 [${k^^}]="${x[@]}" [$(echo c)]=3); declare -p A
set -- a 'b c'
for s in 'b c' a z; do
	case $s in "$@") echo "at $s";; *) echo "no $s";; esac
done
HOME=/h; for s in /h/x '~/x'; do case $s in ~/x) echo "tilde $s";; *) echo "not $s";; esac; done
coproc @ { :; }; echo "coproc=$?"
trap '[[ $BASH_COMMAND == *mark* ]] && echo "saw: $BASH_COMMAND"' DEBUG
: mark
trap - DEBUG
set -x
export Q="a b" W=2
readonly S=3
x=1 echo hi 2>x.err
f() { :; }
x=3 f 2>x3.err
set +x
cat x.err x3.err; rm -f x.err x3.err
