#!/bin/sh
# Build curse's optimized LuaJIT binaries into .bench-lua/ (which is gitignored —
# this script is the reproducible recipe). Produces two artifacts:
#
#   .bench-lua/luajit  -- O3 + PGO, DYNAMIC. Used by the spec harness, the daemon,
#                         and dev. Loads dist/curse.bc from disk.
#   .bench-lua/curse   -- O3 + PGO, fully STATIC, with the module bundle EMBEDDED
#                         (curse_load_bundle in luajit.c). Self-contained: no
#                         dist/curse.bc, no lua/ dir needed. This is the shippable
#                         one-shot binary. Static VM init beats dash (~0.7ms).
#
# Why each knob:
#   -O3 -march=native   ~16% faster real-script runtime (primes 12.4->10.4ms).
#   PGO                 trains the C paths (bytecode reader, GC, lexer) on real
#                       cold+hot workloads; ~another chunk of that 16%.
#   static              removes ld.so + libm/libgcc_s loads: VM init 0.93->0.70ms.
#   embedded bundle     removes the 0.22ms cold file I/O and makes it standalone.
#
# The static build reads /etc/passwd directly (see runtime.lua) so it needs no
# glibc NSS (getpw*) — no dlopen, no caveat.
#
# Usage: scripts/build-luajit.sh [--no-pgo]
set -eu
cd "$(dirname "$0")/.."
ROOT=$(pwd)
LJDIR="$ROOT/.bench-lua/src/luajit"
LJ="$LJDIR/src"
BOOT="$ROOT/.bench-lua/luajit"           # a working luajit to build the bundle with
CCOPT="-O3 -march=native -fomit-frame-pointer"
JOBS=$(nproc 2>/dev/null || echo 4)
PGO=1; [ "${1:-}" = "--no-pgo" ] && PGO=0

[ -x "$BOOT" ] || { echo "need a bootstrap luajit at $BOOT" >&2; exit 1; }
[ -d "$LJ" ]   || { echo "no luajit source tree at $LJ" >&2; exit 1; }

# 1. The module bundle: bytecode file (for the dynamic binary) + C array (embed).
echo ">> building bundle"
"$BOOT" lua/build.lua dist/curse.bc dist/curse_bundle.c >/dev/null

# Rebuild libluajit.a + luajit.o (via make) then fold in the C shim. The final
# `luajit` link in the Makefile fails (it doesn't know about the shim) — expected;
# we link the binaries ourselves. $1 = extra CFLAGS, $2 = extra LDFLAGS, $3 = "clean"
# to wipe first (omit in the PGO-use pass so training .gcda survive).
build_a() {
  ( cd "$LJDIR"
    [ "${3:-}" = clean ] && make clean >/dev/null 2>&1
    make -B CCOPT="$CCOPT $1" LDFLAGS="$2" -j"$JOBS" >/dev/null 2>&1 || true )
  cc $CCOPT $1 -I"$LJ" -c "$LJ/lib_cursesys.c" -o "$LJ/lib_cursesys.o"
  ar r "$LJ/libluajit.a" "$LJ/lib_cursesys.o"
  [ -f "$LJ/luajit.o" ] || { echo "build_a: luajit.o not produced (make failed)" >&2; exit 1; }
}

if [ "$PGO" = 1 ]; then
  echo ">> PGO stage 1: instrument"
  build_a "-fprofile-generate" "-fprofile-generate" clean
  cc $CCOPT -fprofile-generate "$LJ/luajit.o" \
     -Wl,--start-group "$LJ/libluajit.a" -Wl,--end-group -lm -ldl -o "$ROOT/.bench-lua/luajit-inst"
  echo ">> PGO stage 2: train on cold + hot workloads"
  printf 'echo hello\n' > /tmp/curse-train-eh.sh
  printf 's=0\nfor i in 1 2 3 4 5; do s=$((s+i)); done\necho $s\ncase x in x) :;; esac\n' > /tmp/curse-train-small.sh
  printf 'n=2;c=0\nwhile [ $n -le 2000 ]; do d=2;p=1\nwhile [ $((d*d)) -le $n ]; do [ $((n%%d)) -eq 0 ]&&{ p=0;break;};d=$((d+1));done\n[ $p -eq 1 ]&&c=$((c+1));n=$((n+1));done\necho $c\n' > /tmp/curse-train-primes.sh
  for i in 1 2 3 4 5 6 7 8; do
    for m in interp compiled; do
      "$ROOT/.bench-lua/luajit-inst" lua/run.lua /tmp/curse-train-eh.sh    $m >/dev/null 2>&1 || true
      "$ROOT/.bench-lua/luajit-inst" lua/run.lua /tmp/curse-train-small.sh $m >/dev/null 2>&1 || true
    done
    "$ROOT/.bench-lua/luajit-inst" lua/run.lua /tmp/curse-train-primes.sh compiled >/dev/null 2>&1 || true
  done
  echo ">> PGO stage 3: rebuild with profile (no clean, so .gcda survive)"
  build_a "-fprofile-use -fprofile-correction -Wno-missing-profile" ""
  find "$LJ" -name '*.gcda' -delete 2>/dev/null || true
  rm -f "$ROOT/.bench-lua/luajit-inst"
else
  echo ">> building @ -O3 (no PGO)"
  build_a "" "" clean
fi

# The embedded-bundle object (plain data; -O2 is plenty).
cc -O2 -c dist/curse_bundle.c -o "$LJ/curse_bundle.o"

echo ">> linking .bench-lua/luajit (dynamic) and .bench-lua/curse (static + embedded)"
cc $CCOPT "$LJ/luajit.o" \
   -Wl,--start-group "$LJ/libluajit.a" -Wl,--end-group -lm -ldl -o "$ROOT/.bench-lua/luajit"
cc $CCOPT -static "$LJ/luajit.o" "$LJ/curse_bundle.o" \
   -Wl,--start-group "$LJ/libluajit.a" -Wl,--end-group -lm -o "$ROOT/.bench-lua/curse" 2>/dev/null

echo ">> done:"
"$ROOT/.bench-lua/luajit" -e 'print("  dynamic luajit:", jit.version)'
printf '  static curse : ' ; "$ROOT/.bench-lua/curse" -e 'print(require("tier") and "embedded bundle OK")'
