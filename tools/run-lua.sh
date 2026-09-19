#!/bin/sh
# Wrapper so Meson `test()` can run a Lua script on the freshly-built `luajit`
# (a custom_target output, which test() won't accept as the exe directly).
#   run-lua.sh <luajit> <script.lua> [args...]
exec "$@"
