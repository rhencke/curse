# A hot loop in a pipeline stage (or other isolated context) runs the rest of its
# iterations compiled, entered at the loop's resume point; a line abort there (a readonly
# assignment) ends the loop — the aborted iteration never runs again.
exec 2>&1
readonly r=1
declare -n nr=r
for ((i = 0; i < 300; i++)); do
	echo "c $i" >&2
	if ((i == 299)); then nr=5; echo "not reached"; fi
done 2>&1 | tail -3
for i in $(seq 0 299); do
	echo "in $i" >&2
	if ((i == 299)); then nr=5; echo "not reached"; fi
done 2>&1 | tail -3
i=0; while ((i < 300)); do
	echo "w $i" >&2
	if ((i == 299)); then nr=5; echo "not reached"; fi
	((i++))
done 2>&1 | tail -3
echo done
