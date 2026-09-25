# arrayfunc.c / array.c / assoc.c corners: compound-assignment evaluation order,
# the key/value-pair (kvpair) form decided by the FIRST word, "must use subscript"
# text (raw word; single-quoted under declare/local), bad-subscript diagnostics on
# every reference path, huge int64 indices, assoc key quoting in declare -p / @K
# (sh_contains_shell_metas), set -u inside subscripts, and `+=()` bookkeeping.
n() { sed 's/^.*line [0-9]*: //'; }

# --- kvpair form is chosen by the FIRST element only (kvpair_assignment_p)
{ declare -A K1=(k1 v1 [k2]=v2 k3); declare -p K1; } 2>&1 | n
{ v='p q'; declare -A K2=(k $v [x]=$v); declare -p K2; } 2>&1 | n
{ declare -A K3=('' v x y); declare -p K3; } 2>&1 | n
{ declare -A K4=([a]=1); K4+=(b 2 a 3); K4+=([a]+=4 [c]+=5); declare -p K4; } 2>&1 | n

# --- a bare element in a keyed assoc literal: reported as the RAW word, unexpanded
# (declare/local single-quote it), and never expanded (no side effects)
{ k=zz; declare -A B1=([a]=1 $k "a'b" ~ *.nomatch "x y" $'t\tu'); declare -p B1; } 2>&1 | n
{ declare -A B2; c=0; B2=([a]=1 $((c+=1)) "a b" ~); echo "c=$c"; declare -p B2; } 2>&1 | n
{ f() { local -A L=([a]=1 $k); local -A L2; L2=([b]=2 $k); }; f; } 2>&1 | n

# --- per-word order: each [sub]=val word expands its subscript, then its value
{ i=0; a=([$((i+=1))]=$i [$((i+=1))]=$i); declare -p a; } 2>&1 | n
{ declare -A A; i=0; A=([k$i]=$((i+=1)) [k$i]=$((i+=1))); declare -p A; } 2>&1 | n
{ i=0; declare -A A2=([$((i+=1))]=$i [$((i+=1))]=$i); declare -p A2; } 2>&1 | n
{ i=0; a=([i++]=$i [i++]=$i); declare -p a; echo "i=$i"; } 2>&1 | n

# --- a failed [k]= element leaves the running index alone
{ a=(1 2 3); a+=([-1]=x [-4]=q y); echo "st=$?"; declare -p a; } 2>&1 | n

# --- bad (negative) subscripts on every reference/assignment path
b=([3]=x)
( echo "${#b[-9]}" ) 2>&1 | n
( echo "<${!b[-9]}>" ) 2>&1 | n
( echo "<${b[-9]:-def}>" ) 2>&1 | n
( declare b[-9]=1; echo "st=$?" ) 2>&1 | n
( [[ -v b[-9] ]]; echo "st=$?" ) 2>&1 | n
( printf -v 'b[-9]' x; echo "st=$?" ) 2>&1 | n
declare -A E=([k]=v)
( echo "<${E['']}>"; echo "st=$?" ) 2>&1 | n

# --- set -u: ${#A[k]} of a missing assoc element; unset vars inside a subscript
( set -u; declare -A h; echo "${#h[k]}"; echo reached ) 2>&1 | n
( set -u; b=(1); echo "${#b[5]}" ) 2>&1 | n
( set -u; a=(1 2); a[nv]=x; echo notreached ) 2>&1 | n
( set -u; a=(1 2); echo "${a[nv]}" ) 2>&1 | n
( set -u; a=(1 2); unset 'a[nv]' ) 2>&1 | n

# --- unset of an assoc element whose subscript text holds a `]`
( declare -A U=(["a]b"]=1 [a]=2); unset "U[a]b]"; echo "st=$?"; declare -p U ) 2>&1 | n

# --- declare -p / @K / @A key quoting: `#` only first, `~` only first/after = or :
declare -A Q
for k in 'a#b' '#a' 'a~b' 'x=~' 'a:~y' '^' '%' 'a{' 'x,y' '!' '=' 'p/q' '@' '*'; do Q[$k]=1; done
declare -p Q
declare -A Q2=(['a#b']=1 ['a~b']=2); echo "${Q2[@]@K}"; echo "${Q2[@]@A}"

# --- printable UTF-8 is double-quoted (not $'' or '') in declare -p, value and key
( export LC_ALL=C.UTF-8; d=("é" "aé b"); declare -p d; declare -A g=(['é']=1); declare -p g )

# --- huge int64 indices (past 2^53)
( c=([4611686018427387904]=big); c+=(n); declare -p c; echo "${!c[@]}" ) 2>&1 | n
( c=([9007199254740993]=x [9007199254740992]=y); c[9007199254740993]+=Q; declare -p c ) 2>&1 | n
( c=([2**62]=a [2**62+2]=b); echo "${!c[@]}" "${#c[@]}" "${c[-1]}" "${c[-2]-u}" "${c[-3]}" ) 2>&1 | n
( c[9223372036854775807]=m; c+=(w); declare -p c ) 2>&1 | n
( a[9223372036854775808]=x; declare -p a ) 2>&1 | n
( a[18446744073709551617]=x; declare -p a ) 2>&1 | n
( b=(1 2); b[-9223372036854775807]=x; echo "st=$?" ) 2>&1 | n
( e[-9223372036854775808]=x; echo "st=$?" ) 2>&1 | n

# --- `+=()` of nothing still makes the declared array "set"
declare -a g; g+=(); declare -p g
declare -A h; h+=(); declare -p h

# --- a here-string word ends at `)` (read into an element inside a subshell)
(read "r[1]" <<<val; declare -p r) 2>&1 | n
(cat <<<x) 2>&1 | n
f() (cat <<<y); f
echo end
