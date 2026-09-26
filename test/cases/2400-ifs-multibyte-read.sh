# A multibyte IFS character delimits `read` fields as a whole codepoint (bash read.def
# via list_string / get_word_from_string): with IFS=é, the à in 'aàbécé' (sharing é's
# lead byte 0xC3) is ordinary text, not half a delimiter.
export LC_ALL=C.UTF-8
IFS=é read -r -a x <<< 'aàbécé'; printf '<%s>' "${x[@]}"; echo
IFS=é read -r p q <<< 'aàbécé'; printf '<%s>' "$p" "$q"; echo
IFS=é read -r p q r s <<< 'aàbécé'; printf '<%s>' "$p" "$q" "$r" "$s"; echo
IFS=é read -r p <<< 'aàbécé'; printf '<%s>' "$p"; echo
IFS=é read -r p q <<< 'aàbécéd'; printf '<%s>' "$p" "$q"; echo
# the same word split through an expansion (every tier's field engine)
v='aàbécé'; IFS=é; set -- $v; printf '<%s>' "$@"; echo
set -- x$v"y"; printf '<%s>' "$@"; echo
unset IFS
# a long unquoted expansion inside a mixed word splits in linear time
long=$(printf 'ab %.0s' {1..20000}); set -- x$long; echo $# "$1" "${!#}"
# ...but bash consumes the delimiter run BYTE-wise (subst.c: after IFS whitespace, ONE byte
# of a non-whitespace IFS char, sindex++): the rest of a multibyte delimiter then starts
# the next field (as a stray byte it still delimits — here an empty field).
export LC_ALL=C.UTF-8
IFS='é ' read -r a b <<< 'a é b'; printf '<%q>' "$a" "$b"; echo
IFS=' é' read -r a <<< ' a é '; printf '<%q>' "$a"; echo
IFS='é ' read -r -a x <<< ' a é b é c d '; printf '<%q>' "${x[@]}"; echo
IFS='é ' read -r a b <<< 'a àb'; printf '<%q>' "$a" "$b"; echo
v='a é b é c'; IFS='é '; set -- $v; unset IFS; printf '<%q>' "$@"; echo
v='a €b'; IFS='€ '; set -- $v; unset IFS; printf '<%q>' "$@"; echo
# a stray (invalid) byte of the text is matched byte-wise against IFS's bytes; a valid char
# is never split by an IFS byte (only an IFS char that is itself complete delimits whole)
IFS=é read -r -a x <<< $'a\xc3b'; printf '<%q>' "${x[@]}"; echo
IFS=$'\xa9' read -r -a x <<< $'a\xc3\xa9b\xa9c'; printf '<%q>' "${x[@]}"; echo
IFS=$'\xa9' read -r p q <<< $'a\xc3\xa9b\xc3c'; printf '<%q>' "$p" "$q"; echo
IFS=$'\xc3' read -r p q <<< $'aéb\xc3c'; printf '<%q>' "$p" "$q"; echo
# a word split part by part splits as the whole word: the delimiter state carries across
IFS=': '; x=' :a : b: '; set -- $x$x; echo $#; set -- q$x$x; echo $#; set -- $x"q"$x; echo $#; unset IFS
# the same in hot code (a loop and a function that tier up into compiled code)
f() { IFS='é '; set -- $1$1; unset IFS; printf '<%q>' "$@"; IFS='é ' read -r a b <<< "$1"; printf '[%q]' "$a" "$b"; }
for ((i = 0; i < 200; i++)); do r=$(f ' a é b ') n=$((n + ${#r})); IFS=': '; x=' :a : b: '; set -- q$x$x; unset IFS; m=$((m + $#)); done
echo "$r" $n $m
