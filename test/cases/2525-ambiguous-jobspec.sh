# An ambiguous job spec (`%sleep` with two sleep jobs): kill, wait and disown reject it
# deterministically (INVALID_JOB / j < 0 checks) and each names ITSELF — disown too.
# (`jobs` is excluded: its DUP_JOB path reads jobs[-2], bash UB — docs/bash-ub.md.) Run in the
# main shell (in a subshell the jobs aren't the shell's own, and bash never gets as far
# as the ambiguity); checked hot too: the same calls from a function called 150 times.
e=${TMPDIR:-/tmp}/c2525.$$
sleep 5 & sleep 6 &
for c in 'kill -0' disown wait; do
	$c %sleep 2>>"$e"; echo "$c st=$?"
done
sed 's/^[^:]*: line [0-9]*: //' "$e"; : >"$e"
f() { disown %sleep; b=$?; kill -0 %sleep; c=$?; r="$r$b$c "; }
r=; for ((i = 0; i < 150; i++)); do f 2>>"$e"; done
echo "$r" | tr ' ' '\n' | sort | uniq -c
sed 's/^[^:]*: line [0-9]*: //' "$e" | sort | uniq -c
rm -f "$e"
kill %1 %2 2>/dev/null
wait 2>/dev/null
echo done
