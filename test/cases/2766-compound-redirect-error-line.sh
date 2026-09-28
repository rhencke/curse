# A failed redirection on a compound command names bash's line of the moment: a for (( )),
# [[ ]] or (( )) its own line; a top-level compound its end; a nested one (in `||`, `if`,
# a loop, a function) the line only simple commands, for/select/case, subshells and
# function calls set — else the reader's line after the whole top-level command. curse named
# the previous command's line (fuzz F71, F87).
{ :; } > "$x" || :
{ :; } > "$x" && :
( : ) > "$x" || echo or
if :; then :; fi > "$x" || :
while false; do :; done > "$x" || :
if true; then
  { :; } > "$x"
fi
f() {
  { :; } > "$x" || :
}
g()
{
  echo g
  { :; } > "$x" || :
}
h() (
  { :; } > "$x" || :
)
k() { for i in 1; do
  { :; } > "$x"
done; }
f; g; h; k
case a in
a)
  { :; } > "$x" ;;
esac
for ((i=0;i<1;i++)); do
  { :; } > "$x"
done
( :
  { :; } > "$x"
)
eval 'if true; then
{ :; } > "$x"
fi'
printf 'if :; then\n{ :; } > "$x"\nfi\n' > s2766.sh
. ./s2766.sh
trap '{ :; } > "$x" || :' USR1; kill -USR1 $$; trap - USR1
for ((;;))
do
break
done {v}>> $a
[[ a ]] > "$c"
(( 1 )) >\
 "$d"
j=0; while [ $j -lt 150 ]; do
  { :; } > "$x" || :
  j=$((j + 1))
done 2>&1 | sort | uniq -c
rm -f s2766.sh
