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
