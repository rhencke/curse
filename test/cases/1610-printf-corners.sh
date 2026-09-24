# printf corners from builtins/printf.def: option parsing, conversion parsing
# errors, precision handling, %c/%n/%q/%Q, getint/getintmax diagnostics, the
# %(…)T argument edge cases, tescape/bexpand diagnostics, posix-mode floats, and
# printf -v edge cases.
export TZ=UTC
t() { printf "$@" 2>&1 | sed 's/^.*line [0-9]*: //'; echo " st=${PIPESTATUS[0]}"; }
# (in the current shell, for -v and %n assignments; stderr after stdout)
tv() { printf "$@" 2>err; local s=$?; sed 's/^.*line [0-9]*: //' err; echo " st=$s"; }

# options: the last -v wins; -vNAME; -v with a bad array reference
tv -v a -v b 'x'; echo "a=[${a-unset}] b=[${b-unset}]"
tv -vc 'y'; echo "c=$c"
tv -v 'arr[' x
declare -a e=(); tv -v 'e[-1]' z

# printf -v keeps the output made before an error
tv -v q 'ab%yz'; echo "q=[$q]"
tv -v q 'ab%d' zz; echo "q=[$q]"
readonly ro=1; tv -v ro x; echo "ro=$ro"

# missing format character: the whole spec, length modifiers included, is named
t '%l'
t '%5l'
t '%hh'
t 'x%-5.3lz'
t '%5%|'
t '%hs|%ls|%lld|%jd|%zu\n' a b 1 2 3

# %c with no (or an empty) argument prints a NUL byte
printf '%c|%c|' | od -c | sed 's/  */ /g'
printf '%c%c%c\n' abc | od -c | sed 's/  */ /g'

# precision: negative * precision is ignored; wide precisions work
t '%.*s|%.*d|%.*f|\n' -1 abcdef -1 42 -2 1.5
t '%.100s|\n' ab
printf '%.100d|\n' 5 | wc -c
printf '%.*d|\n' 120 5 | wc -c
printf '%120.3f|\n' 1.5 | wc -c
printf '%#.101x|%-+120d|%0105d|%#0104o|\n' 255 7 -3 8 | tr -s ' 0' | od -c | sed 's/  */ /g'
t '%*s|%-*d|%.*s|\n' -4 a 3 5 0 abc
# an out-of-range * value warns (naming the NEXT word) and clamps
t '%.*s|\n' 99999999999 ab

# * width/precision arguments are checked like any integer
t '%*d|\n' x 3
t '%.*d|\n' 3y 3

# invalid-number diagnostics distinguish hex and octal
t '%d\n' 0x
t '%d\n' 08
# glibc strtoimax accepts 0b binary
t '%i %d\n' 0b1 0B11

# diagnostics are written before the command's buffered output
printf 'ab%dcd\n' x 2>&1 | grep -c '^ab0cd$'
# (stdout is line-buffered: the complete lines before a diagnostic come first)
printf 'a\nb%dcd\n' x 2>&1 | sed 's/^.*line [0-9]*: //'

# %n: the byte count restarts on each reuse of the format; bad names fail
tv '%n|' n1 n2; echo " n1=$n1 n2=$n2"
tv 'ab%dcd%n|\n' x n3; echo "n3=$n3"
tv '%n' 'bad-name'
tv '%s%n' xx 'a[1]'

# %q honors precision (on the quoted text); %Q applies it to the raw text
t '%.3q|\n' 'a b c'
t '%Q|%.2Q|%8.2Q|%Q|\n' 'a b' 'a b c' 'a b c' ''
t '%.*q|%.*Q|%-6q|\n' 2 'a b' 2 'a b' 'a,b'
# %q backslash-quotes bash's set: `,` anywhere, `#` only first, `~` first or after : or =
t '%q\n' 'ab,cd' 'a=b' 'a#b' '#a' 'a~b' '~a' 'a:~b' 'a=~b' 'x%+-./@:y' "a'b\"c" 'a{b}c[d]^e'

# %(fmt)T: the argument is an integer (bad text is diagnosed, prefix used);
# an unrepresentable time falls back to the epoch
t '%(%s)T|\n' abc
t '%(%s)T|\n' 12abc
t '%(%s)T|\n' 0x10
t '%(%s)T|\n' ''
LC_ALL=C t '%()T|\n' 3661
t '%(%H)T|\n' 99999999999999999999
t '%(%Y)T|\n' 0x7fffffffffffffff
t '%(abc)X|\n' 5
t '%(a%sb)X|\n' 5

# escapes: missing digits are diagnosed; \' \" \? only in the format
t '\u|\U|\n'
t '\x|\n'
t '%b|\n' '\x'
t '%b|\n' '\u'
t '%b|%b|\n' '\u41' '\U00000041'
t "%b|\\'\\\"\\?|\n" "\\'\\\"\\?"
t 'abc\'
# (a format's own diagnostics repeat on each use)
for k in 1 2; do t '\x|'; done

# thousands-grouping flag is accepted (no grouping in the C locale)
LC_ALL=C t "%'d|%'.2f|\n" 1234567 1234.5

# posix mode: floating conversions use double unless L is given
set -o posix
t '%.20f|%a|%.20Lf|%g\n' 0.1 1 0.1 0.1
set +o posix
t '%.20f|%a\n' 0.1 1
