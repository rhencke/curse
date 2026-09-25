# pcomplete.c / pcomplib.c / builtins/complete.def — the parts 1860 doesn't cover:
# `complete -p` output for every option/action and name quoting, shared compspecs,
# compopt listing/-o/+o/-DEI/errors, completion specs are subshell-local, compgen -F
# (COMP_* vars as compgen sets them, COMPREPLY handling, 124/127, readonly/nameref
# COMP_* vars — unbind is _noref and ignores readonly), -C output parsing + env,
# -W splitting/quoting/no-globbing and fatal expansion errors, -G (glob_filename:
# unsorted, backslash, dotglob only as last synced), -X/-P/-S, the hostname list cache,
# $LINENO inside -W/-C.
main() {
echo '# complete -p: fixed option/action/argument order, quoting of args and names'
complete -o nospace -o filenames -F _f -W 'a b' -P "p'q" -S '$s' -X '!*.c' -G '*.[ch]' -C 'echo x' -d -f -A signal -A hostname c1
complete -o plusdirs -o nosort -o noquote -o dirnames -o default -o bashdefault c2
complete -abcdefgjksuv -A arrayvar -A binding -A disabled -A enabled -A function -A helptopic -A running -A setopt -A shopt -A stopped c3
complete -p c1 c2 c3
complete -W x 'a b' 'c;d' 'e*' '' "f'g" 'h=i' '{x}' '~u' '#h' 'x#' plain
complete -p 'a b' 'c;d' 'e*' '' "f'g" 'h=i' '{x}' '~u' '#h' 'x#' plain
for n in a-b 'a(b' 'a|b' 'a b' 'a\b'; do complete -F "$n" fq; echo "[$n] st=$?"; done; complete -p fq
set -o posix; complete -F a-b fq; echo st=$?; set +o posix
complete e2; complete -p e2; complete -W w r1 r2 r3; complete -r r1 nosuch r3; echo st=$?; complete -p r2
complete -r; complete; echo "empty st=$?"
echo '# one complete call = one shared compspec: compopt on a name changes all of them'
complete -W a n1 n2; compopt -o nospace n1; complete -p n1 n2
complete -W b n2; compopt -o filenames n1; complete -p n1 n2
echo '# compopt: listing (+o for unset), -o then +o, +o wins, errors'
compopt n1 n2; compopt +o nospace -o nospace -o default n1; compopt n1
compopt -o nospace n1 nosuch; echo st=$?; compopt -o bogus n1; echo st=$?
compopt +x; echo st=$?; compopt -o; echo st=$?; compopt -- -o; echo st=$?
complete -D -o default; compopt -D -E; compopt -E; echo st=$?; compopt +D; echo st=$?
f() { compopt -o nospace; echo "in -F: st=$?"; COMPREPLY=(a); }; compgen -F f
complete -r
echo '# completion specs are per-shell: a subshell or $(...) must not leak them'
complete -W a keep
( complete -W sub sb; complete -r keep ); x=$(complete -W cs cs1); complete -p; complete -r
echo '# compgen -F: COMP_* as compgen binds them, COMPREPLY rules'
f() { echo "\$#=$# [$1][$2][$3]"; declare -p COMP_WORDS COMP_CWORD COMP_LINE COMP_POINT; COMPREPLY=(r1 'r 2' '' r1); }
compgen -F f -P '<' -S '>' -W 'w1 w2' w
h() { COMPREPLY=([5]=five [2]=two); }; compgen -F h
i() { COMPREPLY=scalar; }; compgen -F i; echo st=$?
j() { declare -gA COMPREPLY=([k]=v); }; compgen -F j; echo st=$?
k() { local COMPREPLY=(loc); }; compgen -F k; echo st=$?
o() { COMPREPLY=(outer); compgen -F k; echo "inner st=$?"; declare -p COMPREPLY; COMPREPLY+=(o2); }; compgen -F o
m() { COMPREPLY=(a b); return 127; }; compgen -F m -W zz; echo st=$?
r() { COMPREPLY=(a b); return 124; }; compgen -F r -W zz; echo st=$?
n() { COMP_WORDS+=(w); COMP_CWORD=5; COMPREPLY=("${#COMP_WORDS[@]}" "$COMP_CWORD"); }; compgen -F n
declare -p COMP_WORDS COMP_CWORD
echo '# unbinding COMP_*/COMPREPLY ignores readonly and does not follow namerefs'
( declare -r COMP_LINE=ro; q() { echo "in:$COMP_LINE"; }; compgen -F q; echo "${COMP_LINE-unset}" )
( declare -r COMPREPLY=(ro); p() { :; }; compgen -F p; echo "st=$? ${COMPREPLY-unset}" )
( declare -n COMPREPLY=zref; l() { zref=(via ref); }; compgen -F l; declare -p zref; echo "${COMPREPLY-unset}" )
( declare -n COMP_LINE=tgt; tgt=keep; q() { :; }; compgen -F q; declare -p tgt; echo "${COMP_LINE-unset}" )
echo '# compgen -C: exported COMP_*, quoted args, output split at newlines'
compgen -C 'env | grep ^COMP_ | sort; printf "[%s]" >&2; echo >&2' "w'x"
compgen -C 'printf "a\\\\\nb\n\n\nc\n\n"'; compgen -C 'echo; echo'; compgen -C false; echo st=$?
echo '# -W: IFS splitting, quotes kept together, no pathname expansion'
IFS=:; compgen -W 'a:b c'; IFS=$' \t\n'; x='1 2'; compgen -W '$x "$x"'
touch aa ab; compgen -W 'a* "a*" a[a-z]'
echo '# -W expansion errors behave like any expansion error (fatal / discard line)'
( compgen -W '${zz?msg}'; echo "not reached" ); echo "sub st=$?"
( compgen -W '$((1/0))'; echo "not reached" ); echo "sub st=$?"
( set -u; compgen -W '$zz'; echo "not reached" ); echo "sub st=$?"
( compgen -W 'a ${ b'; echo "not reached" ); echo "sub st=$?"
( f() { COMPREPLY=(a); echo $((1/0)); }; compgen -F f; echo "not reached" ); echo "sub st=$?"
echo '# -G: glob_filename order (reverse readdir, unsorted), backslash, no GLOBIGNORE'
mkdir gd; for n in m b z a q; do touch gd/$n; done; ls -f gd | grep -v '^\.' > order
compgen -G 'gd/?' | tr '\n' ' ' | sed 's,gd/,,g'; echo; tac order | tr '\n' ' '; echo
compgen -G 'g\d'; GLOBIGNORE='gd/a'; compgen -G 'gd/[a]'; unset GLOBIGNORE
mkdir -p gs/e; touch gs/e/y; shopt -s globstar; compgen -G 'gs/**'; shopt -u globstar
touch gd/.h; shopt -s dotglob; compgen -G 'gd/*h'; echo "not synced st=$?"; : gd/*; compgen -G 'gd/*h'; shopt -u dotglob
echo '# -X/-P/-S corners'
compgen -W 'ab Ab aB' -X 'a*'; compgen -W 'foo foobar' -X '&bar' foo; compgen -W 'a b' -X '!'; echo st=$?
compgen -W 'ab' -X 'ab' -P p; echo st=$?; compgen -W 'ab' -P '$x' -S '\n'
echo '# hostname list: read once, re-read (APPENDED) on HOSTFILE assignment'
printf '127.0.0.1 zlocal zlo2 # zc\n# zskip\n10.0.0.1\tzhost\n' > hf
HOSTFILE=hf; compgen -A hostname z; printf '1.2.3.4 zadded\n' >> hf; compgen -A hostname za; echo st=$?
printf '1.1.1.1 zother\n' > hf2; HOSTFILE=hf2; compgen -A hostname z
echo '# bashdefault: $( command completion'
zqfn() { :; }; compgen -o bashdefault '$(zqf'; echo st=$?
echo '# $LINENO inside -W and -C'
compgen -W '$LINENO'
compgen -C 'echo $LINENO'
g() {
  compgen -W '$LINENO'
}
g
}
main 2>&1 | sed 's/^.*line [0-9]*: //'
