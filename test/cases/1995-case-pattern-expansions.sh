# case / [[ == ]] patterns with $(…), $((…)), ${…} operators and $*/$@: compiled to
# their glob form (quoted parts escaped) instead of the shared I.case_match matcher.
# (and a recurring $(…) whose body redirects a builtin: the tier fragment runs under the
# isolated fd-level capture, so `echo e >&2` reaches stderr)
set -- "a b" c
t() { case $1 in $(echo 'x*')) echo "1:$1 cmdsub-glob";; "$(echo 'y*')") echo "1:$1 quoted-cmdsub";; $((1+2))) echo "1:$1 arith";; ${p:-z?}) echo "1:$1 default";; "${q:-w*}") echo "1:$1 qdefault";; $*) echo "1:$1 star";; "$*") echo "1:$1 qstar";; $@) echo "1:$1 at";; "$@") echo "1:$1 qat";; *) echo "1:$1 none";; esac; }
for s in xyz 'y*' yz 3 zq w1 'w*' 'a b c' a c; do t "$s"; done
IFS=:; for s in 'a b:c' 'a b c'; do t "$s"; done; unset IFS
f() { case "$1" in "$2"|$3) echo m;; *) echo n;; esac; }
f 'a*' 'a*' q; f ab 'a*' q; f ab x 'a*'
n=0; case x in $((n+=1))) ;; $((n+=1))) ;; x) echo n=$n;; esac
[[ abc == $(echo 'a*') ]] && echo dbl1; [[ abc == "$(echo 'a*')" ]] || echo dbl2
declare -A A
A[Darwin]=dj
for i in 1 2 3 4; do echo ${A[$(echo Darwin ; echo stderr>&2)]^^}; done
for i in 1 2 3 4; do x=$(echo Darwin; echo e >&2); echo $x; done
