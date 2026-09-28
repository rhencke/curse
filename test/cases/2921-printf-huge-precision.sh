# printf with a huge `*` precision: bash (glibc) writes every digit — 1.000… with
# 300000000 zeros is 300 MB — where curse used to print nothing; the number's exact
# expansion ends early, the rest are zeros, streamed (leftover L22). Output goes only to
# /dev/null (dd counts it); precision INT_MAX itself is glibc overflow: docs/bash-ub.md.
# (Near INT_MAX, 2 GiB, glibc under bash needs that much memory for its buffer: with less
# it prints nothing — a resource failure, not a behaviour to copy: docs/bash-ub.md.)
n() { dd of=/dev/null bs=1M 2>&1 | tail -1 | cut -d' ' -f1; }
printf '%.*f' 300000000 1 | n
printf '%.*f' 300000000 1 >/dev/null; echo "st $?"
for f in '%.*f' '%.*e' '%.*g' '%#.*g' '%.*E' '%20.*f' '%-5.*f|' '%010.*f' 'a%.*fb'; do
	printf "$f" 1100000 1.5 | n; printf "$f" 1100000 -2.25 | tail -c 9 | od -An -c
done
printf '%.*f' 1100000 inf | n
f() { printf '%.*e\n' "$1" 12345.678 | cut -c1-12; }; f 1100000
eval 'printf "%.*f" 1100000 0.1 | n'
i=0; while [ $i -lt 150 ]; do printf '%.*f' $((1048576 + i)) $i >/dev/null || echo bad; i=$((i + 1)); done; echo "$i"
