# Traps, jobs and line bookkeeping: an ERR trap set inside a pipeline stage, `wait`'s
# POSIX retention of $!'s job, $BASH_COMMAND after eval/source, $(…) line numbering after
# an eval, a foreground job's report line (bash's restored line_number), a background
# pipeline killed by `kill %N`, break/continue as a pipeline stage or async job inside a
# loop, `break N` from a $(…) in a loop, return from trap handlers, circular namerefs,
# and a readonly prefix assignment reported before the command's redirections.
S=${THIS_SH:-bash}
t=${TMPDIR:-/tmp}/c2310.$$; mkdir -p "$t"
# run a script file; normalize pids and the script's path
r() { $S "$t/$1" 2>&1 | sed -e 's/[0-9][0-9][0-9][0-9]*/N/g' -e "s#^.*/$1: #$1: #"; echo "st=${PIPESTATUS[0]}"; }

echo "-- ERR trap set in a function that runs as a pipeline stage fires there"
g() { trap return ERR; false; echo no; }; g | cat; echo "g=$?"
trap - ERR
h() { false; echo yes; }; trap 'echo ERR-h' ERR; h | cat
trap - ERR

echo "-- wait: \$!'s job stays listed when it had already ended"
cat > "$t/w.sh" <<'EOF'
dead() { while kill -0 "$1" 2>/dev/null; do sleep 0.02; done; }
sleep 3 & a=$!; sleep 3 & b=$!; kill %1 %2; dead $a; dead $b; wait; jobs; echo ---
sleep 3 & kill %1; dead $!
jobs; echo ---
(exit 3) & p=$!; sleep 0.1 & wait; wait $p; echo "p=$?"
EOF
r w.sh

echo "-- \$BASH_COMMAND after eval / source is the eval / source again"
printf 'false\n' > "$t/sf.sh"
cat > "$t/b.sh" <<'EOF'
trap 'echo "ERR: $BASH_COMMAND"' ERR
eval 'false'
eval 'true; false'
f() { eval 'false'; }; f
. "$1"
echo end
EOF
$S "$t/b.sh" "$t/sf.sh" 2>&1 | sed "s#$t/##"

echo "-- a \$(…) after an eval'd command numbers from its own line"
f() { echo "L=${BASH_LINENO[*]}"; }
k() {
  for i in 1 2; do
    x=$(eval 'echo ${BASH_LINENO[*]}')
    echo "$x $(eval 'echo $LINENO')"
    echo "$(eval f)" "${x:-$(eval f)}" "${y:-$(eval f)}"
  done
}
k

echo "-- a foreground job's report line: the enclosing context's"
cat > "$t/j.sh" <<'EOF'
if true; then
  sh -c 'kill -SEGV $$'
fi
f()
{
  sh -c 'kill -SEGV $$'
  echo f
}
f
k() { case a in
  a) sh -c 'kill -SEGV $$' ;;
  esac
  if [[ a ]]; then
    sh -c 'kill -SEGV $$'
  fi
}
k
for i in 1; do
  sh -c 'kill -ABRT $$'; echo z
done
for ((i=0;i<1;i++)); do
  sh -c 'kill -SEGV $$' | cat
done
eval 'true
sh -c "kill -SEGV \$\$"
true'
cat <<E; sh -c 'kill -SEGV $$'
a
E
(
 sh -c 'kill -SEGV $$'
 echo in
)
echo end
EOF
r j.sh

echo "-- a background pipeline killed by kill %N: no foreground report"
cat > "$t/p.sh" <<'EOF'
sleep 1 | cat &
sleep 0.2
kill %1; wait %1; echo "pipe=$?"
EOF
r p.sh

echo "-- break/continue as a pipeline stage or async job in a loop: silent"
for i in 1 2; do break | cat; echo "x$i"; done
for i in 1 2; do echo | break; echo "y$i"; done
for i in 1 2; do break & wait; echo "z$i"; done
for i in 1 2; do continue | cat; echo "c$i"; done
for i in 1 2; do { break; } | cat; echo "g$i"; done 2>&1 | sed 's/^.*line [0-9]*: //'
break | cat 2>&1 | sed 's/^.*line [0-9]*: //'

echo "-- break N from a \$(…) in a loop ends the substitution"
for i in 1 2; do x=$(for j in 1; do break 2; done; echo in2); echo "[$x] $i"; done
for i in 1 2; do x=$(for j in 1; do continue 2; done; echo in3); echo "[$x] $i"; done
for i in 1; do x=$(while :; do for k in 1; do break 3; done; echo no; done; echo in6); echo "[$x]"; done
for i in 1 2; do ( for j in 1; do break 2; done; echo in7 ); echo "p$i"; done

echo "-- return from a trap handler"
cat > "$t/t.sh" <<'EOF'
h() { trap 'return' USR1; false; kill -USR1 $BASHPID; echo notreached; }
h; echo "h=$?"
trap - USR1
f() { trap 'return 7' ERR; false; echo no; }
f; echo "f=$?"
trap - ERR
printf 'return 5\n' > "$1"
m() { . "$1"; echo "m-after $?"; }
m "$1"; echo "m=$?"
k() { trap 'echo inerr; return 3' ERR; . "$1"; echo "k-after $?"; }
k "$1"; echo "k=$?"
trap - ERR
g() { trap "return" ERR; true; false; echo no; }
g; echo "g=$?"
EOF
$S "$t/t.sh" "$t/rs.sh" 2>&1

echo "-- circular namerefs"
cat > "$t/n.sh" <<'EOF'
declare -n c1=c2 c2=c1
c1=5; echo "same-line $?"
echo "next $?"
d() { c1=1; echo "after $?"; }
d; echo "d=$?"
f() { declare -n a=b b=a; a=1; echo "in-f $?"; }
f; echo "f=$? a=$a"
c1=7 && echo and-list
c1=2 env | grep '^c1='; echo "te $?"
declare c1=3; echo "decl $?"; declare -p c1 c2
echo "[$c1]"
echo x; c2=3; echo y
EOF
r n.sh

echo "-- a readonly prefix is reported before the command's redirections"
cat > "$t/ro.sh" <<'EOF'
readonly ro=1
f() { echo "in f"; }
ro=2 f 2>&1 | sed 's/^/S:/'
ro=2 echo hi 2>&1 | sed 's/^/E:/'
ro=2 f 2>/dev/null; echo "st=$?"
ro=2 cat /dev/null 2>/dev/null; echo "st=$?"
ro=2 cat /dev/null; echo "st=$?"
declare -n c1=c2 c2=c1
{ c1=5; echo after; } 2>&1 | sed 's/^/C:/'
EOF
r ro.sh

rm -rf "$t"
