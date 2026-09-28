# A word right after a compound command's closer (`fi x`, `} x`, `done x`) is a syntax
# error reported at the line the word is on — not the line the compound began (leftover
# L21: `alias local='echo }; }'` closing a function body early).
e() { eval "$1"; echo "st $?"; }
e 'if true
then :; fi x'
e '{
:; } x'
e 'f() {
:; } x'
e 'f()
{ :; } x'
e 'function f {
:; } x'
e 'f() (
: ) x'
e 'while false
do :; done x'
e 'case a in
a) ;; esac x'
shopt -s expand_aliases
alias local='echo }; }'
e 'f() {
  local x
}'
unalias local
printf 'if :\nthen :\nfi y\necho no\n' > s2820.sh; . ./s2820.sh; echo "src $?"
trap 'e "{
:; } z"' USR1; kill -USR1 $$; trap - USR1
i=0; while [ $i -lt 150 ]; do e 'for x in 1
do :; done w'; i=$((i + 1)); done 2>&1 | sort | uniq -c
rm -f s2820.sh
