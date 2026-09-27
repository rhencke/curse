# A case pattern is read as ordinary words joined by `|` (parse.y: each pattern is a WORD
# token), so a quoted or escaped `|` or `)` belongs to the pattern — it is neither an
# alternative separator nor the clause's close. And bash's syntax errors at the token
# where a pattern word or its `|`/`)` belongs.
S=${THIS_SH:-bash}
t=${TMPDIR:-/tmp}/c2420.$$; mkdir -p "$t"; cd "$t" || exit 1
e() { sed 's/^[^:]*: line \([0-9]*\): /L\1: /'; }
r() { printf '%b' "$1" > s.sh; $S s.sh 2>&1 | e; echo "st=${PIPESTATUS[0]}"; }

echo "-- quoted and escaped | and ) in patterns"
case 'a|b' in "a|b") echo q1;; *) echo n1;; esac
case 'a|b' in a\|b) echo q2;; *) echo n2;; esac
case 'a|b' in 'a|b') echo q3;; *) echo n3;; esac
case z in "x)"|z) echo q4;; *) echo n4;; esac
case 'x)' in "x)"|z) echo q5;; *) echo n5;; esac
case b in 'a|'|b) echo q6;; *) echo n6;; esac
case 'a' in 'a|'|b) echo n7;; *) echo q7;; esac
case ')' in \)) echo q8;; esac
case '|' in "|") echo q9;; esac
case 'a b' in "a b"|c) echo q10;; esac
case "x|y" in $'x|y') echo q11;; esac
case p in "$(echo ')')"|p) echo q12;; esac
case ')' in "$(echo ')')"|p) echo q13;; esac
case 'a"b' in 'a"b'|"x'y") echo q14;; esac
case "x'y" in 'a"b'|"x'y") echo q15;; esac
case 5 in $((2+3))|6) echo q16;; esac
case y in ${u:-y}|z) echo q17;; esac
case 'a|b' in a*|z) echo q18;; esac
case '(' in \() echo q19;; esac
case "multi
line" in "multi
line"|x) echo q20;; esac
echo "-- syntax errors at the offending token"
r 'case a in a|) echo x;; esac\necho after'
r 'case a in |a) echo x;; esac'
r 'case a in ) echo x;; esac'
r 'case a in a b) echo x;; esac'
r 'case a in a;;esac'
r 'case a in a&) echo x;; esac'
r 'case a in a||b) echo x;; esac'
r 'case a in x|(z)) echo x;; esac'
r 'case a in a(b)) echo x;; esac'
r 'case a in a'
r 'case a in "a'
r 'echo 1\ncase a in\na\n) echo x;; esac'
cd / && rm -rf "$t"   # (leave nothing behind in $TMPDIR)
