# `read -d '\'` without -r: read.def takes each backslash as an escape before it looks for
# the delimiter, so a `\` never ends the read — it runs to end of input, status 1. curse's
# chunked/peeked fast paths split at the delimiter first and returned 0 (fuzz F114).
read -d '\' x <<< 'ab c\'; echo "st=$? [$x]"
printf 'ab c\\' | { read -d '\' x; echo "st=$? [$x]"; }
printf 'ab\\c\\d' | { read -d '\' x; echo "st=$? [$x]"; }
printf 'ab\\\\c\\d' | { read -d '\' x; echo "st=$? [$x]"; }
printf 'ab\\c\\d' | { read -r -d '\' x; echo "raw st=$? [$x]"; }
printf 'ab\\c' > f3061; read -d '\' x < f3061; echo "file st=$? [$x]"
f() { read -d '\' "$1" <<< 'f\u'; echo "st=$? [${!1}]"; }; f fv
eval 'read -d "\\" y <<< "e\\v"'; echo "st=$? [$y]"
printf 'read -d "\\\\" z <<< "s\\\\w"\necho "st=$? [$z]"\n' > s3061.sh; . ./s3061.sh
trap 'read -d "\\" t <<< "t\\t"; echo "trap st=$? [$t]"' USR1; kill -USR1 $$; trap - USR1
i=0; while [ $i -lt 150 ]; do read -d '\' v <<< "a$i\\b"; echo "st=$? [${v%%[0-9]*}]"; i=$((i + 1)); done | sort | uniq -c
rm -f f3061 s3061.sh
