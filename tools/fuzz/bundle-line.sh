#!/bin/sh
# Map curse.bundle:N (the core modules, concatenated by lua/build.lua) to module:line.
# usage: bundle-line.sh N...   (reads lua/build.lua's `mods` order)
R=$(cd "$(dirname "$0")/../.." && pwd)
mods=$(sed -n 's/^local mods = {\(.*\)}/\1/p' "$R/lua/build.lua" | tr -d '" ')
for n in "$@"; do
  echo "$mods" | awk -v n="$n" -v R="$R" 'BEGIN{FS=","} {
    off=1
    for (i=1;i<=NF;i++) { f=R"/lua/"$i".lua"; c=0; while ((getline l < f) > 0) c++; close(f)
      if (n > off+1 && n <= off+1+c) { printf "%s:%d\n", $i, n-off-1; exit }
      off += c + 3 }
    print "?" }'
done
