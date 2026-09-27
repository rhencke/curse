# Pinned bash behaviour: a pipeline stage whose stderr goes into the pipe (`2>&1 |`) can
# write far more than a pipe holds — set -x lines, `echo … >&2`, printf >&2 — while the
# reader (sort) drains it; nothing stalls (bash's stages are separate processes).
for ((k = 0; k < 3000; k++)); do
	(set -x; : xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx)
done 2>&1 | sort | uniq -c
for ((k = 0; k < 3000; k++)); do
	echo yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy >&2
	printf '%s\n' zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz >&2
done 2>&1 | sort | uniq -c
f() { set -x; : "$1"; set +x; } 2>&1
for ((k = 0; k < 3000; k++)); do f wwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwww; done | sort | uniq -c
