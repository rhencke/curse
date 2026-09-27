# Word splitting and `read` in non-UTF-8 multibyte locales (Big5, GBK, GB18030): bash's
# string_extract_verbatim (subst.c) tests a byte that is no multibyte char with MEMBER
# (general.h), whose mbschr compares a SIGNED char. So a high byte delimits only when IFS
# is that one byte, and an ASCII byte >= '0' only when IFS holds it as a char of its own
# (not as a trail byte: Big5's \xa4@). A byte below '0' is found by strchr. A valid
# multibyte char delimits only whole. Under IFS=é in Big5, `a\xc3\xa0b` (c3 a0 is
# invalid there) stays whole. A quoted "${a[@]}" joins on IFS[0], so an IFS[0] that is no
# MEMBER joins the elements. read_mbchar may take the delimiter as a trail byte.
dump() { LC_ALL=C od -An -c | tr -s ' ' | tr -d '\n'; echo; }
t() { # locale ifs text
	LC_ALL=$1; IFS=$2; local x=$3 out a arr p q
	set -- $x; out="$#:"; for a; do out+="<$a>"; done
	IFS=$2 read -r p q <<<"$x"; out+=" P<$p><$q>"
	IFS=$2 read -r -a arr <<<"$x"; out+=" R${#arr[@]}:"; for a in "${arr[@]}"; do out+="<$a>"; done
	LC_ALL=C; IFS=$' \t\n'; printf %s "$out" | dump
}
cases=(
	$'\xc3\xa9' $'a\xc3\xa0b'
	$'\xc3\xa9' $'a\xc3\xa0b\xc3\xa9c'
	$'\xc3' $'a\xc3\xa0b'
	$'\xc3:' $'a\xc3\xa0b:c'
	$'\xa4\x40' 'a@b'
	$'\xa4\x40' $'a\xa4\x40b'
	$'\xa4\x40,' 'a@b,c'
	@ $'a\xa4@b@c'
	$'\xa4\x21' $'a\xa4\x21b'
	$'\x81\x30\x81\x30' $'a0b\x81\x30c'
	$'x\xc3\xa9' $'a\xc3\xa0bxc'
	$'\xff:' $'a\xffb:c'
	$'\xa4' $'a\xa4\x40b\xa4c'
	'5' $'a\x815\x815b'
	$'\xa4\x40 ' $'a @b\xa4\x40 c'
)
# (GBK and GB18030 run a case per process: glibc's mblen/mbtowc keep a STATIC
# conversion state, which a GB18030 scan can leave pending for later ones)
if [ "$1" = one ]; then
	t "$2" "$3" "$4"
	exit
fi
S=${THIS_SH:-bash}
sect() { # locale [each: a process per case]
	if ! LC_ALL=$1 locale charmap >/dev/null 2>&1; then
		echo "-- $1: skip"
		return 1
	fi
	echo "-- $1"
	for ((k = 0; k < ${#cases[@]}; k += 2)); do
		if [ "$2" ]; then
			"$S" "$0" one $1 "${cases[k]}" "${cases[k + 1]}"
		else
			t $1 "${cases[k]}" "${cases[k + 1]}"
		fi
	done
}
sect zh_CN.gbk each
sect zh_CN.gb18030 each
sect zh_TW.BIG5 || exit 0
LC_ALL=zh_TW.BIG5
echo "-- hot loop (Big5)"
n=0 m=0
for ((i = 0; i < 160; i++)); do
	IFS=$'\xc3\xa9'; x=$'a\xc3\xa0b\xc3\xa9c'; set -- $x; n=$((n + $#))
	IFS=$'\xa4\x40,'; x='a@b,c'; set -- $x; m=$((m + $#))
done
IFS=$' \t\n'
echo "$n $m"
f() { local IFS=$'\xa4\x40'; set -- $1; echo "fn $#"; }
for ((i = 0; i < 150; i++)); do f 'a@b'; done | sort | uniq -c | sed 's/^ *//'
echo "-- eval / trap / source"
IFS=$'\xc3\xa9'; x=$'a\xc3\xa0b'
eval 'set -- $x; echo "eval $#"'
trap 'set -- $x; echo "trap $#"' USR1; kill -USR1 $$; trap - USR1
d=${TMPDIR:-/tmp}/b5$$; mkdir -p "$d"
echo 'set -- $x; echo "source $#"' >"$d/s"; . "$d/s"; rm -rf "$d"
IFS=$' \t\n'
