#!/bin/sh
# Build the patched LuaJIT VM for curse. This is the ONE encapsulated
# "build the dependency" step the Meson build drives; everything else (fetching
# + pinning LuaJIT, generating the module bundle, linking the static `curse`,
# the C client, tests, install) is Meson's job. It replaces the old sprawling
# scripts/build-luajit.sh.
#
# Meson has already prepared the source (subprojects/luajit): curse.patch applied
# and lib_cursesys.c / lib_cursesig.c overlaid into src/ (see subprojects/
# luajit.wrap + packagefiles/). This script just:
#   1. copy that prepared source into a private build tree
#   2. build libluajit.a via LuaJIT's Makefile, fold in the curse C libs (`ar`)
#   3. (optional) 3-stage PGO: instrument -> train on cold+hot workloads -> rebuild
#   4. link the dynamic `luajit`
#
# Outputs written into --out: luajit (dynamic binary), libluajit.a, luajit.o
#   -DCURSE_SIG_DESTRUCTIVE (in --ccopt): preempt a running JIT loop by
#   destructively overwriting its back-edge on a signal (see lib_cursesig.c).
set -eu

SRC= REPO= CCOPT= OUT= PGO=0 JOBS=4
while [ $# -gt 0 ]; do
  case "$1" in
    --src)    SRC=$2;    shift 2 ;;
    --repo)   REPO=$2;   shift 2 ;;
    --ccopt)  CCOPT=$2;  shift 2 ;;
    --out)    OUT=$2;    shift 2 ;;
    --jobs)   JOBS=$2;   shift 2 ;;
    --pgo)    PGO=1;     shift ;;
    --no-pgo) PGO=0;     shift ;;
    *) echo "build-luajit-vm: unknown arg: $1" >&2; exit 2 ;;
  esac
done
: "${SRC:?} ${REPO:?} ${OUT:?}"
CC=${CC:-cc}
# Meson gives @OUTDIR@ relative to the build dir; make it absolute so the steps
# that `cd` elsewhere (PGO training) still find the output binaries.
OUT=$(CDPATH= cd -- "$OUT" && pwd)

WORK="$OUT/luajit-build"   # private patched build tree (a copy of the pinned src)
LJ="$WORK/src"

# 1. Fresh copy of the Meson-prepared source (already patched, curse C libs in
#    src/) into a private, writable build tree (LuaJIT builds in-tree). Drop .git
#    and the files the packagefiles/luajit overlay dropped in (the subproject
#    meson.build and curse.patch itself); they play no part in the Makefile build.
rm -rf "$WORK"; mkdir -p "$WORK"
( cd "$SRC" && tar cf - --exclude=.git --exclude=meson.build --exclude=curse.patch . ) | ( cd "$WORK" && tar xf - )

# 3. Build libluajit.a via LuaJIT's Makefile, then fold in the curse C libs.
# LuaJIT's own final `luajit` link fails (it can't see the curse shim) — expected,
# we link it ourselves after `ar`-ing the shim into libluajit.a. $1=extra CFLAGS,
# $2=extra LDFLAGS, $3="clean" to wipe first (omit in the PGO-use pass so .gcda live).
build_a() {
  ( cd "$WORK"
    [ "${3:-}" = clean ] && make clean >/dev/null 2>&1
    make -B CCOPT="$CCOPT $1" LDFLAGS="$2" -j"$JOBS" >/dev/null 2>&1 || true )
  $CC $CCOPT $1 -I"$LJ" -c "$LJ/lib_cursesys.c" -o "$LJ/lib_cursesys.o"
  $CC $CCOPT $1 -I"$LJ" -c "$LJ/lib_cursesig.c" -o "$LJ/lib_cursesig.o"
  ar r "$LJ/libluajit.a" "$LJ/lib_cursesys.o" "$LJ/lib_cursesig.o"
  [ -f "$LJ/luajit.o" ] || { echo "build-luajit-vm: make failed (no luajit.o)" >&2; exit 1; }
}

if [ "$PGO" = 1 ]; then
  echo ">> PGO 1/3: instrument"
  build_a "-fprofile-generate" "-fprofile-generate" clean
  $CC $CCOPT -fprofile-generate "$LJ/luajit.o" \
     -Wl,--start-group "$LJ/libluajit.a" -Wl,--end-group -lm -ldl -o "$OUT/luajit-inst"
  echo ">> PGO 2/3: train (cold + hot workloads)"
  T=$(mktemp -d)
  printf 'echo hello\n' > "$T/eh.sh"
  printf 's=0\nfor i in 1 2 3 4 5; do s=$((s+i)); done\necho $s\ncase x in x) :;; esac\n' > "$T/small.sh"
  printf 'n=2;c=0\nwhile [ $n -le 2000 ]; do d=2;p=1\nwhile [ $((d*d)) -le $n ]; do [ $((n%%d)) -eq 0 ]&&{ p=0;break;};d=$((d+1));done\n[ $p -eq 1 ]&&c=$((c+1));n=$((n+1));done\necho $c\n' > "$T/primes.sh"
  i=0; while [ "$i" -lt 8 ]; do
    for m in interp compiled; do
      ( cd "$REPO" && "$OUT/luajit-inst" lua/run.lua "$T/eh.sh"    "$m" >/dev/null 2>&1 || true )
      ( cd "$REPO" && "$OUT/luajit-inst" lua/run.lua "$T/small.sh" "$m" >/dev/null 2>&1 || true )
    done
    ( cd "$REPO" && "$OUT/luajit-inst" lua/run.lua "$T/primes.sh" compiled >/dev/null 2>&1 || true )
    i=$((i + 1))
  done
  echo ">> PGO 3/3: rebuild with profile"
  build_a "-fprofile-use -fprofile-correction -Wno-missing-profile" ""
  find "$LJ" -name '*.gcda' -delete 2>/dev/null || true
  rm -f "$OUT/luajit-inst"; rm -rf "$T"
else
  build_a "" "" clean
fi

# 5. Link the dynamic `luajit` (loads dist/curse.bc from disk at runtime).
$CC $CCOPT "$LJ/luajit.o" \
   -Wl,--start-group "$LJ/libluajit.a" -Wl,--end-group -lm -ldl -o "$OUT/luajit"

# Expose the pieces Meson links the static, bundle-embedded `curse` from.
cp "$LJ/libluajit.a" "$OUT/libluajit.a"
cp "$LJ/luajit.o"    "$OUT/luajit.o"
echo ">> luajit VM built: $("$OUT/luajit" -e 'io.write(jit.version)')"
