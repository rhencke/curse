# A recursive function that turns hot mid-recursion keeps every call frame: the call-stack
# arrays (FUNCNAME, BASH_LINENO) list the calls made before it compiled too. In a run that
# starts interpreted, a command substitution before the definition loaded the compiler
# lazily, and the function then compiled standalone without the program's "reads the call
# stack" note — its later calls kept no frames (fuzz F88).
h() { r="${BASH_LINENO[*]}"; f="${FUNCNAME[*]}"; }
x=$(:)
y() { (( $1 > 0 )) && y $(( $1 - 1 )) || { h; set -- $r; echo "Y $# ${r% * *} $f" | cut -c1-40; set -- $f; echo "F $#"; }; }
y 150
z() { if [ "$1" -gt 0 ]; then z $(( $1 - 1 )); else h; set -- $f; echo "Z $#"; fi; }
z 160
eval 'w() { if [ "$1" -gt 0 ]; then w $(( $1 - 1 )); else h; set -- $r; echo "W $#"; fi; }'
w 155
printf 'v() { if [ "$1" -gt 0 ]; then v $(( $1 - 1 )); else h; set -- $f; echo "V $#"; fi; }\n' > s3000.sh
. ./s3000.sh
v 170
i=0; while [ $i -lt 3 ]; do y 120 | tail -1; i=$((i + 1)); done
rm -f s3000.sh
