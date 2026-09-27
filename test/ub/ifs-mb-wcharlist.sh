# docs/bash-ub.md: IFS that isn't valid text in the locale (mbstowcs fails, so bash's
# wcharlist is uninitialized heap) while a glibc mbtowc state left pending by an earlier
# split word (x ends in a lone \xc3) completes on the unquoted IFS[0] between the quoted
# elements of "${q[@]}". bash then tests the char against that garbage; curse's pinned
# choice: IFS holds nothing, so the elements are JOINED by IFS[0], never split.
# (Checked hot too: 150 calls from a function, and through eval.)
export LC_ALL=C.UTF-8
p() { printf '%s:' "$1"; shift; printf '<%s>' "$@" | od -An -tx1 | tr -d '\n'; echo; }
x=$'a\xc3'; q=(a b)
IFS=$'\xa9'; : $x; p u1 "${q[@]}"
: $x; p u2 "${q[@]}" "${q[@]}"
eval ': $x; p u3 "${q[@]}"'
f() { : $x; set -- "${q[@]}"; r="$r$#"; }
r=; for ((i = 0; i < 150; i++)); do f; done; echo "${#r} ${r%%2*}" | cut -c1-8
