#!/bin/sh
# Wrapper so Meson `test()` can run a Lua script on the freshly-built `luajit`
# (a custom_target output, which test() won't accept as the exe directly).
#   run-lua.sh <luajit> <script.lua> [args...]
# Each test gets its OWN compile cache ($XDG_CACHE_HOME), removed afterwards. The cache
# is keyed by a hash of the curse sources, so every worktree/suite built from the same
# sources shares one ~/.cache/curse/<stamp> dir: test_cache deletes, plants and asserts
# on artifacts there, and a concurrent suite doing the same made its "cold miss" and
# "runs the file on disk" checks fail at random (and each run left artifacts behind).
T=$(mktemp -d "${TMPDIR:-/tmp}/curse-unit.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
XDG_CACHE_HOME="$T" "$@"
