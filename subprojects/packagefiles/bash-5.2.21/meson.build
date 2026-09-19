# Source-only overlay: curse doesn't build bash, it runs bash's own test suite.
# Exposes the tests/ dir to the parent (see the conformance tests in ../../meson.build).
project('bash-tests', 'c', version: '5.2.21')
tests_dir = meson.current_source_dir() / 'tests'
