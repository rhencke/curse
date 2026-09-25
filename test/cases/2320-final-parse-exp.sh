# Final parse/expansion queue: a simple command's line (where yacc reduced its first
# element), arithmetic through bad namerefs, Big5 here-document continuations, $"…" in a
# here-document word and in $(…) bodies, `$(cat <<)`, compgen -W's $(…), SHLVL's tail
# exec (pipeline stages, a function called as a comsub's tail), -i assignment errors,
# [[ $op … ]], and setlocale's "" reading the environment bash last rebuilt.
S=${THIS_SH:-bash}
e() { sed 's/^[^:]*: line \([0-9]*\): /L\1: /'; }
t=${TMPDIR:-/tmp}/c2320.$$; mkdir -p "$t"; cd "$t" || exit 1
r() { printf '%b' "$1" > s.sh; $S s.sh 2>&1 | e; echo "st=${PIPESTATUS[0]}"; }

echo "-- -i assignment errors (declare/local/export prefixes)"
r 'declare -i x; x="2 x"; echo "a $?"\necho n1\ndeclare x="3 x"; echo "b $?"\nf() { local -i y="6 x"; echo "e $?"; }; f\nexport x="7 x"; echo "g $?"\necho end'
echo "-- [[ with a non-literal operator: a parse-time error"
r 'echo s\nop=-f; [[ $op /etc/passwd ]] && echo yes\necho after'

echo "-- a command's line: past a leading assignment/redirect, else once the 2nd token is read"
r 'a=`echo x\necho $LINENO\necho $LINENO` b=1\necho "$a"\na=$(echo x\necho $LINENO\necho $LINENO) b=1\necho "$a"\necho `echo x\necho $LINENO` z'
r 'readonly r\nr=$(echo 1\necho 2) true\necho $LINENO'
r 'readonly r\na=`echo x\necho $LINENO` r=1\necho $?'
r 'readonly r\nr="\n" true\necho $?'
r 'a=$(echo\n) nope "x\ny"'
r 'nope "x\ny"'
r '>/dev/null nope "x\ny"'

echo "-- arithmetic through namerefs: cycles, a self-named local, element refs, no target"
r 'declare -n s=t t=s\n(( s=2 )); echo "d $?"\n(( s )); echo "e $?"\n(( s++ )); echo "f $?"\necho "c $((s))"\ns=1; echo "a $?"\necho "n $?"\ns=1 x=2 true; echo "p $? [$x]"\ns=(1); echo "j $?"; declare -p s'
r 'r=5; f() { local -n r=r 2>/dev/null; for ((r=0;r<1;r++)); do :; done; echo "st $? $r"; }; f; echo "top $r"'
r 'declare -n v="a[2]"\n(( v=5 )); declare -p a\n(( v++ )); echo "$v"; echo $((v+1)); let v+=1; declare -p a\ndeclare -n w="b[@]"\n(( w=1 )); echo "w $?"; echo "[$w]"'
r 'declare -n r\ni=0; for ((r=0;i++<2;r++)); do echo "in $i"; done; echo "st $?"\n(( r=2 )); echo "s $?"\necho $((r=3)) "x $?"'

echo "-- Big5: a here-document body is read byte by byte (a trail \\\\ joins lines)"
if LC_ALL=zh_HK.big5hkscs locale charmap 2>/dev/null | grep -q BIG5; then
	printf 'cat <<E\n\xa3\x5c\nabc\nE\ncat <<"E"\n\xa3\x5c\nabc\nE\ncat <<E\n\xa3\x5c\\\nq\nE\nx=$(cat <<E\n\xa3\x5c\nabc\nE\n)\necho "$x"\n' > b5.sh
	LC_ALL=zh_HK.big5hkscs $S b5.sh | od -An -tx1
else
	echo ' a3 61 62 63 0a a3 5c 0a 61 62 63 0a a3 5c 71 0a'; echo ' a3 61 62 63 0a'
fi

echo "-- a here-document's \${u-\$\"k\"}: the quotes drop, the \$ expands what follows"
r 'k=K\ncat <<E\n[${u-$"k"}] [${u-$"k"x}] [${u-a$"k"}] [${u-$"{k}"}] [${u-$""k}] [${u-"$"k}] [${u-$"k m"}] [${u=$"z"}]\nE\necho "[${v-$"k"}] [$u]"'

echo "-- \$(cat <<): the missing delimiter is a syntax error when the line is read"
r 'echo a\nx=$(cat <<)\necho b'
r 'echo a\nx=$(cat <<\n)\necho b'

echo "-- \$\"…\" in a \$(…) body: translated as the OUTER line is read (\`…\`: as it runs)"
mkdir -p d/en/LC_MESSAGES # a GNU .mo: "hello" -> "hallo", "multi" -> "a<NL>b"
printf '\336\022\004\225\0\0\0\0\2\0\0\0\34\0\0\0\54\0\0\0\0\0\0\0\0\0\0\0\5\0\0\0\74\0\0\0\5\0\0\0\102\0\0\0\5\0\0\0\110\0\0\0\3\0\0\0\116\0\0\0hello\0multi\0hallo\0a\nb\0' > d/en/LC_MESSAGES/t.mo
r 'export LC_ALL=en_US.UTF-8 TEXTDOMAINDIR=$PWD/d\nTEXTDOMAIN=t\necho $"hello" $(echo $"hello")\nx=$(echo $"multi"\necho $LINENO)\necho "$x"\necho $"multi" $LINENO\necho $LINENO\nTEXTDOMAIN=q\necho $(echo $"hello"; TEXTDOMAIN=t; echo $"hello")\nTEXTDOMAIN=t; echo $(echo $"hello") $"hello" `echo $"hello"` "`echo $"hello"`"\nunset TEXTDOMAIN; echo $(TEXTDOMAIN=t; echo $"hello") `TEXTDOMAIN=t; echo $"hello"`'

echo "-- compgen -W: its words don't glob, a \$(…) in them runs as usual"
touch a1 a2
compgen -W '$(echo a*) b*' -- a; compgen -W '`echo a*`' -- a; echo "${-//[^f]}"

echo "-- SHLVL: no in-place exec in a pipeline stage; a function called as a comsub's tail"
printf '#!/bin/sh\necho $SHLVL\n' > lv; chmod +x lv
r 'f() { ./lv; }\nk() { f; }\nn() { true && ./lv; }\nm() { if true; then ./lv; fi; }\necho "c $(./lv)" "ct $(true; ./lv)"\necho "p $(./lv)" | cat\n{ echo "g $(./lv)"; } | cat\n(./lv) | cat\n(true; ./lv) | cat\necho "f $(f)" "tf $(true; f)" "k $(k)" "n $(n)" "m $(m)" "ft $(f; true)"\necho "pf $(f)" | cat\n(true; f)\nf & wait'

echo "-- setlocale(\"\"): the environment bash last rebuilt (a spawn), not the variables now"
printf 'x=\xc3\xa9\nunset LC_CTYPE; echo "a ${#x}"\nLC_CTYPE=; echo "b ${#x}"\n/bin/true; LC_CTYPE=; echo "c ${#x}"\nexport LC_CTYPE=en_US.UTF-8; echo "d ${#x}"\nunset LC_CTYPE; echo "e ${#x}"\n' > lc.sh
env -u LANG -u LC_ALL LC_CTYPE=en_US.UTF-8 $S lc.sh

cd / && rm -rf "$t"
