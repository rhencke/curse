# A function's return runs pop_context, whose sv_ifs recomputes IFS's first character
# in the CURRENT locale: IFS=é set under UTF-8, then LC_ALL=C, then a call — "$*" joins
# with the single byte \303 from then on (bash; before the call, docs/bash-ub.md). Also
# when the compiled call keeps a RETURN-trap hook (the program has eval: rt.fn_return).
export LC_ALL=C.UTF-8
set -- a b
f() { :; }
IFS=é; LC_ALL=C
f
r=; for ((i = 0; i < 150; i++)); do s="$*"; r="$r${#s}"; done
eval 's2="$*"'
printf '%s|' "$*" "$s2" | od -An -tx1
echo "${#r} ${r%%[!3]*}" | cut -c1-8
g() { IFS=é; LC_ALL=C.UTF-8; LC_ALL=C; f; t="$*"; echo "${#t}"; }
for ((i = 0; i < 150; i++)); do g a b; done | sort | uniq -c | sed 's/^ *//'
trap 'u="$*"' RETURN
IFS=é; LC_ALL=C.UTF-8; LC_ALL=C; f a b
trap - RETURN
printf '%s|' "$u" "$*" | od -An -tx1
