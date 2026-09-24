# trap builtin audit (bash builtins/trap.def + trap.c): listing format/quoting and
# order, decode_signal parsing (legal_number, RTMIN+n, SIG prefix), the first-arg
# heuristic, `--`, posix-mode listing, traps as seen from subshells and $( ) (and a
# function run there), RETURN's $?, and running signal traps synchronously
# after `kill -SIG $$` ($?, nesting, recursion, return/break from a trap).
e() { "$@" 2>&1 | sed 's/^.*line [0-9]*: //'; return ${PIPESTATUS[0]}; }

# showtrap: the action is single-quoted with sh_single_quote (' -> '\'')
trap "it's" HUP; trap "a'b'c" USR1
trap -p HUP USR1
trap - HUP USR1

# listing order: EXIT, signals by number, then DEBUG, ERR, RETURN
trap 'r' RETURN; trap 'e' ERR; trap ':' DEBUG; trap 'x' EXIT; trap 'u' USR1
trap
trap - RETURN ERR DEBUG EXIT USR1

# decode_signal: legal_number (sign, surrounding blanks, leading zeros); no SIG+number
for s in +2 ' 15' '15 ' 00 SIG2 sig15 SIGEXIT 0x1; do
  e trap 'echo x' "$s"; echo "[$s] $?"
done
trap - EXIT
# every realtime number is valid; numbers without a name print numerically
trap 'rt' rtmin+16 RTMIN+30 SIGRTMIN+0 32 33; trap; trap - rtmin+16 rtmin+30 rtmin 32 33
e trap 'x' rtmin+31; e trap 'x' SIGRTMIN+

# `--` ends options: what follows is the action even if it looks like an option
trap -- -p USR1; echo "st=$?"; trap -- -l USR2; trap -p USR1 USR2
trap - USR1 USR2
e trap --help | head -1

# first-arg heuristic: an all-digit signal first = reset all; `trap SIG` alone = reset
trap 'echo x' TRAP USR1; trap 5 USR1; trap -p TRAP USR1; echo "a st=$?"
trap USR2 BOGUS 2>/dev/null; echo "b st=$?"; trap -p

# posix mode: names lose SIG, -p lists defaults as `-`, `trap SIG` is a usage error
(
  set -o posix
  trap 'echo a' USR1; trap '' HUP
  trap
  trap -p EXIT HUP USR1 TERM DEBUG RTMAX 32
  e trap USR1; echo "st=$?"; trap -p USR1
)

# subshells: a trap command with only a bad spec still drops inherited strings
trap 'echo h' HUP; trap '' USR2
( trap 'x' 99 2>/dev/null; trap ) | sed 's/^/c: /'
trap - HUP USR2

# a function listing traps in a subshell/$( ) sees ERR/RETURN (not TRAPPED there),
# the RETURN trap does not fire in the subshell, and the parent keeps its traps
trap 'echo ERR' ERR
trap 'echo RET' RETURN
f() { trap; echo "--"; }
echo "cs: $(f)"
( f )
false
trap -p ERR RETURN
trap - ERR RETURN

# RETURN trap sees $? from before `return N`
echo 'false; return 3' > src.sh
trap 'echo "RET st=$?"' RETURN
. ./src.sh; echo "st=$?"
set -T; g() { false; return 4; }; g; echo "st=$?"; set +T
trap - RETURN

# a signal trap runs after kill returns: $? in it is kill's status
trap 'echo "in usr1 st=$?"' USR1
(exit 7); kill -USR1 $$; echo "after st=$?"
kill -USR1 $$ $$ $$; echo "coalesced st=$?"
# another signal sent from inside a handler runs at once (nested)
trap 'echo h-in; kill -USR2 $$; echo h-out' HUP
trap 'echo u2' USR2
kill -HUP $$
# the same signal from inside its own handler recurses
n=0
trap 'n=$((n+1)); echo "t$n"; [ $n -lt 3 ] && kill -TERM $$; echo "t$n-end"' TERM
kill -TERM $$; echo "n=$n"
trap - TERM HUP

# return / break inside a signal trap act on the interrupted function / loop
trap 'echo "usr2 st=$?"; return 9' USR2
g() { kill -USR2 $$; echo "g continued"; }
g; echo "g ret=$?"
trap 'echo in-trap; break' USR1
for i in 1 2 3; do [ $i = 2 ] && kill -USR1 $$; echo "i=$i"; done
echo "after loop i=$i"
trap - USR1 USR2

# `return` in a trap handler returns from the function (or sourced file) it
# interrupted — the ERR-trap idiom; a bare `return` gives the pre-trap status
f() { trap 'return 7' ERR; false; echo "not reached"; }
f; echo "f ret=$?"
trap - ERR
h() { trap 'return' USR1; false; kill -USR1 $BASHPID; echo "not reached"; }
h; echo "h ret=$?"
trap - USR1
in1() { trap 'return 4' ERR; false; echo "not reached"; }
out1() { in1; echo "out1 sees $?"; trap - ERR; echo "out1 end"; }
out1; echo "out1 ret=$?"
s1() { ( trap 'return 5' ERR; false; echo "not reached" ); echo "sub $?"
  x=$(trap 'return 6' ERR; false; echo "not reached"); echo "cs $? [$x]"; }
s1; echo "s1 ret=$?"
trap - ERR
l() { trap 'return 12' ERR; for i in 1 2 3; do [ $i = 2 ] && false; echo "l $i"; done; }
l; echo "l ret=$?"
trap - ERR
printf '%s\n' "trap 'return 8' ERR" 'false' 'echo "not reached"' > src.sh
. ./src.sh; echo "src ret=$?"
trap - ERR
printf '%s\n' "trap 'return 2' USR1" > src.sh
. ./src.sh
m() { kill -USR1 $$; echo "not reached"; }
m; echo "m ret=$?"
# ...but at the top level it is an error, and the handler goes on
trap 'echo a; return 5; echo b' USR1
kill -USR1 $$; echo "top st=$?"
trap - USR1
rm -f src.sh
