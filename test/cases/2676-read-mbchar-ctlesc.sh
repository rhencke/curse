# read's CTLESC/CTLNUL marking around read_mbchar (read.def, bash 5.2.21). A CTLESC (\1)
# or CTLNUL (\177) read on its own is marked with a CTLESC (saw_escape; not \177 when IFS
# holds it), and a marked value is dequoted. The bytes read_mbchar takes after a lead
# byte go in RAW. A raw \1 there still escapes the next byte for the split (subst.c's
# string_extract_verbatim), but it stays in the value when nothing else was marked. A
# raw \177 is removed from a read -a field (list_string's remove_quoted_nulls).
export LC_ALL=C.UTF-8
d() { od -An -tx1 | tr -s ' ' | tr -d '\n'; echo; }
echo "-- c09's table"
printf '\xc3\x01\n' | { read -r -N 2 x; printf %s "$x" | d; }
printf '\xc3\x01\n' | { read -r -N 3 x; printf %s "$x" | d; }
printf '\xc3\x01\n' | { read -r -d , x; printf %s "$x" | d; }
printf '\xc3\x7f\n' | { IFS=, read -r -a a; printf '%s|' "${a[@]}" | d; }
echo "-- raw \\1 escapes the split, kept unless marked"
printf '\xc3\x01 b\n' | { read -r x y; printf '%s|%s' "$x" "$y" | d; }
printf '\x01\xc3\x01X\n' | { read -r x; printf %s "$x" | d; }
printf '\x7f\xc3\x7fY\n' | { IFS=, read -r -a a; printf '%s|' "${a[@]}" | d; }
printf '\xe2\x82\x01\n' | { read -r -N 2 x; printf %s "$x" | d; }
echo "-- a matrix"
for L in C C.UTF-8; do
	export LC_ALL=$L
	for inp in 'a\177b c\n' '\177\n' 'a\\\177b\n' '\001\177 x\n' 'x\\\001y\177\n' 'a\303\177 b\n' 'a\303\001\177 b\n'; do
		for ifs in $' \t\n' $'\177' $'\1' ' ,'; do
			printf "$inp" | { IFS=$ifs read -r x y; printf '%s|%s' "$x" "$y" | d; }
			printf "$inp" | { IFS=$ifs read x y; printf '%s|%s' "$x" "$y" | d; }
			printf "$inp" | { IFS=$ifs read -r -a a; printf '%s|' "${a[@]}" | d; }
			printf "$inp" | { IFS=$ifs read -r; printf %s "$REPLY" | d; }
			printf "$inp" | { IFS=$ifs read -r -N 4 x; printf %s "$x" | d; }
		done
	done
done
export LC_ALL=C.UTF-8
echo "-- hot loop"
printf 'a\xc3\x01 b\n%.0s' {1..160} >"${TMPDIR:-/tmp}/rm$$"
n=0 k=0
while read -r x y; do
	[ "$x" = $'a\xc3\x01 b' ] && n=$((n + 1))
	k=$((k + 1))
done <"${TMPDIR:-/tmp}/rm$$"
echo "$n/$k"
f() { printf '\xc3\x7f\n' | { IFS=, read -r -a a; printf '%s|' "${a[@]}"; }; }
for ((i = 0; i < 150; i++)); do f | d; done | sort | uniq -c | sed 's/^ *//'
rm -f "${TMPDIR:-/tmp}/rm$$"
echo "-- eval / trap / source"
eval 'printf "\xc3\x01\n" | { read -r -N 2 x; printf %s "$x" | d; }'
trap 'printf "\xc3\x01\n" | { read -r -d , x; printf %s "$x" | d; }' USR1; kill -USR1 $$; trap - USR1
s=${TMPDIR:-/tmp}/rs$$
echo 'printf "\xc3\x01 b\n" | { read -r x y; printf "%s|%s" "$x" "$y" | d; }' >"$s"; . "$s"; rm -f "$s"
