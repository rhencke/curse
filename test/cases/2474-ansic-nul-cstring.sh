# $'…' is a C string: its value ends at the first NUL (ansicstr's result is used as a
# C string) — `"x"$'\0'"y"` is `xy`, $'a\0b' is `a`, $'\0z' is empty — in every context.
printf '<%s>' "x"$'\0'"y" x$'\0'y $'\0'z $'a\0b' $'\x00'w $'\c@'k $'\000'm $'\u0000x' $'\x{0}y'; echo
echo x$'\0'y | od -An -c
v=a$'\0'b; echo "${#v} $v"
a=(p$'\0'q r); echo "${a[@]} ${#a[0]}"
case x$'\0'y in xy) echo match ;; *) echo nomatch ;; esac
[[ a$'\0'b == ab ]] && echo eq
IFS=$'\0'; set -- "a b"; echo $#; unset IFS
f() { echo "$1 ${#1}"; }; f $'m\0n'
declare -A h=([$'a\0b']=1); echo "${!h[@]}"
echo ${u-$'t\0v'}x
n=0
for ((i = 0; i < 160; i++)); do y=p$'\0'q; z=$'r\0s'; [ "$y$z" = pqr ] && n=$((n + 1)); done
echo "n=$n"
g() { printf '%s' "$1"$'\0'"$2"; }
for ((i = 0; i < 160; i++)); do g a b; echo; done | uniq -c
