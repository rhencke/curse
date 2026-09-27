# A builtin's failed write (`> /dev/full`): bash 5.2's builtins/*.def decide per builtin.
# The ones ending in sh_chkwrite (echo, printf, pwd, type, set's listings, trap, hash's
# table, alias's full listing, complete -p NAME, history's listing, dirs, …) report
# `NAME: write error: …` and return 1; pushd/popd report it (through dirs_builtin) but keep
# 0; the rest (jobs, kill -l, caller, history -p WORD, hash -t, alias NAME, compgen,
# command -v) are silent and keep their own status. Every tier, every context.
hash -r
hash > /dev/full; echo "hash (empty) st=$?"
alias zz=yy
alias > /dev/full; echo "alias st=$?"
alias zz > /dev/full; echo "alias zz st=$?"
kill -l 9 > /dev/full; echo "kill -l 9 st=$?"
kill -l HUP > /dev/full; echo "kill -l HUP st=$?"
history -p x > /dev/full; echo "history -p x st=$?"
trap -l > /dev/full; echo "trap -l st=$?"
set > /dev/full; echo "set st=$?"
complete -W x foo
complete -p foo > /dev/full; echo "complete -p foo st=$?"
complete -p > /dev/full; echo "complete -p st=$?"
compgen -W 'a b' > /dev/full; echo "compgen st=$?"
command -v echo > /dev/full; echo "command -v st=$?"
cd /tmp
pushd / > /dev/full; echo "pushd st=$?"
popd > /dev/full; echo "popd st=$?"
dirs > /dev/full; echo "dirs st=$?"
f() { caller > /dev/full; echo "caller st=$?"; caller 0 > /dev/full; echo "caller 0 st=$?"; }
f
hash ls
hash > /dev/full; echo "hash st=$?"
hash -t ls > /dev/full; echo "hash -t st=$?"
# the redirection on an enclosing command: the builtin's own policy still decides
eval 'hash -r; hash' > /dev/full; echo "eval hash st=$?"
eval 'kill -l 9' > /dev/full; echo "eval kill st=$?"
{ trap -l; } > /dev/full; echo "group trap st=$?"
g() { echo a; true; }
g > /dev/full; echo "fn echo;true st=$?"
g() { history -p x; }
g > /dev/full; echo "fn history -p st=$?"
builtin hash > /dev/full; echo "builtin hash st=$?"
command kill -l 9 > /dev/full; echo "command kill st=$?"
# a listing bigger than stdio's buffer fails mid-builtin
big=$(printf '%5000s' x)
declare -p big > /dev/full; echo "declare -p big st=$?"
alias zz="$big"
alias zz > /dev/full; echo "alias zz big st=$?"
alias zz=yy
echo 'trap -l; echo "src st=$?" >&2; kill -l 9; echo "src kill st=$?" >&2' > "${TMPDIR:-/tmp}/chkw-src.sh"
. "${TMPDIR:-/tmp}/chkw-src.sh" 2>&1 > /dev/full
rm -f "${TMPDIR:-/tmp}/chkw-src.sh"
trap 'kill -l 9 > /dev/full; echo "trap kill st=$?"; hash > /dev/full; echo "trap hash st=$?"' USR1
kill -USR1 $$
trap - USR1
hash ls
# hot: the compiled tier runs the same forms
hot() {
	local i s=
	for ((i = 0; i < 160; i++)); do
		kill -l 9 > /dev/full; s+=$?
		history -p x > /dev/full; s+=$?
		alias zz > /dev/full; s+=$?
		hash -t ls > /dev/full; s+=$?
		caller > /dev/full; s+=$?
		trap -l > /dev/full 2>/dev/null; s+=$?
		hash > /dev/full 2>/dev/null; s+=$?
		set > /dev/full 2>/dev/null; s+=$?
		echo a > /dev/full 2>/dev/null; s+=$?
		pushd / > /dev/full 2>/dev/null; s+=$?
		popd > /dev/full 2>/dev/null; s+=$?
		eval 'kill -l 9' > /dev/full; s+=$?
		s+=" "
	done
	printf '%s\n' $s | sort | uniq -c
}
hot
# with a background job running (the shell's writes then yield to it)
sleep 2 &
jobs > /dev/full; echo "jobs st=$?"
jobs -p > /dev/full; echo "jobs -p st=$?"
hash > /dev/full; echo "bg hash st=$?"
echo a > /dev/full; echo "bg echo st=$?"
kill -l 9 > /dev/full; echo "bg kill st=$?"
hot
kill %1
wait
