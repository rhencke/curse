# `read -t` on a process substitution times out (status 128+SIGALRM, partial input kept)
# when its writer is slow: opening /dev/fd/N of the pipe doesn't wait for data (bash's
# redirection just opens it; the timeout covers the read). And when data comes in time,
# it's read (a hot loop: compiled).
read -t .3 r < <(sleep 1); echo "st=$? r=[$r]"
read -t .3 r < <(printf 'par'; sleep 1); echo "partial st=$? r=[$r]"
n=0
for ((i = 0; i < 150; i++)); do
	read -t 5 r < <(echo "x$i") && [ "$r" = "x$i" ] && n=$((n+1))
done
echo "read in time: $n"
