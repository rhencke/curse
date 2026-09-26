# Builtin option parsing as bash's internal_getopt (builtins/bashgetopt.c) + the callers'
# CASE_HELPOPT / builtin_usage: an exact `--` ends the options, a lone `-` is an operand,
# bundles and attached/separate arguments, `--help` the builtin's help (status 2), a bad
# letter `-X: invalid option` + the usage line (status 2), a missing argument `-X: option
# requires an argument` + usage, `+X` in the message for a `+` option, and each
# builtin's own diagnostics after its options.
S=${THIS_SH:-bash}
exec 2>&1
t=${TMPDIR:-/tmp}/c2430.$$; mkdir -p "$t"; cd "$t" || exit 1
p() { # each probe in a fresh shell: its output, then its status
	printf '%s\n' "$1" > p.sh
	echo "[$1]"
	"$S" p.sh
	echo "st=$?"
}

echo "-- invalid options: the first bad letter, the usage line, status 2"
for c in alias unalias hash type disown history shopt umask trap jobs pwd suspend \
	enable help wait read mapfile readarray printf fc ulimit times caller getopts \
	source . eval; do
	p "$c -Z"
done
p 'alias -pZ'
p 'type -tZa ls'
p 'hash --x'
p 'history -5'
p 'read -rd'
p 'f() { local -aZ x; }; f'
p 'f() { local +Z x; }; f'
p 'f() { local -f -Z f; }; f'
p 'declare -Z'
p 'compgen -Z'
p 'compgen -p'
p 'complete -Z'
p 'compopt +Z'
p 'bind -Z'

echo "-- missing arguments"
for c in 'hash -p' 'history -d' 'read -a' 'read -rn' 'mapfile -n' 'printf -v' 'fc -e' \
	'enable -f' 'wait -p' 'exec -a' 'compgen -W' 'compopt -o' 'compopt +o' 'bind -m'; do
	p "$c"
done
p 'hash -d'
p 'hash -t'

echo "-- --help: the builtin's help (first line), status 2"
for c in alias hash type history shopt umask trap read printf times getopts source eval exec; do
	p "$c --help | head -1; exit \${PIPESTATUS[0]}"
done
p 'f() { local --help | head -1; }; f'
p 'bind --help'

echo "-- -- and - and attached arguments"
p 'alias -- -p=1; alias -p'
p 'type -- -t'
p 'read -rd: a <<< "x:y"; echo "$a"'
p 'read -rN3 -n2 a <<< abcdef; echo "$a"'
p 'printf -vx %s y; echo "$x"; printf -- -v; echo'
p 'mapfile -tn2 a < /etc/passwd; echo ${#a[@]}'
p 'hash -p/bin/ls ll; hash -t ll'
p 'umask -pS 022; umask'
p 'shopt -qs extglob; echo $?; shopt -p extglob'
p 'history -ps a b'
p 'trap -pl | head -1'
p 'ulimit -S -n; ulimit -Sn'
p 'caller -- 0; echo $?'
p 'getopts -- a x; echo "$x"'
p 'eval -- echo hi'
p 'source -- /dev/null; echo $?'
p 'times -- | wc -l'
p 'pwd -LPL >/dev/null; echo $?'
p 'jobs -lx echo'
p 'bind -x foo'
p 'bind -xfoo'

echo "-- posix mode: an option error in a special builtin exits"
for c in 'trap -Z' 'eval -Z' 'source -Z' 'times -Z' 'exec -Z' 'set -Z'; do
	p "set -o posix; $c; echo after"
done
p 'set -o posix; pwd -Z; echo after'

echo "-- usage lines of the operand checks"
p 'unalias'
p 'caller x'
p 'getopts'
p 'source'
p 'dirs -Z'
p 'pushd -Z'
p 'popd +x'

echo "-- translated (de_DE)"
for c in 'alias -Z' 'hash -p' 'unalias' 'caller x' 'trap -Z' 'popd x'; do
	printf '%s\n' "$c" > p.sh
	echo "[$c]"
	env -u LANGUAGE LC_ALL=de_DE.UTF-8 "$S" p.sh
	echo "st=$?"
done
cd / && rm -rf "$t"
