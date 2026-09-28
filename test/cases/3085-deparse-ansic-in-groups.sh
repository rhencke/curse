# `declare -f` prints words as parse.y read them: a $'…' in an array literal is translated
# ('…'), and inside a ${…} / $((…)) too — then, in "…", left bare unless the ${…} is a
# pattern operator (# % / ^ ,: single-quoted), a NUL in a bare one ending the word's text;
# a "…" nested in a ${…} is a plain string again (its `$` and $'…' kept), a $"…" in a
# group becomes "…". curse printed $'…' untranslated there and dropped a `$` before a `"`
# nested in ${…} (fuzz F96, F97).
f() { a=(x $'t\tu' p$'\0'q); echo "${x-$'a\tb'}"; }; declare -f f
g() { p "${x+"$"}" "${u-"a$"}" "${x+$"t"}"; }; declare -f g
h() { echo "${x-$'a\tb'}" ${x-$'c\td'} "${x#$'e\tf'}" ${x#$'g\th'} "${x/$'i'/$'j'}" "${x:-$'k\'l'}" ${x:-$'m\'n'} "${x-"$'o'"}" "$'p'" "${x-${y-$'q'}}" ${x-"$'r'"}; b+=($'y'); local c=($'s'); declare -a d=($'t'); }
declare -f h
k() { echo "${u-r$'\0'tail}" "${u,,$'\x41'}" $(( $'1' + 1 )) "$(( ${#x} ))"; x=(${u:-$'z\0y'}); }
declare -f k
eval "$(declare -f g)"; x=1; u=; g() { printf '<%s>' "${x+"$"}" "${u-"a$"}"; echo; }; g
i=0; while [ $i -lt 150 ]; do eval 'm() { echo "${x-$'"'"'a'"'"'}" "${x+"$"}"; }'; declare -f m; i=$((i + 1)); done | sort | uniq -c
