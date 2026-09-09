#!/usr/bin/env bash
# Differential real-world test: run each script under bash AND under curse, each
# in its own throwaway, resource-limited Docker container, then compare stdout,
# exit code, and the *whole container filesystem* it produced (via `docker diff`
# for the changed-path set plus a content diff of each changed file). A
# divergence is a candidate curse bug.
#
# Isolation: separate containers, non-root uid, --memory / --cpus / --pids-limit
# caps and a wall-clock timeout. Network is left on (bridge). The script runs with
# cwd and $HOME = /tmp inside the container (a real dir, so its writes land in the
# container fs and show up in the export/diff — unlike a bind mount).
#
#   test/real/diff.sh [script ...]      # defaults to test/real/scripts/*.sh
set -u

IMAGE="${CURSE_IMAGE:-curse-dev:latest}"
MEM="${MEM:-512m}"; CPUS="${CPUS:-1}"; TIMEOUT="${TIMEOUT:-60}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mkdir -p "$here/.ccache"

# Paths whose changes are noise, not script behavior: engine plumbing (node/npm
# caches), and inherently-nondeterministic content (a .git repo's internals).
NOISE='/tmp/\.(npm|node|v8|cache)|/tmp/curse-|\.ccache|/\.git/|/\.git$'
# Collapse per-run randomness so it doesn't masquerade as a divergence: mktemp
# suffixes, long digit runs (pids, epochs), and the sandbox path itself.
canon() { sed -E -e 's#(/tmp/[A-Za-z0-9._-]*[Tt]mp\.?)[A-Za-z0-9]{6,}#\1X#g' \
                 -e 's#\.tmp\.[A-Za-z0-9]{6,}#.tmp.X#g' \
                 -e 's#[0-9]{4,}#N#g'; }

run_one() {  # $1=cname $2=out-prefix $3..=argv
  local cname="$1" pfx="$2"; shift 2
  docker run --name "$cname" \
    --memory="$MEM" --memory-swap="$MEM" --cpus="$CPUS" --pids-limit=512 \
    -u "$(id -u):$(id -g)" -e HOME=/tmp -e NODE_COMPILE_CACHE=/ccache \
    -e CURSE_CACHE=/ccache/curse-tc \
    -v "$here":/work:ro -v "$here/.ccache":/ccache \
    -v "$SCRIPT_HOST":/script.sh:ro -w /tmp \
    "$IMAGE" timeout "$TIMEOUT" "$@" >"$pfx.out" 2>"$pfx.err"
  echo $? >"$pfx.code"
}

# `docker diff` change set, minus noise, randomness canonicalized, sorted.
fsdiff() { docker diff "$1" 2>/dev/null | grep -vE "$NOISE" | canon | sort -u; }
norm() { canon < "$1"; }

fails=0; total=0
scripts=("$@")
[ ${#scripts[@]} -eq 0 ] && scripts=("$here"/test/real/scripts/*.sh)

for SCRIPT_HOST in "${scripts[@]}"; do
  [ -f "$SCRIPT_HOST" ] || continue
  SCRIPT_HOST="$(cd "$(dirname "$SCRIPT_HOST")" && pwd)/$(basename "$SCRIPT_HOST")"
  total=$((total + 1))
  name="$(basename "$SCRIPT_HOST")"
  OUT="$(mktemp -d)"
  bc="curse-diff-bash-$$-$total"; cc="curse-diff-curse-$$-$total"
  docker rm -f "$bc" "$cc" >/dev/null 2>&1

  run_one "$bc" "$OUT/bash"  bash /script.sh
  run_one "$cc" "$OUT/curse" node /work/src/cli/curse.mts run /script.sh

  bcode=$(cat "$OUT/bash.code"); ccode=$(cat "$OUT/curse.code")
  odiff=$(diff <(norm "$OUT/bash.out") <(norm "$OUT/curse.out"))
  fsdiff "$bc" >"$OUT/bash.fs"; fsdiff "$cc" >"$OUT/curse.fs"
  fsset=$(diff "$OUT/bash.fs" "$OUT/curse.fs")

  docker rm -f "$bc" "$cc" >/dev/null 2>&1

  if [ "$bcode" = "$ccode" ] && [ -z "$odiff" ] && [ -z "$fsset" ]; then
    printf 'PASS  %-26s exit=%s  fs-changes=%s\n' "$name" "$bcode" "$(grep -c . "$OUT/bash.fs")"
    rm -rf "$OUT"
  else
    fails=$((fails + 1))
    printf 'DIFF  %-26s bash_exit=%s curse_exit=%s\n' "$name" "$bcode" "$ccode"
    [ -n "$odiff" ]  && { echo "  --- stdout diff (< bash, > curse) ---"; echo "$odiff" | head -25 | sed 's/^/  /'; }
    [ -n "$fsset" ]  && { echo "  --- fs change-set diff (< bash, > curse) ---"; echo "$fsset" | head -20 | sed 's/^/  /'; }
    [ "$bcode" != "$ccode" ] && { echo "  --- curse stderr (tail) ---"; tail -5 "$OUT/curse.err" | sed 's/^/  /'; }
    echo "  (artifacts: $OUT)"
  fi
done

echo
echo "real-world diff: $((total - fails))/$total scripts matched bash (stdout + exit + container fs)"
[ "$fails" -eq 0 ]
