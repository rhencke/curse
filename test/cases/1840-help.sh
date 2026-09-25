# help, from bash's builtins/help.def + the doc strings: every builtin's long,
# -d, -s and -m form (checksummed), the two-column listing (and at COLUMNS=40),
# patterns, the non-builtin topics (if, while, (( )), variables, …), errors
# (no topic matches, invalid option, a mix of found and missing).
e() { sed 's/^.*line [0-9]*: //'; }
names=$(enable -a | cut -d' ' -f2)
for b in $names; do help "$b"; done | md5sum
for b in $names; do help -d "$b"; done | md5sum
for b in $names; do help -s "$b"; done | md5sum
for b in $names; do help -m "$b"; done | md5sum
help | md5sum; help | wc -l
COLUMNS=40 help | md5sum
help 'r*' | md5sum; help -d 'r*'
help -s 'ex*'
help nosuch 2>&1 | e; echo "st=${PIPESTATUS[0]}"
help -x 2>&1 | e; echo "st=${PIPESTATUS[0]}"
help -d nosuch echo 2>&1 | e; echo "st=${PIPESTATUS[0]}"
help -- -x 2>&1 | e; echo "st=${PIPESTATUS[0]}"
help if while for | md5sum; help -d '(( ))' '[[ ... ]]' 'for ((' '{ ... }' 'variables' 'job_spec'
help -s if case function; help -d time coproc select
help '*' | wc -l
