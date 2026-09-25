# pathexp.c + lib/glob/{glob.c,sm_loop.c,smatch.c}: pathname expansion and pattern
# matching corners — GLOBIGNORE's dotglob side effect (setup_glob_ignore) and its
# FNM_PATHNAME matching quirks, bracket-expression escapes/ranges/classes (BRACKMATCH),
# globasciiranges, nocase + char classes, trailing backslashes, extglob parsing, and
# the multibyte (Big5-HKSCS) cases behind bash's glob.tests/glob2.sub.
LC_ALL=C.UTF-8
t() { # t STRING PATTERN -> case result, [[ ]] result
	local r=n; case $1 in $2) r=y;; esac
	[[ $1 == $2 ]] && r+=Y || r+=N
	echo "$r [$1] [$2]"
}
mkdir g && cd g || exit
touch a b abc Abc .h

# GLOBIGNORE flips the real dotglob flag: set non-empty => on, unset => off (even if
# dotglob was set by shopt), empty => unchanged; only matches are filtered by it
GLOBIGNORE=; echo "1: " *; shopt -p dotglob
GLOBIGNORE=x; shopt -p dotglob
shopt -u dotglob; echo "2: " *
unset GLOBIGNORE; shopt -s dotglob; GLOBIGNORE=x; unset GLOBIGNORE
echo "3: " *; shopt -p dotglob
GLOBIGNORE=x; GLOBIGNORE=; echo "4: " *; shopt -p dotglob; unset GLOBIGNORE
f() { local GLOBIGNORE=abc; echo "5: " a*; }; f; echo "5b:" *; shopt -p dotglob
shopt -u dotglob

# GLOBIGNORE uses FNM_PATHNAME, but a trailing * (or *?) still matches across `/'
mkdir d1; touch d1/f1 d1/f2
for gi in '*' 'd*' '*?' 'd**' '*1' '*f1' 'd1/?1'; do
	GLOBIGNORE=$gi; echo "6 $gi: " d1/*
done
unset GLOBIGNORE
# extglob and nocaseglob apply to GLOBIGNORE patterns
shopt -s extglob
GLOBIGNORE='!(a*)'; echo "7: " *
GLOBIGNORE='x:!(b)'; echo "8: " *
GLOBIGNORE='+(a|b)'; echo "9: " *
unset GLOBIGNORE
shopt -s nocaseglob; GLOBIGNORE='a*'; echo "10:" *; unset GLOBIGNORE; shopt -u nocaseglob

# bracket expressions: backslash escapes inside [...], quoted `-', ranges, classes
t '^' '[\^]'
t '\' '[\^]'
t '-' '[a\-c]'
t 'b' '[a\-c]'
t 'b' '[a-\c]'
[[ - == [a"-"c] ]] && echo "q-: y"; [[ b == [a"-"c] ]] || echo "qb: n"
t 'b' '[[:alpha:]-z]'
t '-' '[[:alpha:]-z]'
t '1' '[[:alpha:]-z]'
t 'b' '[z-ab]'
t 'a' '[[:foo:]a]'
t '[ab' '[ab'
t '[\' '[\'
t ']' '[[.].]]'
t '-' '[[.hyphen.]]'
t 'b' '[a-[.c.]]'
touch x-c xbc; echo "11:" x[b"-"d]c x[\-]c

# a [[ ]] pattern that merely STARTS with a quoted part still globs
[[ a-b == "a-"* ]] && echo "q*: y"

# a pattern ending in `*\' never matches; `?\' does
t 'a\' '*\'
t 'a\' '?\'
touch 'q\' 'qq\'; p='q*\'; echo "12:" $p; p='q?\'; echo "13:" $p

# `//' in a pattern's directory part is kept
echo "14:" d1//*

# globasciiranges (default on): ranges by code point; off: locale collation
LC_ALL=en_US.UTF-8
t 'é' '[a-z]'
t 'B' '[a-c]'
shopt -u globasciiranges
t 'B' '[a-c]'
t 'b' '[A-C]'
shopt -s globasciiranges
# [=e=] is a single-character equivalence (no accent folding)
t 'é' '[[=e=]]'
LC_ALL=C.UTF-8
# character classes are not case-folded by nocasematch / nocaseglob
shopt -s nocasematch
t 'A' '[[:lower:]]'
t 'a' '[[:upper:]]'
t 'B' '[a-c]'
shopt -u nocasematch
shopt -s nocaseglob; echo "15:" [[:lower:]]*; echo "16:" [[:upper:]]b*; shopt -u nocaseglob

# extglob off: a pattern word from an expansion is not an extglob (case, pathname)
shopt -u extglob
touch aa; p='+(a)'
case aa in $p) echo "17: y";; *) echo "17: n";; esac
echo "18:" $p
[[ aa == $p ]] && echo "19: y"
shopt -s extglob
# an unclosed extglob group is a syntax error; an escaped paren inside is fine
eval 'echo @(a' 2>&1 | sed 's/^.*line [0-9]*: //'
eval '[[ ")" == @(\)) ]] && echo "20: y"'
eval '[[ ")" == @(x|\)) ]] && echo "21: y"'

# multibyte: in Big5-HKSCS U+03B1 is 0xA3 0x5C — the trailing byte is not a backslash
LC_ALL=zh_HK.big5hkscs
a=$'\xa3\x5c'
[[ $a = $a ]] && echo "22: ok"
case $a in $a) echo "23: ok";; *) echo "23: bad";; esac
read x y z <<< "$a b c"; echo "24: $y"
# $'\u…' is encoded in the locale current when the line is parsed
b=$'\u3b1'; printf '25: %s\n' "$b" | od -An -tx1
LC_ALL=C.UTF-8
