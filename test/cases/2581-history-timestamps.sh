# History timestamps (readline's history_comment_char): every entry gets one (hist_inittime),
# starting with the comment char CURRENT when it was added — '\0' in a script, but '#'
# once bash_initialize_history ran sv_histchars (an interactive shell; `set -H`), or
# HISTTIMEFORMAT appeared (sv_histtimefmt), or $histchars named one (kept after a shorter
# value; '#' again on unset). history/`history -w` show and write only the stamps under
# the current char. HISTFILESIZE truncation (history_truncate_file) counts a newline only
# when the next line isn't a timestamp under that char.
S=${THIS_SH:-bash}
t=${TMPDIR:-/tmp}/c2581.$$; mkdir -p "$t"; cd "$t" || exit 1
export HOME=$t # (no ~/.bashrc)
TS() { sed 's/[0-9]\{9,\}/TS/g; s/[0-9]\{4\}/Y/g'; }
run() { # the session's input, the history file before
	printf "$2" > hf
	printf '%s\n' "$1" | env -u HISTFILESIZE -u HISTSIZE HISTFILE=$t/hf PS1= "$S" -i 2>/dev/null | TS
	echo "== $1"; TS < hf
}
run 'echo a
HISTTIMEFORMAT="[%%Y] "
history
history -w /dev/stdout' 'old\n'
run 'echo a
histchars="!^#"
history -w /dev/stdout
HISTTIMEFORMAT=X
history' 'old\n'
run 'history -s foo
HISTTIMEFORMAT="<%%Y> "
history' ''
printf '%s\n' 'set -o history
echo x
set -H
echo y
HISTTIMEFORMAT="[%Y] "
history
history -w /dev/stdout
set +H
history -c
histchars="!^%"
echo a
HISTTIMEFORMAT="T "
history
histchars="!^"
history -w /dev/stdout
history -c
histchars="!^%"
unset histchars
echo b
history -w /dev/stdout' > s1
"$S" s1 2>&1 | TS
show() { echo "-- $1"; od -c hf | sed 's/  */ /g'; }
cat > s2 <<'EOS'
HISTFILE=$HOME/hf
printf '#1\na\n#2\nb\n#3\nc\n' > hf; HISTFILESIZE=2; show ts-script
printf '#1\na\n#2\nb\n#3\nc\n' > hf; HISTTIMEFORMAT=; HISTFILESIZE=2; show ts-fmt
printf '#1\na\n#2\nb\n#3\nc\n' > hf; HISTFILESIZE=1; show ts1
printf '#1\na\n#2\nb\n#3\nc' > hf; HISTFILESIZE=1; show nonl
printf '#1\na\n#2\nb\n#3\nc\n' > hf; HISTFILESIZE=0; show zero
printf 'a\nb\nc\n' > hf; HISTFILESIZE=' 2 '; show ws
printf '\n\n\n' > hf; HISTFILESIZE=1; show blanks
printf 'x\n#9\n#8\ny\n' > hf; HISTFILESIZE=1; show dbl
printf '#1\na\n#2\nb\n#3\nc\n' > hf; eval 'HISTFILESIZE=2'; show eval
unset HISTTIMEFORMAT
f() { HISTFILESIZE=$1; }
printf '%s\n' $(seq 300) > hf; for ((i=300;i>=150;i--)); do f $i; done; show hot
printf '#1\na\n#2\nb\n#3\nc\n' > hf; HISTTIMEFORMAT= f 2; show prefix
unset HISTFILE
printf '1\n2\n3\n' > .history; HISTFILESIZE=1; echo "-- unset"; cat .history
EOS
. ./s2
cd / && rm -rf "$t"
