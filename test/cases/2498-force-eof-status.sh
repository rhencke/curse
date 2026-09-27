# A $( … ) body's syntax error is FORCE_EOF: it ends the whole shell from inside
# eval (status 1), a sourced file (status 1) or a trap handler (2) — and under -c
# every FORCE_EOF reaches run_one_command's top level, which returns 127 (shell.c),
# the -c string's own included.
exec 2>&1
printf 'echo $(fi)\n' > ce.sh
for c in 'echo $(echo a; ;)' 'echo $(fi)' 'x=$(fi)' 'true; echo $(fi); echo after' 'echo $(echo a;;)' \
	'source ./ce.sh; echo after' 'f() { source ./ce.sh; }; f; echo after' 'f() { eval "x=\$(fi)"; }; f; echo after' \
	'trap "x=\$(fi)" USR1; kill -USR1 $$; echo after' 'set -o posix; eval "x=(a \"b"; echo after' 'x=(a' 'fi'; do
	"$THIS_SH" -c "$c" 2>/dev/null; echo "-c [$c] $?"
	"$THIS_SH" -c "eval '$c'; echo after-eval" 2>/dev/null; echo "-c eval [$c] $?"
	printf '%s\necho after $?\n' "$c" > fe.sh
	"$THIS_SH" fe.sh 2>/dev/null; echo "file [$c] $?"
done
n=0
for i in $(seq 160); do (eval 'x=$(fi)') 2>/dev/null; n=$((n + $?)); (source ./ce.sh) 2>/dev/null; n=$((n + $?)); done
echo "n=$n"
rm -f ce.sh fe.sh
