# `$!` of a plain external command run with `&` is the REAL pid of that program, in every
# path the command can take (top level, set -m, a function, eval, a hot loop, a trap):
# /proc/$! exists, ps finds it, kill $! and wait $! reach it, and jobs -l/-p agree.
pidmax=$(cat /proc/sys/kernel/pid_max)
real() { # real PID: a live process of ours, not a synthetic number
	if [ "$1" -le "$pidmax" ] && [ -d "/proc/$1" ] && ps -o pid= -p "$1" >/dev/null; then echo real; else echo "not-real"; fi
}
check() { # LABEL: start a sleeper, prove $! real, jobs agree, kill it, wait for 143
	/bin/sleep 5 &
	p=$!
	echo "$1: $(real "$p")"
	jobs -p >"$T"; read -r jp <"$T"; [ "$jp" = "$p" ] && echo "$1: jobs -p = \$!"
	jobs -l >"$T"; read -r _ jl _ <"$T"; [ "$jl" = "$p" ] && echo "$1: jobs -l pid = \$!"
	kill "$p"
	wait "$p"
	echo "$1: wait status $?"
	[ -d "/proc/$p" ] || echo "$1: reaped"
}
T=$(mktemp)

check top

# wait $! yields the program's own exit status
/bin/sh -c 'exit 7' &
wait $!
echo "exit-7 status $?"

# expanded (pure) arguments still spawn the program itself
n=5 w=sle
/bin/${w}ep "${n:-1}" &
echo "expanded: $(real $!)"
kill $!; wait $!; echo "expanded status $?"

# STOP / CONT reach the real process
/bin/sleep 5 &
p=$!
kill -STOP $p
i=0; st=
while [ $i -lt 100 ]; do st=$(ps -o stat= -p $p); case $st in T*) break ;; esac; i=$((i + 1)); /bin/sleep 0.02; done
echo "stopped: ${st%%[!T]*}"
kill -CONT $p
kill $p; wait $p; echo "stop-cont status $?"

# a function and eval
f() { check func; }
f
eval 'check eval'
eval '/bin/sleep 5 & q=$!'
echo "eval-bang: $(real $q)"; kill $q; wait $q; echo "eval-bang status $?"

# a trap handler
trap 'check trap' USR1
kill -USR1 $$
trap - USR1

# a hot loop: every $! is a distinct real pid (not a synthetic one past pid_max)
prev= bad=0 same=0
for ((k = 0; k < 160; k++)); do
	/bin/true &
	b=$!
	[ "$b" -le "$pidmax" ] || bad=$((bad + 1))
	[ "$b" = "$prev" ] && same=$((same + 1))
	wait "$b" || bad=$((bad + 1))
	prev=$b
done
echo "loop: bad=$bad same=$same"

# set -m: the job leads a process group of its own
set -m
check monitor
/bin/sleep 5 &
p=$!
g=$(ps -o pgid= -p $p); g=${g// /}
[ "$g" = "$p" ] && echo "monitor: own pgrp"
kill $p; wait $p; echo "monitor status $?"
set +m
/bin/sleep 5 &
p=$!
g=$(ps -o pgid= -p $p); g=${g// /}
m=$(ps -o pgid= -p $$); m=${m// /}
[ "$g" = "$m" ] && echo "nomonitor: shell's pgrp"
kill $p; wait $p; echo "nomonitor status $?"
rm -f "$T"

# the job's words are still the job's to expand: an expansion error is reported once, by
# the job (its line), and the shell carries on; no side effect reaches the shell
/bin/echo a b &
wait; echo "_=$_"
/bin/echo $((1/0)) &
wait; echo "div status $?"
x='a  b'; /bin/echo $x "${x}" ${x:-$(echo z)} &
wait
unset u; ( set -u; /bin/echo $u & wait; echo "nounset: went on" ); echo "nounset status $?"
a=(1 2 3); i=0; /bin/echo ${a[i]} ${#a[@]} ${a[i++]} &
wait; echo "i=$i"
: ${d:=unset}; /bin/echo ${d:=x} ${e:=y} & wait; echo "e=${e-unset}"
nosuchcmd_zz arg &
wait $!; echo "notfound status $?"
