# An extglob group that never closes: bash's sm_loop still hands `*(`/`?(`/`!(` after a `*`
# run to EXTMATCH (`**([[:` matches anything, `*!(Q` only the empty string), and
# match_upattern first tries the pattern made `*…*` (`*!(Q*` fails on `a`: no replacement).
# curse took the group as literal text (fuzz F110). [[ ]] matches extended even with
# extglob off (bash 5.2); case only with it on.
t() { for s in '' a '*(a' x xa 'x*(a' b ab; do [[ $s == $1 ]]; printf %s $?; case $s in $1) printf c;; *) printf n;; esac; done; echo " $1"; }
for p in '**([[:' '*!(Q' '*(a' '+(a' 'x*(a' '*?(' '?*(a' 'a*!(b' '**(a|b' '*(a)*(b'; do t "$p"; done
shopt -s extglob
for p in '**([[:' '*!(Q' '*(a' 'a*!(b' '*?(' '**(a|b'; do t "$p"; done
for p in '**([[:' '*!(Q' '*(a' 'a*!(b' '*?(' '!(a)' '*!(a)' '!(*a*)' '@(a|!(b))'; do
  for s in '' a 'x*(a' ab aaa cab; do printf '[%s|%s|%s|%s|%s|%s|%s|%s]' "${s#$p}" "${s##$p}" "${s%$p}" "${s%%$p}" "${s/$p/R}" "${s//$p/R}" "${s/#$p/R}" "${s/%$p/R}"; done; echo " $p"
done
eval '[[ "" == **([[: ]]'; echo "eval $?"
printf '[[ "" == *!(Q ]]; echo "src $?"\n' > s3062.sh; . ./s3062.sh
trap '[[ "" == *?( ]]; echo "trap $?"' USR1; kill -USR1 $$; trap - USR1
i=0; while [ $i -lt 150 ]; do p='*!(Q'; s=$((i % 2)); [ $s = 0 ] && s=; [[ $s == $p ]]; echo "$? ${s/$p/R}"; i=$((i + 1)); done | sort | uniq -c
rm -f s3062.sh
