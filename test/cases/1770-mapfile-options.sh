# builtins/mapfile.def: mapfile/readarray option parsing and range checks,
# diagnostics, target-variable checks, delimiters/-t, -O vs clearing, fd
# positioning after -n, and -C callback arguments/quantum.
e() { "$@" 2>&1 </dev/null | sed 's/^.*line [0-9]*: //'; echo "st=${PIPESTATUS[0]}"; }

# --- invalid option values (legal_number + range checks)
e mapfile -n x a
e mapfile -n -1 a
e mapfile -n 4294967296 a
e mapfile -n 99999999999999999999 a
e mapfile -n '' a
e mapfile -n 0x10 a
e mapfile -O -1 a
e mapfile -O 4294967296 a
e mapfile -s x a
e mapfile -s 4294967296 a
e mapfile -c 0 a
e mapfile -c -1 a
e mapfile -c 4294967296 a
e mapfile -u x a
e mapfile -u -1 a
e mapfile -u 99 a
e mapfile -u 2147483648 a
e mapfile -u 4294967296 a
e mapfile -z a
e mapfile -O
e mapfile ''
e mapfile a-b
e mapfile 'a[0]'
e mapfile -- -t
e readarray -q
# --help (CASE_HELPOPT) prints the long help on stdout, status 2
mapfile --help | head -2; echo "st=${PIPESTATUS[0]}"
readarray --help | head -2; echo "st=${PIPESTATUS[0]}"

# --- target variable checks
readonly ro=(1 2); e mapfile ro <<<"x"; declare -p ro
declare -A as=([k]=v); e mapfile -O 1 as <<<"x"; declare -p as
sc=hello; mapfile -O 3 -t sc <<<$'x'; declare -p sc
declare -i ii=5; mapfile -t ii <<<$'1+1\n3'; declare -p ii
arr=(o); declare -n r=arr; mapfile -t r <<<$'p\nq'; declare -p arr
declare -n r2=arr[1]; e mapfile -t r2 <<<$'p'
mapfile -tn1 a3 extra <<<$'1\n2'; declare -p a3

# --- clearing vs -O, empty input, no trailing delimiter
x=(1 2 3); mapfile x </dev/null; declare -p x
x=(1 2 3); mapfile -O 1 x </dev/null; declare -p x
y=([0]=a [5]=b [9]=c); mapfile -t -O 5 y <<<$'X\nY'; declare -p y
printf 'a\nb' | { mapfile z; declare -p z; }
# huge -O: bash's index is an unsigned int and wraps
mapfile -t -O 4294967295 w <<<$'a\nb'; declare -p w

# --- delimiters and -t
printf 'a::b::' | { mapfile -d :: z; declare -p z; }
printf 'x\0\0y\0' | { mapfile -t -d '' z; declare -p z; }
printf 'a\0b\nc\n' | { mapfile -t z; declare -p z; }
printf 'a\n\n\nb\n' | { mapfile -t z; declare -p z; }
printf 'a\r\nb\r\n' | { mapfile -t -d $'\r' z; declare -p z; }
printf '1\n2\n' > f; mapfile -t -d '' z < f; declare -p z

# --- the fd is left just past the last line taken
printf '%s\n' 1 2 3 4 5 > f
{ mapfile -t -n 2 -s 1 a; read -r v; echo "v=$v"; } < f; declare -p a
printf '1,2,3,4\n' | { mapfile -t -d , -n 2 a; echo "rest: $(cat)"; }
exec 4< f; mapfile -t -u 4 -n 1 a; mapfile -t -u 4 b; declare -p a b; exec 4<&-
mapfile -t -s 10 s < f; declare -p s

# --- -C callback: gets index and the (quoted) line, before assignment
cb() { echo "cb[$#] idx=$1 line=$(printf %q "$2") len=${#z[@]}"; }
printf '%s\n' a b c d e | { mapfile -t -c 2 -C cb z; declare -p z; }
printf '%s\n' a b | { mapfile -c 1 -C cb z; }
printf '%s\n' a b c | { mapfile -t -O 7 -s 1 -c 1 -C cb z; }
printf '%s\n' "it's" '$(echo no)' '*' | { mapfile -t -c 1 -C cb z; }
printf '%s\n' a b c d | { mapfile -t -n 3 -c 1 -C cb z; declare -p z; }
seq 1 5001 | { mapfile -t -C cb z; echo ${#z[@]}; }
seq 1 7 | { mapfile -t -c 3 -C 'echo pre; echo' z; }
printf '%s\n' a b | { mapfile -t -c 1 -C 'z[9]=set; :' z; declare -p z; }
mapfile -t -c 1 -C 'false' w <<<$'a\nb'; echo "st=$?"
mapfile -t -c 1 -C 'echo $(( 1/0 ))' w <<<$'a' 2>&1 | sed 's/^.*line [0-9]*: //'
mapfile -t -c 1 -C 'echo' -O 4294967295 w <<<$'a\nb'
