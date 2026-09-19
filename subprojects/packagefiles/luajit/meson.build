# Overlay so the pinned LuaJIT checkout is a valid (source-only) Meson
# subproject. curse does NOT rebuild LuaJIT in Meson — it drives LuaJIT's own
# Makefile (see the top-level meson.build + tools/build-luajit-vm.sh). This just
# exposes the fetched source directory to the parent project.
project('luajit', 'c', version: '2.1', license: 'MIT')
lj_src = meson.current_source_dir()
