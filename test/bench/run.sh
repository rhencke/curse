#!/usr/bin/env bash
# Microbenchmarks of common shell patterns: bash, dash (POSIX scripts only), and curse
# through its daemon — cold (a fresh compile cache: the first run) and hot (best of 3).
# Usage: test/bench/run.sh [NAME…]   (default: every test/bench/*.sh)
# Needs curse-client on PATH (build/) and a running or auto-starting daemon.
set -u
here=$(cd "$(dirname "$0")" && pwd)
export BENCH_TMP=$(mktemp -d)
trap 'rm -rf "$BENCH_TMP"' EXIT
# data the read/source benchmarks use
awk 'BEGIN{for(i=0;i<50000;i++) print "user"i":x:"i":"i"::/home/u"i":/bin/sh"}' > "$BENCH_TMP/data.txt"
echo 'v=$((v+1))' > "$BENCH_TMP/inc.sh"
ms() { local s=$EPOCHREALTIME; "$@" >/dev/null 2>&1; local e=$EPOCHREALTIME; echo $(( (${e/./} - ${s/./}) / 1000 )); }
best() { local b=999999 t; for _ in 1 2 3; do t=$(ms "$@"); [ "$t" -lt "$b" ] && b=$t; done; echo "$b"; }
posix() { ! grep -qE '(^|[^$])\(\(|\[\[|declare|local |\$\{[^}]*[:/^,]|<<<|\+=|function |printf -v|mapfile|=~' "$1"; }
printf '%-14s %7s %7s %7s %7s   (ms)\n' bench bash dash cold hot
if [ $# -gt 0 ]; then set -- "${@/#/$here/}"; set -- "${@/%/.sh}"; else set -- "$here"/*.sh; fi
for f in "$@"; do
	n=$(basename "$f" .sh); [ "$n" = run ] && continue
	b=$(best bash "$f"); d=-
	if command -v dash >/dev/null && posix "$f"; then d=$(best dash "$f"); fi
	export XDG_CACHE_HOME=$(mktemp -d)
	c=$(ms curse-client "$f"); h=$(best curse-client "$f")
	rm -rf "$XDG_CACHE_HOME"
	printf '%-14s %7s %7s %7s %7s\n' "$n" "$b" "$d" "$c" "$h"
done
