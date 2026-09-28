# `read -N N -a ARR`: read.def empties IFS for -N (ignore_delim), so list_string makes the
# whole text read ONE element (none when nothing was read) — curse split it on IFS (fuzz
# F112, F113: an IFS-whitespace character read alone was dropped).
read -N 99 -a arr <<< 'a b'; echo "st $?"; declare -p arr
read -N 1 -r -a arr <<< $' \t'; declare -p arr
read -N 5 -a arr <<< 'a\ b c'; declare -p arr
read -N 4 -r -a arr <<< '\\ab'; declare -p arr
arr=(1 2 3); read -N 2 -a arr < /dev/null; echo "st $?"; declare -p arr
IFS=x; read -N 4 -a arr <<< 'axbx'; declare -p arr; unset IFS
printf 'x\1y\177z  ' | { read -N 7 -a arr; declare -p arr | od -An -c; }
f() { read -N 3 -a "$1" <<< ' q '; declare -p "$1"; }; f fa
eval 'read -N 2 -a ea <<< "  "'; declare -p ea
printf 'read -N 3 -a sa <<< " s "\n' > s3060.sh; . ./s3060.sh; declare -p sa
trap 'read -N 2 -a ta <<< " t"; declare -p ta' USR1; kill -USR1 $$; trap - USR1
i=0; while [ $i -lt 150 ]; do read -N 3 -a la <<< "$i "; echo "${#la[@]}:${la[0]}"; i=$((i + 1)); done | sed 's/[0-9]*[0-9] /N /' | sort | uniq -c
rm -f s3060.sh
