# A script with an alias runs a line at a time (line mode): a function defined on one line
# (via eval, invisible to the compiler) must still make a later `$(fname)` isolated, cold
# and hot — a function call in $(…) is never the light no-checkpoint capture.
alias q=true
eval 'lf() { g=$((g+1)); echo lf; }'; x=$(lf); echo "x=$x g=${g-u}"
for ((i = 0; i < 150; i++)); do x=$(lf); done; echo "x=$x g=${g-u}"
eval 'lp() { n=$((n+1)); }'
for ((i = 0; i < 150; i++)); do x=$(true && lp | cat); done; echo "n=${n-u}"
