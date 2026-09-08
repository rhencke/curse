#!/usr/bin/env bash
# Dev wrapper: run a command inside the curse-dev image (Node 24 + bash 5.2.37),
# with the repo mounted at /work and matching host uid so files stay yours.
#
#   ./x node ./src/cli/curse.mts run script.sh
#   ./x npm install
#   ./x bash            # interactive shell
#
# IMAGE / interactive flags can be overridden via env.
set -euo pipefail

IMAGE="${CURSE_IMAGE:-curse-dev:latest}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

tty_flags=()
if [ -t 0 ] && [ -t 1 ]; then tty_flags=(-it); fi

exec docker run --rm "${tty_flags[@]}" \
  -u "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  -v "$here":/work \
  -w /work \
  "$IMAGE" "$@"
