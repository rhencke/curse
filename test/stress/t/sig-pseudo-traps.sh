#@ guards: EXIT, ERR, DEBUG and RETURN traps set and fired inside $(…), a pipeline stage, a subshell, eval, a sourced file, a function and a hot compiled loop (compiled-tier DEBUG/RETURN handling, the in-process subshell trap save/restore of inproc-subshells)
#@ timeout: 20
src=${TMPDIR:-/tmp}/pseudo.$$.sh
echo "== ERR"
trap 'echo "  ERR st=$? line=$LINENO"' ERR
false
x=$(false; echo "in-comsub")
echo "x=$x"
false | true
true | false
( false; echo in-subshell )
eval 'false; echo in-eval'
printf 'false\necho in-source\n' >"$src"; . "$src"
f() { false; echo in-fn; return 2; }
f
i=0; while [ $i -lt 300 ]; do i=$((i+1)); [ $((i % 100)) = 0 ] && false; done
set -E
g() { false; }
x=$(g); ( g ); g
set +E
trap - ERR
echo "== RETURN"
trap 'echo "  RETURN ${FUNCNAME[0]:-top} st=$?"' RETURN
r() { return 4; }
r; echo "r st=$?"
x=$(r); echo "comsub x=[$x]"
r | cat
( r )
eval r
printf 'echo sourcing\nreturn 5\n' >"$src"; . "$src"; echo "source st=$?"
set -o functrace
r2() { r; }
r2
set +o functrace
trap - RETURN
echo "== DEBUG"
n=0
trap 'n=$((n+1))' DEBUG
a=1
b=$(echo x)
echo y | cat >/dev/null
( c=1 )
eval 'd=1'
i=0; while [ $i -lt 200 ]; do i=$((i+1)); done
trap - DEBUG
echo "debug traps: $n"
set -T
trap 'case $BASH_COMMAND in echo*) echo "  DEBUG: $BASH_COMMAND";; esac' DEBUG
h() { echo in-h; }
h
x=$(echo in-comsub-debug); echo "$x"
trap - DEBUG
set +T
echo "== EXIT"
( trap 'echo "  EXIT subshell"' EXIT; echo in-sub )
x=$(trap 'echo "  EXIT comsub"' EXIT; echo body); echo "x=[$x]"
{ trap 'echo "  EXIT stage"' EXIT; echo stage; } | cat
( trap 'echo "  EXIT nested outer"' EXIT; ( trap 'echo "  EXIT nested inner"' EXIT; exit 3 ); echo "inner st=$?" )
( trap 'echo "  EXIT on error st=$?"' EXIT; set -e; false; echo never )
( trap 'echo "  EXIT killed by TERM"' EXIT; trap 'exit 7' TERM; kill -TERM $BASHPID; echo after-kill ); echo "st=$?"
( trap 'echo "  EXIT then exit 9"; exit 9' EXIT; exit 1 ); echo "st=$?"
rm -f "$src"
trap 'echo "  EXIT main st=$?"; "$STH" probe' EXIT
exit 6
