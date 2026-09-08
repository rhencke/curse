#!/usr/bin/env bash
# Fetch the Oils (Oil shell) spec tests for conformance tracking.
#
# The spec tests are Apache-2.0 (compatible with this project's GPLv3+; see
# NOTICE.md). They live only in the git repo; GitHub's web UI is blocked in some
# environments but codeload is not. Files land in reference/oil/ (gitignored).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
dest="$root/reference/oil"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Downloading Oils spec tests (codeload)…"
curl -sSL "https://codeload.github.com/oilshell/oil/tar.gz/refs/heads/master" -o "$tmp/oil.tar.gz"
top="$(tar tzf "$tmp/oil.tar.gz" | head -1 | cut -d/ -f1)"
tar xzf "$tmp/oil.tar.gz" -C "$tmp" "$top/spec" "$top/LICENSE.txt"

rm -rf "$dest"
mkdir -p "$dest"
mv "$tmp/$top/spec" "$dest/spec"
mv "$tmp/$top/LICENSE.txt" "$dest/LICENSE.txt"

echo "Fetched $(ls "$dest/spec"/*.test.sh | wc -l) spec files into $dest/spec"
