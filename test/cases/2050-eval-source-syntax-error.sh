# Syntax errors in eval'd and sourced text (run repeatedly: the tier compiles recurring
# eval/source text). The valid prefix runs, the error line runs nothing, status 2; in
# posix mode it ends the shell only when no command ran in that text before the error
# (bash's evalstring.c: this_shell_builtin is still the eval/source) and not under `command`.
exec 2>&1
d=${TMPDIR:-/tmp}/curse-2050.$$
mkdir -p "$d"
printf 'echo s1\nif then\necho s2\n' > "$d/bad.inc"
printf 'fi\n' > "$d/bad0.inc"
for i in 1 2 3; do
	eval 'echo a$i; echo b )'; echo "st=$?"
	eval 'echo c$i
if then
echo d'; echo "st=$?"
	. "$d/bad.inc"; echo "src=$?"
	eval 'x=(1 [2]=y); echo e ${x[@]}'; echo "st=$?"
done 2>&1 | sed 's/^.*line [0-9]*: //'
f() { eval 'echo in f; fi'; echo "f st=$?"; }
{ f; f; f; } 2>&1 | sed 's/^.*line [0-9]*: //'
( set -o posix; for i in 1 2 3; do echo i$i; if [ $i = 3 ]; then eval "fi"; fi; eval "echo ok$i"; done; echo no ) 2>&1 | sed 's/^.*line [0-9]*: //'
( set -o posix; for i in 1 2 3; do . "$d/bad.inc"; echo cont $?; done ) 2>&1 | sed 's/^.*line [0-9]*: //'
( set -o posix; for i in 1 2 3; do x=1; . "$d/bad0.inc"; echo cont $?; done; echo no ) 2>&1 | sed 's/^.*line [0-9]*: //'
( set -o posix; for i in 1 2 3; do eval "x=1; echo e; fi"; echo cont $?; done; eval "y=2; fi"; echo no ) 2>&1 | sed 's/^.*line [0-9]*: //'
( set -o posix; for i in 1 2 3; do command eval "fi"; echo c $?; done ) 2>&1 | sed 's/^.*line [0-9]*: //'
rm -rf "$d"
