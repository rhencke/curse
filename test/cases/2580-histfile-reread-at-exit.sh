# An interactive shell saves its history at exit only when `set -o history` is still on
# (shell.c exit_shell: `if (remember_on_history) maybe_save_shell_history ()`), and
# maybe_save_shell_history (bashhist.c) reads $HISTFILE THEN: unsetting or emptying it
# mid-session writes nothing, a new $HISTFILE gets the session's lines instead.
S=${THIS_SH:-bash}
t=${TMPDIR:-/tmp}/c2580.$$; mkdir -p "$t"; cd "$t" || exit 1
export HOME=$t # (no ~/.bashrc)
run() { # the session's input
	printf 'old\n' > hf; rm -f hf2
	printf '%s\n' "$1" | env -u HISTFILESIZE -u HISTSIZE HISTFILE=$t/hf PS1= "$S" -i >/dev/null 2>&1
	echo "== $1"; cat hf; [ -e hf2 ] && { echo "-- hf2"; cat hf2; }
}
hot='f() { x=$((x+1)); }; for ((i=0;i<200;i++)); do f; done; echo $x'
run "echo a
$hot
unset HISTFILE"
run "echo b
HISTFILE="
run "echo c
$hot
set +o history"
run 'set +o history
echo d
set -o history'
run "echo e
$hot
HISTFILE=\$HOME/hf2"
run 'echo f
set +o history
echo g
set -o history'
run "echo h
eval 'unset HISTFILE'"
run "echo i
trap 'set +o history' EXIT"
printf 'HISTFILE=$HOME/hf2\n' > src
run "echo j
. ./src"
run "echo k
g() { HISTFILE=; }; for ((i=0;i<200;i++)); do g; done"
cd / && rm -rf "$t"
