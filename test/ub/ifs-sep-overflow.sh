# docs/bash-ub.md: IFS's first character computed as a whole multibyte char (IFS=é under
# UTF-8: ifs_firstc_len 2), then LC_ALL=C — sv_locale doesn't redo sv_ifs — so bash copies
# 2 bytes + NUL into `char sep[MB_CUR_MAX+1]` (2 bytes): a stack overflow. curse's pinned
# choice: the first character is used whole, "$*" joins with both bytes.
# (Checked hot too: a 150-iteration loop, and through eval. A function's return runs
# pop_context's sv_ifs, which recomputes IFS[0] in the C locale — so no function is
# called between the locale change and the expansions.)
export LC_ALL=C.UTF-8
set -- a b
IFS=é; LC_ALL=C
r=; for ((i = 0; i < 150; i++)); do s="$*"; r="$r${#s}"; done
eval 's2="$*"'
printf '%s|' "$*" "$s2" | od -An -tx1
echo "${#r} ${r%%[!4]*}" | cut -c1-8
