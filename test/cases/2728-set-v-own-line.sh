# `set -v` run from a sourced file or an eval string: echoing starts with the NEXT line
# read, never the line holding the `set -v` itself — nor, after it on that line, anything
# already read (fuzz F52). Its lines were echoed from the text's first line.
printf 'set -v\necho x\n' > s2728.sh
. ./s2728.sh
set +v
printf 'set -v; echo y\necho z\n' > s2728.sh
. ./s2728.sh
set +v
printf 'echo a\nset -v\necho b\nset +v\n' > s2728.sh
. ./s2728.sh
eval 'set -v
echo w'
set +v
f() { eval 'echo p; set -v
echo q'; }; f
set +v
trap '. ./s2728.sh; echo t' USR1; kill -USR1 $$; trap - USR1
j=0; while [ $j -lt 150 ]; do . ./s2728.sh; j=$((j + 1)); done 2>&1 | sort | uniq -c
rm -f s2728.sh
