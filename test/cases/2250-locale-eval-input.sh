# bash-5.2.21 locale.c / eval.c / input.c audit.
# locale.c: LC_ALL > LC_<cat> > LANG precedence (assign/unset/local/empty), the
#   "setlocale: VAR: cannot change locale" warnings, an invalid value leaving the
#   prior locale in force, $"…" translation via TEXTDOMAIN/TEXTDOMAINDIR (at parse
#   time), collation for [[ < ]], LC_NUMERIC in printf/time, case folding.
# eval.c: reader_loop EOF/exit statuses, backslash at EOF, syntax-error line numbers
#   of a script read from stdin, `-i` continuing after an error, IGNOREEOF.
# input.c: a script on stdin that `read`s its own stdin, heredocs, NUL bytes, \r\n.
S=${THIS_SH:-bash}
unset LANGUAGE LC_ALL LC_CTYPE LC_COLLATE LC_MESSAGES LC_NUMERIC LC_TIME
export LANG=en_US.UTF-8
w() { eval "$1" 2>&1 | sed 's/^.*line [0-9]*: //'; }   # normalize diagnostics
c() { sed 's/^[^:]*: //'; }                              # drop a child's "name:" only

## precedence (${#x} counts chars in UTF-8, bytes in C)
x='é'
LC_ALL=C; echo "C:${#x}"
unset LC_ALL; echo "unset:${#x}"
LC_CTYPE=C; echo "ctype:${#x}"
LC_ALL=en_US.UTF-8; echo "all-wins:${#x}"
unset LC_ALL; echo "ctype-again:${#x}"
unset LC_CTYPE; LANG=C; echo "lang:${#x}"
LC_ALL=; echo "empty-all:${#x}"
LANG=en_US.UTF-8; echo "lang-utf:${#x}"; unset LC_ALL

## invalid names warn (LANG and LC_MONETARY don't); only builtins see a prefix
for v in LC_ALL LC_CTYPE LC_COLLATE LC_MESSAGES LC_NUMERIC LC_TIME LANG LC_MONETARY; do
  w "$v=bogus_YY; echo \"$v st=\$?\""
done
w 'LC_ALL=bogus4 true; LC_ALL=bogus5 /bin/true; echo pfx'
w 'f() { local LC_ALL=bogus6; }; f; echo local'
w 'LC_ALL=C.UTF-8; LC_CTYPE=bogus7; echo masked'

## an invalid value leaves the PRIOR locale in force
LANG=C; LC_CTYPE=en_US.UTF-8; echo "a:${#x}"
{ LC_CTYPE=bogus; } 2>/dev/null; echo "b:${#x}"
unset LC_CTYPE; LC_ALL=C.UTF-8; echo "c:${#x}"
{ LC_ALL=bogus; } 2>/dev/null; echo "d:${#x}"
unset LC_ALL; LANG=en_US.UTF-8; LANG=bogus; echo "e:${#x}"
LANG=en_US.UTF-8

## a function-local LC_ALL goes away on return, and the locale with it
[[ a < B ]]; echo "utf a<B $?"
f() { local LC_ALL=C; [[ a < B ]]; echo "local C $?"; }; f
[[ a < B ]]; echo "after f $?"
( LC_COLLATE=C; [[ a < B ]]; echo "sub C $?" ); [[ a < B ]]; echo "after sub $?"
LC_ALL=C test a \< B; echo "test prefix $?"

## LC_NUMERIC: radix in printf and `time`, grouping with %'
LC_NUMERIC=de_DE.UTF-8
printf '%.2f %g\n' 3,5 1,5
printf '%f|%f|\n' 1x 2y 2>/dev/null     # an invalid number mid-format keeps its place
TIMEFORMAT='[%1R]'; { time true; } 2>&1 | tr 0-9 N
printf "%'d\n" 1234567
LC_NUMERIC=en_US.UTF-8; printf "%'d %'.1f\n" 1234567 1234.5
unset LC_NUMERIC TIMEFORMAT

## case modification follows LC_CTYPE, including single-byte (Latin-9) locales
LC_ALL=tr_TR.UTF-8
y=istanbul; echo "${y^^} ${y^}"
LC_ALL=en_US.iso885915
z=$'\xe9t\xe9'; printf '%s' "${z^^}" | od -An -tx1; echo "${#z}"
unset LC_ALL

## $"..." is looked up in $TEXTDOMAINDIR/<lang>/LC_MESSAGES/$TEXTDOMAIN.mo
mkdir -p d/en/LC_MESSAGES     # a minimal GNU .mo: "hello" -> "hallo"
printf '\336\022\004\225\0\0\0\0\1\0\0\0\34\0\0\0\44\0\0\0\0\0\0\0\0\0\0\0\5\0\0\0\54\0\0\0\5\0\0\0\62\0\0\0hello\0hallo\0' > d/en/LC_MESSAGES/t.mo
LC_ALL=en_US.UTF-8
echo $"hello" "no domain"
TEXTDOMAIN=t TEXTDOMAINDIR=$PWD/d
echo $"hello" "$"hello"" $"other"
v=$"hello"; case hallo in $"hello") echo "case $v";; esac
LC_ALL=C
echo "C:" $"hello"
LC_ALL=en_US.UTF-8; echo "same line, still C:" $"hello"
unset LC_ALL TEXTDOMAIN TEXTDOMAINDIR

## eval.c: end of input
printf 'echo a\nfalse' > nonl.sh; $S nonl.sh; echo "st=$?"
printf 'echo a \\' > bs.sh; $S bs.sh; echo "st=$?"
printf 'echo a; \\\n' | $S 2>&1 | c; echo "st=$?"
printf '(exit 7)\n#comment only' | $S; echo "st=$?"
printf 'exit 1 2\necho still\n' | $S 2>&1 | c
printf 'echo 1\n\necho $LINENO\nnope_cmd\necho 2 )\n' | $S 2>&1 | c; echo "st=$?"
printf 'echo a )\necho b\n' | HOME=$PWD $S --norc -i 2>/dev/null; echo "i st=$?"
printf 'IGNOREEOF=2\necho a\n' | HOME=$PWD $S --norc -i 2>&1 >/dev/null | grep -c 'Use "exit"'

## input.c: a script on stdin shares stdin with the commands it runs
printf 'read x\nhello world\necho "got:$x"\n' > r1.sh; $S < r1.sh
printf 'head -n1 >/dev/null\nskipped\necho after\n' > r2.sh; $S < r2.sh
printf 'if true; then\nread y\necho "y=$y"\nfi\nYDATA\n' | $S
printf 'cat <<E\nbody line\nE\necho after-heredoc\n' | $S 2>/dev/null
printf 'v=%s\necho ${#v}\n' "$(printf '%*s' 20000 '' | tr ' ' x)" | $S

## NUL bytes are dropped from input (a NUL on line 1 of a file => binary)
printf 'echo a\0b\necho c\n' | $S 2>&1 | od -An -c
printf 'echo a\necho b\0c\n' > nul.sh; $S nul.sh 2>&1 | od -An -c
printf 'echo a\0b\n' > nul1.sh; $S nul1.sh 2>&1 | c; echo "st=${PIPESTATUS[0]}"

## \r is an ordinary word character: `fi\r` is not `fi`
printf 'echo one\r\n' | $S | od -An -c
printf 'if true; then echo y; fi\r\necho z\n' | $S 2>&1 | c | od -An -c
printf '{ echo g; }\r\n' | $S 2>&1 | c | od -An -c
