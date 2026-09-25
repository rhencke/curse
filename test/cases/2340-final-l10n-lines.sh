# Localized diagnostics and bash's line drift after a discarded command.
# Under a message locale with a bash catalog (/usr/share/locale/<lang>/LC_MESSAGES/bash.mo)
# bash prints its own messages translated: the `line N' prologs (error.c's " line ",
# builtin_error's "line %d: " — they differ in French), builtin messages with their
# arguments (a strerror / an _() argument translated too), warnings, usage lines, type's
# descriptions, help texts, job states padded by bytes, and libc's strerror/strsignal
# texts. A discarded command (a failed assignment list, an arithmetic error) leaves
# bash's line counter at the error's line, so every later line is numbered lower by how
# far the command ran past it — for good.
unset LANGUAGE
exec 2>&1
mkdir -p d2340

echo "-- de: builtin and shell errors, prefixes, arguments"
LC_ALL=de_DE.UTF-8
printf '%d\n' 1.5
nosuch_cmd_2340
./nosuch_file_2340
readonly ro=1; ro=2
( : ${u_2340?} )
cd /nonexistent_2340
f() { local; }; f
unset -v 1
echo $((1/0))
(( 1 = 2 ))
let "1=2"
: $((0 ? x=8 : x=9))
: $((1 + ))
echo "$(printf 'a\0b')"
printf '%d\n' 99999999999999999999
printf '%.2f|' 0,5; printf '%.2f\n' 0.5
eval 'a=(1 2'
echo "-- de: stdout texts"
type echo if ls cd f | head -4
type nosuch_2340
getopts
help -s cd
help : | head -2
hash -r; hash
sleep 2 & jobs; kill %1; wait
{ sh -c 'kill -SEGV $$'; } 2>&1 | sed 's/[0-9][0-9]* /PID /'

echo "-- fr: the two prologs differ"
LC_ALL=fr_FR.UTF-8
printf '%d\n' x
nosuch_cmd_2340
./d2340
printf '%d\n' 99999999999999999999
type echo
help -s cd
echo "$(printf 'a\0b')"
LC_ALL=ja_JP.UTF-8
printf '%d\n' x
nosuch_cmd_2340
LC_ALL=C
printf '%d\n' x

echo "-- line drift"
readonly r=1
r=1 a=`echo x
echo y`
echo "L $LINENO"
g() { r=9; }
if true; then
  g
fi
echo "L $LINENO"
h() { echo "h $LINENO ${BASH_LINENO[0]}"; caller; }
for i in 1; do
  : $((i/0))
done
h
x=1 \
  y=$(echo "c $LINENO")
echo "$y $LINENO"
cat <<E; r=2 z=1
e
E
echo "L $LINENO"
BASH_ARGV0=prog
cd /nonexistent_2340
nosuch_cmd_2340
echo "L $LINENO"
