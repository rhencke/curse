# [=c=] equivalence classes through bash's FNMATCH_EQUIV_FALLBACK: configure finds that
# glibc's fnmatch can test bracket equivalence classes, so smatch.c's collequiv asks
# fnmatch("[[=c=]]", ch) when two characters don't collate equal — accented letters then
# match their base letter's class in a UTF-8 locale. (A bash built without the fallback,
# e.g. Debian's 5.2.37, matches only identical characters.)
t() { local r=n; case $1 in $2) r=y;; esac; [[ $1 == $2 ]] && r+=Y || r+=N; echo "$r [$1] [$2]"; }
for loc in en_US.UTF-8 C.UTF-8 C; do
  LC_ALL=$loc
  echo "-- $loc"
  for c in e é è ê ë E É a à á A ñ n o ö ø; do t "$c" '[[=e=]]'; t "$c" '[[=a=]]'; t "$c" '[[=n=]]x' ; done
  t 'éx' '[[=e=]]x'; t 'ñ' '[![=n=]]'; t 'ö' '[[=o=][=e=]]'
done
LC_ALL=en_US.UTF-8
d=$(mktemp -d); cd "$d" || exit
touch fe fé fè fa fà
echo f[[=e=]]; echo f[[=a=]]; echo f[![=e=]]
x=fééé; echo "${x//[[=e=]]/E}"
cd / && rm -rf "$d"
