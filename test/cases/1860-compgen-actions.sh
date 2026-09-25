# builtins/complete.def (compgen/complete/compopt) + pcomplete.c/pcomplib.c,
# the non-interactive parts: compgen's actions (-A NAME and the letter forms),
# -G/-W/-X/-P/-S/-F/-C, the -o fallbacks (default/bashdefault/dirnames/plusdirs),
# output order (fixed per-action order, never globally sorted or de-duplicated),
# option parsing, statuses; complete -p/-r/-D/-E/-I; compopt outside completion.
main() {
mkdir -p dA eB bin/qqdir; touch fA fB '!x' 'y!'
printf '#!/bin/sh\n' > bin/qqexe; chmod +x bin/qqexe bin/qqdir
echo '# -G globs (not prefix-filtered), -X & and ! and extglob/nocasematch'
compgen -G 'f*'; compgen -G 'f*' zzz; compgen -G '*!'; compgen -G 'nomatch*'; echo st=$?
compgen -G 'd*' -W x -P '<'
compgen -X '&' -W 'ab abc xab' ab; compgen -X '!&*' -W 'ab abc xab' ab
compgen -X '\&*' -W '&x ab'; compgen -X '&' -W 'a* ab' 'a*'; echo st=$?
compgen -f -X '!!*' '!'
shopt -s nocasematch; compgen -X 'A*' -W 'ab Ab'; echo st=$?; shopt -u nocasematch
compgen -X '!(a*)' -W 'ab cd'; echo st=$?
shopt -s extglob; compgen -X '!(a*)' -W 'ab cd'; shopt -u extglob
echo '# -o fallbacks: plusdirs appends, dirnames/default/bashdefault only when empty'
compgen -o plusdirs -W 'x dA' d
compgen -o plusdirs -X 'd*' -P '<' -W 'dx' d
compgen -o dirnames -W zz eB; compgen -o dirnames -W zz zz
compgen -o default -X '*' -P '<' -W zz fA
zqvar=1; compgen -o bashdefault -W zz '$zqv'
compgen -o bogus -W zz; echo st=$?; compgen -o; echo st=$?
echo '# no dedup, no global sort; fixed action order (alias, arrayvar, function, variable)'
compgen -W 'b a b a'; compgen -o plusdirs -W 'dA' dA
alias zal=ls; zfn() { :; }; zarr=(1); declare -A zass=([k]=1); zsc=1; declare zun
compgen -v -A function -a z; compgen -A arrayvar z
compgen -A directory -A file dA
PATH=$PWD/bin; alias qqal=x; qqfn() { :; }; qqexe() { :; }; compgen -c qq; PATH=/usr/bin:/bin
echo '# action lists'
compgen -A signal SIGT; compgen -A signal EX
compgen -k | head -4; compgen -A shopt | head -2
compgen -A helptopic '('; compgen -A helptopic for; compgen -A helptopic va
compgen -A binding accept-l
enable -n test; compgen -A disabled; compgen -A enabled tes; echo st=$?; enable test
compgen -u root; compgen -g root | grep -x root; compgen -s ftp-dat | grep -x ftp-data
sleep 0.1 & compgen -j; compgen -A running sl; compgen -A stopped; echo st=$?; wait
echo '# -W: every word expanded (tilde too), "$@" splits'
compgen -W 'a ~/z' | sed "s|^$HOME|H|"; set -- one two; compgen -W '"$@"' o
echo '# -F: warning, COMP_TYPE/COMP_KEY, 124, vars unbound afterwards'
f() { declare -p COMP_TYPE COMP_KEY; COMPREPLY=(q); }; compgen -F f
declare -p COMPREPLY COMP_WORDS COMP_LINE; echo st=$?
r() { COMPREPLY=(x); return 124; }; compgen -F r; echo st=$?
compgen -F nosuch -W ab; echo st=$?
echo '# -C: runs as `cmd compgen WORD PREV` in a subshell; COMP_LINE empty'
y=5; compgen -C 'y=9; echo $COMP_LINE:$COMP_POINT' ab; echo "y=$y"
echo '# option parsing: clusters and attached args; bare compgen'
compgen -dW 'x' dA; compgen -P'<' -Wab a; compgen -Adirectory eB
compgen; echo st=$?; compgen -W; echo st=$?; compgen -A nope; echo st=$?
echo '# complete: -D/-E/-I specs, -p status, usage'
complete -D -W d; complete -E -W e; complete -I -W i; complete -W c cc
complete -p; complete -p -D; complete -pE
complete -p nosuch cc; echo st=$?
complete -r -D; complete -p -D; echo st=$?; complete -p
complete -f; echo st=$?; complete -F; echo st=$?
compopt -D -o nospace; echo st=$?
}
main 2>&1 | sed 's/^.*line [0-9]*: //'
