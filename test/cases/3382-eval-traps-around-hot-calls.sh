# Traps set by eval'd text while a hot loop calls small functions: every call behaves as
# bash's — the hooks fire (or don't) exactly as they would with no shortcut taken. (curse's
# compiled tier splices such calls, or skips their trap guard, only while no trap is set.)
inc() { n=$((n + 1)); }
bump() { n=$((n + $1)); false; }
say() { echo "say $1"; }
n=0
for ((i = 0; i < 400; i++)); do
	inc
	case $i in
	150) eval "trap 'echo DEBUG \$n' DEBUG" ;;
	151) eval "trap - DEBUG" ;;
	200) eval "trap 'echo ERR \$n \$?' ERR" ;;
	201) bump 10 ;;
	202) eval "trap - ERR" ;;
	250) eval "set -o functrace; trap 'echo RET \$n' RETURN" ;;
	252) eval "trap - RETURN; set +o functrace" ;;
	esac
done
echo "n=$n"
# a signal trap whose handler returns from the function it interrupted
arm() { eval "trap 'return 7' USR1"; kill -USR1 $$; echo "not reached"; }
quiet() { m=$((m + 1)); }
m=0
for ((i = 0; i < 200; i++)); do
	quiet
	if ((i == 160)); then arm; echo "arm $?"; trap - USR1; fi
done
echo "m=$m"
# a function that arms the trap by calling one that does
sets() { eval "trap 'return 4' USR2"; }
outer() { sets; kill -USR2 $$; echo "not reached"; }
for ((i = 0; i < 160; i++)); do quiet; done
outer; echo "outer $?"; trap - USR2
# $FUNCNEST set by eval: a call nested past it fails, and bash abandons the loop
g() { inc; }
for ((i = 0; i < 200; i++)); do
	inc
	if ((i == 170)); then eval "FUNCNEST=1"; g; echo "g $?"; fi
done
echo "n=$n i=$i"
