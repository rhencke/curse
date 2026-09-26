# `NAME --help`, the builtin_error / internal_error prologs of a nameless message, a
# backquoted `< …` body's syntax error, and gettext's memory of a translation.
# - --help (internal_getopt's GETOPT_HELP, no_options, CHECK_HELPOPT) is the builtin's help
#   and status 2 — as the first argument, or where an option word goes; echo, test/[, :,
#   true, false take it as an argument; bind shows only its usage line. A special
#   builtin's --help is a usage error, so fatal in posix mode; `return --help` and
#   `exit --help` (even from an expansion) don't return / exit; exec's redirections stay.
# - under fr_FR, sh_invalidid's `X': not a valid identifier (builtin_error: `ligne N :`)
#   vs check_identifier's for/select/function/coproc names (internal_error: ` ligne N:`)
# - a `…` body starting with `<` is parsed in the shell itself first ($(< file)): its
#   syntax error is one line on and discards the command (the rest of the line too); a
#   `…` body counts its leading newlines; a redirection missing its word before a
#   newline is `newline'
# - glibc reads $LANGUAGE from the environ bash last rebuilt (a spawn, a $(…), a pipeline,
#   an async command, after a prefix assignment), and keeps a message it translated until
#   the next setlocale
S=${THIS_SH:-bash}
exec 2>&1
unset LANGUAGE

echo "-- --help: the help, status 2"
for b in . alias bg break builtin caller cd command compgen complete compopt continue \
	declare dirs disown enable eval exec exit export fc fg getopts hash help history jobs \
	kill let local logout mapfile popd printf pushd pwd read readarray readonly return set \
	shift shopt source suspend times trap type typeset ulimit umask unalias unset wait; do
	o=$(for i in 1; do "$b" --help; echo "st=$?"; done)
	printf '%s: %s | %s | %s\n' "$b" "${o%%$'\n'*}" "$(echo "$o" | wc -l)" "${o##*$'\n'}"
done
for b in echo test : true false; do "$b" --help; echo "$b st=$?"; done
[ --help ]; echo "[ st=$?"
bind --help; echo "bind st=$?"
echo "-- where an option word goes"
for c in "alias -p" "cd -L" "command -p" "compopt -o default" "declare -a" "enable -a" \
	"fc -l" "hash -r" "help -d" "history -c" "mapfile -t" "readarray -t" "printf -v v" \
	"pwd -L" "read -r" "readonly -a" "export -n" "suspend -f" "type -a" "typeset -a" \
	"ulimit -S" "umask -p" "wait -n" "local -a" "trap -p" "unset -v" "set -e" "exec -c"; do
	o=$($c --help 2>&1; echo "st=$?")
	echo "$c: ${o%%$'\n'*} ${o##*$'\n'}"
done
declare a --help; echo "st=$?"
export b -n; echo "st=$?"
echo "-- through command / builtin, from an expansion"
command cd --help | head -1; echo "st=${PIPESTATUS[0]}"
builtin pwd --help | head -1; echo "st=${PIPESTATUS[0]}"
command -v --help | head -1
h=--help
f() { return $h >/dev/null; echo "f after $?"; return --help >/dev/null; echo "f again $?"; }; f
g() { set -x; return "$h" >/dev/null; set +x; echo "g after $?"; } 2>/dev/null; g
(exit --help >/dev/null; echo "exit after $?"; exit "$h" >/dev/null; echo "again $?")
(builtin exit $h >/dev/null; echo "builtin exit $?")
for i in 1 2; do break $h >/dev/null; continue --help >/dev/null; echo "loop $i $?"; done
set -- a b; shift --help >/dev/null; echo "shift $? $#"
source $h >/dev/null; echo "source $?"
echo "-- exec's redirections stay, even for --help or a bad option"
( exec --help >/dev/null; echo "not shown"; echo "exec $?" >&2 )
( exec -x 2>/dev/null >/dev/null; echo "not shown"; echo "exec -x $?" >&2 )
echo "-- posix: a special builtin's --help ends the shell"
for c in 'eval --help' 'export --help' 'set --help' 'exec --help' 'command eval --help' \
	'cd --help' 'return --help'; do
	$S -o posix -c "$c >/dev/null; echo \"$c: goes on \$?\""; echo "$c: st=$?"
done

echo "-- fr: which prolog a nameless \`X': not a valid identifier gets"
cat > id2360.sh <<'X'
x=a
$x-b() { :; }
for 1a in x; do :; done
select 1a in x; do :; done </dev/null
coproc 1a { :; }
declare -n r='a[1]'; r=(1)
a[1]=x true
declare -n e='z[1]'; coproc e { :; }; wait
declare -n q; for q in 'a b' ok; do :; done
declare -n n3; n3='a b'
unset -n r e q n3
declare -n n6='a[1]'; n6[2]=3
complete -F 'a b' x
set -o posix
function 1a { :; }
X
LC_ALL=fr_FR.UTF-8 $S id2360.sh
LC_ALL=ja_JP.UTF-8 $S id2360.sh | head -7

echo "-- a \`< …\` body: parsed first, one line on, the command discarded"
cat > bq2360.sh <<'X'
echo `<`; echo "not run"
echo "next $?"
x=`< `
echo "n2 $? [$x]"
x=`
<`
echo "n3 $?"
f() { echo `<;`; echo "not in f"; }; f; echo "not after f"
echo "n4 $?"
eval 'echo `<`; echo "not in eval"'; echo "eval $?"
(echo `<`; echo "not in sub"); echo "sub $?"
echo "$(echo `<`)"; echo "cs $?"
echo `< x y`; echo "fine $?"
echo `<<`; echo "heredoc $?"
X
$S bq2360.sh
printf 'set -e\necho `<`\necho "not reached"\n' > bq2360e.sh
$S bq2360e.sh; echo "set -e st=$?"
echo "-- a \`…\` body's line numbers count its leading newlines"
i=0
for s in 'x=`\n>`' 'echo `\n\n>`' 'echo x `\n;;`' 'x=`\n\n;;\n\n`' 'true;x=`\n\n)`' \
	'echo `>\n\n`' 'echo `a >\n`' 'x=`\necho $LINENO`; echo $x' 'echo `\necho $LINENO`' \
	'eval ">\n\n"' 'x=`<\n\n`' 'x=`\n\n<`'; do
	i=$((i+1)); printf "$s\n" > nl2360.sh; $S nl2360.sh
done

echo "-- LANGUAGE: the environ as bash last rebuilt it; a translation, once made, kept"
cat > lg2360.sh <<'X'
export LANGUAGE=de
cd /nonexistent_2360
export LANGUAGE=de
/bin/true
cd /nonexistent_2360
export LANGUAGE=ja
/bin/true
cd /nonexistent_2360
getopts
LC_TIME=C
cd /nonexistent_2360
unset LANGUAGE
x=$(:)
cd /nonexistent_2360
echo $((1/0))
X
env -u LC_ALL -u LANGUAGE LANG=fr_FR.UTF-8 $S lg2360.sh
for pre in 'x=$(:)' ':' ': < <(:)' ': &' ': | :' '(:)' 'x=1 :' 'LANGUAGE=ja /bin/true'; do
	printf 'export LANGUAGE=de\n%s\nLC_TIME=C\ncd /nonexistent_2360\n' "$pre" > lg2360.sh
	echo "$pre => $(env -u LC_ALL -u LANGUAGE LANG=fr_FR.UTF-8 $S lg2360.sh 2>&1 | tail -1)"
done
echo "-- LANGUAGE's list replaces the locale: nothing found, the English text"
echo 'cd /nonexistent_2360' > lg2360.sh
env -u LC_ALL LANGUAGE=xx LANG=fr_FR.UTF-8 $S lg2360.sh
env -u LC_ALL LANGUAGE=xx:de LANG=fr_FR.UTF-8 $S lg2360.sh
rm -f id2360.sh bq2360.sh bq2360e.sh nl2360.sh lg2360.sh
