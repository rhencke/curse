#!/bin/sh
# The client/daemon protocol across versions, and the std fds a client had closed.
# A client and a daemon of different protocol versions must never give a wrong status:
# the version is in the socket's name (curse-v2.sock) and in the request header; a
# daemon that doesn't speak the header closes before its first frame, and the client
# then runs the script itself (curse). Old (v1) framing is still served correctly.
#   daemon-protocol.sh <luajit> <curse-client> <curse> <repo>
set -u
abs() { (cd "$(dirname "$1")" && printf "%s/%s" "$(pwd)" "$(basename "$1")"); }
LJ=$(abs "$1") CL=$(abs "$2") CURSE=$(abs "$3") REPO=$(abs "$4")
T=$(mktemp -d) || exit 1
D=
cleanup() {
	[ -n "$D" ] && kill -9 $D $(cat /proc/$D/task/$D/children 2>/dev/null) 2>/dev/null
	rm -rf "$T"
}
trap cleanup EXIT
mkdir -p "$T/xdg" "$T/old" "$T/none" "$T/bin"
chmod 700 "$T/xdg" "$T/old" "$T/none"
export XDG_CACHE_HOME="$T/cache" # (never the real ~/.cache)
ln -s "$CL" "$T/bin/sh"   # the client as deployed: argv[0] sh puts the fallback in shell mode
ln -s "$CURSE" "$T/bin/curse" # the fallback: curse itself
PEER="$REPO/test/daemon-proto-peer.lua"
fail=0
check() { # NAME GOT EXPECTED
	if [ "$2" != "$3" ]; then
		printf 'FAIL %s\n--- expected\n%s\n--- got\n%s\n' "$1" "$3" "$2"
		fail=1
	fi
}
# (where the script ran: the daemon's luajit, or the fallback curse)
WHERE='case $(readlink /proc/$$/exe) in *luajit*) echo daemon;; *curse*) echo fallback;; *) echo other;; esac; exit 7'
run() { # XDG -> where + status
	env XDG_RUNTIME_DIR="$1" PATH="$T/bin:$PATH" "$T/bin/sh" -c "$WHERE"
	echo "rc=$?"
}

env XDG_RUNTIME_DIR="$T/xdg" CURSE_BUNDLE= LUA_PATH="$REPO/lua/?.lua;;" CURSE_WORKERS=2 \
	"$LJ" "$REPO/lua/daemon.lua" >"$T/log" 2>&1 &
D=$!
n=0
until [ -S "$T/xdg/curse-v2.sock" ]; do
	n=$((n + 1))
	[ $n -gt 1000 ] && { echo "daemon did not start"; cat "$T/log"; exit 1; }
	sleep 0.01
done

# this version's client, at this version's daemon: served there
check current "$(run "$T/xdg")" "daemon
rc=7"
# the framings a client of another version sends: v1 is still served; an unknown one is
# refused before the first frame (so that client falls back, never reading a status)
check v1-framing "$(XDG_RUNTIME_DIR= "$LJ" "$PEER" client "$T/xdg/curse-v2.sock" v1)" "served 7"
check v2-framing "$("$LJ" "$PEER" client "$T/xdg/curse-v2.sock" v2)" "served 7"
check v3-framing "$("$LJ" "$PEER" client "$T/xdg/curse-v2.sock" v9)" "refused"
# an old (v1-only) daemon reached at this client's socket name: it drops the request, and
# the client runs the script itself — the right status, never 127
"$LJ" "$PEER" olddaemon "$T/old/curse-v2.sock" >"$T/old.out" &
O=$!
until [ -s "$T/old.out" ]; do sleep 0.01; done
check old-daemon "$(run "$T/old")" "fallback
rc=7"
wait $O
# no daemon at all: the same
check no-daemon "$(run "$T/none")" "fallback
rc=7"

# fds 0-2 closed at the client are closed for the script (not the client's socket)
printf 'read -r x; echo "read $? [${x-unset}]"\n' >"$T/rd.sh"
check closed-stdin "$(env XDG_RUNTIME_DIR="$T/xdg" "$T/bin/sh" "$T/rd.sh" 2>&1 <&- | sed 's/^.*line 1: //')" \
	"read: read error: 0: Bad file descriptor
read 1 [unset]"
check closed-stdout "$( (env XDG_RUNTIME_DIR="$T/xdg" "$T/bin/sh" -c 'echo hi; echo "st=$?" >&2' >&-) 2>&1 | sed 's/^.*line 1: //')" \
	"echo: write error: Bad file descriptor
st=1"
check closed-stderr "$(env XDG_RUNTIME_DIR="$T/xdg" "$T/bin/sh" -c 'echo err >&2; echo "st=$?"' 2>&-)" "st=1"

[ $fail = 0 ] && echo "daemon-protocol: ok"
exit $fail
