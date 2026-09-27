# bash reads an interactive shell's input with readline even when stdin isn't a terminal
# (`bash -i < pipe`, line editing on): control characters in the input run readline's
# default emacs bindings — history recall (C-p/C-n, M-<, M->, arrow keys), incremental
# search (C-r/C-s: C-j/ESC end it, C-g aborts, any other key ends it and runs), C-o
# operate-and-get-next (accept, then the history entry after it), motion, kills and yanks,
# transpose, quoted-insert, C-d (EOF on an empty line), CR accepts; an edited history line
# stays edited while browsing. (tests/history4.sub drives C-r and C-o this way.) Also:
# load_history truncates $HISTFILE to HISTFILESIZE (defaulting to HISTSIZE) before
# reading it (sv_histsize).
S=${THIS_SH:-bash}
t=${TMPDIR:-/tmp}/c2582.$$; mkdir -p "$t"; cd "$t" || exit 1
export HOME=$t # (no ~/.bashrc)
k=0
rl() { # input (printf format)
	k=$((k + 1))
	printf "$1" | HISTFILE= "$S" --norc -i 2>/dev/null | od -An -c | sed 's/  */ /g; s/^/'"$k"':/'
}
while IFS= read -r l; do rl "$l"; done <<'EOS'
echo a\recho b\n
echo hi
echo abc\x02\x02X\n
echo abc\x01\x06\x06Z\n
echo abc\x05Q\n
echo abcdef\x02\x02\x02\x0b\n
echo aaa bbb\x17ccc\n
echo aaa bbb\x15echo new\n
echo aaa\x08\x08Z\n
echo aaa\x7f\x7fZ\n
echo one\necho two\n\x10\n
echo one\necho two\n\x10\x10\n
echo one\necho two\n\x10\x10\x0e\n
echo one\necho two\n\x12one\n\n
echo one\necho two\n\x12one\x1bX\n
echo one\necho two\n\x12on\x12\n
echo one\necho two\n\x12zz\x07\n
echo one\necho two\necho three\n\x10\x10\x10\x0f\x0f\n
echo one\necho two\necho three\n\x12one\x0f\x0f\n
echo x\x04y\n
\x04echo after\n
echo ab\x14\n
echo aaa bbb\x17\x19\x19\n
echo esc\x1bbX\n
echo foo bar\x1bb\x1bdZ\n
echo q\x16\x01q\n
echo abc\x1b[D\x1b[DX\n
echo one\n\x1b[A\n
echo 'a\nb'\n\x10\n
echo nul\x00x\n
echo one\necho two\n\x12o\x12\x12\x08\n
echo abc\x0b\x01\x0bZ\x19\n
echo one\necho two\necho three\n\x12t\x12\x12\n
echo one\necho two\necho three\n\x12e\x12\x12\x12\x12\n
echo one\necho two\necho three\n\x10\x10\x10\x13t\n\n
echo one\necho two\necho three\n\x1b<\n
echo one\necho two\necho three\n\x10\x10\x1b>X\n
echo one\necho two\n\x12zzz\x08\x08\x08w\n\n
echo one\necho two\n\x12\x12\n
echo one\n\x12on\x12\n\x12\x12\n
echo one\necho two\n\x12o\x07\n
echo one\n\x12one\x1b
echo one\necho two\necho three\n\x10\x10\x0f\x0f\x0f\n
echo one\necho two\necho three\n\x10\x10\x10\x0fecho x\n
HISTSIZE=2\necho one\necho two\necho three\n\x10\x10\x0f\x0f\n
echo é\n
echo aé\x02X\n
echo abc\x1bcX\n
echo abc def\x01\x1bf\x1buX\n
echo a b\x1b#
echo  a   b\x02\x1b\\X\n
echo abc\x1dbX\n
echo one\x0b\x0b\x0b\n
echo aaa bbb\x17\x17\x19\n
echo one\n\x10\x08\x08\x08two\n
echo one\n\x10\x01\x0b\x0e\x10\n
EOS
# hot: a function run 150 times in the session, then recalled and re-run with C-p / C-o
rl 'f() { n=$((n+1)); }\nfor ((i=0;i<150;i++)); do f; done; echo $n\n\x10\n\x10\x10\x10\x0f\x0f\n'
eval 'rl "echo e1\\necho e2\\n\\x12e1\\x0f\\n"'
# (tests/history4.sub) a history file, recalled with C-r + C-o, and replayed with C-p + C-o
printf '%s\n' 'echo 0' 'echo 1' 'echo "(left' 'mid' 'right)"' 'echo A' 'echo B' 'history -w' > hf
printf 'HISTFILE=\n\022left\017\017\017\017\n' | HISTSIZE= HISTFILE=$t/hf "$S" --norc -i 2>/dev/null
printf 'HISTFILE=\n\022left\017\017\017\017\n' | HISTSIZE=4 HISTFILE=$t/hf "$S" --norc -i 2>/dev/null
cat hf
input="$(cat hf)
"$'\cP\cP\cP\cO\cO
'
printf "$input" | HISTSIZE= HISTFILE= "$S" --norc -i 2>/dev/null
printf "$input" | HISTSIZE=6 HISTFILE= "$S" --norc -i 2>/dev/null
# load_history's truncation
seq 20 | sed 's/^/echo /' > hf
printf 'echo x\n' | HISTFILE=$t/hf HISTSIZE=5 "$S" --norc -i >/dev/null 2>&1; cat hf; echo --
seq 20 | sed 's/^/echo /' > hf
printf 'HISTFILE=\n' | HISTFILE=$t/hf HISTSIZE=5 HISTFILESIZE=7 "$S" --norc -i >/dev/null 2>&1; cat hf; echo --
seq 20 | sed 's/^/echo /' > .history
printf 'set -o history\nhistory | wc -l\n' > s; HISTSIZE=3 "$S" s; cat .history
cd / && rm -rf "$t"
