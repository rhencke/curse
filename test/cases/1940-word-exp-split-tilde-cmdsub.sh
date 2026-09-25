# subst.c (non-parameter-expansion parts): word splitting, null-argument removal,
# tilde expansion, command-substitution exit status / NUL warning, $'...' \x{..},
# arithmetic results splitting, and the case-pattern "$@" first-word quirk.
p() { printf '<%s>' "$@"; echo " n=$#"; }
n() { sed 's/^.*line [0-9]*: //'; }

# --- word splitting: whitespace NOT in $IFS is ordinary text, even right after a delimiter
IFS=:; x='a: b'; p $x; x='a:  :b'; p $x
set -- a ' c '; p $@; p $*; a=(a ' c '); p ${a[@]}
IFS=,; set -- 'a b' ' c '; p $@
IFS=$'\t'; x=$'a\t b'; p $x; x=$'a\t\t b'; p $x
IFS=$'\t:'; x=$'a\t :b'; p $x
IFS=' '; x=$'a\tb \t c'; p $x
IFS=$'\n'; x=$'a\n b\n\n c'; p $x
IFS=: read -ra r <<< 'x:  :y'; p "${r[@]}"
IFS=$'\t' read -ra r <<< $'x\t y'; p "${r[@]}"
# non-whitespace IFS with empty positional elements / trailing nulls
IFS=:; set -- a '' b; p $@ x$@y; set -- '' a ''; p $*; set -- '' ''; p $* ${@}x
unset IFS

# --- arithmetic expansion results are word-split like any unquoted expansion
IFS=1; k=10; p $((k+1)); p $((10+1)); p x$((121))y; p "$((121))"; p $[121]
IFS=0; p $((100)) $(( -101 )); b=($((101))); p "${b[@]}"
unset IFS

# --- "$@"/"${a[@]}" with zero elements joined only to empty EXPANSIONS -> no word at all
set --; a=(); e=
p "$e$@"; p "$@$e"; p "${@}${e}" "${a[*]}${@}"; p "$e${a[@]}"; p "${a[@]}$e"
p "${e}${@:1}"; p "${a[@]}${a[*]}"
# ...but a literal "" or a non-@ expansion keeps one empty word
p "$@"""; p ''"${a[@]}"; p "${a[*]}$e"; p "$e$*"

# --- quoted "$@" as a case pattern uses only its FIRST word (IFS="" joins with space)
set -- a b
for s in a b 'a b' xa 'xa by'; do
  case "$s" in "$@") echo "q@ [$s]";; esac
  case "$s" in x"$@"y) echo "xq@y [$s]";; esac
done
IFS=
for s in a 'a b' 'xa by'; do
  case "$s" in "$@") echo "E q@ [$s]";; esac
  case "$s" in x"$@"y) echo "E xq@y [$s]";; esac
done
unset IFS

# --- tilde expansion
HOME=/hh
b=(x=~ ~ a:~ [3]=~ [4]=a:~ [5]=x=~); declare -p b
declare -a c=(x=~); declare -p c
echo a=~ b=a:~ a+=~ a[1]=~ 1a=~ a=\~ 'a'=~
HOME='/h*'; echo ~ ~/x; for i in ~; do echo "$i"; done; d=(~); echo "${d[@]}"
HOME=/hh; x=/hh; y='~'
echo "${x/\~/T}" "${y/\~/T}" "${x/"~"/T}" "${x#\~}" "${y#\~}" "${x/~/T}" "${y/'~'/T}"
(PWD=/fake; echo ~+ ~+0 ~-0; OLDPWD=/o; echo ~- ~-0 ~+1)
(unset PWD; echo ~+ ~+0 x=~+)

# --- command substitution: $? of an assignment-only command = last cmdsub's status
x=$(exit 3) y=$(exit 4); echo "st=$?"
x=$(exit 3) y=1; echo "st=$?"
x=$(exit 3) y=$(true); echo "st=$?"
x=`exit 6` y=`exit 7`; echo "st=$?"
x=1 $(exit 5); echo "st=$?"
x=$(exit 3) $(exit 5); echo "st=$?"
a=( $(exit 3) ); echo "st=$?"
a=( x "$(exit 3)" ); echo "st=$?"
a[$(exit 2)1]=$(exit 4); echo "st=$?"
x=$((1)) y=$(exit 2)$(exit 3); echo "st=$?"
x=${u:-$(exit 5)}; echo "st=$?"
f() { x=$(exit 8) y=z; echo "fst=$?"; }; f
# NUL bytes are dropped with one warning per substitution
{ x=$(printf 'a\0b'); } 2>&1 | n
{ x=$(printf 'a\0\0b\0'); echo "[$x]"; } 2>&1 | n
{ x=`printf 'q\0r'`; echo "[$x]"; } 2>&1 | n

# --- $'...' braced hex escape
printf '%q ' $'\x{41}' $'\x{4142}' $'\x{41' $'\x{0041}b' $'\x{7e}'; echo
