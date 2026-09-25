# A subshell whose LAST command is an external exec'd in its place (bash's CMD_NO_FORK:
# execute_in_subshell / optimize_subshell_command / should_optimize_fork) dies by the
# signal that kills that command, so its PARENT reports the subshell's own text, at the
# parent's line_number (a function body's `{`, a for/case head, the top-level command's
# last line; a non-`{` function body's stale function_bstart). Not exec'd in place — a
# trap of its own, more commands after it, `time` — the subshell reports the inner
# command itself. Also: `( ( … ) )` runs the inner in the outer's process, `! ( … )`
# shows its `!`, `( exec cmd )`, pipeline stages and background pipeline jobs list every
# process, and `time ( … ) 2>f` times inside the subshell's redirections.
S=${THIS_SH:-bash}
t=${TMPDIR:-/tmp}/c2350.$$; mkdir -p "$t"
r() { $S "$t/$1" 2>&1 | sed -e 's/ *[0-9]\{4,\}/ N/g' -e "s#^.*/$1: #$1: #"; echo "st=${PIPESTATUS[0]}"; }

echo "-- the last command of a ( … ): the subshell dies"
cat > "$t/a.sh" <<'EOF'
( sh -c 'kill -KILL $$' ); echo "s=$?"
( :; sh -c 'kill -TERM $$' ); echo "s=$?"
( :; sh -c 'kill -KILL $$' ); echo "s=$?"
( : && sh -c 'kill -KILL $$' ); echo "s=$?"
( sh -c 'kill -KILL $$' 2>/dev/null ); echo "s=$?"
( :; sh -c 'kill -KILL $$' 2>/dev/null ); echo "s=$?"
( sh -c 'kill -HUP $$'; : ); echo "s=$?"
( :; sh -c 'kill -KILL $$' && : ); echo "s=$?"
( sh -c 'kill -INT $$' ); echo "s=$?"
( sh -c 'kill -QUIT $$' ); echo "s=$?"
( sh -c 'kill -SEGV $$' ); echo "s=$?"
( sh -c 'kill -KILL $$' ) >/dev/null; echo "s=$?"
( exec 2>&1; sh -c 'kill -KILL $$' ); echo "s=$?"
( exec sh -c 'kill -KILL $$' ); echo "s=$?"
eval "( sh -c 'kill -KILL \$\$' )"; echo "s=$?"
x=$( sh -c 'kill -KILL $$' ); echo "s=$?"
x=$( ( sh -c 'kill -KILL $$' ) ); echo "s=$?"
EOF
r a.sh

echo "-- traps: its own keep it (the inner command is reported inside)"
cat > "$t/b.sh" <<'EOF'
( trap 'echo t' EXIT; sh -c 'kill -KILL $$' ); echo "s=$?"
( trap 'echo t' USR1; sh -c 'kill -KILL $$' ); echo "s=$?"
( trap '' USR1; sh -c 'kill -KILL $$' ); echo "s=$?"
( trap 'echo e' ERR; sh -c 'kill -KILL $$' ); echo "s=$?"
trap 'echo got' HUP
( sh -c 'kill -HUP $$' ); echo "s=$?"
trap - HUP
EOF
r b.sh

echo "-- the report's line: the parent's"
cat > "$t/c.sh" <<'EOF'
f() {
  echo in f
  ( sh -c 'kill -KILL $$' ); echo "s=$?"
}
f
g() ( sh -c 'kill -KILL $$' )
g; echo "s=$?"
h() { :; }
g2() ( h2() { :; }
  sh -c 'kill -KILL $$' )
g2; echo "s=$?"
function j ( sh -c 'kill -KILL $$' )
j
k() ( sh -c 'kill -TERM $$' )
k; echo "s=$?"
if true
then ( sh -c 'kill -KILL $$' )
fi
for i in 1 2; do
  ( sh -c 'kill -KILL $$' )
done
while true
do
  ( sh -c 'kill -KILL $$' )
  break
done
case x in x) ( sh -c 'kill -KILL $$' ) ;; esac
m() {
  if true; then
    ( sh -c 'kill -KILL $$' )
  fi
}
m
set -e
( sh -c 'kill -KILL $$' ) || echo "s=$?"
EOF
r c.sh

echo "-- nested, negated, timed"
cat > "$t/d.sh" <<'EOF'
( ( sh -c 'kill -KILL $$' ) ); echo "s=$?"
( ( ( sh -c 'kill -KILL $$' ) ) ); echo "s=$?"
( ( kill -KILL $BASHPID ) ); echo "s=$?"
( ( sh -c 'kill -KILL $$' ); : ); echo "s=$?"
( ( sh -c 'kill -KILL $$' ) >/dev/null ); echo "s=$?"
! ( sh -c 'kill -KILL $$' ); echo "s=$?"
( ! ( sh -c 'kill -KILL $$' ) ); echo "s=$?"
TIMEFORMAT=T
time ( sh -c 'kill -KILL $$' ); echo "s=$?"
time ( sh -c 'kill -KILL $$' ) 2>/dev/null; echo "s=$?"
time ( : ) 2>/dev/null; echo "s=$?"
time ( echo x >&2 ) 2>"$1"; echo "s=$?"; cat "$1"
time ! ( : ) 2>/dev/null; echo "s=$?"
time { :; } 2>/dev/null; echo "s=$?"
time ( : ) 2>/dev/null | cat; echo "s=$?"
( sh -c 'echo $SHLVL' )
( :; sh -c 'echo $SHLVL' )
! ( :; sh -c 'echo $SHLVL' )
time ( sh -c 'echo $SHLVL' ) 2>/dev/null
( ( sh -c 'echo $SHLVL' ) )
f() { time ( : ) 2>/dev/null; time ! ( : ); }
declare -f f
EOF
$S "$t/d.sh" "$t/tf" 2>&1 | sed -e 's/ *[0-9]\{4,\}/ N/g' -e "s#^.*/d.sh: #d.sh: #"

echo "-- pipelines and background jobs"
cat > "$t/e.sh" <<'EOF'
( sh -c 'kill -KILL $$' ) | cat; echo "s=$?"
( kill -KILL $BASHPID ) | cat; echo "s=$?"
: | ( kill -KILL $BASHPID ); echo "s=$?"
: | ( sh -c 'kill -KILL $$' ); echo "s=$?"
: | sh -c 'kill -KILL $$'; echo "s=$?"
( sh -c 'kill -KILL $$' ) &
wait $!; echo "w=$?"
: | sh -c 'kill -KILL $$' & wait
: | ( kill -KILL $BASHPID ) & wait
( kill -KILL $BASHPID ) & wait
( sh -c 'kill -KILL $$' ) | cat & wait
: | ( sh -c 'kill -KILL $$' ) & wait
EOF
r e.sh
rm -rf "$t"
