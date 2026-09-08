# PIPESTATUS reflects each stage's exit status
true | false | true
echo "a=${PIPESTATUS[@]}"
echo "a0=${PIPESTATUS[0]} a1=${PIPESTATUS[1]} a2=${PIPESTATUS[2]}"
echo "len=${#PIPESTATUS[@]}"

# a single command is a one-element PIPESTATUS
false
echo "single=${PIPESTATUS[0]} rc=$?"
true
echo "single2=${PIPESTATUS[0]}"

# explicit statuses through a pipe
sh -c 'exit 5' | sh -c 'exit 7' | sh -c 'exit 0'
echo "codes=${PIPESTATUS[*]}"

# pipefail picks the last non-zero; PIPESTATUS still has them all
set -o pipefail
false | true
echo "pf-rc=$? pf-ps=${PIPESTATUS[*]}"
set +o pipefail

# PIPESTATUS is refreshed by the next command
true
echo "refreshed=${PIPESTATUS[*]}"
