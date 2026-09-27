#!/bin/sh
# Build the AFL++ harnesses (called by the `fuzz-harness` target in tools/fuzz/meson.build).
#   build.sh AFL_CC CC SRCDIR LUAJIT_INCDIR BUNDLE_C LIBLUAJIT_A OUTDIR
# -> OUTDIR/harness (afl-cc: forkserver + Lua-level edge coverage), OUTDIR/harness-plain
#    (plain cc: the same runner without AFL, for triage), OUTDIR/sbx (the triage sandbox).
set -eu
AFLCC=$1 CC=$2 S=$3 INC=$4 BUNDLE=$5 LIB=$6 O=$7
mkdir -p "$O"
$CC -O2 -c "$BUNDLE" -o "$O/bundle.o"
$CC -O2 -c "$S/afl_glue.c" -o "$O/afl_glue.o"
# (lua_sethook and kill are wrapped: see harness.c)
link() { # compiler output
  "$1" -O2 -static "$O/$2.o" "$O/afl_glue.o" "$O/bundle.o" -Wl,--wrap=lua_sethook,--wrap=kill \
    -Wl,--start-group "$LIB" -Wl,--end-group -lm -lpthread -o "$O/$2" 2>&1 |
    grep -v 'in statically linked applications requires at runtime' || true
  test -x "$O/$2"
}
AFL_QUIET=1 "$AFLCC" -O2 -I"$INC" -c "$S/harness.c" -o "$O/harness.o"
AFL_QUIET=1 link "$AFLCC" harness
$CC -O2 -I"$INC" -c "$S/harness.c" -o "$O/harness-plain.o"
link "$CC" harness-plain
$CC -O2 -static "$S/sbx.c" -o "$O/sbx"
