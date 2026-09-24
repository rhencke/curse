# bash test.c (the test/[ builtin, plus unary_test/arithcomp shared with [[ ]]):
# integer operands go through legal_number (strtoimax: leading isspace, trailing only
# blank/tab, overflow is an error); -v N is "is $N set" for any legal_number N; -R is a
# nameref test; `-t` takes its fd operand only when it is a number (else it is -t 1 and
# the next word is left to the parser); [[ -eq ]] arith errors just make that primary
# false; file-test corners (missing/dangling files, -N, -h '').
t() { "$@" 2>&1 | sed 's/^.*line [0-9]*: //'; echo "st=${PIPESTATUS[0]}"; }

# --- integer operands: legal_number whitespace, sign, overflow ---
for a in ' 12 ' $'\n3' $'3\t' $'3\n' $'3\r' + - '+-1' 9223372036854775807 \
         9223372036854775808 -9223372036854775808 -9223372036854775809 99999999999999999999; do
  printf '%q: ' "$a"; t [ "$a" -eq "$a" ]
done
t test 1 -lt 9223372036854775808
x=99999999999999999999; t [ 1 -lt $x ]
# the same in a hot loop (the compiled tier must not wrap or reject the literal)
i=0; while [ $i -lt 99999999999999999999 ]; do i=$((i+1)); [ $i -gt 150 ] && break; done 2>/dev/null
echo "loop st=$? i=$i"
n=0; for k in $(seq 150); do [ $k -ne 9223372036854775808 ] 2>/dev/null && n=$((n+1)); done; echo "n=$n"

# --- -v N: any legal_number N names a positional parameter ---
set -- a b
for v in 0 1 2 3 -1 ' 1' '2 ' +2 02 99999999999999999999 2x; do
  [ -v "$v" ]; a=$?; test -v "$v"; b=$?; [[ -v $v ]]; printf '%q=%s%s%s\n' "$v" $a $b $?
done
set --

# --- -R: variable is a nameref ---
tgt=1; declare -n ref=tgt; declare -n unsetref
for r in ref tgt unsetref nosuch; do
  [ -R $r ]; a=$?; test -R $r; b=$?; [[ -R $r ]]; echo "R $r=$a$b$?"
done

# --- -t in the expression parser: a non-number operand is not consumed ---
t [ -t -a x -a y ]
t [ -t x -o y ]
t [ x -a -t -o '' ]
t [ -t 99 -a x ]
t [ -t ' 99 ' ]
t [ -t 0x1 ]
t [ -t 4294967297 ]

# --- [[ ]] arithmetic operands: an eval error makes only that primary false ---
f() { [[ 1+ -eq 1 || 1 -eq 1 ]]; echo "a=$?"; }; f 2>&1 | sed 's/^.*line [0-9]*: //'
f() { [[ 1 -eq 2+ || 1 -eq 1 ]]; echo "b=$?"; }; f 2>&1 | sed 's/^.*line [0-9]*: //'
f() { [[ ! 1 -eq 1+ ]]; echo "c=$?"; }; f 2>&1 | sed 's/^.*line [0-9]*: //'
f() { [[ 08 -eq 8 || 1 -eq 1 ]]; echo "d=$?"; }; f 2>&1 | sed 's/^.*line [0-9]*: //'
f() { [[ 1/0 -eq 1 ]] || echo "e=$?"; echo next; }; f 2>&1 | sed 's/^.*line [0-9]*: //'
f() { [[ 1+ -eq 2+ ]]; echo "g=$?"; [[ x -eq 1 && 1/0 -eq 1 ]]; echo "h=$?"; }; f 2>&1 | sed 's/^.*line [0-9]*: //'
g() { for k in $(seq 150); do [[ $k -eq 1+ || $k -gt 0 ]] || echo bad; done 2>/dev/null; echo "hot=$?"; }; g

# --- $? captured right after a test, in a program that also uses declare ---
x=-5; [ "$x" -eq 5 ]; s=$?; echo "s=$s"
for k in $(seq 150); do [ "$k" = 0 ]; s=$?; done; echo "hot s=$s"
declare -i dummy=1
for k in $(seq 150); do false; s=x; s+=$?; done; echo "append s=$s"
# every assignment form reads the PREVIOUS $? in its value (and subscript) before resetting it
false; e[$?]=x; false; e[$?]+=$?; declare -p e; e=(1); false; e+=($?); declare -p e
declare -A as; false; as[$?]=$?; declare -p as
false; declare dx=$?; false; typeset tx=$?; false; export ex=$?; false; readonly rx=$?
false; declare -i ix=$?+1; echo "$dx $tx $ex $rx $ix"; false; ix=$?; false; ix+=$?; echo "ix=$ix"
lf() { false; local lx=$?; echo "local=$lx"; }; lf
false; px=$? env | grep '^px='
tg=; declare -n nr=tg; false; nr=$?; echo "tg=$tg"
for ((i=0;i<150;i++)); do false; hb[i]=$?; (exit 4); hb[i+1]+=$?; done; echo "${hb[149]} ${hb[150]}"
for ((i=0;i<150;i++)); do false; as[k$i]=$?; done; echo "${as[k149]}"

# --- file tests: missing / dangling / -N / empty-name corners ---
: > f; ln -s nowhere dangling; ln -s f lf; mkdir d
touch -d '2001-01-01 00:00:00' old; touch -d '2002-01-01 00:00:00' new
touch -d '2001-01-01 00:00:00.5' frac; touch -d '2001-01-01 00:00:00.25' frac2
touch -a -d '2001-01-01' rd; touch -m -d '2003-01-01' rd
touch -m -d '2001-01-01' ur; touch -a -d '2003-01-01' ur
for p in "f missing" "missing f" "missing missing" "old new" "new old" "frac frac2" \
         "old old" "lf f" "dangling dangling" "dangling f" "d d/"; do
  set -- $p; printf '%s %s:' "$1" "$2"
  for op in -nt -ot -ef; do test "$1" $op "$2"; printf ' %s' $?; done; echo
done
for fl in rd ur f dangling ''; do
  printf '%q:' "$fl"
  for op in -N -h -L -e -f -s; do test $op "$fl"; printf '%s' $?; done; echo
done
