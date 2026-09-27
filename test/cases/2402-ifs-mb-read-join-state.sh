# read and word splitting with multibyte / special IFS bytes (bash 5.2 read.def, subst.c)
p() { printf '%s:' "$1"; shift; printf '<%s>' "$@" | od -An -c | tr -s ' ' | tr -d '\n'; echo; }
for loc in C.UTF-8 C; do
export LC_ALL=$loc; echo "== $loc"
# a backslash escapes ONE byte of a multibyte char (CTLESC + byte, read_mbchar's rest raw)
for ifs in é $'\xa9' $'é ' $' \xa9' ':'; do
	for inp in 'a\éb' 'a\é' 'x a\é b' 'a\éé\éb'; do
		IFS=$ifs read -r -a A <<< "$inp"; p "$(printf %q "$ifs") $inp r-a" "${A[@]}"
		IFS=$ifs read -a A <<< "$inp"; p a "${A[@]}"
		IFS=$ifs read x y <<< "$inp"; p xy "$x" "$y"
	done
done
# IFS holding CTLESC (\1): read marks nothing but a CTLNUL (\1\177, kept whole); read -a's
# list_string drops an escaped (bare) \177; a marked one makes read dequote every \1
for ifs in $'\1' $'\1 ' $' \1:' $'\1\177'; do
	for inp in $'a\\\177b' $'a\1\\\177' $'\\\177' $'a\1b\1c\177' $'a\1b\1c' $'a\177 b\1 '; do
		IFS=$ifs read -a A <<< "$inp"; p "$(printf %q "$ifs") $(printf %q "$inp") a" "${A[@]}"
		IFS=$ifs read x y <<< "$inp"; p xy "$x" "$y"
		IFS=$ifs read <<< "$inp"; p R "$REPLY"
	done
done
# \v \f \r are IFS whitespace (isspace) to word splitting; read's own strips take only
# space/tab/newline
for ifs in $'\v' $'\f\t' $'\v:' $'\r\n'; do
	for inp in $'\va\v\vb\v' $'a\v:\vb' $'\f\fa\f' $'a\r\rb\r'; do
		IFS=$ifs read -r -a A <<< "$inp"; p "$(printf %q "$ifs") $(printf %q "$inp") r-a" "${A[@]}"
		IFS=$ifs read -r x y <<< "$inp"; p rxy "$x" "$y"
		IFS=$ifs read -r x <<< "$inp"; p rx "$x"
		v=$inp; IFS=$ifs; set -- $v; unset IFS; p ws "$@"
		IFS=$ifs; set -- $v$v; unset IFS; p ws2 "$@"
	done
done
# a multibyte char split across word parts is joined before splitting
x=$'a\xc3'; y=$'\xa9b'
for ifs in é $'\xa9' $'\xc3' $' \xa9'; do
	IFS=$ifs; p "$(printf %q "$ifs") j" $x$y; p j2 $x"$y"; p j3 ${x}$'\xa9'b; unset IFS
done
# read_mbchar reads past an incomplete char: the delimiter it takes is data
read -r a b <<< $'a\xc3'; p m1 "$a" "$b"
read -r a b <<< $'\xf0\x9f'; p m2 "$a" "$b"
done
# glibc's mbtowc keeps a static state that a split word ending in an incomplete char leaves
# pending (string_extract_verbatim); a later stray continuation byte completes it
export LC_ALL=C.UTF-8
pr() { printf ' pr=%d' "'"$'\xa9'; echo; }
x=$'a\xc3'; q=($'\xc3' $'a\xc3'); set -- $'a\xc3' $'\xa9b'
IFS=é; : "${q[*]}"$x; pr; : $x; p st1 $@; pr
printf '%d ' "'"$'\xc3'; IFS=$'\xa9'; p st2 "$x"$y; pr
IFS=''; : ${q[*]}; pr; : ${q[*]}x; pr
unset IFS
