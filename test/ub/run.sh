#!/bin/sh
# Pins curse's documented choice for each bash-UB case (docs/bash-ub.md): the oracle
# can't be used there (bash itself varies), so each case has a committed expected output,
# checked in every tier. Usage: test/ub/run.sh LUAJIT REPO
lj=$(cd "$(dirname "$1")" && pwd)/$(basename "$1"); repo=$2; fail=0
for t in "$repo"/test/ub/*.sh; do
	case $t in */run.sh) continue ;; esac
	exp=${t%.sh}.expected
	for mode in interp compiled tiered; do
		m=$mode; [ "$m" = tiered ] && m=
		out=$(cd "${TMPDIR:-/tmp}" && CURSE_BUNDLE= LUA_PATH="$repo/lua/?.lua;;" "$lj" "$repo/lua/run.lua" "$t" $m </dev/null 2>&1)
		if [ "$out" != "$(cat "$exp")" ]; then
			echo "ub-pin FAIL: $(basename "$t") [$mode]"; printf '%s\n' "$out" | diff "$exp" - | head -10; fail=1
		fi
	done
done
[ $fail = 0 ] && echo "ub-pins: all ok"
exit $fail
