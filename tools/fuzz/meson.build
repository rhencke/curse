# AFL++ fuzzing (tools/fuzz/README.md): `meson compile -C build fuzz`. Never part of
# `meson test`. Needs afl-cc + afl-fuzz on PATH; without them the target explains why.
afl_cc   = find_program('afl-cc', required: false)
afl_fuzz = find_program('afl-fuzz', required: false)
fuzz_sh  = files('fuzz.sh')
if afl_cc.found() and afl_fuzz.found()
  fuzz_harness = custom_target('fuzz-harness',
    input:   [files('build.sh', 'harness.c', 'afl_glue.c', 'sandbox.h', 'sbx.c', 'bashco.h'), curse_bundle_c, libluajit],
    output:  ['harness', 'harness-target', 'harness-plain', 'sbx'],
    command: ['sh', '@INPUT0@', afl_cc, meson.get_compiler('c').cmd_array()[0],
      meson.current_source_dir(), meson.project_build_root() / 'luajit-build' / 'src',
      '@INPUT6@', '@INPUT7@', meson.current_build_dir()],
    build_by_default: false)
  gram_mutator = shared_module('gram_mutator', files('gram_mutator.c'),
    name_prefix: '',
    c_args: ['-O2',
      '-DGRAM_DEFAULT_LUAJIT="' + meson.project_build_root() / 'luajit' + '"',
      '-DGRAM_DEFAULT_ROOT="' + repo + '"'],
    build_by_default: false)
  fuzz_deps = [fuzz_harness, gram_mutator, vm, curse]
  fuzz_env = {
    'FUZZ_ROOT': repo, 'FUZZ_BIN': meson.current_build_dir(),
    'FUZZ_LUAJIT': meson.project_build_root() / 'luajit',
    'FUZZ_CURSE': meson.project_build_root() / 'curse',
    'FUZZ_WORK': meson.project_build_root() / 'fuzz-work',
    'FUZZ_DEFAULT_SECONDS': get_option('fuzz_seconds').to_string(),
    'FUZZ_BASH_SRC': repo / 'subprojects' / 'bash-5.2.21',
    'FUZZ_OIL_SPEC': repo / 'subprojects' / 'oil' / 'spec',
  }
  if bash_found
    fuzz_deps += [oracle_bash]
    fuzz_env += {'FUZZ_ORACLE': oracle_bash.full_path()}
  endif
  run_target('fuzz', command: [fuzz_sh, 'campaign'], depends: fuzz_deps, env: fuzz_env)
  run_target('fuzz-triage', command: [fuzz_sh, 'triage'], depends: fuzz_deps, env: fuzz_env)
else
  message('afl-cc/afl-fuzz not found: the `fuzz` target only explains how to get them (AFL++)')
  run_target('fuzz', command: ['sh', '-c',
    'echo "fuzz: AFL++ (afl-cc, afl-fuzz) was not found when this build dir was configured." >&2; ' +
    'echo "      Install AFL++ (Debian: apt install afl++), then: meson setup --reconfigure build" >&2; exit 1'])
endif
