# An integer scalar (declare -i) that becomes an array by an element assignment keeps its
# value as element 0, as any scalar does — `declare -i ii=3; (( ii[1]++ ))` is
# ([0]="3" [1]="1"); curse dropped it (its value lived only as a number) (fuzz F103).
declare -i ii=3; e='ii[1]++'; echo "$(( $e ))"; declare -p ii
declare -i j=3; (( j[1]++ )); declare -p j
declare -i k=3; (( k[2]=7 )); declare -p k
declare -i k2=3; (( k2[2]+=7 )); declare -p k2
declare -i m=3; m[1]=5; declare -p m
declare -i n=3; n+=(4); declare -p n
declare -i n4=3; n4[1]=2; echo "${n4[@]}"
s=4; (( s[1]++ )); declare -p s
f() { local -i l=3; (( l[1]++ )); declare -p l; }; f
eval 'declare -i ev=9; ev[3]=1; declare -p ev'
printf 'declare -i sv=8; (( sv[1]=2 )); declare -p sv\n' > s3044.sh; . ./s3044.sh
trap 'declare -i tv=6; tv[1]=1; declare -p tv' USR1; kill -USR1 $$; trap - USR1
i=0; while [ $i -lt 150 ]; do unset v; declare -i v=$i; (( v[1]=1 )); echo "${v[0]}"; i=$((i + 1)); done | awk '{ s += $1 } END { print NR, s }'
rm -f s3044.sh
