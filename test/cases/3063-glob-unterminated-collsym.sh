# An unterminated `[.` collating symbol inside a bracket: BRACKMATCH's parse_collsym runs
# off the end of the pattern and the bracket fails (a `[` aside) — `[]a[.a.F]` matches no
# `]`. curse's ERE conversion took the `[.` as members (fuzz F111).
t() { for s in ']' a '[' x '[.a' F . b 'x['; do [[ $s == $1 ]]; printf %s $?; case $s in $1) printf c;; *) printf n;; esac; done; echo " $1"; }
for p in '[]a[.a.F]' '[[.a]' '[a[.x' '[.a' 'x[[.a.]' '[!a[.a.F]' '[a-[.z]' '*[[.b]*'; do t "$p"; done
s=']'; echo "${s#[]a[.a.F]}|${s/[]a[.a.F]/R}"
f() { p='[]a[.a.F]'; [[ ']' == $p ]]; echo "fn $?"; }; f
eval "[[ ']' == []a[.a.F] ]]"; echo "eval $?"
trap 'case "]" in []a[.a.F]) echo trap c1;; *) echo trap c0;; esac' USR1; kill -USR1 $$; trap - USR1
i=0; while [ $i -lt 150 ]; do case "]" in []a[.a.F]) echo c1;; *) echo c0;; esac; i=$((i + 1)); done | sort | uniq -c
