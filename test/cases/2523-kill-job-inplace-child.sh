# `kill %N` reaches the process the job IS: a `{ …; exec cmd; } &` job's process has become
# cmd, and a `( …; cmd ) &` job execs its last command in place (execute_in_subshell's
# CMD_NO_FORK) — both die with the job. A `{ …; cmd; } &` group forks cmd as a child of its
# own, which a plain kill (no job control: kill_pid signals the job's pid) leaves running;
# with job control (set -m) the job is a process group and killpg reaches every member.
# With job control, a background job a signal killed is reported in the standard form
# (notify_of_job_status's `else if (job_control)`: `[N]+  Terminated  cmd`), and an async
# job no longer starts with SIGINT ignored (setup_async_signals is only without it).
t=${TMPDIR:-/tmp}; u=$$
left() { ps -eo pid=,args= | awk -v a="$1" '$2 == "/bin/sleep" && $3 == a { print $1 }'; }
chk() { local p; p=$(left "$1"); echo "$2 left=$(echo $p | wc -w)"; [ -n "$p" ] && kill $p; }
# (kill only once the job's sleep runs: an earlier kill would end the job before it)
up() { until [ -n "$(left "$1")" ]; do sleep 0.01; done; }
settle() { while kill -0 "$1" 2>/dev/null; do sleep 0.01; done; /bin/true; }
n=0
v() { n=$((n + 1)); echo "30.$u$n"; }
a=$(v); { /bin/sleep $a; } & p=$!; up $a; kill %1; wait %1; chk $a "group st=$?"
a=$(v); ( /bin/true; /bin/sleep $a ) & p=$!; up $a; kill %1; wait %1; chk $a "paren-tail st=$?"
a=$(v); { /bin/true; exec /bin/sleep $a; } & p=$!; up $a; kill %1; wait %1; chk $a "exec st=$?"
a=$(v); { (/bin/true; /bin/sleep $a); /bin/true; } & p=$!; up $a; kill %1; wait %1; chk $a "nested st=$?"
a=$(v); ( exec /bin/sleep $a ) & p=$!; up $a; kill %1; wait %1; chk $a "paren-exec st=$?"
hot() {
  local i r=
  for ((i = 0; i < 150; i++)); do
    { exec /bin/sleep $1; } & kill %1; wait %1; r+="$? "
  done
  echo $r | tr ' ' '\n' | sort | uniq -c | sed 's/^ *//'
}
a=$(v); hot $a; chk $a hot
set -m
a=$(v); { /bin/sleep $a; } & p=$!; up $a; kill %1; settle $p 2>&1; chk $a "jc group"
a=$(v); { /bin/true; exec /bin/sleep $a; } & p=$!; up $a; kill %1; settle $p 2>&1; chk $a "jc exec"
{ sleep 5; } 2>&1 & p=$!; kill -PIPE %1; settle $p 2>&1; echo pipe
sleep 5 & p=$!; kill -INT %1; settle $p 2>&1; echo int
sleep 5 & p=$!; trap 'echo usr' USR1; kill -USR1 %1; settle $p 2>&1; trap - USR1; echo usr1
