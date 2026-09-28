#!/bin/bash
# A fuzz campaign inside a hardened container (tools/fuzz/README.md "Docker"):
#   meson compile -C build fuzz-docker          image build + fuzz.sh campaign inside
#   run.sh campaign | triage [SINCE] | exec CMD...   (exec: a command in the same container,
#                                                  e.g. the containment probes)
# Env (the fuzz knobs pass through): FUZZ_SECONDS FUZZ_INSTANCES FUZZ_JOBS FUZZ_TRIAGE_MAX
#   GRAM_COUNT GRAM_TIMEOUT_MS AFL_CUSTOM_MUTATOR_ONLY FUZZ_TLOOP
#   FUZZ_DOCKER_OUT   the ONE writable host directory (default FUZZ_WORK, BUILD/fuzz-work):
#                     fuzz.sh's state (seeds, queues, triage; /fuzz-work inside) + the lock
#   FUZZ_DOCKER_SLACK seconds allowed on top of FUZZ_SECONDS for seeds + triage (3600)
#   FUZZ_DOCKER_MAXKB the output dir's cap, in KB (3 GB); the in-container watchdog ends
#                     the container when it is exceeded
#
# ONE budget for all fuzzing on the host: every instance of a campaign runs in this one
# container (--cpus=2, cpu weight 128, 4 GB RAM, no swap), the container name is fixed
# (curse-fuzz) and a second invocation is refused (flock on the output dir + the name),
# never queued.
set -u
here=$(cd "$(dirname "$0")" && pwd)
NAME=curse-fuzz
IMAGE=curse-fuzz:latest

if [ "${1:-}" = --inside ]; then
  # ---- in the container: fuzz.sh (or the probe command) under the output-dir watchdog.
  shift
  maxkb=${FUZZ_DOCKER_MAXKB:-3145728}
  if [ "${1:-}" = exec ]; then shift; "$@" & else "$here/../fuzz.sh" "$@" & fi
  child=$!
  # (bounded: ends with the child; the host's timeout bounds the child. du every 10 s)
  n=0
  while kill -0 "$child" 2>/dev/null; do
    [ $((n++ % 10)) = 0 ] && kb=$(du -sk /fuzz-work 2>/dev/null | cut -f1)
    if [ "${kb:-0}" -gt "$maxkb" ]; then
      # (exiting ends the container: docker-init is pid 1 and the kernel kills the rest
      # of the pid namespace with it)
      echo "fuzz-docker: WATCHDOG: /fuzz-work is ${kb} KB > ${maxkb} KB: stopping the container" >&2
      exit 3
    fi
    sleep 1
  done
  wait "$child"
  exit
fi

# ---- on the host
: "${FUZZ_ROOT:=$(cd "$here/../../.." && pwd)}"
: "${FUZZ_BIN:=$FUZZ_ROOT/build/tools/fuzz}"
: "${FUZZ_LUAJIT:=$FUZZ_ROOT/build/luajit}"
: "${FUZZ_CURSE:=$FUZZ_ROOT/build/curse}"
: "${FUZZ_ORACLE:=$FUZZ_ROOT/build/test/oracle/bash}"
: "${FUZZ_BASH_SRC:=$FUZZ_ROOT/subprojects/bash-5.2.21}"
: "${FUZZ_OIL_SPEC:=$FUZZ_ROOT/subprojects/oil/spec}"
: "${FUZZ_DOCKER_OUT:=${FUZZ_WORK:-$FUZZ_ROOT/build/fuzz-work}}"
die() { echo "fuzz-docker: $*" >&2; exit 1; }
command -v docker > /dev/null || die "docker not on PATH"
mkdir -p "$FUZZ_DOCKER_OUT" || die "cannot create $FUZZ_DOCKER_OUT"
OUT=$(cd "$FUZZ_DOCKER_OUT" && pwd)
ROOT=$(cd "$FUZZ_ROOT" && pwd)

exec 9> "$OUT/.lock"
flock -n 9 || die "another fuzz-docker run holds $OUT/.lock: refusing to start a second one"
docker container inspect "$NAME" > /dev/null 2>&1 &&
  die "a container named $NAME already exists (another fuzz campaign on this host): refusing to start a second one"

if [ "${FUZZ_DOCKER_BUILD:-1}" = 1 ]; then
  docker build -q -t "$IMAGE" "$here" > /dev/null || die "image build failed"
fi

[ $# -gt 0 ] || set -- campaign
case $1 in
  campaign|triage|seeds|exec) ;;
  *) die "usage: run.sh campaign | triage [SINCE-FILE] | seeds | exec CMD..." ;;
esac
secs=${FUZZ_SECONDS:-${FUZZ_DEFAULT_SECONDS:-1800}}
deadline=$((secs + 300 + ${FUZZ_DOCKER_SLACK:-3600}))
[ "$1" = exec ] && deadline=${FUZZ_DOCKER_SLACK:-600}

# read-only mounts: the repo (sources + the meson build: harness, luajit, curse, the bash
# oracle) and the bash / oil sources when they live outside it (subproject symlinks)
mounts=(-v "$ROOT:$ROOT:ro")
for p in "$FUZZ_BASH_SRC" "$FUZZ_OIL_SPEC" "$FUZZ_BIN" "$FUZZ_LUAJIT" "$FUZZ_CURSE" "$FUZZ_ORACLE"; do
  r=$(readlink -f "$p") || continue
  case $r in "$ROOT"/*) ;; *) [ -e "$r" ] && mounts+=(-v "$r:$r:ro") ;; esac
done
envs=()
for v in FUZZ_SECONDS FUZZ_INSTANCES FUZZ_JOBS FUZZ_TRIAGE_MAX FUZZ_DEFAULT_SECONDS \
         GRAM_COUNT GRAM_TIMEOUT_MS AFL_CUSTOM_MUTATOR_ONLY FUZZ_DOCKER_MAXKB FUZZ_TLOOP; do
  [ -n "${!v+x}" ] && envs+=(-e "$v=${!v}")
done

CID="$OUT/.cid"
rm -f "$CID"
cleanup() { # by ID, only a container this run created (--cidfile): a `docker run` refused
  # because another run's container holds the NAME must never stop that one
  [ -s "$CID" ] || return 0
  local id; id=$(cat "$CID")
  docker container inspect "$id" > /dev/null 2>&1 || { rm -f "$CID"; return 0; }
  echo "fuzz-docker: stopping $NAME ($id)" >&2
  docker kill "$id" > /dev/null 2>&1
  docker rm -f "$id" > /dev/null 2>&1
  rm -f "$CID"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# Limits (each justified in README.md "Docker"):
timeout -k 30 "$deadline" docker run --rm --name "$NAME" --cidfile "$CID" --init \
  --user "$(id -u):$(id -g)" \
  --read-only --tmpfs /tmp:rw,nosuid,nodev,size=256m,mode=1777 \
  --network none \
  --cap-drop ALL --security-opt no-new-privileges \
  --security-opt seccomp="$here/seccomp.json" \
  --cpus 2 --cpu-shares 128 \
  --memory 4g --memory-swap 4g --pids-limit 2048 \
  --ulimit nofile=4096:4096 --ulimit nproc=8192:8192 \
  --ulimit fsize=1073741824:1073741824 --ulimit core=0:0 \
  --stop-timeout 30 \
  "${mounts[@]}" -v "$OUT:/fuzz-work:rw" \
  -e HOME=/tmp -e TMPDIR=/tmp -e FUZZ_NS_PROC=0 -e FUZZ_WORK=/fuzz-work \
  -e FUZZ_ROOT="$ROOT" -e FUZZ_BIN="$FUZZ_BIN" -e FUZZ_LUAJIT="$FUZZ_LUAJIT" \
  -e FUZZ_CURSE="$FUZZ_CURSE" -e FUZZ_ORACLE="$FUZZ_ORACLE" \
  -e FUZZ_BASH_SRC="$FUZZ_BASH_SRC" -e FUZZ_OIL_SPEC="$FUZZ_OIL_SPEC" \
  "${envs[@]}" -w /fuzz-work \
  "$IMAGE" bash "$here/run.sh" --inside "$@"
rc=$?
[ $rc = 124 ] && echo "fuzz-docker: deadline (${deadline}s) reached" >&2
exit $rc
