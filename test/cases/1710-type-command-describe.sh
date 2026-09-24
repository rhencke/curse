# builtins/type.def (type_builtin, describe_command) + builtins/command.def:
# option parsing (last of -t/-p/-P wins, long --type/--path/--all, `--`), -a with
# -t/-p over every kind, non-executable and directory PATH hits, relative/empty
# PATH entries, hashed names (-P consults the hash, -a doesn't), disabled
# builtins, posix-mode "special" wording + absolute paths, command -v/-V
# formats (alias requoting, -V's absolute path), command -p leaving $PATH alone,
# and command dropping special-builtin properties.
norm() { local l; while IFS= read -r l; do l=${l//"$PWD"/PWD}; echo "${l#*line [0-9]*: }"; done; }
P0=$PATH
mkdir -p d1/sub d2 d3
for n in foo echo; do printf '#!/bin/sh\necho d1-%s "$@"\n' $n > d1/$n; chmod +x d1/$n; done
printf '#!/bin/sh\necho d2-foo\n' > d2/foo; printf '#!/bin/sh\necho d2-true\n' > d2/true
printf '#!/bin/sh\necho d2-sub\n' > d2/sub; chmod +x d2/foo d2/true d2/sub
printf 'noexec\n' > d3/nx
printf '#!/bin/sh\necho bar\n' > bar; chmod +x bar
PATH=d1:d2:d3

echo "-- last of -t/-p/-P wins; -P keeps forcing the PATH search"
foo() { :; }
type -tp foo; echo st=$?
type -pt foo; echo st=$?
type -Pt foo; echo st=$?
echo "-- -a combined with -t: every kind, files included"
type -at true
type -at foo
shopt -s expand_aliases; alias foo=bar
type -at foo; type -ap foo
unalias foo; unset -f foo
echo "-- long options, and the prescan quirk after --"
type --type true; type -type foo; type --path foo; type -path foo; type --all -p foo
type -- -type 2>&1 | norm
echo "-- non-executable / directory PATH entries"
type nx; echo st=$?
type -a nx 2>&1 | norm; type -t nx; type -P nx
type sub; type -a sub; command -v sub
echo "-- relative and empty PATH elements"
PATH=:d1; type bar; command -v bar; type -a bar
PATH=d1::; type -a bar
PATH=d1:d2:d3
echo "-- hash: recorded with ./, -P uses it, -a skips it"
foo >/dev/null
type foo; type -p foo
hash -p ./d2/foo foo
type -P foo; type -aP foo; type -ap foo
hash -r
echo "-- disabled builtins"
enable -n echo
type -a echo; type -t echo
enable echo
enable -n test; type -a test 2>&1 | norm; echo st=$?; enable test

echo "-- command -v/-V formats"
shopt -s expand_aliases; alias q="it's" ll='ls -l'
command -v q ll; command -V q
unalias q ll
command -V foo | norm
command -Vv foo; command -vV foo | norm
command -v -- foo; command -V -- foo | norm
command -v -p foo; echo st=$?
command -v -x 2>&1 | norm; echo st=$?
command -v zzz foo; echo st=$?
f9() { coproc cat /dev/null; }
command -V f9
echo "-- posix mode: special builtins, absolute relative-PATH results, exec-only"
set -o posix
type export; command -V export; command -V echo; type -a set
type foo | norm; type -p foo | norm; command -v foo | norm
type nx 2>&1 | norm; command -v nx; echo st=$?
echo "-- command strips special-builtin properties (posix)"
z=1 command :; echo "z=${z-unset}"
( command : > nodir/x; echo "survived redir st=$?" ) 2>&1 | norm
( readonly R=1; command export R=2; echo "cmd export st=$?" ) 2>&1 | norm
( command set -o bogus; echo "cmd set st=$?" ) 2>&1 | norm
set +o posix

echo "-- command -p: looks up in the standard path, leaves \$PATH alone"
PATH=d1
command -pv foo; echo st=$?
command -p foo 2>&1 | norm
echo "P=$PATH"
command -p true; echo "P=$PATH"
PATH=$P0
command -p sh -c 'echo "$PATH"' | { read -r p; [ "$p" = "$P0" ] && echo samepath || echo diffpath; }
PATH=d1:d2:d3
echo "-- write errors: type checks, command -v/-V don't"
{ type echo > /dev/full; echo st=$?; } 2>&1 | norm
command -v echo > /dev/full; echo st=$?
command -V echo > /dev/full; echo st=$?
