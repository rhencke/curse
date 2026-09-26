# An interactive shell's history at exit (bashhist.c maybe_save_shell_history): only this
# session's lines are APPENDED to $HISTFILE, each with its timestamp line when
# HISTTIMEFORMAT is set (as `history -a` — not the lines read from the file again) —
# histappend or not; when HISTSIZE left fewer lines in the list than the session added,
# the list is rewritten; nothing new, nothing written. Then the file is cut to
# HISTFILESIZE.
S=${THIS_SH:-bash}
t=${TMPDIR:-/tmp}/c2431.$$; mkdir -p "$t"; cd "$t" || exit 1
export HOME=$t # (no ~/.bashrc)
run() { # the file before, then the session's input (then any environment)
	printf "$1" > hf
	printf '%s\n' "$2" | env -u HISTFILESIZE -u HISTSIZE HISTFILE=$t/hf PS1= $3 "$S" -i >/dev/null 2>&1
	echo "== $2 $3"
	sed 's/^#[0-9][0-9]*$/#TS/' hf
}
run 'old1\nold2\n' 'echo a'
run 'old1\nold2\n' 'shopt -s histappend
echo b'
run 'old1\nold2\n' 'echo c' HISTTIMEFORMAT=%s
run 'old1\nold2\n' 'HISTSIZE=1
echo d
echo e'
run 'old1\nold2\nold3\n' 'HISTFILESIZE=2
echo f'
run 'old1\n' 'history -a
history -c'
cd / && rm -rf "$t"
