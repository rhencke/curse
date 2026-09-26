project('curse', 'c',
  version: '0.1.0',
  license: 'GPL-3.0-or-later',
  meson_version: '>= 1.1.0',
  default_options: ['c_std=gnu11', 'warning_level=1'])

# ---------------------------------------------------------------------------
# curse: a bash-compatible shell on a custom-patched LuaJIT. This build
#   1. fetches + pins LuaJIT                    (subprojects/luajit.wrap)
#   2. builds the patched VM via LuaJIT's Makefile   (tools/build-luajit-vm.sh)
#   3. amalgamates the Lua runtime into a bytecode bundle  (lua/build.lua, run
#      on the luajit produced in step 2 -- a staged bootstrap, no external Lua)
#   4. links the dynamic `luajit` and the static, self-contained `curse`
#   5. builds the tiny static C client              (daemon/curse-client.c)
# `meson test` runs the LuaJIT unit tests + the conformance corpora (bash + oil are
# Meson subprojects, fetched at setup); `ninja fetch-real` downloads the real-world
# scripts test/real/diff.sh compares.
# ---------------------------------------------------------------------------

cc     = meson.get_compiler('c')
repo   = meson.project_source_root()
bindir = get_option('bindir')

# 1. LuaJIT source, fetched + pinned by Meson's wrap system.
luajit_sp = subproject('luajit')
lj_src    = luajit_sp.get_variable('lj_src')

# VM compiler knobs (the ones the retired build-luajit.sh carried).
ccopt = '-O2 -fomit-frame-pointer -DCURSE_SIG_DESTRUCTIVE'
if get_option('native')
  ccopt = ccopt + ' -march=native'
endif

vm_builder = find_program('tools' / 'build-luajit-vm.sh')

# 2. Build the patched LuaJIT VM (drives LuaJIT's own Makefile; folds in
#    lib_cursesys/lib_cursesig; optional 3-stage PGO via -Dpgo=true).
vm = custom_target('luajit-vm',
  output:  ['luajit', 'libluajit.a', 'luajit.o'],
  command: [vm_builder,
    '--src',   lj_src,
    '--repo',  repo,
    '--ccopt', ccopt,
    '--out',   '@OUTDIR@',
    '--jobs',  '4',
    get_option('pgo') ? '--pgo' : '--no-pgo'],
  # (curse's own C additions, and the LuaJIT files curse.patch modifies: editing
  # them must rebuild the VM)
  depend_files:     [lj_src / 'src' / 'lib_cursesys.c', lj_src / 'src' / 'lib_cursesig.c',
                     lj_src / 'src' / 'lj_trace.c', lj_src / 'src' / 'lj_asm.c',
                     lj_src / 'src' / 'lj_asm_x86.h', lj_src / 'src' / 'lj_clib.c',
                     lj_src / 'src' / 'lj_jit.h', lj_src / 'src' / 'luajit.c',
                     lj_src / 'src' / 'lj_ffrecord.c'],
  console:          true,
  build_by_default: true,
  install:          true,
  install_dir:      [bindir, false, false])

luajit_bin = vm[0]
libluajit  = vm[1]
luajit_o   = vm[2]

# 3. Amalgamate the Lua runtime into a bytecode bundle (+ a C array for
#    embedding), using the luajit we just built (staged bootstrap).
# The bundle is regenerated whenever any lua/ module changes (build.lua reads them
# all) — without this, editing lua/*.lua would leave a stale bundle.
lua_sources = run_command('sh', '-c', 'ls lua/*.lua', check: true).stdout().strip().split('\n')
bundle = custom_target('bundle',
  output:       ['curse.bc', 'curse_bundle.c'],
  depend_files: lua_sources,
  # lua/build.lua reads lua/*.lua relative to cwd, so run it from the repo root;
  # resolve the build-dir-relative luajit + outputs to absolute paths first.
  command: ['sh', '-c',
    'lj=$(readlink -f "$2"); o1=$(readlink -f "$3"); o2=$(readlink -f "$4"); cd "$1" && exec "$lj" lua/build.lua "$o1" "$o2"',
    'sh', repo, luajit_bin, '@OUTPUT0@', '@OUTPUT1@'],
  console:     true,
  install:     true,
  install_dir: [get_option('datadir') / 'curse', false])

curse_bc       = bundle[0]
curse_bundle_c = bundle[1]

# 4. Link the static, self-contained `curse` (embeds the bundle -> is /bin/sh).
curse = custom_target('curse',
  input:   [luajit_o, curse_bundle_c, libluajit],
  output:  'curse',
  command: ['sh', '-c',
    'cc ' + ccopt + ' -c "$2" -o "$4.bundle.o" && ' +
    'cc ' + ccopt + ' -static "$1" "$4.bundle.o" -Wl,--start-group "$3" -Wl,--end-group -lm -o "$4"',
    'sh', '@INPUT0@', '@INPUT1@', '@INPUT2@', '@OUTPUT@'],
  console:          true,
  build_by_default: true,
  install:          true,
  install_dir:      bindir)

# 5. The tiny static C client a `/bin/sh` symlink points at (talks to `cursed`).
curse_client = executable('curse-client',
  files('daemon' / 'curse-client.c'),
  c_args:    ['-O2'],
  link_args: ['-static', '-s'],
  install:   true)

# --- Tests: run the LuaJIT unit suites on the freshly-built luajit ------------
# test() won't take a custom_target output as the exe, so run through a wrapper
# with the built `luajit` as the first argument.
run_lua  = find_program('tools' / 'run-lua.sh')
test_env = environment()
test_env.set('LUA_PATH', repo / 'lua' / '?.lua' + ';;')

foreach t : ['test_cache', 'test_ext', 'test_forin', 'test_funcs', 'test_nested', 'test_tier']
  test(t, run_lua,
    args:    [luajit_bin, repo / 'lua' / (t + '.lua')],
    workdir: repo,
    env:     test_env,
    depends: vm,
    suite:   'unit',
    timeout: 120)
endforeach

run_target('fetch-real', command: [files('test' / 'real' / 'fetch.sh')])

# --- Conformance harness: bash (oracle) vs dash vs curse interp/compiled/tiered.
#     A separate 'conformance' suite (heavy) — `meson test --suite unit` skips it.
#     is_parallel:false so the corpora don't stack their internal job pools and
#     slam the box.
# External tools the harness runs — declared so `meson setup` verifies them up
# front (no guessing at deps): bash (the oracle) + timeout are required; dash is
# an optional extra comparison column.
find_program('bash', required: true)      # the oracle; the harness runs it from PATH
find_program('timeout', required: true)   # per-run timeout guard
dash_prog = find_program('dash', required: false)

conf = find_program('test' / 'conformance' / 'run.sh')
conf_shells = dash_prog.found() ? 'dash,curse-cold,curse-hot' : 'curse-cold,curse-hot'

# `cases` (curse's own scripts) needs no external corpus — always available.
# curse now runs via its daemon, so the tests need the built luajit + the module
# bundle + the C client; depend on all three so `meson test` builds them itself.
conf_deps = [vm, bundle, curse_client]
test('conformance-cases', conf, args: ['--corpus', 'cases', '--shells', conf_shells],
  suite: 'conformance', depends: conf_deps, workdir: repo, is_parallel: false, timeout: 0)

# bash + oil corpora are Meson subprojects (bash: release tarball + checksum; oil:
# pinned git, whose spec tests ship in no release tarball). Required by default: a
# fetch failure is a HARD ERROR, not a soft skip. -Dconformance=disabled skips the
# fetch for a lean/offline build; =auto makes it best-effort (non-fatal offline).
conf_feat = get_option('conformance')
if not conf_feat.disabled()
  bash_sp = subproject('bash', required: conf_feat)
  oil_sp  = subproject('oil',  required: conf_feat)
  if bash_sp.found()
    test('conformance-bash', conf,
      args: ['--corpus', 'bash', '--bash-dir', bash_sp.get_variable('tests_dir'), '--shells', conf_shells],
      suite: 'conformance', depends: conf_deps, workdir: repo, is_parallel: false, timeout: 0)
  endif
  if oil_sp.found()
    test('conformance-oil', conf,
      args: ['--corpus', 'oil', '--oil-dir', oil_sp.get_variable('spec_dir'), '--shells', conf_shells],
      suite: 'conformance', depends: conf_deps, workdir: repo, is_parallel: false, timeout: 0)
  endif
endif

summary({'dash (extra column)': dash_prog.found(),
         'bash+oil corpora': not conf_feat.disabled()},
        section: 'Conformance', bool_yn: true)
