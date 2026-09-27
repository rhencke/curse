#!/bin/sh
# Build the conformance ORACLE: GNU bash from the vendored release (the bash Meson
# subproject, 5.2.21 — the same tree the bash corpus comes from). curse is bug-for-bug
# compatible with exactly this bash, so the harness runs it, never the host's bash.
#   build-oracle-bash.sh <bash-srcdir> <objdir> <out>
# Out-of-tree (VPATH) build in <objdir>: the source tree is never written to.
# Configured like a plain release build: --prefix=/usr (the paths compiled in — message
# catalogs /usr/share/locale, the debugger's /usr/share/bashdb — are the system's, as a
# distro build's are; bash's BEHAVIOUR is 5.2.21's own: no distro patches, config-top.h
# as released), --without-bash-malloc (glibc malloc, as distro builds use). Not installed.
# -fpermissive: GCC 14 turned several old-C warnings (implicit declarations, incompatible
# pointer types, int conversions) into ERRORS, and 5.2.21 predates that. It breaks the
# build (lib/termcap/tparam.c calls write() undeclared) and, worse, silently flips
# configure's probes: "checking for broken strtold" fails to COMPILE (strtold(foo, &bar)
# with a char *), so STRTOLD_BROKEN gets defined and printf's %f/%e/%g print "nan" for
# every number. -fpermissive gives back GCC 13's behaviour, the one 5.2.21 was released
# against; check_oracle below refuses a build whose float printf is broken.
set -eu
src=$(cd "$1" && pwd); obj=$2; out=$3
mkdir -p "$obj"; obj=$(cd "$obj" && pwd)
if [ ! -f "$obj/Makefile" ]; then
	(cd "$obj" && "$src/configure" --prefix=/usr --without-bash-malloc -q \
		CFLAGS='-g -O2 -fpermissive') >"$obj/configure.out" 2>&1 \
		|| { cat "$obj/configure.out" >&2; exit 1; }
fi
# (-j: bash's Makefile is parallel-safe; MAKEFLAGS from a parent make/ninja is dropped)
MAKEFLAGS= make -C "$obj" -s -j"$(nproc 2>/dev/null || echo 2)" bash >"$obj/make.out" 2>&1 \
	|| { tail -40 "$obj/make.out" >&2; exit 1; }
# check_oracle: a miscompiled oracle would silently redefine "correct"
got=$("$obj/bash" -c 'printf "%.2f %g %s" 3.14159 1e3 "$BASH_VERSION"' </dev/null)
case "$got" in "3.14 1000 5.2."*) ;;
	*) echo "build-oracle-bash: the built bash is broken: printf '%.2f %g' gave '$got'" >&2; exit 1 ;;
esac
cp "$obj/bash" "$out.tmp" && mv -f "$out.tmp" "$out"
