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
# Everything under packagefiles/luajit (curse.patch + the added C libs): the VM's
# real inputs (see the luajit-vm target).
# (Absolute path strings, not files(): Meson's sandbox refuses files() under
# subprojects/, which packagefiles/ sits in.)
lj_overlay = run_command('sh', '-c',
  'find "$1"/subprojects/packagefiles/luajit -type f ! -name meson.build | LC_ALL=C sort',
  'sh', repo, check: true).stdout().strip().split('\n')

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
  # The VM is built from the pristine pinned commit + the LIVE packagefiles
  # overlay and patch (not Meson's setup-time-prepared copy, which never picks up
  # later edits): every file under packagefiles/luajit, and the builder itself,
  # is a build input -- editing any of them rebuilds the VM and so `curse`.
  depend_files:     lj_overlay + files('tools' / 'build-luajit-vm.sh'),
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

foreach t : ['test_build', 'test_cache', 'test_ext', 'test_forin', 'test_funcs', 'test_nested', 'test_sigjit', 'test_sigload', 'test_sigpreempt', 'test_tier']
  test(t, run_lua,
    args:    [luajit_bin, repo / 'lua' / (t + '.lua')],
    workdir: repo,
    env:     test_env,
    depends: vm,
    suite:   'unit',
    timeout: 120)
endforeach

# The static self-contained `curse` as a shell (argv[0] sh/bash): its ffi.C resolves
# through lib_cursesys.c's symbol table, not dlsym, and the corpora only exercise the
# daemon — so check the table covers every ffi.C symbol and run external commands.
# bash-UB cases (docs/bash-ub.md): curse's documented choice, pinned in every tier —
# the oracle can't score these (bash itself varies there).
test('ub-pins', files('test' / 'ub' / 'run.sh'),
  args:    [luajit_bin, repo],
  workdir: repo,
  depends: [vm],
  suite:   'unit',
  timeout: 60)

# The compile census (tools/delegate-census.lua): every corpus program + synthetic ones past
# Lua's limits, emitted whole and as a fragment in every emit mode — nocompile must be 0
# and every LOADFAIL/refusal a known one (tools/census-known, a ratchet). Four shards.
foreach i : ['1', '2', '3', '4']
  test('census-' + i, run_lua,
    args:    [luajit_bin, repo / 'tools' / 'delegate-census.lua', '--modes', '--shard', i + '/4',
              '--check', repo / 'tools' / 'census-known'],
    workdir: repo,
    env:     test_env,
    depends: vm,
    suite:   'unit',
    timeout: 600)
endforeach

test('static-shell', files('test' / 'static-shell.sh'),
  args:    [luajit_bin, curse, repo],
  workdir: repo,
  depends: [vm, curse],
  suite:   'unit',
  timeout: 120)

# The client/daemon protocol across versions (an old or future peer: fallback, never a
# wrong status) and the std fds a client had closed.
test('daemon-protocol', files('test' / 'daemon-protocol.sh'),
  args:    [luajit_bin, curse_client, curse, repo],
  workdir: repo,
  depends: [vm, curse, curse_client],
  suite:   'unit',
  timeout: 120)

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
# curse's own cases also run in the bare interpreter (no daemon, no OSR): OSR would hide an
# interp-only difference from curse-cold.
cases_shells = conf_shells + ',curse-interp'

# `cases` (curse's own scripts) needs no external corpus, but it does need the oracle (below).
# curse now runs via its daemon, so the tests need the built luajit + the module
# bundle + the C client; depend on all three so `meson test` builds them itself.
conf_deps = [vm, bundle, curse_client]

# bash + oil corpora are Meson subprojects (bash: release tarball + checksum; oil:
# pinned git, whose spec tests ship in no release tarball). Required by default: a
# fetch failure is a HARD ERROR, not a soft skip. -Dconformance=disabled skips the
# fetch for a lean/offline build; =auto makes it best-effort (non-fatal offline).
conf_feat = get_option('conformance')
# The ORACLE every corpus is scored against is bash built from the bash subproject
# (5.2.21), never the host's bash: curse is bug-for-bug compatible with that exact
# release, and the bash corpus is its own test suite. The harness refuses to run
# against anything else (it checks $BASH_VERSION). So the bash subproject is needed
# even for the cases corpus.
bash_found = false
if not conf_feat.disabled()
  bash_sp = subproject('bash', required: conf_feat)
  oil_sp  = subproject('oil',  required: conf_feat)
  bash_found = bash_sp.found()
endif
if bash_found
  bash_src_dir = bash_sp.get_variable('tests_dir') / '..'
  subdir('test' / 'oracle')
  conf_deps += [oracle_bash]
  oracle_args = ['--oracle', oracle_bash.full_path(), '-v']
  # (curse-interp's scripts run $THIS_SH as the static curse: depend on it too)
  test('conformance-cases', conf, args: ['--corpus', 'cases', '--shells', cases_shells] + oracle_args,
    suite: 'conformance', depends: conf_deps + [curse], workdir: repo, is_parallel: false, timeout: 0)
  test('conformance-bash', conf,
    args: ['--corpus', 'bash', '--bash-dir', bash_sp.get_variable('tests_dir'), '--shells', conf_shells] + oracle_args,
    suite: 'conformance', depends: conf_deps, workdir: repo, is_parallel: false, timeout: 0)
  if oil_sp.found()
    test('conformance-oil', conf,
      args: ['--corpus', 'oil', '--oil-dir', oil_sp.get_variable('spec_dir'), '--shells', conf_shells] + oracle_args,
      suite: 'conformance', depends: conf_deps, workdir: repo, is_parallel: false, timeout: 0)
  endif
else
  # No oracle (-Dconformance=disabled, or =auto offline): conformance-cases is still
  # registered, and SKIPS (77) saying why — never silently absent, never a pass.
  test('conformance-cases', find_program('sh'),
    args: ['-c', 'echo "SKIP: conformance-cases needs the bash 5.2.21 oracle, built from the bash subproject (not configured: -Dconformance=' + (conf_feat.disabled() ? 'disabled' : 'auto') + ', or its fetch failed)"; exit 77'],
    suite: 'conformance', is_parallel: false)
endif

# --- Stress suite (test/stress): signals, daemon concurrency, past flakes under load,
#     tier agreement. SEPARATE and opt-in: the default setup excludes it, so a plain
#     `meson test` never runs it; run it with `meson test -C build --suite stress`
#     (or test/stress/run.sh directly, which takes the knobs: -n -j -l -d …).
stress_env = environment()
stress_env.set('STRESS_BUILD', meson.project_build_root())
test('stress', files('test' / 'stress' / 'run.sh'),
  suite: 'stress', depends: conf_deps, workdir: repo, env: stress_env,
  is_parallel: false, timeout: 0)
add_test_setup('default', exclude_suites: ['stress'], is_default: true)

summary({'dash (extra column)': dash_prog.found(),
         'bash+oil corpora': bash_found,
         'cases': bash_found ? 'scored vs the in-tree bash 5.2.21 oracle' : 'skipped (no oracle: needs the bash subproject)'},
        section: 'Conformance', bool_yn: true)
