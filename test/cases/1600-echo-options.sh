# echo, from bash's builtins/echo.def + ansicstr (lib/sh/strtrans.c) in echo mode:
# option words are only all-valid [neE] clusters; `-`, `--`, `-nx` are operands;
# posix + xpg_echo takes no options at all; \c ends ALL output; octal needs the
# leading 0 (\0nnn: up to 3 more digits), a bare \1..\7 stays literal; \x/\u/\U
# with no digits stay literal; a write error is reported and is status 1 — also
# inside a pipeline stage.
x() { printf '%s: ' "$1"; shift; "$@" | od -An -c | tr -s ' ' | tr '\n' '~'; echo; }
x dash echo -
x dashdash echo -- a
x badopt echo -nx a
x combo echo -neE 'a\tb'
x combo2 echo -En 'a\tb'
x after echo a -n
x multi echo -n -e 'a\tb' -E
x stop echo -e 'a\cb' c d
x stop2 echo -e 'x' 'a\c' c
x oct0 echo -e '\0101\01\0\00040\0400|'
x oct1 echo -e '\101\1\7|'
x hex echo -e '\x41\x4\x\xg\x414\x{41}|'
x uni echo -e '\u41\u\U\U41é\U0001F600|'
x esc echo -e '\e\E\a\b\f\v\r\n\t\\\q\"\'"'"'\?|'
x lonebs echo -e 'a\'
x empty echo -e ''
x emptyargs echo '' ''
x nlonly echo -n
x cctl echo -e '\cA|'
shopt -s xpg_echo
x xpg echo 'a\tb' -n
x xpgE echo -E 'a\tb'
x xpgn echo -n 'a\tb'
set -o posix
x posixxpg echo -n 'a\tb' -e
set +o posix
shopt -u xpg_echo
set -o posix
x posixonly echo -n 'a\tb'
set +o posix

# write errors: reported (NAME: line N: prefix stripped), status 1
echo a >/dev/full; echo "st=$?"
echo b 2>&1 >/dev/full | sed 's/^.*line [0-9]*: //'
{ echo c >/dev/full; echo "grp st=$?"; } 2>&1 | sed 's/^.*line [0-9]*: //'
f() { echo d >/dev/full; echo "fn st=$?"; }; f 2>&1 | sed 's/^.*line [0-9]*: //'
echo e | { read -r l; echo "$l" >/dev/full; echo "rd st=$?"; } 2>&1 | sed 's/^.*line [0-9]*: //'
