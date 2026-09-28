# notify_of_job_status as bash 5.2.21 has it (patch 5.2-030 changed it later): a
# non-interactive shell marks a background job a signal killed as notified even when it
# prints nothing for it (TERM, a trapped signal), so it leaves the job table at once; a
# `-c` shell does the same with jobs that simply exited — `jobs` doesn't list them, `wait
# %N` finds no such job, `wait PID` still has the status. A script keeps an exited job
# until `jobs`/`wait` shows it. In posix mode a -c shell prints nothing and keeps only $!'s.
S=${THIS_SH:-bash}
# Every job's end is ordered against the shell, so no line depends on timing (a bash that
# is slow to run a test would otherwise print differently):
# settle PID: until the job has ended and been reaped (kill -0 still finds a zombie), then a
# foreground command — its wait runs notify_of_job_status — so every `jobs` below sees the
# notification done. A `( … ) &` job that ends by itself first waits on the fifo `fq` for
# the shell's `: >fq`: a child that ends between fork and stop_pipeline makes bash's
# reset_current find no running job, and the ended job is then not current (`+`) — seen
# under load. Two jobs killed together are killed and settled one at a time, the later one
# first: reaping the first while the second still ran made the second current (`[2]+`) —
# seen under load, in bash's reaping order as in curse's. The USR1 trap is set after its job's fork: a USR1 that reaches bash's forked
# child before its exec would run the inherited trap there, and `sleep 3` then ends Done.
body='
settle() { while kill -0 "$1" 2>/dev/null; do sleep 0.01; done; /bin/true; }
(read x <fq; exit 0) & : >fq; settle $!; echo "a:"; jobs
sleep 3 & p=$!; kill %1; settle $p; echo "b:"; jobs
sleep 3 & p=$!; trap "echo usr1" USR1; kill -USR1 %1; settle $p; echo "d:"; jobs; trap - USR1
sleep 3 & p=$!; kill -HUP %1; settle $p; echo "e:"; jobs
sleep 3 & p=$!; kill %1; settle $p; echo "f:"; jobs; wait $p; echo "f wait=$?"
(read x <fq; exit 3) & : >fq; settle $!; echo "g:"; jobs; wait %1; echo "g=$?"
(read x <fq; exit 4) & q=$!; : >fq; settle $q; (read x <fq; exit 5) & : >fq; settle $!; echo "h:"; jobs; wait $q; echo "h=$?"
sleep 3 & a=$!; sleep 3 & b=$!; kill %2; settle $b; kill %1; settle $a; wait; jobs; echo "i:"; wait $b; echo "i=$?"
'
n() { sed -e 's/[0-9][0-9][0-9][0-9]*/N/g' -e 's/^[^ ]*: line/SH: line/'; }
rm -f fq; mkfifo fq
printf '%s' "$body" > js.sh
echo "== script"; "$S" js.sh 2>&1 | n
echo "== -c"; "$S" -c "$body" 2>&1 | n
echo "== -c posix"; "$S" --posix -c "$body" 2>&1 | n
rm -f js.sh fq
# hot: the same in a loop of 150 (compiled): a TERM-killed job notify dropped from the table,
# then `wait` (bgp_clear) forgets its pid too
settle() { while kill -0 "$1" 2>/dev/null; do sleep 0.01; done; /bin/true; }
hot() { local i r=; for ((i = 0; i < 150; i++)); do
  sleep 3 & p=$!; kill $p; settle $p; wait; wait $p 2>/dev/null; r+="$? "; done; echo $r | tr ' ' '\n' | sort | uniq -c; }
hot | sed 's/^ *//'
