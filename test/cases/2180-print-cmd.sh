# print_cmd.c audit: how bash re-prints commands (declare -f / type bodies, BASH_COMMAND,
# jobs text) and formats set -x traces (PS4, xtrace_print_word_list quoting,
# [[ ]] / (( )) / for / case heads).

# --- redirection printing: fd defaults per operator, >&word, closes, {var}, heredocs
rd() { a <>f; a 1<>f; a 2<>f; a >&file; a >& file; a 5<&-; a >&3-; a <&3-; a {v}<&3-
a {v}>&-; a {v}<<<s; a 0<<<s; a 1<&2; a 3>&$x-; cat <<"E" 4<<-\F
$x
E
	y
	F
}
declare -f rd

# --- heredoc bodies deferred past connectors (&, |, &&, ;)
hd() { cat <<B &
b
B
( cat <<C )
c
C
cat <<P | tr p q
p
P
cat <<A && echo ok
a
A
}
declare -f hd

# --- time/!/|&/& forms
tm() { time; time -p; ! time a; a |& b; a & }
declare -f tm

# --- command substitutions: newlines kept, `$( (` spacing, $"..." loses its $
cs() { x=$(echo a
echo b;echo c); z=$( (echo d) ); t=$"loc"; s=$'a\tb'; v=$(f() { :; }; f); }
declare -f cs

# --- function bodies that are not { } groups (any compound command is allowed)
eval 'fa() (( $1 > 2 ))'; fa 5; echo "fa5=$?"; fa 1; echo "fa1=$?"; declare -f fa
eval 'fb() for x in 1 2; do echo "fb $x"; done'; echo "st=$?"; fb
eval 'fc_() [[ -n $1 ]]'; echo "st=$?"; fc_ a && echo fc-yes
eval 'fd_() case $1 in a) echo fd-A;; esac'; fd_ a
eval 'fe() while false; do :; done'; fe; echo "fe=$?"
eval 'ff() if true; then echo ff-if; fi'; ff; declare -f ff
eval 'fg_() for ((j=0;j<2;j++)); do echo "fg $j"; done'; fg_
eval 'fh() ( echo sub ) > /dev/null'; fh; declare -f fh

# --- structures curse already prints right (holes in the corpora)
st() { coproc { a; } 2>/dev/null; coproc N { b; }; select y; do :; done
for ((;;)); do break; done; case $1 in a|b) x ;& c) y ;;& (*) ;; esac
if a & then b & fi; x | { y; z; } | w; function inner { if b; then c; fi; }; }
declare -f st
ex() { echo a; if true; then echo b; fi; }; export -f ex
env | sed -n '/^BASH_FUNC_ex%%/,/^}/p'
function if { :; }; declare -f if

# --- BASH_COMMAND text
trap 'echo "BC=[$BASH_COMMAND]"' DEBUG
echo hi >/dev/null 2>&1
[[ -n x && y == y ]]
for i in a; do :; done
cat <<E >/dev/null
doc
E
coproc { :; }
trap - DEBUG
wait

# --- xtrace quoting (sh_contains_shell_metas before ansic_shouldquote)
( set -x; : a~b a=~b a:~b a# '#a' a^ a%b 'a b' $'a\tb' $'a\nb' $'\001' $'\e[m' ''
  v=$'x\ty' w=$'\e[0m' z=
  declare q=$'x\ty'
  arr=(a 'b c' $'d\te') ) 2>&1

# --- xtrace of [[ ]]: empty operands as '', quoted pattern chars backslashed
( set -x; p='*'; e=
  [[ -z $e ]]; [[ $e ]]; [[ $e < '' ]]; [[ ! -n $e ]]
  [[ ab == "ab" ]]; [[ ab == a"b"* ]]; [[ ab != $p ]]; [[ ab == "$p" ]]
  [[ ab = 'a?' ]]; [[ a =~ "a." ]]; [[ 'a b' =~ a\ b ]]; [[ $'\t' == ' ' ]] ) 2>&1

# --- xtrace of (( )), arith-for (empty slots trace as 1), for/case heads
( set -x; a=5; (( $a + 1 )); for ((; a<6 ;)); do a=6; done; for ((i=0;;)); do break; done
  for x in "a b" $'t\tu'; do break; done; case $'\t' in *) ;; esac ) 2>&1

# --- PS4: first char repeated per level; empty or unset PS4 prints no prefix
( set -x; PS4='>> '; x=$(: one; y=$(: two)); PS4=''; : empty; unset PS4; : unset ) 2>&1
