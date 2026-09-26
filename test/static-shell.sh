#!/bin/sh
# The self-contained STATIC `curse`, run as a shell (argv[0] sh/bash). The conformance
# corpora drive curse through the daemon (the dynamic luajit), so without this nothing
# exercises the static binary — whose ffi.C has no dlsym, only lib_cursesys.c's table.
#   static-shell.sh <luajit> <curse> <repo>
set -u
abs() { (cd "$(dirname "$1")" && printf "%s/%s" "$(pwd)" "$(basename "$1")"); }
LJ=$(abs "$1") CURSE=$(abs "$2") REPO=$3
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
export XDG_CACHE_HOME="$T/cache"   # never the real ~/.cache (shared by every build/suite)
fail=0

# 1. every ffi.C symbol the dynamic luajit resolves must resolve in the static binary
(cd "$REPO" && "$LJ" tools/ffi-syms.lua names lua) > "$T/names" || exit 1
(cd "$REPO" && "$CURSE" tools/ffi-syms.lua check lua "$T/names") || fail=1

# 2. the static binary as a shell: external commands, pipelines, $(…), background jobs
ln -s "$CURSE" "$T/bash"
ln -s "$CURSE" "$T/sh"
check() { # NAME SHELL SCRIPT EXPECTED
	got=$(env -u CURSE_ARGV0 "$T/$2" -c "$3" 2>&1; echo "rc=$?")
	if [ "$got" != "$4" ]; then
		printf 'FAIL %s (%s)\n--- expected\n%s\n--- got\n%s\n' "$1" "$2" "$4" "$got"
		fail=1
	fi
}
for s in bash sh; do
	check external $s 'echo a; /bin/true; echo "b $?"; false; echo "c $?"; echo d' "a
b 0
c 1
d
rc=0"
	check path-search $s 'printf "%s\n" x | tr x y; env true && echo ok' "y
ok
rc=0"
	check pipeline $s 'printf "3\n1\n2\n" | sort | head -n 2 | paste -sd, -' "1,2
rc=0"
	check cmdsubst $s 'x=$(printf ab | tr a-z A-Z); echo "[$x]"; echo "[$(ls /nonexistent-dir 2>/dev/null; echo $?)]"' "[AB]
[2]
rc=0"
	check background $s 'sleep 0.1 & p=$!; cat /dev/null & wait $p; echo "w $?"; wait; echo done' "w 0
done
rc=0"
	check not-found $s 'no-such-cmd-xyz 2>/dev/null; echo "s $?"' "s 127
rc=0"
	check exit-status $s '/bin/sh -c "exit 7"; echo "s $?"; exit 3' "s 7
rc=3"
done
exit $fail
