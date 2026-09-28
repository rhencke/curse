# A `\<newline>` that ends the input is one more line read: bash's here-document warning
# and its end-of-file syntax error name the line after it (every joined line of a body
# counts too), and a body whose input ends in a lone `\` (no newline) loses it — and its
# last newline — at the end of a script file. curse counted one line short (fuzz F45).
# This file itself ends in a body line `x\` and a newline.
printf 'f() {\n  echo '"'"'6\n}\n'"'"'\\\n' > s2744a.sh; . ./s2744a.sh; echo "a $?"
printf 'if true; then\\\n' > s2744b.sh; . ./s2744b.sh; echo "b $?"
printf 'cat <<EOF\nx\\\ny\\\n' > s2744c.sh; . ./s2744c.sh; echo "c $?"
printf 'cat <<"EOF"\nx\\' > s2744e.sh; . ./s2744e.sh; echo "e $?"
# (a sourced or eval'd text ending in that lone `\`: bash stores the EOF shell_getc returned
# after it in the line, as a 0xff byte — deterministic, copied)
printf 'cat <<EOF\nx\\' > s2744d.sh; . ./s2744d.sh | od -An -c; echo "d $?"
eval 'cat <<EOF
w\' | od -An -c
eval 'cat <<EOF
p\
q\
'; echo "eval $?"
eval 'if :; then\
'; echo "eval2 $?"
f() { eval 'cat <<EOF
r\
'; echo "function $?"; }; f
trap 'eval "cat <<EOF
t\\
"; echo "trap $?"' USR1; kill -USR1 $$; trap - USR1
i=0; while [ $i -lt 150 ]; do eval 'cat <<EOF
u\
'; i=$((i + 1)); done 2>&1 | sort | uniq -c
rm -f s2744?.sh
cat <<EOF
x\
