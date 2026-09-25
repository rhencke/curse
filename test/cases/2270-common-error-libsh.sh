# builtins/common.c + error.c + lib/sh (strtrans.c, shquote.c, zread.c, fmtulong.c,
# strtoimax.c) audit: numeric-argument forms, signal lists, sh_* diagnostics and
# sh_chkwrite, error prefixes (stdin scripts, sourced-via-PATH), escape decoding,
# shell quoting, read -n on invalid UTF-8, printf/arith number limits.
S=${THIS_SH:-bash}
e() { sed 's/^.*line [0-9]*: //'; }
g() { echo "## $1"; (eval "$1") 2>&1 | e; echo "st=${PIPESTATUS[0]}"; }
n() { sed 's#^[^ ]*bash: #SH: #'; }

# get_exitstat / get_numeric_arg: leading +, blanks, --, overflow, too many args
g 'exit +3'; g 'exit " 4 "'; g 'exit -- 5'; g 'exit 9223372036854775808'; g 'exit 4294967297'
g 'exit 1 2'; g 'exit 0x10'; g 'exit $'"'"'\v7'"'"
g 'f(){ return -- -3; }; f; echo r=$?'; g 'f(){ return --3; }; f'; g 'f(){ return 1 2; }; f'
g 'set -- a b c; shift +1; echo "$@"'; g 'set -- a b c; shift -- 1; echo "$@"'; g 'shift 99999999999999999999'
g 'for i in 1; do break x; done; echo st=$?'; g 'for i in 1; do break 0; done'; g 'for i in 1; do continue " 1"; done; echo ok'

# kill -l / trap -l: exit-status conversion, RT names, invalid specs
g 'kill -l 9 SIGINT int 137 0 64 65'; g 'kill -l 34 35 50 63 RTMIN+3 SIGRTMAX-1'
g 'kill -l | tail -1'; g 'trap -l | wc -l'; g 'kill -lSIGHUP'; g 'kill -- -1x'

# sh_invalidopt on `--X`: bash reports the `-` option char
g 'disown --Z'; g 'shopt --Z'; g 'alias --Z'
# sh_notbuiltin / progcomp_remove with an empty compspec table
g 'enable -d nosuch'; g 'enable -d echo'
$S -c 'complete -r nosuch; echo st=$?' 2>&1 | e
g 'set -m; fg'; g 'set -m; bg'
( sleep 0 & wait %1; echo w=$?; jobs %1; echo st=$? ) 2>&1 | e
g 'mkdir -p hd; set -r; history -w hd/h'

# sh_chkwrite: which builtins report write errors, and with what status
for c in 'alias a=b; alias' shopt 'hash -r; hash ls; hash' enable 'ulimit -n' 'f(){ :; }; declare -f' 'kill -l' 'echo hi' umask; do
  g "$c > /dev/full"
done
g 'bind -l > /dev/full'

# error.c: scripts read from stdin number lines from the start of the input
printf 'echo 1\necho 2\n(\n' | $S 2>&1 | n
printf 'echo $LINENO\n\nnosuch_z\necho $LINENO\nf() {\n  echo $LINENO\n}\nf\n' | $S 2>&1 | n
printf 'echo 1\n\nfi\n' | $S 2>&1 | n
printf 'f(){ echo "${BASH_SOURCE[*]}|${FUNCNAME[*]}"; nosuch; }\nf\necho "[${BASH_SOURCE[*]}]"\ng(){ caller; }; g\n' | $S 2>&1 | n
# ... and a file found through $PATH is named by its PATH-relative path
mkdir -p sub; printf 'nosuch_s\necho "${BASH_SOURCE[0]}"\n' > sub/s2.sh
PATH=sub:$PATH $S -c 'source s2.sh' 2>&1
# setlocale failure is a warning
g 'LC_ALL=xx_YY.bogus; echo after'; g 'LC_MESSAGES=xx_YY; echo after'

# get_working_directory: a removed cwd inside a pipeline stage
( mkdir -p gd; cd gd; rmdir ../gd; pwd -P; echo "st=$?" ) 2>&1 | e | sed "s#$PWD#TOP#"
{ mkdir -p gd; cd gd; rmdir ../gd; pwd -P; echo "st=$?"; cd .; echo "[$PWD]"; } 2>&1 | e | sed "s#$PWD#TOP#"

# strtrans.c: $'…' / echo -e / printf %b edges
p() { printf '%s' "$1" | od -An -c | tr -s ' '; }
p $'a\cAb'; p $'\c?'; p $'\c@x'; p $'\c\\'; p $'\x'; p $'\x41\x4'; p $'\x123'; p $'\0101'
p $'\400'; p $'\8'; p $'\u'; p $'\u41'; p $'\U110000'; p $'\UFFFFFFFF'; p $'\ud800'
p "$(echo -e '\0101\101\01' 'a\cb' c)"; p "$(printf '%b|' '\0101\101' 'x\cy' z)"
# (a '…\' single-quoted word inside $( ): eval'd so a parse failure stays local)
eval 'p "$(echo '"'\\'"')"; p "$(echo '"'a\\'"' b)"' 2>&1 | e
# shquote.c: a lone single quote is \' (sh_single_quote special case)
c="'"; echo "${c@Q}" "${c@A}"; a=("'" "x'"); echo "${a[@]@Q}"
alias q="'"; alias q; set | grep '^c='
complete -W "'" foo; complete -p foo
( set -x; : "'" ) 2>&1
x=$'a\xffb'; printf '%q\n' "$x" '' '~x' 'a=b' '#a' 'a#'; declare -p x
# zread.c/read: -n counts an invalid UTF-8 lead byte as one char
for s in '\xff\xfeab' '\xc0ab' '\xf5abc' '\xe2ab'; do
  printf "$s\n" | LC_ALL=C.UTF-8 $S -c 'read -n 2 x; printf "%s" "$x" | od -An -c'
done
# fmtulong / strtoimax / arith bases
printf '%u %o %x\n' -1 -1 -9223372036854775808; printf '%d\n' 9223372036854775808 2>&1 | e
echo $(( 64#_ )) $(( 36#z )) $(( 9223372036854775807 + 1 )) $(( 1 << 64 )) $(( 18446744073709551616 ))
g 'echo $(( 65#1 ))'; g 'echo $(( 10# ))'; g 'echo $(( 010#9 ))'; g 'echo $(( 08 ))'
printf '[%(x]\n' 2>&1 | e | od -An -c | tr -s ' '
