#@ guards: readline's keymaps and variables are PROCESS-global, and a daemon worker serves one script after another: a script that ran `bind` at its top level left its bindings for the next script on that worker (case 2300's own warm rerun saw the cold run's `"\C-xq": "outer"` and a subshell's leaked binding). A worker whose script bound keys at its top level now retires after it, as it does after lowering a hard rlimit
#@ timeout: 120
#@ iters: 0.5
S=$THIS_SH
n=0 N=20
for ((i = 0; i < N; i++)); do
	"$S" -c 'bind "\"\C-xq\": \"outer$1\"" 2>/dev/null; bind "set bell-style visible" 2>/dev/null' _ "$i" </dev/null
	c=$("$S" -c 'bind -s 2>/dev/null | grep -c "C-xq"; bind -v 2>/dev/null | grep -c "bell-style visible"' </dev/null | tr -d '\n')
	[ "$c" = 00 ] && n=$((n + 1))
done
echo "scripts that started with readline's defaults: $n/$N"
