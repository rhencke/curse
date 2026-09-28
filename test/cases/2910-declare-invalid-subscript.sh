# declare/typeset/local/export/readonly `NAME[SUB]=v` whose `[` doesn't close before the
# `=` as skipsubscript reads it (quotes nest: `A["]=1`) is no assignment — "`A["]=1': not a
# valid identifier", status 1 (leftover L11).
declare 'B["]=1'; echo "st $?"
declare -a C; declare 'C["]=1'; echo "st $?"; declare -p C
local_t() { local 'D["]=2'; echo "l $?"; }; local_t
declare 'E[1]x=3'; echo "st $?"
export 'F["]=1'; echo "st $?"
readonly 'G["]=1'; echo "st $?"
typeset "H['x]=1"; echo "st $?"
declare 'I[a["]"]=1' 2>&1; echo "st $?"
eval "declare 'J[\"]=1'"; echo "eval $?"
printf "declare 'K[\"]=1'\necho \"src \$?\"\n" > s2910.sh; . ./s2910.sh
trap "declare 'L[\"]=1'; echo \"trap \$?\"" USR1; kill -USR1 $$; trap - USR1
i=0; while [ $i -lt 150 ]; do declare 'M["]=1' 2>/dev/null || n=$((n + 1)); i=$((i + 1)); done; echo "$n"
rm -f s2910.sh
