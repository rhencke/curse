# The conformance oracle: bash built from the vendored bash subproject (see
# tools/build-oracle-bash.sh). Output: <build>/test/oracle/bash — this directory holds
# only `bash`, so the harness can put it first on PATH and a test's own `bash` is the
# oracle too. Not installed.
oracle_bash = custom_target('oracle-bash',
  output:  'bash',
  command: [find_program('..' / '..' / 'tools' / 'build-oracle-bash.sh'),
            bash_src_dir, '@PRIVATE_DIR@', '@OUTPUT@'],
  build_by_default: true,
  console: true)
