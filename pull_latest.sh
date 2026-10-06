#!/usr/bin/env bash
# Check GitHub for new commits on this branch and pull them in. Never overwrites local work:
# it only fast-forwards, and stops (changing nothing) if you have uncommitted changes or
# commits GitHub doesn't have.
#
#   bash pull_latest.sh
set -u
cd "$(dirname "$0")" || exit 1

branch=$(git rev-parse --abbrev-ref HEAD)
echo "Checking GitHub (origin/$branch) ..."
if ! git fetch origin --quiet; then
	echo "Could not reach GitHub."
	exit 1
fi
if ! git rev-parse --verify -q "origin/$branch" > /dev/null; then
	echo "GitHub has no branch '$branch' yet."
	exit 1
fi

behind=$(git rev-list --count "HEAD..origin/$branch")
ahead=$(git rev-list --count "origin/$branch..HEAD")

if [ "$behind" -eq 0 ]; then
	echo "Up to date."
	[ "$ahead" -gt 0 ] && echo "($ahead local commit(s) not pushed yet: git push)"
	exit 0
fi

echo "$behind new commit(s) on GitHub:"
git log --oneline "HEAD..origin/$branch"

if [ "$ahead" -gt 0 ]; then
	echo
	echo "Not pulled: you also have $ahead local commit(s) GitHub doesn't, so the branches have diverged."
	echo "Merge by hand:  git merge origin/$branch"
	exit 2
fi
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
	echo
	echo "Not pulled: you have uncommitted changes. Commit or stash them first:"
	git status --short --untracked-files=no
	exit 2
fi

echo
git pull --ff-only --quiet origin "$branch" && echo "Pulled. Now at $(git log --oneline -1)"
