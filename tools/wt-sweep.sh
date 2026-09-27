#!/usr/bin/env bash
# wt-sweep.sh [-n]: clean up finished agent worktrees without ever losing work.
#
# A linked worktree is REMOVED (and its branch deleted) only when both hold:
#   - its branch is fully merged into main (every commit reachable from main), and
#   - it has no uncommitted work: no modified/staged tracked file, no untracked file
#     that isn't ignored (by main's .gitignore too: an old checkout's may predate a rule).
#     Ignored files — build/, fetched subprojects/, .scratch/ — are regenerable by
#     definition and go with it;
#   - it is idle: no process has its cwd inside it and nothing in it changed for an hour
#     (a just-created worktree has no commits yet, so "merged" alone would match one an
#     agent is still building in).
# Everything else is KEPT and listed with the reason, for a human (or the coordinator)
# to decide. Nothing is ever force-deleted on a guess. -n: report only.
# Agents keep their scratch in <worktree>/.scratch/ (ignored), so it dies with the
# worktree; evidence worth keeping is committed or quoted in the agent's report.
set -u
dry=; [ "${1:-}" = -n ] && dry=1
top=$(git rev-parse --show-toplevel) || exit 1
cd "$top" || exit 1
git worktree prune
main=$(git rev-parse --verify -q main) || { echo "wt-sweep: no main branch" >&2; exit 1; }
removed=0 kept=0 wt=
in_use() { # (sets in_use_why)
	local p c
	for p in /proc/[0-9]*; do
		c=$(readlink "$p/cwd" 2>/dev/null) || continue
		case $c/ in "$1"/*) in_use_why="pid ${p#/proc/} runs there"; return 0 ;; esac
	done
	c=$(find "$1" -mmin -60 -print -quit 2>/dev/null)
	[ -n "$c" ] && { in_use_why="changed within the hour (${c#"$1"/})"; return 0; }
	return 1
}
while read -r key val; do
	case $key in
	worktree) wt=$val br= ;;
	branch) br=${val#refs/heads/} ;;
	'')
		[ -z "$wt" ] || [ "$wt" = "$top" ] && { wt=; continue; }
		why=
		if [ -z "$br" ]; then
			why="detached HEAD"
		elif ! git merge-base --is-ancestor "$br" "$main"; then
			why="$(git rev-list --count "$main..$br") commit(s) not on main; last $(git log -1 --format=%cr "$br")"
		elif [ -n "$(git -C "$wt" -c core.excludesFile="$top/.gitignore" status --porcelain 2>&1 | head -1)" ]; then
			why="uncommitted work"
		elif in_use "$wt"; then
			why="in use: $in_use_why"
		fi
		if [ -n "$why" ]; then
			echo "kept    $wt [${br:-?}]: $why"
			kept=$((kept + 1))
		elif [ -n "$dry" ]; then
			echo "would remove $wt [$br] (merged, clean)"
		else
			git worktree remove --force "$wt" && git branch -d "$br" >/dev/null &&
				echo "removed $wt [$br] (merged, clean)" && removed=$((removed + 1))
		fi
		wt=
		;;
	esac
done < <(git worktree list --porcelain; echo)
echo "wt-sweep: $removed removed, $kept kept"
