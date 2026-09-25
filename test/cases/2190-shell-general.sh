# shell.c + general.c audit: shell invocation (option parsing, -c/$0, startup
# files, script-file handling, reading from stdin) and general.c helpers
# (legal_number, identifiers, importable function names, tilde prefixes,
# PROMPT_DIRTRIM trimming for \w). The shell under test runs as a child via $THIS_SH;
# its path is normalized to SH in diagnostics.
S=${THIS_SH:-bash}
n() { sed "s#$S#SH#g"; }
t() { echo "--- $*"; "$S" "$@" 2>&1 | n; echo "st=${PIPESTATUS[0]}"; }
h() { echo "--- $*"; "$S" "$@" 2>&1 | sed -n 1p | n; echo "st=${PIPESTATUS[0]}"; }

# -c: $0/$1.. binding, a missing command string, options after -c, `--` after -c
t -c 'echo "0=$0 #=$# @=$*"' zero one two
t -c
t -c -e 'false; echo notreached'
t -c -- 'echo $0 $1' a b
t -c 'echo "$BASH_EXECUTION_STRING|${BASH_ARGV[*]}"' a b
t -s -c 'echo $-'
echo 'echo "$0|$1|$#|$-"; nosuch_s' | "$S" -s x y 2>&1 | n
echo 'echo "$0|$#"' | "$S" 2>&1 | n
# `-` and `--` end the options: the next word is the script
t - -c
echo 'echo stdin' | "$S" -s -- -q 2>&1 | n

# invalid options: message + usage, status 2; long options must come first
t -z
h --nosuchopt
h -e --posix -c 'echo x'
h -l --posix -c 'echo x'
t --init-file
t -o nosuchopt -c 'echo x'
t -O nosuchshopt -c 'echo x'
t -o -c 'echo x'
# single-dash long options, and long options that are not ignored
t -norc -c 'echo singledash-long'
t -posix -c 'shopt -o posix'
t --verbose -c 'echo v'
t --debug -c 'echo d'
t --restricted -c 'shopt restricted_shell; PATH=x'
t -r -c 'shopt restricted_shell'
t --login --noprofile -c 'shopt login_shell'
t -a -c 'x=1; env | grep ^x='
t -n -c 'echo a; if'
printf 'echo pre\nif\n' > syn2.sh; t -n syn2.sh
t -D -c 'echo $"hello"'
printf 'f() { echo a;echo b; }\nif true;then echo x;fi\n' > pp.sh; t --pretty-print pp.sh
t -o | sed -n 1,4p
"$S" -O </dev/null | sed -n 1,2p
"$S" +o </dev/null | sed -n 1,2p
h --version

# startup files: login shells, BASH_ENV (non-interactive), ENV (posix -i), --rcfile
echo 'echo in-bash_profile' > .bash_profile
echo 'echo in-bash_login' > .bash_login
echo 'echo in-profile' > .profile
echo 'echo in-bashrc' > .bashrc
t -l -c 'echo main1'
rm .bash_profile; t -l -c 'echo main2'
rm .bash_login; t -l -c 'echo main3'
t --posix -l -c 'echo main-posix'
"$S" -i -c 'echo withrc' 2>/dev/null
"$S" --norc -i -c 'echo "norc $PS1"' 2>/dev/null
echo 'echo in-rc2 $0 $#' > rc2
"$S" --rcfile rc2 -i -c 'echo main $0 $#' nm a b 2>/dev/null
ENV=./.profile "$S" --posix -i -c 'echo posix-env' 2>/dev/null
PS1=x PS2=y "$S" -c 'echo ${PS1-unset1} ${PS2-unset2}'
printf 'echo "BASH_ENV 0=$0 #=$#"\n' > benv.sh
BASH_ENV=./benv.sh "$S" -c 'echo main' 2>&1 | n
printf 'echo "$0|$1|$#"; nosuch_s\n' > s3.sh
BASH_ENV=./benv.sh "$S" s3.sh a b 2>&1 | n
BASH_ENV='$HOME/benv.sh' "$S" --posix -c 'echo posix-no-benv'
printf 'set -- q r\n' > sp.sh; BASH_ENV=./sp.sh "$S" -c 'echo "$0|$*"' z a b
printf 'false; echo benv-cont\n' > fe.sh; BASH_ENV=./fe.sh "$S" -e -c 'echo main $-'
printf 'exit 5\n' > ex.sh; BASH_ENV=./ex.sh "$S" -c 'echo notrun'; echo "st=$?"

# script files: PATH search, directory, binary files ($0 is the script name)
mkdir -p pdir dir; printf 'echo "inpath 0=$0"\n' > pdir/pscript.sh
PATH=$PWD/pdir:$PATH t pscript.sh
t dir
printf 'echo hi\0there\n' > bin1.sh; t bin1.sh
printf '\177ELF\n' > elf.sh; t elf.sh
printf '#!/bin/sh\necho line2\0\n' > bin2.sh; t bin2.sh
printf '#!/bin/sh\necho line2\necho l3\0\n' > bin3.sh; t bin3.sh
"$S" s3.sh 2>&1; echo "st=$?"
"$S" < s3.sh 2>&1 | n

# general.c: legal_number (whitespace, sign, overflow), identifiers, import names
for i in 1 2; do break 99999999999999999999; done 2>&1 | sed 's/^.*line [0-9]*: //'
f() { return "$1"; }; false; f --; echo "return-- st=$?"
declare 1a=3 2>/dev/null | cat; echo "badassign-pipe=${PIPESTATUS[0]}"
f-g() { echo dash; }; export -f f-g
"$S" --posix -c 'type -t f-g' 2>&1 | n
env 'BASH_FUNC_ab%%=() { echo x; }; echo INJECT' "$S" -c 'type -t ab' 2>&1 | n

# tilde prefixes: only assignment-shaped words, quoting, posix mode
H=$HOME; hn() { sed "s#$H#HOME#g"; }
echo a=~/x b:~/x --opt=~/x ~"/x" ~\/x y=~/q=~/r | hn
set -o posix; echo a=~/x | hn; set +o posix
v=; echo "${v:-~/d}" ${v:-~/d} | hn
HOME=''; echo "[~]" ~/a; HOME=$H
# PROMPT_DIRTRIM trims \w (keeping the ~ prefix; no trim for <=3 chars)
PS1='\w'; mkdir -p aaaa/bbbb/cccc/dddd/eeee a/b/c/d
cd aaaa/bbbb/cccc/dddd/eeee
for d in 1 2 4 5 0 -1 x ' 2'; do PROMPT_DIRTRIM=$d; echo "$d=${PS1@P}"; done
cd "$H/a/b/c/d"; PROMPT_DIRTRIM=1; echo "${PS1@P}"; PROMPT_DIRTRIM=2; echo "${PS1@P}"
