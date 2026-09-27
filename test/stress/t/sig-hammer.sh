#@ guards: signals from OUTSIDE at random intervals (a detached sender hammering $$ with USR1/USR2/HUP) while the shell runs a hot compiled loop, externals, $(…), pipelines, redirections, read from files and `wait`: every syscall a signal interrupts (EINTR) must be resumed, never surface as an error; each trap runs at most once per signal sent and at least once; no work is lost and no zombie is left (signal-preemption's EINTR path, under load)
#@ timeout: 60
#@ iters: 2
# Properties only (the signals' timing is random): every line printed is a verdict.
H=$STH
d=$HOME/hm; mkdir -p "$d"
n1=0 n2=0 n3=0
trap 'n1=$((n1+1))' USR1
trap 'n2=$((n2+1))' USR2
trap 'n3=$((n3+1))' HUP
rm -f "$d"/s1 "$d"/s2 "$d"/s3
"$H" hammer $$ 10 300 200 3000 "$d/s1"
"$H" hammer $$ 12 300 200 3000 "$d/s2"
"$H" hammer $$ 1 150 500 5000 "$d/s3"
work() { # one round of everything interruptible; returns a checksum of what it computed
	local k=$1 x y l acc=0
	x=$(echo "c$k")                                 # comsub + builtin
	y=$(/bin/echo "e$k")                            # comsub + external
	echo "$x $y" >>"$d/log"                         # redirection (append)
	read -r l <"$d/log"                             # read from a file
	l=$(printf '%s\n' a b c | /bin/cat | wc -l)     # a pipeline of externals
	( acc=$((k * 2)); exit $((acc % 7)) ); acc=$?   # subshell status
	/bin/true & wait $!                             # a job, waited
	echo $(( ${#x} + ${#y} + l + acc ))
}
sum=0 i=0 hot=0
until [ -e "$d/s1" ] && [ -e "$d/s2" ] && [ -e "$d/s3" ]; do
	i=$((i+1))
	r=$(work $i); sum=$((sum + r))
	for ((j = 0; j < 2000; j++)); do hot=$((hot + j % 3)); done   # a hot (compiled) loop
done
s1=$(cat "$d/s1") s2=$(cat "$d/s2") s3=$(cat "$d/s3")
# recompute what the rounds must have summed to, with no signals around
trap - USR1 USR2 HUP
exp=0 ehot=0
for ((k = 1; k <= i; k++)); do exp=$((exp + $(work $k))); for ((j = 0; j < 2000; j++)); do ehot=$((ehot + j % 3)); done; done
# (verdicts on stdout; the varying numbers behind a bad one go to stderr, kept as evidence)
echo "work intact: $([ $sum = $exp ] && [ $hot = $ehot ] && echo yes || { echo "NO: sum=$sum exp=$exp hot=$hot/$ehot rounds=$i" >&2; echo NO; })"
echo "log lines: $([ $(wc -l <"$d/log") = $((2 * i)) ] && echo ok || { echo "log: $(wc -l <"$d/log") lines for $i rounds" >&2; echo bad; })"
ok() { [ "$1" -ge 1 ] && [ "$1" -le "$2" ] && echo ok || { echo "$1 traps for $2 signals" >&2; echo bad; }; }
echo "USR1 traps: $(ok $n1 $s1)"
echo "USR2 traps: $(ok $n2 $s2)"
echo "HUP traps: $(ok $n3 $s3)"
z=$(ps -o stat= --ppid $$ | grep -c '^Z'); echo "zombies: $([ $z = 0 ] && echo none || { echo "zombies: $z" >&2; echo SOME; })"
rm -rf "$d"
"$STH" probe
