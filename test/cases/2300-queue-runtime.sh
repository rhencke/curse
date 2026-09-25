# Runtime queue: PIPESTATUS after ( … ), a pipeline stage's view of the parent's jobs
# (jobs_hack), dead-job cleanup at the parser's next input line (notify_and_cleanup),
# `return` from a trap handler, and `bind` isolated in subshells / $( ) / stages.

# --- ( … ) is waited for as a one-process job: it sets PIPESTATUS (setjstatus)
(exit 3); echo "a ${PIPESTATUS[0]} ${#PIPESTATUS[@]}"
{ false; }; echo "b ${PIPESTATUS[@]}"
true | (exit 4); echo "c ${PIPESTATUS[@]}"
f() { (exit 5); echo "e ${PIPESTATUS[0]}"; }; f
if (exit 7); then :; fi; echo "h ${PIPESTATUS[@]}"
( (exit 8) ); echo "i ${PIPESTATUS[@]}"
for i in 1; do (exit 9); done; echo "j ${PIPESTATUS[@]}"
{ (exit 3); } >/dev/null; echo "k ${PIPESTATUS[@]}"
! (exit 3); echo "l ${PIPESTATUS[@]}"
(exit 3) || true; echo "m ${PIPESTATUS[@]}"
while (exit 3); do :; done; echo "n ${PIPESTATUS[@]}"
(exit 3) </nonexistent 2>/dev/null; echo "o ${PIPESTATUS[@]}"
true | (exit 2) | { (exit 9); }; echo "p ${PIPESTATUS[@]}"

# --- a `jobs` pipeline stage lists the parent's jobs, %+/%- marks included; a
# compound stage has none (without_job_control)
sleep 3 & sleep 3 &
jobs %1 | cat
jobs | cat
jobs %- | cat
echo "procsub:"; cat < <(jobs %+)
echo "group:"; { jobs; } | cat
echo "loop:"; while :; do jobs; break; done | cat
kill %1 %2; wait %1 %2

# --- a job `wait`/`jobs` reported stays listed until the parser reads its next line
sleep 0 & wait %1; jobs %1; echo "r1=$?"
jobs %1 2>&1 | sed 's/^.*line [0-9]*: //'; echo "r2=${PIPESTATUS[0]}"
{
sleep 0 & wait %1
jobs %1; echo "r3=$?"
}
g() { sleep 0 & wait %1; }; g; jobs %1; echo "r4=$?"
g
jobs %1 2>/dev/null; echo "r5=$?"
sleep 0 & wait %1; eval 'jobs %1' 2>/dev/null; echo "r6=$?"
sleep 0 & wait %1; eval 'true'; jobs %1 2>/dev/null; echo "r7=$?"
sleep 0 & wait %1; (jobs %1) 2>/dev/null; echo "r8=$?"
sleep 0 & wait %1; x=$(jobs %1 2>/dev/null); echo "r9=$? [$x]"
eval "sleep 0 & wait %1
jobs %1" 2>/dev/null; echo "r10=$?"
sleep 0 & wait %1; jobs; jobs %1 2>/dev/null; echo "r11=$?"

# --- `return` in a trap handler returns from the function the trap interrupted
h() { trap 'return' USR1; false; kill -USR1 $BASHPID; echo notreached; }; h; echo "trap return -> $?"
k() { trap 'false; return' USR1; true; kill -USR1 $BASHPID; echo notreached; }; k; echo "trap return2 -> $?"
trap - USR1
f() { trap "return 7" ERR; false; echo no; }; f; echo "err-return $?"
g() { trap "return" ERR; true; false; echo no; }; g 2>err.$$; echo "err-return2 $?"; sed 's/^.*line [0-9]*: //' err.$$; rm -f err.$$
trap - ERR

# --- bind changes readline's (process-wide) state: a subshell's changes die with it
( bind '"\C-y": accept-line' ) 2>/dev/null; bind -q accept-line 2>/dev/null | grep -c C-y
x=$(bind 'set bell-style none' 2>/dev/null); bind -v 2>/dev/null | grep bell-style
bind 'set bell-style visible' 2>/dev/null | cat; bind -v 2>/dev/null | grep bell-style
( bind '"\C-x\C-y": "macro text"'; bind -s ) 2>/dev/null; bind -s 2>/dev/null | grep -c macro
bind '"\C-xq": "outer"' 2>/dev/null; ( bind '"\C-xq": "inner"'; bind -s | grep xq ) 2>/dev/null; bind -s 2>/dev/null | grep xq
( bind -r '\C-xq' ) 2>/dev/null; bind -s 2>/dev/null | grep xq
( bind 'set editing-mode vi'; bind -v | grep editing-mode ) 2>/dev/null; bind -v 2>/dev/null | grep editing-mode
( bind -x '"\C-t": echo hi'; bind -X ) 2>/dev/null; bind -X 2>/dev/null | wc -l
bind '"\C-y": accept-line' 2>/dev/null; bind -q accept-line 2>/dev/null | grep -c C-y
