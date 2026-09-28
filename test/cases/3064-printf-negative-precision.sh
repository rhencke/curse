# printf with a negative literal precision (`%.-1d`): bash skips the `-` and hands the
# spec to printf(3) (`%.-1ld`), and glibc prints an unknown `-` conversion as its own spec
# text (flags, width, `.0`, `-`) — then the rest (`1ld`) as text; the argument is still
# consumed. %b/%q/%Q/%(…)T go through printstr, where that precision is 0. curse
# said "`-': invalid format character" (fuzz F109).
printf '[%.-1d]\n' 5; echo $?
printf '[%--.-1x]\n' 5; printf '[%*.-1y]\n' 3 5; echo $?; printf '[%5.-1A]\n' 5
printf '[%0-5.-1d|%-05.-12i|%+ #05.-1o|% 0.-1u|%.-1X]\n' 1 2 3 4 5
printf "[%'.-1d|%'.-1f]\n" 1 2
printf '[%*.-1d|%*.-1d]\n' -7 5 3 4
printf '[%.-1s|%5.-1s|%.-1c|%.-3e|%.-1g|%-9.-1E]\n' ab cd x 1 2 3
printf '[%.-1b|%5.-1b|%.-1q|%6.-2Q|%.-Q|%.-(%s)T]\n' 'a\tb' xy 'a b' hello x 5
printf '[%.-1d]\n' abc; echo $?
printf '[%.-1f]\n' 1x; echo $?
printf '[%.-1d%s]\n' 1 a 2 b
printf '[%.-hd|%.-1lld|%.-1Lf|%.-d]\n' 1 2 3 4
printf -v v '[%.-1d]' 7; echo "$v"
printf '[%.-1]\n' 7; echo $?
f() { printf "[%.-${1}d]\n" 9; }; f 3
eval "printf '[%.-2s]\n' e"
printf "printf '[%%.-1i]\\\\n' 1\n" > s3064.sh; . ./s3064.sh
trap "printf '[%.-1u]\n' 2" USR1; kill -USR1 $$; trap - USR1
( set -o posix; printf '[%.-1f|%.-1Lf]\n' 1 2 )
i=0; while [ $i -lt 150 ]; do printf '[%.-1d|%3.-2s]\n' $i x; i=$((i + 1)); done | sort | uniq -c
rm -f s3064.sh
