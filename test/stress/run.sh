#!/usr/bin/env bash
# Stress suite for curse. See test/stress/README.md for what each test guards.
#
# Every test runs curse in several shells: interp, compiled, tiered (run.lua directly),
# dcold and dwarm (the C client against a PRIVATE daemon; dcold uses a fresh empty
# compile cache, dwarm reuses it). Deterministic tests are compared with bash 5.2.21
# (the oracle) and with each other. Nondeterministic scenarios are written as scripts
# that check their own properties and print a deterministic verdict, so they compare the
# same way.
#
# After EVERY test the runner checks these invariants:
#   - every shell run (oracle too) left no process in its session: no orphan, stopped
#     (T) or zombie process (each run gets a session of its own; the daemon's session
#     is scanned for anything that is not the daemon or a worker);
#   - no fd >= 3 reached a probe external (`"$STH" probe` in the scripts, plus a probe
#     sent to every daemon worker after the test);
#   - the test's TMPDIR is empty;
#   - the private daemon still answers, and has the same number of workers as before.
#
# Usage: test/stress/run.sh [options] [FILTER...]
#   -n, --iterations N   iterations per test (default 4; a test may scale it)
#   -j, --jobs P         iterations run in parallel (default 2)
#   -l, --load K         K busy loops run during each test, killed by PID after (default 1)
#   -d, --duration S     per-test wall-clock cap: no iteration starts after S seconds (default 90)
#   -t, --timeout S      per-shell-run timeout scale (default 1.0; a test sets its own base)
#   -r, --results DIR    results dir (default build/stress-results/<timestamp>)
#   -m, --modes LIST     curse shells (default interp,compiled,tiered,dcold,dwarm)
#       --oracle PATH    bash 5.2.21 (default: $H_ORACLE, then the in-tree build/test/oracle/bash)
#       --list           list the tests and what they guard
#   FILTER: substrings of test names; only matching tests run.
# Exit status: 0 when every test passed, 1 on any failure, 2 on a usage/setup error.
set -uo pipefail
shopt -s nullglob

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
# The whole run lives under ONE memory + task limit (tools/capped: a cgroup scope in the
# shared curse-work.slice): a runaway test's process tree — not just one process — is
# killed there, never the host (a recursive-subshell probe once filled 15 GB).
if [ -z "${CAPPED:-}" ] && [ "${1:-}" != --run-unit ]; then exec "$REPO/tools/capped" "$0" "$@"; fi
BUILD=${STRESS_BUILD:-$REPO/build}

ITERS=4 JOBS=2 LOAD=1 DURATION=90 TSCALE=1.0 RESULTS="" MODES_SEL="" LIST=0
ORACLE=${H_ORACLE:-}
FILTERS=()
while [ $# -gt 0 ]; do
	case "$1" in
	-n | --iterations) ITERS=$2; shift 2 ;;
	-j | --jobs) JOBS=$2; shift 2 ;;
	-l | --load) LOAD=$2; shift 2 ;;
	-d | --duration) DURATION=$2; shift 2 ;;
	-t | --timeout) TSCALE=$2; shift 2 ;;
	-r | --results) RESULTS=$2; shift 2 ;;
	-m | --modes) MODES_SEL=$2; shift 2 ;;
	--oracle) ORACLE=$2; shift 2 ;;
	--list) LIST=1; shift ;;
	-h | --help) sed -n '2,31p' "$0"; exit 0 ;;
	--) shift; FILTERS+=("$@"); break ;;
	-*) echo "stress: unknown option $1" >&2; exit 2 ;;
	*) FILTERS+=("$1"); shift ;;
	esac
done

# ---- tests ------------------------------------------------------------------------
hdr() { # FILE KEY -> the value of its `#@ KEY: value` header line (empty if none)
	sed -n "s/^#@ $2: *//p" "$1" | head -1
}
TESTS=()
for f in "$HERE"/t/*.sh "$HERE"/t/*.drv; do
	name=$(basename "$f"); name=${name%.*}
	if [ ${#FILTERS[@]} -gt 0 ]; then
		ok=0; for x in "${FILTERS[@]}"; do [[ $name == *"$x"* ]] && ok=1; done
		[ $ok = 1 ] || continue
	fi
	TESTS+=("$f")
done
IFS=$'\n' TESTS=($(printf '%s\n' "${TESTS[@]}" | sort -t/ -k1)); unset IFS
if [ $LIST = 1 ]; then
	for f in "${TESTS[@]}"; do n=$(basename "$f"); printf '%-28s %s\n' "${n%.*}" "$(hdr "$f" guards)"; done
	exit 0
fi
[ ${#TESTS[@]} -gt 0 ] || { echo "stress: no tests selected" >&2; exit 2; }

# ---- the oracle: bash 5.2.21, never another version ---------------------------------
if [ -z "$ORACLE" ]; then
	for c in "$BUILD/test/oracle/bash" "$REPO/build/test/oracle/bash" "$BUILD/oracle/bash" "$REPO/build/oracle/bash"; do
		[ -x "$c" ] && { ORACLE=$c; break; }
	done
fi
[ -n "$ORACLE" ] && [ -x "$ORACLE" ] || { echo "stress: no bash 5.2.21 oracle (use --oracle PATH)" >&2; exit 2; }
ov=$("$ORACLE" -c 'echo ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}.${BASH_VERSINFO[2]}')
[ "$ov" = 5.2.21 ] || { echo "stress: oracle $ORACLE is bash $ov, not 5.2.21" >&2; exit 2; }

LUAJIT=$BUILD/luajit CLIENT=$BUILD/curse-client BUNDLE=$BUILD/curse.bc
for x in "$LUAJIT" "$CLIENT" "$BUNDLE"; do
	[ -e "$x" ] || { echo "stress: $x missing — run 'meson compile -C build'" >&2; exit 2; }
done

# ---- results + scratch ----------------------------------------------------------------
[ -n "$RESULTS" ] || RESULTS=$BUILD/stress-results/$(date +%Y%m%d-%H%M%S)
mkdir -p "$RESULTS" || exit 2
RESULTS=$(cd "$RESULTS" && pwd)
# scratch: STRESS_SCRATCH, else ${TMPDIR:-/tmp} (nothing machine-specific: it runs off this box)
SCR=$(mktemp -d "${STRESS_SCRATCH:-${TMPDIR:-/tmp}}/stress.XXXXXX") || exit 2
BIN=$SCR/bin
mkdir -p "$BIN/oracle" "$BIN/direct" "$BIN/daemon" "$SCR/xdg" "$SCR/dcache"
chmod 700 "$SCR/xdg"

# The helper (sthelp.c): built here, into the scratch dir.
STH=$SCR/bin/sthelp
cc -O2 -o "$STH" "$HERE/sthelp.c" &&
	cc -O2 -DST_WRAPPER -DST_LUAJIT="\"$BUILD/luajit\"" -DST_REPO="\"$REPO\"" -o "$BIN/direct/bash" "$HERE/sthelp.c" ||
	{ echo "stress: cannot build sthelp" >&2; exit 2; }
# Every shell this runner starts (and the daemon) gets a memory cap, as in the conformance
# harness: an unbounded test must fail by itself, never take the host into the OOM killer.
# (after the compiles: cc wants more address space than a shell). Override: H_VMEM_KB.
ulimit -v "${H_VMEM_KB:-2097152}" 2>/dev/null || true

# THIS_SH for each family: its basename is `bash`, as the conformance harness does it.
ln -s "$ORACLE" "$BIN/oracle/bash"
# ($BIN/direct/bash: sthelp built as a launcher of curse from the sources, no /bin/sh between)
ln -s "$CLIENT" "$BIN/daemon/bash"
FALLBACK=$BIN/no-daemon # a dropped daemon must fail loudly, never run something else
printf '#!/bin/sh\necho "curse: daemon unavailable" >&2\nexit 127\n' >"$FALLBACK"
chmod +x "$FALLBACK"

ALLMODES=(interp compiled tiered dcold dwarm)
if [ -n "$MODES_SEL" ]; then IFS=, read -ra ALLMODES <<<"$MODES_SEL"; fi

LOADPIDS=()
DPID=""
cleanup() {
	local p
	for p in "${LOADPIDS[@]}"; do kill -9 "$p" 2>/dev/null; done
	[ -n "$DPID" ] && "$STH" killsid "$DPID"
	# extra daemons a test started (their sessions are recorded as it starts them)
	for p in $(cat "$SCR"/extra-daemons 2>/dev/null); do "$STH" killsid "$p"; done
	rm -rf "$SCR"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---- the private daemon ----------------------------------------------------------------
# start_daemon XDG CACHE WORKERS LOG -> prints the daemon pid (its own session)
start_daemon() {
	local pid n=0
	pid=$(env XDG_RUNTIME_DIR="$1" XDG_CACHE_HOME="$2" CURSE_BUNDLE="$BUNDLE" CURSE_WORKERS="$3" \
		CURSE_IDLE=3600 "$STH" spawn "$4" -- "$LUAJIT" "$REPO/lua/daemon.lua") || return 1
	until [ -S "$1/curse-v2.sock" ]; do
		n=$((n + 1)); [ $n -gt 1500 ] && { echo "stress: daemon did not start in 30s" >&2; cat "$4" >&2; return 1; }
		sleep 0.02
	done
	echo "$pid"
}
DWORKERS=$((JOBS + 1))
XDGN=0 XDG=$SCR/xdg # (the private daemon's runtime dir: a new one on each restart)
DPID=$(start_daemon "$XDG" "$SCR/dcache" "$DWORKERS" "$SCR/daemon.log") || exit 2
workers() { "$STH" children "${1:-$DPID}" | wc -l; } # a daemon's workers are its children

# ---- running one shell ------------------------------------------------------------------
# runsh MODE SCRIPT PREFIX TIMEOUT_S [ARGS...]
#   env knobs: R_CWDSRC (copy this dir into the run's cwd), R_STDIN, R_TMPDIR, R_CACHE
#   (XDG cache for the daemon modes), R_ENV (extra NAME=VALUE words).
#   Writes PREFIX.out .err .st (sthelp status) .probe; the cwd is PREFIX.cwd.
runsh() {
	local mode=$1 script=$2 p=$3 tmo=$4; shift 4
	local cwd=$p.cwd
	rm -rf "$cwd"; mkdir -p "$cwd"
	[ -n "${R_CWDSRC:-}" ] && cp -a "$R_CWDSRC/." "$cwd/"
	: >"$p.probe"
	local ms; ms=$(awk -v t="$tmo" -v s="$TSCALE" 'BEGIN{printf "%d", t*s*1000}')
	local -a E=(env -i PATH="/usr/local/bin:/usr/bin:/bin" HOME="$cwd" TMP="$cwd" LANG=C.UTF-8
		TMPDIR="${R_TMPDIR:-$TT}" STH="$STH" STRESS_PROBE_OUT="$p.probe" STRESS_TDIR="$TDIR" STRESS_REPO="$REPO"
		XDG_RUNTIME_DIR="$XDG" XDG_CACHE_HOME="${R_CACHE:-$SCR/dcache}" CURSE_FALLBACK="$FALLBACK"
		${R_ENV:-})
	local -a C
	local mw=$mode; [ "$script" = -c ] && mw="" # (`-c CODE`: no mode keyword; tiered)
	case $mode in
	oracle) C=("${E[@]}" THIS_SH="$BIN/oracle/bash" "$ORACLE" "$script" "$@") ;;
	interp | compiled | tiered)
		C=("${E[@]}" THIS_SH="$BIN/direct/bash" CURSE_ARGV0="$BIN/direct/bash" CURSE_BUNDLE=
			LUA_PATH="$REPO/lua/?.lua;;" "$LUAJIT" "$REPO/lua/run.lua" "$script" $mw "$@") ;;
	dcold | dwarm) C=("${E[@]}" THIS_SH="$BIN/daemon/bash" "$CLIENT" "$script" "$@") ;;
	*) echo "stress: bad mode $mode" >&2; return 2 ;;
	esac
	(cd "$cwd" && "$STH" run "$p.st" "$ms" "${R_STDIN:-/dev/null}" "$p.out" "$p.err" -- "${C[@]}")
}

# st_of PREFIX -> "exit N" / "signal N" / "hang"
st_of() { head -1 "$1.st" 2>/dev/null || echo "nostatus"; }

# A crash: a fatal signal, or an internal error from the Lua side.
CRASH_RE='internal error|stack traceback|^luajit:|PANIC|attempt to (index|call|compare|perform|concatenate)|bad argument #|curse: daemon unavailable'
is_crash() { # PREFIX MODE -> 0 when the run crashed (reason on stdout)
	local s; s=$(st_of "$1")
	case $s in "signal 4" | "signal 5" | "signal 6" | "signal 7" | "signal 8" | "signal 11" | "signal 31")
		echo "fatal $s"; return 0 ;; esac
	if grep -qE "$CRASH_RE" "$1.err" 2>/dev/null; then echo "stderr: $(grep -m1 -E "$CRASH_RE" "$1.err")"; return 0; fi
	return 1
}

# ---- failures -------------------------------------------------------------------------
# fail CATEGORY MESSAGE [EVIDENCE_DIR]: record a failure of the current test. The first
# failure of each kind keeps its evidence dir whole (first-KIND/); later ones only with KEEPALL.
fail() {
	local cat=$1 msg=$2 ev=${3:-}
	(
		flock 9
		printf '%s\t%s\n' "$cat" "$msg" >>"$TDIR/failures"
		# the first failure of each KIND is kept (a hang after a mismatch keeps its own
		# evidence), per script (a driver runs many)
		local ff=$TDIR/first-$cat; [ -n "${LABEL:-}" ] && [ "$LABEL" != "$NAME" ] && ff=$ff-$LABEL
		if [ -n "$ev" ] && [ -d "$ev" ]; then
			if [ ! -e "$ff" ]; then cp -a "$ev" "$ff"
			elif [ -n "${KEEPALL:-}" ]; then cp -a "$ev" "$TDIR/failure-$(basename "$ev")-$RANDOM"; fi
		fi
	) 9>"$TDIR/.lock"
}
past_deadline() { [ "$(date +%s)" -ge "$DEADLINE" ]; }
# (strip the cwd copies out of an evidence dir: corpus trees are big)
prune_cwd() { rm -rf "$1"/*.cwd; }

# ---- invariants per run -------------------------------------------------------------------
# check_run PREFIX MODE LABEL EVDIR: leftovers, probe, crash, hang -> fail(); returns 1 if
# the run is unusable for comparison (hang/crash).
check_run() {
	local p=$1 m=$2 lab=$3 ev=$4 bad=0 why
	local cat=invariant
	[ "$m" = oracle ] && cat=test-bug # the oracle violating an invariant is the TEST's fault
	if grep -q '^leftover' "$p.st" 2>/dev/null; then
		fail "$cat" "$lab [$m]: processes left in the run's session: $(grep '^leftover' "$p.st" | tr '\n' ';')" "$ev"
	fi
	if [ -s "$p.probe" ]; then
		fail "$cat" "$lab [$m]: fd leaked into a probe: $(head -3 "$p.probe" | tr '\n' ';')" "$ev"
	fi
	if [ "$(st_of "$p")" = hang ]; then
		[ "$m" = oracle ] && cat=test-bug || cat=hang
		fail "$cat" "$lab [$m]: timed out after $(sed -n 's/^ms //p' "$p.st")ms" "$ev"; bad=1
	elif [ "$m" != oracle ] && why=$(is_crash "$p" "$m"); then
		fail crash "$lab [$m]: $why" "$ev"; bad=1
	fi
	return $bad
}

# ---- script tests ------------------------------------------------------------------------
# result key of a run: stdout + status
key_of() { cat "$1.out" 2>/dev/null; printf '\n[%s]\n' "$(st_of "$1")"; }

# Oracle samples of the current script: $ODIR/N.{out,st,key}; oracle_sample N runs one
# more. ($ODIR is per script: a driver may run many scripts in one test.)
oracle_sample() { # (serialized: iterations running in parallel may both ask for one)
	local n=$1 o=$ODIR
	mkdir -p "$o"
	(
		flock 8
		[ -e "$o/$n.key" ] && exit 0
		local ot=$SCR/otmp/$NAME.$LABEL; mkdir -p "$ot"
		R_TMPDIR=$ot runsh oracle "$SCRIPT" "$o/$n" "$TMO" "${SARGS[@]}"
		check_run "$o/$n" oracle "$LABEL oracle sample $n" "$o" || true
		[ -z "$(ls -A "$ot")" ] || fail test-bug "$LABEL oracle sample $n left temp files: $(ls -A "$ot" | head -3 | tr '\n' ' ')"
		rm -rf "$ot"
		key_of "$o/$n" >"$o/$n.key"
		prune_cwd "$o"
	) 8>"$o/.lock"
}
matches_oracle() { # KEYFILE -> 0 if equal to any oracle sample (sampling more on a miss)
	local n
	for ((n = 0; n < ORACLE_SAMPLES; n++)); do
		oracle_sample "$n"
		cmp -s "$1" "$ODIR/$n.key" && return 0
	done
	return 1
}

# one iteration of a script test: all modes, then compare
script_iter() {
	local it=$1 d=$TDIR/$LABEL-it$1 m cache
	mkdir -p "$d"
	cp "$SCRIPT" "$d/input.sh" 2>/dev/null
	cache=$d/cache; mkdir -p "$cache" # dcold: a fresh, empty compile cache; dwarm: the same one after
	local -a ran=()
	for m in "${MODES[@]}"; do
		R_CACHE=$cache runsh "$m" "$SCRIPT" "$d/$m" "$TMO" "${SARGS[@]}"
		if check_run "$d/$m" "$m" "$LABEL it$it" "$d"; then ran+=("$m"); fi
		key_of "$d/$m" >"$d/$m.key"
	done
	rm -rf "$cache"
	[ -n "$R_CWDSRC" ] && prune_cwd "$d" # (corpus trees: big, and a copy of the source)
	# write every diff first, then record the failures (fail() snapshots the dir)
	local first="" groups="" split=0
	for m in "${ran[@]}"; do
		[ -z "$first" ] && first=$m
		cmp -s "$d/$first.key" "$d/$m.key" || split=1
	done
	if [ $split = 1 ]; then
		for m in "${ran[@]}"; do groups+="$m=$(md5sum <"$d/$m.key" | cut -c1-8) "; done
		for m in "${ran[@]}"; do [ "$m" = "$first" ] || diff -u "$d/$first.key" "$d/$m.key" >"$d/diff.$first-vs-$m" 2>&1; done
	fi
	local bad=""
	if [ -z "$NOORACLE" ]; then
		for m in "${ran[@]}"; do
			if ! matches_oracle "$d/$m.key"; then
				bad+="$m "
				diff -u "$ODIR/0.key" "$d/$m.key" >"$d/diff.oracle-vs-$m" 2>&1
			fi
		done
		[ -n "$bad" ] && cp "$ODIR/0.key" "$d/oracle.key" 2>/dev/null
	fi
	# tier agreement: every curse shell that ran to completion must agree
	[ $split = 1 ] && fail tier-mismatch "$LABEL it$it: curse shells disagree: $groups" "$d"
	# oracle agreement
	[ -n "$bad" ] && fail oracle-mismatch "$LABEL it$it: differs from bash 5.2.21: $bad" "$d"
	[ -n "${KEEPITERS:-}" ] || rm -rf "$d"
}

# run_script_test FILE: all iterations of one script, $JOBS at a time. Its `#@` headers
# set the options; a driver overrides them with O_LABEL O_ITERS (absolute) O_MODES
# O_ORACLE (varies|none|det) O_CWD O_TIMEOUT O_KEEP (all).
run_script_test() {
	SCRIPT=$1
	LABEL=${O_LABEL:-$NAME}
	ODIR=$TDIR/$LABEL-oracle
	local mult; mult=$(hdr "$SCRIPT" iters); mult=${mult:-1}
	TMO=${O_TIMEOUT:-$(hdr "$SCRIPT" timeout)}; TMO=${TMO:-20}
	local ms; ms=${O_MODES:-$(hdr "$SCRIPT" modes)}
	if [ -n "$ms" ]; then
		MODES=()
		for m in ${ms//,/ }; do [[ " ${ALLMODES[*]} " == *" $m "* ]] && MODES+=("$m"); done
	else MODES=("${ALLMODES[@]}"); fi
	KEEPALL=""; [ "${O_KEEP:-$(hdr "$SCRIPT" keep)}" = all ] && KEEPALL=1
	local okind=${O_ORACLE:-$(hdr "$SCRIPT" oracle)}
	NOORACLE=""; [ "$okind" = none ] && NOORACLE=1
	# a test that promises a deterministic oracle is checked for it: the oracle runs
	# twice up front and must agree with itself; a varying one gets up to 4 samples
	if [ "$okind" = varies ]; then ORACLE_SAMPLES=4; else ORACLE_SAMPLES=2; fi
	local srcd; srcd=${O_CWD:-$(hdr "$SCRIPT" cwd)}
	R_CWDSRC=""; [ -n "$srcd" ] && R_CWDSRC=$(eval "echo $srcd")
	export R_CWDSRC
	SARGS=()
	local n=${O_ITERS:-$(awk -v a="$ITERS" -v b="$mult" 'BEGIN{n=int(a*b+0.5); if(n<1)n=1; print n}')}
	if [ -z "$NOORACLE" ]; then
		oracle_sample 0
		if [ "$okind" != varies ]; then
			oracle_sample 1
			cmp -s "$ODIR/0.key" "$ODIR/1.key" ||
				fail test-bug "$LABEL: the oracle's output varies between runs (not deterministic): $(diff "$ODIR/0.key" "$ODIR/1.key" | head -5 | tr '\n' ';')" "$ODIR"
		fi
	fi
	local it
	for ((it = 1; it <= n; it++)); do
		past_deadline && { echo "   ($LABEL: duration cap after $((it - 1))/$n iterations)"; break; }
		while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n; done
		script_iter "$it" &
	done
	wait
	echo "$LABEL $((it - 1))" >>"$TDIR/iterations"
}

# ---- corpus replay through test/conformance/run.sh (its CLI only) ------------------------
# replay_conformance CORPUS REPEATS FILTER... : run the harness REPEATS times (curse-cold +
# curse-hot through ITS daemon, bash 5.2.21 as the oracle via PATH), under the load, and
# keep every failing row's expected/actual output (H_DIFF_DIR) per repeat.
replay_conformance() {
	local corpus=$1 reps=$2; shift 2
	local r d rows tmo=${CONF_TIMEOUT:-60}
	for ((r = 1; r <= reps; r++)); do
		past_deadline && { echo "   (duration cap: $((r - 1))/$reps harness repeats of $corpus)"; break; }
		d=$TDIR/conf-$corpus-r$r; mkdir -p "$d/diffs"
		PATH="$BIN/oracle:$PATH" TMPDIR=$SCR H_DIFF_DIR="$d/diffs" \
			timeout $((tmo * 8 + 120)) "$REPO/test/conformance/run.sh" --corpus "$corpus" --jobs "$JOBS" \
			--timeout "$tmo" --shells curse-cold,curse-hot --results "$d/rows.tsv" "$@" >"$d/log" 2>&1
		local rc=$?
		[ $rc -eq 124 ] && fail hang "conformance $corpus r$r: the harness itself timed out" "$d"
		rows=$(awk -F'\t' '$3=="FAIL"{print $2" "$5}' "$d/rows.tsv" 2>/dev/null | sort)
		if [ -n "$rows" ]; then
			local f
			for f in "$d"/diffs/*.expected; do
				local b=${f%.expected}
				for s in "$b".curse-*; do diff -u "$f" "$s" >"$s.diff" 2>&1; done
			done
			fail oracle-mismatch "conformance $corpus r$r: $(echo "$rows" | tr '\n' ',' | sed 's/,$//')" "$d"
		fi
		awk -F'\t' '$3=="ORACLE-TIMEOUT"{print $5}' "$d/rows.tsv" 2>/dev/null | while read -r t; do
			fail test-bug "conformance $corpus r$r: the oracle timed out on $t (raise CONF_TIMEOUT)"
		done
		[ -s "$d/rows.tsv" ] || fail test-bug "conformance $corpus r$r: harness produced no rows (rc $rc): $(tail -3 "$d/log" | tr '\n' ';')" "$d"
		cat "$d/rows.tsv" >>"$TDIR/conformance-rows.tsv" 2>/dev/null
		[ -n "$rows" ] || rm -rf "$d"
	done
}

# ---- per-test invariants (daemon, TMPDIR) --------------------------------------------------
daemon_check() { # LABEL: the private daemon answers, same workers, nothing else in its session
	local lab=$1 n=0 w ok=0 extra
	local p=$TDIR/daemon-check; mkdir -p "$p"
	R_CACHE=$SCR/dcache R_TMPDIR=$SCR runsh dwarm -c "$p/alive" 10 'echo alive' 2>/dev/null
	if [ "$(cat "$p/alive.out" 2>/dev/null)" != alive ]; then
		fail invariant "$lab: the private daemon did not answer: $(st_of "$p/alive") $(head -c 300 "$p/alive.err")" "$p"
	fi
	# worker count back to what it was, nothing but daemon + workers in its session
	while :; do
		w=$(workers)
		extra=$("$STH" scan "$DPID" "$DPID" $("$STH" children "$DPID" | awk '{print $1}'))
		[ "$w" -eq "$W0" ] && [ -z "$extra" ] && { ok=1; break; }
		n=$((n + 1)); [ $n -ge 50 ] && break
		sleep 0.1
	done
	if [ $ok = 0 ]; then
		# Fewer workers: one died and was not replaced. More: the pool forks an OVERFLOW
		# worker whenever a connection waits while every worker is busy — a worker still
		# draining a finished script's background jobs counts as busy, and nested curse
		# (`$THIS_SH`) holds one worker while it needs another — and keeps it until its idle
		# timeout. That growth is by design, so it is bounded, not forbidden: beyond what the
		# concurrency explains (JOBS+1 extra; any, for `#@ nested: yes` / `#@ concurrent: yes`)
		# it is a failure. (The daemon is restarted either way, so each test starts at W0.)
		if [ "$w" -lt "$W0" ] || { [ "$w" -gt $((W0 + JOBS + 1)) ] && [ "$NESTED" != yes ] && [ "$CONCURRENT" != yes ]; }; then
			fail invariant "$lab: daemon workers $W0 before, $w after: $("$STH" children "$DPID" | tr '\n' ';')"
		elif [ "$w" -gt "$W0" ]; then
			echo "(daemon pool grew $W0 -> $w: overflow workers)" >>"$TDIR/log"
		fi
		[ -n "$extra" ] && fail invariant "$lab: processes left in the daemon's session (orphans/stopped): $(echo "$extra" | tr '\n' ';')"
		# start the next test on a FRESH daemon: zombies can't be killed, and anything left
		# would be blamed on the next test too (ours: the daemon's own session)
		echo "(restarting the private daemon after this test)" >>"$TDIR/log"
		# (in a NEW runtime dir: the old instance's lock and socket go away only once its
		# last process is gone, which under load can take a while)
		"$STH" killsid "$DPID"
		XDGN=$((XDGN + 1)); XDG=$SCR/xdg$XDGN; mkdir -p "$XDG"; chmod 700 "$XDG"
		DPID=$(start_daemon "$XDG" "$SCR/dcache" "$DWORKERS" "$SCR/daemon.log") || { echo "stress: daemon restart failed" >&2; exit 2; }
		for ((n = 0; n < 200; n++)); do [ "$(workers)" -ge "$DWORKERS" ] && break; sleep 0.05; done
		W0=$(workers)
	fi
	# fd probe in every worker: one concurrent request per worker, each held for a moment
	local i
	for ((i = 0; i < W0; i++)); do
		R_CACHE=$SCR/dcache R_TMPDIR=$SCR runsh dwarm -c "$p/probe$i" 10 '"$STH" probe; /bin/sleep 0.3' &
	done
	wait
	for ((i = 0; i < W0; i++)); do
		[ -s "$p/probe$i.probe" ] && fail invariant "$lab: a daemon worker leaks fds into externals: $(head -3 "$p/probe$i.probe" | tr '\n' ';')" "$p"
	done
	rm -rf "$p"
}
tmpdir_check() {
	local left; left=$(ls -A "$TT" 2>/dev/null | head -5)
	[ -z "$left" ] || { fail invariant "$1: temp files left in TMPDIR: $(echo "$left" | tr '\n' ' ')"; rm -rf "${TT:?}"/* "$TT"/.[!.]* 2>/dev/null; }
}

# ---- load ----------------------------------------------------------------------------------
load_start() { local i; LOADPIDS=(); for ((i = 0; i < LOAD; i++)); do "$STH" busy & LOADPIDS+=($!); done; }
load_stop() { local p; for p in "${LOADPIDS[@]}"; do kill -9 "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; LOADPIDS=(); }

# ---- main loop -------------------------------------------------------------------------------
export STH ORACLE REPO BUILD LUAJIT CLIENT BUNDLE SCR BIN FALLBACK
echo "stress: ${#TESTS[@]} tests; iterations=$ITERS jobs=$JOBS load=$LOAD duration=${DURATION}s; shells: ${ALLMODES[*]}"
echo "        oracle $ORACLE (bash $ov); daemon pid $DPID ($DWORKERS workers); results $RESULTS"
printf 'test\tverdict\tseconds\titerations\tfailures\n' >"$RESULTS/summary.tsv"
# (the pool forks one worker, warms up, then the rest: wait for all of them)
for ((n = 0; n < 200; n++)); do [ "$(workers)" -ge "$DWORKERS" ] && break; sleep 0.05; done
W0=$(workers)
nfail=0
for f in "${TESTS[@]}"; do
	NAME=$(basename "$f"); NAME=${NAME%.*}
	TDIR=$RESULTS/$NAME; rm -rf "$TDIR"; mkdir -p "$TDIR"
	TT=$SCR/tmp/$NAME; mkdir -p "$TT"
	cap=$(hdr "$f" duration); cap=${cap:-$DURATION}
	NESTED=$(hdr "$f" nested) CONCURRENT=$(hdr "$f" concurrent)
	t0=$(date +%s); DEADLINE=$((t0 + cap))
	printf '%-30s ' "$NAME"
	load_start
	(
		unset R_CWDSRC
		case $f in
		*.sh) run_script_test "$f" ;;
		*.drv) source "$f"; drv_main ;;
		esac
	) >"$TDIR/log" 2>&1
	load_stop
	daemon_check "$NAME"
	tmpdir_check "$NAME"
	secs=$(($(date +%s) - t0))
	its=$(awk '{s+=$NF} END{print s+0}' "$TDIR/iterations" 2>/dev/null)
	if [ -s "$TDIR/failures" ]; then
		nfail=$((nfail + 1)); nf=$(wc -l <"$TDIR/failures")
		cats=$(cut -f1 "$TDIR/failures" | sort | uniq -c | awk '{printf "%s%s×%s", (NR>1?", ":""), $2, $1}')
		echo "FAIL  (${secs}s, $cats)"
		cut -f2 "$TDIR/failures" | head -3 | sed 's/^/      /' | cut -c1-220
		printf '%s\tFAIL\t%s\t%s\t%s\n' "$NAME" "$secs" "$its" "$cats" >>"$RESULTS/summary.tsv"
	else
		echo "ok    (${secs}s, $its iterations)"
		printf '%s\tok\t%s\t%s\t\n' "$NAME" "$secs" "$its" >>"$RESULTS/summary.tsv"
	fi
	rm -rf "$TT"
done
echo
if [ $nfail -gt 0 ]; then
	echo "stress: $nfail of ${#TESTS[@]} tests FAILED — details: $RESULTS/<test>/failures, evidence in first-<kind>*/"
	exit 1
fi
echo "stress: all ${#TESTS[@]} tests passed ($RESULTS)"
exit 0
