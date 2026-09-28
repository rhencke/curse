# Under `set -n` a non-interactive shell reads without executing: a `time` pipeline prints
# no timing report, but a here-document delimited by end-of-file — in a $( … ) too, which
# is read with its line — is still warned about. curse printed the report and dropped the
# warning (fuzz F94, F95).
e() { printf '%s\n' "$1" > "${TMPDIR:-/tmp}/c3084.$$"; "$THIS_SH" "${TMPDIR:-/tmp}/c3084.$$" 2>&1 | sed 's/^[^:]*: //'; echo "st $?"; }
e 'set -n
time echo hi'
e 'set -n
time -p { echo a; }
echo after'
e 'set -n
z=$(cat <<EOF
hey
EOF  )'
e 'set -n
cat <<EOF
hey'
e 'set -n
f() { z=$(cat <<EOF
hey
EOF  )
}'
e 'eval $'"'"'set -n\ntime echo hi'"'"'
echo notreached'
e 'eval $'"'"'set -n\nz=$(cat <<EOF\nhey\nEOF  )'"'"''
rm -f "${TMPDIR:-/tmp}/c3084.$$"
i=0; while [ $i -lt 150 ]; do ( eval $'set -n\ntime :\nz=$(cat <<E\nx\nE  )' ); echo "loop $?"; i=$((i + 1)); done 2>&1 | sed 's/^[^:]*: //' | sort | uniq -c
