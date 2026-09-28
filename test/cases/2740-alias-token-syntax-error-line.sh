# A syntax error at a token read from an alias's text echoes bash's input line then — the
# alias text (its pushed string), where the delimiter read_token_word ungets after a word
# that ends the text overwrites its last character (`}` shows as ` `, `fi` as `f `); a
# text ending in an operator is done by then and the source line shows (fuzz F41).
shopt -s expand_aliases
alias local='}' a2='} x' a3='fi' a4='echo; done' a5=')' a6='echo )' a7='x }'
eval 'f() {
  local a
}'; echo "a $?"
eval 'f() {
  a2 a
}'; echo "b $?"
eval 'a3'; echo "c $?"
eval 'a4 x'; echo "d $?"
eval 'f() {
  a5 a
}'; echo "e $?"
eval 'a6'; echo "f $?"
eval 'a7'; echo "g $?"
g() { eval 'a3 z'; echo "function $?"; }; g
printf 'if :; then\n  a3\n' > s2740.sh; . ./s2740.sh; echo "source $?"
trap 'eval "a4"; echo "trap $?"' USR1; kill -USR1 $$; trap - USR1
i=0; while [ $i -lt 150 ]; do eval 'a3'; echo "st $?"; i=$((i + 1)); done 2>&1 | sort | uniq -c
rm -f s2740.sh
