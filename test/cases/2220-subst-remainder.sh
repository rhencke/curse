# subst.c remainder (beyond 1920/1940/1950): process substitution lifetime and naming,
# $(<file) forms, command-substitution parsing/backquote rules/errexit, $[ ] legacy
# arithmetic in every arithmetic context, variable values are NOT re-expanded inside
# arithmetic, $"…" / "$" inside double-quoted default words and here-docs, positional
# slices ${@:n} in scalar (assignment/here-doc) contexts, ${!prefix@} joined with IFS,
# IFS split cache vs a locale change, and declaration-builtin assignment lookalikes.
p() { printf '<%s>' "$@"; echo " n=$#"; }
e() { sed 's/^.*line [0-9]*: //'; }

# --- process substitution: /dev/fd naming, args, for lists, redirect targets, $!
echo <(:) <(:) >(:); f() { echo "$@"; cat "$1" "$2"; }; f <(echo fa) <(echo fb)
for x in <(echo fl); do cat $x; done
echo pre<(:)post {a,b}<(:) | sed 's/[0-9][0-9]*/N/g'
case <(:) in /dev/fd/*) echo casepat;; esac
cat <(exit 3); echo st=$?; : <(exit 7); wait $!; echo st=$?
echo x > >(cat); wait; paste <(echo 1) <(echo 2)
# ... an assignment-only statement closes its <() when it finishes (a prefix one doesn't)
x=<(echo pre) eval 'cat $x'
x=<(echo a); cat $x 2>/dev/null || echo closed1
a=( <(echo arr) ); cat ${a[0]} 2>/dev/null || echo closed2
a[1]=<(echo el); cat ${a[1]} 2>/dev/null || echo closed3
declare y=<(echo dcl); cat $y 2>/dev/null || echo closed4
g() { x=<(echo inf); cat $x 2>/dev/null || echo closed5; }; g

# --- $(<file) and its lookalikes
printf 'l1\nl2\n\n\n' > ff; x=$(<ff); p "$x"; x=$( < ff ); p "$x"; x=`<ff`; p "$x"
x=$(<ff 2>/dev/null); p "$x"; x=$(0<ff); p "$x"; x=$(<ff cat); p "$x"; x=$(<ff; echo z); p "$x"
{ x=$(<nofile); echo "st=$?"; } 2>&1 | e
eval 'x=$(<)' 2>&1 | e; eval 'echo $(>)' 2>&1 | e; eval 'x=`<`' 2>&1 | e

# --- command substitution parsing and backquote backslash rules
x=$(printf 'a\r\n\n'); printf '%q\n' "$x"; x=$(printf '\n\na\n'); printf '%q\n' "$x"
echo $(case a in a) echo A;; esac) $(case a in (a) echo "(";; esac) "$(echo ')')"
echo $(echo a # c )
) $(cat <<'X'
)"'`
X
)
x=5; p `echo \\\\` "`echo \\\\`" `echo \$x` `echo \\$x` "`echo \$x`" "`echo \\$x`"
p `echo '\"'` "`echo '\"'`" `echo \`echo in\`` $(echo \`echo o\`)
# errexit is off inside $() unless inherit_errexit
(set -e; x=$(false; echo after); echo "[$x]"; shopt -s inherit_errexit
 x=$(false; echo after2); echo "notreached [$x]"); echo st=$?

# --- $[ ] is $(( )) everywhere arithmetic is expanded
echo $[1+2] "$[3*3]" $[ $(echo 4) ** 2 ]
echo $(( $[1+1] * 2 )) "$(( $[2] ))" $[ $[1] + 1 ]
a=(5 6); echo $(( a[$[1]] )) ${a[$[1]]} ${a[ $[0] ]}
s=abcdef; echo ${s:$[1]:$[2]}
(( yy = $[3] )); echo "yy=$yy"; [[ $[1+1] -eq 2 ]] && echo dbr-ok
for ((i=$[0]; i<$[2]; i++)); do printf '%s' $i; done; echo
{ echo $(( "1" + '2' )); } 2>&1 | e

# --- a variable's VALUE is not word-expanded inside arithmetic (only a subscript is)
(x='$y'; y=3; echo $(( x ))) 2>&1 | e
(x='$(echo 2)'; echo $(( x + 1 ))) 2>&1 | e
(x='`echo 3`'; echo $(( x ))) 2>&1 | e
(x='"3"'; echo $(( x ))) 2>&1 | e
(x='$((3))'; echo $(( x ))) 2>&1 | e
(x='a[$(echo 1)]'; a=(5 6); echo $(( x ))) 2>&1 | e

# --- $"…" and a lone "$" in double-quoted contexts
v='v w'; p $"$v" $"a\nb" $"\$v" "$"v"" $"`echo bq`"
x=1; p "${x+"$"}" "${u-"$"}" "${u-"a$"}" "${u-"$ "}" "${u-"$"}x" "${u:-"$"}" "${x+$"t"}"
cat <<E
a$"b" $"$x" $"" "$"q $ $'ansi'
E
echo "$(cat <<E
in $"cs"
E
)"

# --- ${@:n} / ${a[@]:n} in a scalar context is an element slice, not a substring
set -- a b c; aa=(x y z)
y=${@:1}; p "$y"; y=${@:2}; p "$y"; y=${@:1:1}; p "$y"; y=${aa[@]:1}; p "$y"; y=${aa[@]:1:1}; p "$y"
IFS=:; y=${@:1}; p "$y"; y="${@:1}"; p "$y"; y=${*:2}; p "$y"; unset IFS
cat <<E
${@:2} ${*:2} ${@:1:1}
E

# --- ${!prefix@}/${!prefix*} in a scalar context join with IFS[0]; ${!a[@]} with a space
zz1=1 zz2=2 zz_3=3; IFS=:
x="${!zz@}"; p "$x"; x=${!zz*}; p "$x"; p "${!zz*}" ${!zz*}
b=([3]=x [7]=y); y=${!b[@]}; p "$y" "${!b[*]}"; unset IFS

# --- the IFS split set follows a locale change (C: each byte of é is a delimiter)
LC_ALL=C.UTF-8; IFS=é; x='aébéc'; p $x
LC_ALL=C; p $x; IFS=:; IFS=é; p $x; unset IFS

# --- declaration builtins: which words are assignments
HOME=/h; v='a b'; n=z
declare x=$v; p "$x"; declare $n=$v; p "$z"; declare $n=~; p "$z"
command declare c1=$v; p "$c1"; builtin declare b1=$v; p "$b1"
declare -a arr=$v arr2="($v)"; declare -p arr arr2
k='arr4=(3 4)'; { declare -a $k; declare -p arr4; } 2>&1 | e
touch 'g=1'; declare g=*; p "$g"; declare 'g'=*; p "$g"
lf() { local l=$v l2=~/x; p "$l" "$l2"; }; lf
