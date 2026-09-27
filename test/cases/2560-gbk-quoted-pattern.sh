# Pinned bash behaviour: in a GBK locale a QUOTED pattern escapes by CHARACTERS (quote_string /
# COPY_CHAR_P): the trail byte 0x7c (`|`) of the double-byte char 0x81 0x7c is part of that
# char, not a metachar to backslash ‚Äî case, [[ == ]], ${v%pat}, and the set -x trace of a
# quoted [[ ]] pattern (every character backslashed, the double-byte char once).
LC_ALL=zh_CN.gbk
s=$'a\x81\x7cb'; p=$'\x81\x7cb'
case $s in "$s") echo m1;; *) echo n1;; esac
case $s in "aÅ|b") echo m2;; *) echo n2;; esac
case $s in a"$p") echo m3;; *) echo n3;; esac
[[ $s == *"$p" ]] && echo m4
echo "1${s%"$p"}" "2${s/"$p"/X}" "3${s#a"$p"}"
eval 'case $s in "$s") echo e1;; esac'
f() { case $1 in "aÅ|b") return 0;; esac; return 1; }
g() { case $1 in "$2") return 0;; esac; return 1; }
n=0; for ((i=0;i<200;i++)); do f "$s" && n=$((n+1)); g "$s" "$s" && n=$((n+1)); [[ ${s%"$p"} == a ]] && n=$((n+1)); done; echo $n
( set -x; case $s in "aÅ|b") :;; esac; [[ $s == "aÅ|b" ]]; [[ $s == "$s" ]] ) 2>&1
