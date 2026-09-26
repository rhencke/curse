# notify_of_job_status as bash 5.2.21 has it (patch 5.2-030 changed it later): a
# non-interactive shell marks a background job a signal killed as notified even when it
# prints nothing for it (TERM, a trapped signal), so it leaves the job table at once; a
# `-c` shell does the same with jobs that simply exited — `jobs` doesn't list them, `wait
# %N` finds no such job, `wait PID` still has the status. A script keeps an exited job
# until `jobs`/`wait` shows it. In posix mode a -c shell prints nothing and keeps only $!'s.
S=${THIS_SH:-bash}
body='
sleep 0.05 & sleep 0.2; echo "a:"; jobs
sleep 3 & kill %1; sleep 0.2; echo "b:"; jobs
trap "echo usr1" USR1; sleep 3 & kill -USR1 %1; sleep 0.2; echo "d:"; jobs; trap - USR1
sleep 3 & kill -HUP %1; sleep 0.2; echo "e:"; jobs
sleep 3 & p=$!; kill %1; sleep 0.2; echo "f:"; jobs; wait $p; echo "f wait=$?"
(exit 3) & sleep 0.2; echo "g:"; jobs; wait %1; echo "g=$?"
(exit 4) & q=$!; (exit 5) & sleep 0.2; echo "h:"; jobs; wait $q; echo "h=$?"
'
n() { sed -e 's/[0-9][0-9][0-9][0-9]*/N/g' -e 's/^[^ ]*: line/SH: line/'; }
printf '%s' "$body" > js.sh
echo "== script"; "$S" js.sh 2>&1 | n
echo "== -c"; "$S" -c "$body" 2>&1 | n
echo "== -c posix"; "$S" --posix -c "$body" 2>&1 | n
rm -f js.sh
