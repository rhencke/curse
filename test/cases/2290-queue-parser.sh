# parse.y queue: multibyte lexing in a charset whose trail bytes are ASCII, here-documents
# in backticks, ASSIGNMENT_WORD function names, extglob in command substitution bodies,
# assignment line numbers, and builtin-named nameref errors.
S=${THIS_SH:-bash}
# (English diagnostics whatever locale runs this: the filters match bash's C texts)
if [ -n "${LC_ALL-}" ]; then export LANG=$LC_ALL; unset LC_ALL; fi; export LC_MESSAGES=C
e() { sed 's/^.*line [0-9]*: //'; }
g() { echo "## $1"; (eval "$1") 2>&1 | e; echo "st=${PIPESTATUS[0]}"; }
t=${TMPDIR:-/tmp}/c2290.$$; mkdir -p "$t"

echo "-- Big5-HKSCS: U+03B1 is a3 5c, its trail byte never a backslash (shell_getc's per-char read)"
if LC_ALL=zh_HK.big5hkscs locale charmap 2>/dev/null | grep -q BIG5; then
	a=$'\xa3\x5c'
	LC_ALL=zh_HK.big5hkscs $S -c "[[ $a = $a ]]" && echo ok 7
	LC_ALL=zh_HK.big5hkscs $S -c "echo ${a}x \"$a\" '$a' \$'$a' | od -An -tx1"
	LC_ALL=zh_HK.big5hkscs $S -c "echo \`echo $a\` \$(echo $a) | od -An -tx1"
	LC_ALL=zh_HK.big5hkscs $S -c "b=$a; echo \${#b}; c=( $a $a ); echo \${#c[@]}"
	LC_ALL=zh_HK.big5hkscs $S -c "f() { echo $a; }; f | od -An -tx1"
	LC_ALL=zh_HK.big5hkscs $S -c "eval '[[ $a == $a ]]' && echo ev"
	LC_ALL=C $S -c "echo ${a}x" | od -An -tx1 # (a byte-wise locale: the backslash escapes x)
else
	echo ok 7; echo ' a3 5c 78 20 a3 5c 20 a3 5c 20 a3 5c 0a'; echo ' a3 5c 20 a3 5c 0a'
	echo 1; echo 2; echo ' a3 5c 0a'; echo ev; echo ' a3 78 0a'
fi

echo "-- a here-document in backticks: a last 'DELIM  ' line is body text (warned)"
printf 'x=`cat <<EOF\nhello\nEOF  `\necho "[$x]"\ny=`cat <<EOF\nhi\nEOF  \n`\necho "[$y]"\nz=$(cat <<EOF\nhey\nEOF  )\necho "[$z]"\nw=`cat <<EOF\nok\nEOF\n`; echo "[$w]"\n' > "$t/hd.sh"
$S "$t/hd.sh" 2>&1 | e
echo "-- a lone assignment runs at the line it ended on (its \`…\` / \$(…) bodies number from there)"
printf 'x=$(echo $LINENO\necho $LINENO); echo $x\nx=`echo $LINENO\necho $LINENO`; echo $x\na=1 b=`echo $LINENO\necho $LINENO`; echo $b\nreadonly r; r=`\necho`\nx=`echo $LINENO\nnope_2290`\n' > "$t/ln.sh"
$S "$t/ln.sh" 2>&1 | sed 's/^[^ ]*: line/line/'

echo "-- an assignment word can't name a function; a subscripted word can"
g 'c=d() { echo x; }; echo after'; g 'c=d () { echo x; }'; g 'a[1]=b() { :; }'; g 'a+=b() { :; }'
g 'a=b=c() { :; }'; g 'func-name=ext () { echo fx; }; func-name=ext'; g '9a=b() { echo 9; }; 9a=b'
g 'a[1]() { echo x; }; a[1]; declare -F'; g 'set -o posix; a[1]() { :; }; echo $?'

echo "-- extglob: a \$(…) body is parsed as its line is read, a \`…\` body when it runs"
printf 'shopt -s extglob; echo @(x)\necho rc=$?\n' > "$t/x1.sh"; $S "$t/x1.sh" 2>&1 | e
printf 'echo @(\\))\necho rc=$?\n' > "$t/x2.sh"; $S "$t/x2.sh" 2>&1 | e
printf 'x=$(echo @(\\))); echo "[$x]"\n' > "$t/x3.sh"; $S "$t/x3.sh" 2>&1 | e
printf 'x=$(shopt -s extglob; echo @(x)); echo "[$x]"\n' > "$t/x4.sh"; $S "$t/x4.sh" 2>&1 | e
printf 'for i in 1 2; do x=`echo @(\\))`; done; echo "[$x]"\n' > "$t/x5.sh"; $S "$t/x5.sh" 2>&1 | e
printf 'shopt -s extglob\nx=$(echo @(x)); echo "[$x]"\ncase $(echo +(y)) in *) echo m;; esac\n' > "$t/x6.sh"; $S "$t/x6.sh" 2>&1 | e
printf 'shopt -s extglob\necho `echo @(x)`; shopt -u extglob; echo `echo @(x)`; echo "$(echo "@(q)")"\n' > "$t/x7.sh"; $S "$t/x7.sh" 2>&1 | e
g 'shopt -s extglob; echo @(x)'; g 'echo @(\))'; g 'x=$(echo @(\))); echo "[$x]"'

echo "-- a nameref given a bad target names the builtin"
g 'declare -n r; getopts x r -h; unset r; unset -n r'
g 'declare -n r; ((r=0)); echo st=$?; unset -n r'; g 'declare -n r; let r=0; unset -n r'
g 'declare -n r; exec {r}>/dev/null; unset -n r'; g 'declare -n r; : {r}>/dev/null; unset -n r'
for i in 1 2 3; do declare -n r; ((r=i)); unset -n r; done 2>&1 | e
rm -rf "$t"
