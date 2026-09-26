# `set -e` vs expansion errors: which ones exit the shell (error.c report_error, whose
# exit_immediately_on_error test ignores an if/&&/! context) and which DISCARD the rest of
# the line and go on (an arithmetic error's expand_wdesc_error / evalerror, a nameref's
# bad target, a substring's `< 0`), with $? = 1 on the next line.
# - report_error: a bad array subscript (read, element read/write, compound assignment,
#   printf -v / read / declare target, (( )) / let / [[ -v ]] / test -v), a readonly
#   variable's err_readonly (not a builtin's own `declare: r: readonly variable`),
#   failglob's `no match`, a bad substitution, `$1: cannot assign in this way`
# - an eval / source / `command` run in an errexit-exempt context clears -e for what it
#   runs (execute_builtin), so a report_error there doesn't exit; a $(…) has -e off
# - parser_error under -e exits at its FIRST line, status 2 (no offending-line echo)
# - a DISCARD unwinding out of an `if` condition leaves errexit live again afterwards
# - [[ ]]: a newline where an operator / operand is read is a `newline' token; the input's
#   end reads as a newline, then EOF (`unexpected EOF while looking for `]]'')
S=${THIS_SH:-bash}
exec 2>&1
t=${TMPDIR:-/tmp}/c2370.$$; mkdir -p "$t"; cd "$t" || exit 1
n=0
p() { # each probe is its own script: `set -e`, the line, then what the next line sees
	n=$((n + 1))
	printf 'set -e\n%s\necho next $?\n' "$1" > p$n.sh
	echo "[$n] $1"
	"$S" p$n.sh
	echo "st=$?"
}

echo "-- arithmetic errors: DISCARD the line, no exit"
p 'x=$((1/0)); echo same'
p 'echo $((1+)); echo same'
p 'for i in 1; do echo $((1/0)); echo body; done; echo after'
p 'f() { echo $((1/0)); echo infn; }; f; echo afterf'
p 'if echo $((1/0)); then echo t; fi; echo same'
p '[[ $((1/0)) = 1 ]] || echo f; echo same'
p '[[ a =~ $((1/0)) ]] || echo f; echo same'
p '[[ 1 -eq 1/0 ]] || echo f; echo same'
p 'a=(1); if echo ${a[1/0]}; then echo t; fi; echo same'
p 'if a[1/0]=x; then echo t; fi; echo same'
p 'x=1; x+=$((1/0)); echo same'
p 'f() { local x=$((1/0)); echo infn; }; f; echo same'
p 'export x=$((1/0)); echo same'
p "x='1+'; if echo \$((x)); then echo t; fi; echo same"
p 'x=abc; if echo ${x:0:-5}; then echo t; fi; echo same'
p 'x=abc; if echo ${x:1/0}; then echo t; fi; echo same'
p 'a=(1 2 3); if echo ${a[@]:1/0}; then echo t; fi; echo same'
p 'unset x; echo ${x:$((1/0))}; echo same'
p 'echo $((1/0)) | cat; echo same'
p 'y=$(echo $((1/0)); echo inside); echo "y=$y"'
p 'eval "echo \$((1+)); echo more"; echo same'
p 'if eval "echo \$((1/0)); echo more"; then echo t; else echo f; fi; echo same'
p 'if command eval "echo \$((1/0))"; then echo t; else echo f; fi; echo same'
p '(( 1/0 )); echo same'
p 'if let 1/0; then echo t; else echo f; fi; echo same'
p 'if for ((i=1/0; i<1; i++)); do :; done; then echo t; else echo f; fi; echo same'
p 'if x=$((1/0)); then :; fi; false; echo survived'
p 'f() { if x=$((1/0)); then :; fi; }; f; false; echo survived'

echo "-- a nameref's bad target: DISCARD"
p 'declare -n ref; ref=1; echo same'
p 'declare -n ref; if ref=1; then echo t; fi; echo same'
p 'declare -n ref; ref+=1; echo same'
p 'declare -n ref; : ${ref:=1}; echo same'
p 'declare -n ref; eval "ref=1; echo more"; echo same'

echo "-- bad array subscripts: report_error exits, even in if / && / !"
p 'a=(1 2); x=${a[-5]}; echo same'
p 'a=(1 2); echo "${a[-5]}"; echo same'
p 'a=(1 2); echo ${#a[-5]}; echo same'
p 'a=(1 2); if echo ${a[-5]}; then echo t; fi; echo same'
p 'a=(1 2); echo ${a[-5]} && echo t; echo same'
p 'a=(1 2); ! echo ${a[-5]}; echo same'
p 'a=(1 2); f() { echo ${a[-5]}; echo infn; }; if f; then echo t; fi; echo same'
p 'a=(1 2); f() { return 3; }; f || echo ${a[-5]}; echo same'
p 'trap "echo EXIT \$?" EXIT; a=(1 2); echo ${a[-5]}; echo same'
p 'a=(1 2); y=$(echo ${a[-5]}; echo inside); echo "y=$y"'
p 'shopt -s inherit_errexit; a=(1 2); y=$(echo ${a[-5]}; echo inside); echo "y=$y"'
p 'a=(1 2); echo ${a[-5]} | cat; echo same'
p 'a=(1 2); if ( echo ${a[-5]} ); then echo t; else echo f; fi; echo same'
p 'a=(1 2); if echo ${!a[-5]}; then echo t; fi; echo same'
p 'a=(1 2); if echo ${a[-5]:-def}; then echo t; fi; echo same'
p 'a=(1 2); if local x=${a[-5]}; then echo t; fi; echo same'
p 'a=(1 2); for i in ${a[-5]}; do echo i; done; echo same'
p 'a=(1 2); case ${a[-5]} in *) echo c;; esac; echo same'
p 'a=(1 2); if a[-5]=x; then echo t; fi; echo same'
p 'a=(1 2); if a+=([-5]=x); then echo t; fi; echo same'
p 'declare -A A; if A=([]=1); then echo t; fi; echo same'
p "declare -A A; if A=('' v); then echo t; fi; echo same"
p 'a=(1 2); if printf -v "a[-5]" x; then echo t; fi; echo same'
p 'a=(1 2); if read "a[-5]" <<< x; then echo t; fi; echo same'
p 'a=(1 2); if declare "a[-5]=x"; then echo t; fi; echo same'
p 'a=(1); if (( a[-5] )); then echo t; fi; echo same'
p 'a=(1); if (( a[@]+1 )); then echo t; fi; echo same'
p 'a=(1 2); if let "a[-5]=1"; then echo t; fi; echo same'
p 'a=(1); if [[ -v a[-5] ]]; then echo t; fi; echo same'
p 'a=(1 2); if test -v "a[-5]"; then echo t; fi; echo same'
p 'a=(1 2); if unset "a[-5]"; then echo t; else echo f; fi; echo same'
p 'a=(1 2); if eval "echo \${a[-5]}"; then echo t; fi; echo same'
p 'a=(1 2); eval "echo \${a[-5]}; echo more"; echo same'
p 'a=(1 2); if command eval "echo \${a[-5]}"; then echo t; fi; echo same'
p 'a=(1 2); if source /dev/stdin <<< "echo \${a[-5]}"; then echo t; fi; echo same'
p 'a=(1 2); if eval "f() { echo \${a[-5]}; echo inner; }; f"; then echo t; fi; echo same'
p 'a=(1 2); set +e; echo ${a[-5]}; echo same'

echo "-- other report_errors"
p 'shopt -s failglob; if echo /nonexist*; then echo t; fi; echo same'
p 'shopt -s failglob; if eval "echo /nonexist*; echo more"; then echo t; else echo f; fi; echo same'
p "x='a b'; if echo \${!x}; then echo t; fi; echo same"
p 'x=1; if echo ${x@Z}; then echo t; fi; echo same'
p 'if echo ${1:=x}; then echo t; fi; echo same'

echo "-- readonly: err_readonly exits, a builtin's own message doesn't"
p 'readonly r=1; if r=2; then echo t; fi; echo same'
p 'readonly r=1; if r=2 true; then echo t; fi; echo same'
p 'readonly r=1; f() { :; }; if r=2 f; then echo t; fi; echo same'
p 'readonly r=1; if for r in 1; do echo body; done; then echo t; fi; echo same'
p 'readonly r=1; if read r <<< x; then echo t; fi; echo same'
p 'readonly r=1; if printf -v r x; then echo t; fi; echo same'
p 'readonly r=1; if getopts a r -a; then echo t; fi; echo same'
p 'readonly OLDPWD; if cd /; then echo t; fi; echo same'
p 'readonly r=1; if exec {r}>/dev/null; then echo t; fi; echo same'
p 'readonly r=1; if export r=2; then echo t; fi; echo same'
p 'readonly r=1; if readonly r=2; then echo t; fi; echo same'
p 'readonly r=1; if r+=2; then echo t; fi; echo same'
p 'readonly ra=(1); if ra=(2); then echo t; fi; echo same'
p 'readonly ra=(1); if ra[0]=2; then echo t; fi; echo same'
p 'readonly r=1; if (( r=2 )); then echo t; fi; echo same'
p 'readonly r=1; if let r=2; then echo t; fi; echo same'
p 'readonly r=1; if mapfile r < /dev/null; then echo t; fi; echo same'
p 'readonly r=1; if select r in 1; do break; done <<< 1; then echo t; fi; echo same'
p 'readonly r=1; declare -n ref=r; if ref=2; then echo t; fi; echo same'
p 'readonly r=1; if declare r=2; then echo t; else echo f; fi; echo same'
p 'readonly r=1; f() { if local r=2; then echo t; else echo f; fi; }; f; echo same'
p 'readonly r=1; if unset r; then echo t; else echo f; fi; echo same'
p 'readonly r=1; if eval r=2; then echo t; else echo f; fi; echo same'

echo "-- parser_error under -e: its first line, status 2"
p 'eval "if"; echo same'
p 'if eval "if"; then echo t; else echo f; fi; echo same'
p 'eval "echo )"; echo same'
p 'eval "case"; echo same'
p 'eval "a=(1 2"; echo same'
p 'declare -A A; eval "A=([a]=1 [b)"; echo same'
p 'eval "[[ a"; echo same'
p 'x=$(if); echo same'

echo "-- [[ ]] and newlines (no -e)"
printf 'eval "$(cat q.sh)"; echo "eval st=$?"\n' > e.sh
for c in '[[ a ==\n b ]]' '[[ -n\n b ]]' '[[ a\n]]' 'x=1\n[[ a b\nc ]]' \
	'[[ -n a &&\n\n -n b\n ]] && echo y' '[[\n a ]] && echo y' '[[ ( a == b\n ]]' \
	'[[ ( ( a\n ]]' '[[ (\n a b ) ]]'; do
	printf "$c\necho after\n" > q.sh
	echo "[[ $c"
	"$S" q.sh; echo "st=$?"
	"$S" e.sh
done
echo "-- [[ ]] at the input's end"
for c in '[[ a' '[[ -n a' '[[ a == b' '[[ a &&' '[[' '[[ ( a )' 'x\n[[ -n a\n\n'; do
	printf "$c" > q.sh
	echo "[[ $c"
	"$S" q.sh; echo "st=$?"
	"$S" e.sh
done
cd / && rm -rf "$t"
