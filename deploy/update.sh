#!/bin/bash
# Keeps a deployed server on the tip of a branch.
#
# Run by opensro-update.timer every few minutes: fetch, and if the branch
# moved, fast-forward, rebuild the compose stack and check the gateway came
# back. A build that fails, or a server that never listens, is rolled back
# to the commit that was running, and that origin commit is *held*: the
# script will not try it again until origin moves on (or the hold file is
# removed). When nothing changed it exits 0 without a word, so the journal
# only shows real events.
#
#   sudo systemctl start opensro-update.service   # update now
#   journalctl -u opensro-update                  # what it did, and why
#   FORCE=1 deploy/update.sh                       # rebuild even if unchanged
#
# Local edits to tracked files stop the update (loudly) rather than being
# thrown away; untracked files such as docker-compose.override.yml are fine.
set -euo pipefail

REPO=${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
BRANCH=${BRANCH:-dev}
PORT=${PORT:-15779}
HOLD="$REPO/.git/update-held"

cd "$REPO"
git fetch -q origin "$BRANCH"
running=$(git rev-parse HEAD)
wanted=$(git rev-parse "origin/$BRANCH")

if [ "$running" = "$wanted" ] && [ "${FORCE:-0}" != 1 ]; then
	exit 0
fi
if [ -f "$HOLD" ] && [ "$(cat "$HOLD")" = "$wanted" ]; then
	echo "origin/$BRANCH is still $wanted, which failed to come up last time; holding at $running (rm $HOLD to retry)" >&2
	exit 1
fi
if git status --porcelain | grep -qv '^??'; then
	echo "the working tree has local changes; not updating until they are committed or stashed:" >&2
	git status --short | grep -v '^??' >&2
	exit 1
fi

# The gateway is up when the port answers twice, ten seconds apart -- one
# answer could be a container that is about to crash and be restarted.
listening() {
	local i
	for i in $(seq 1 45); do
		if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
			sleep 10
			(exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && return 0
		fi
		sleep 2
	done
	return 1
}

rollback() {
	echo "rolling back to $running" >&2
	git reset -q --hard "$running"
	docker compose up -d --build >/dev/null 2>&1 || echo "the rollback build failed too; the stack is down" >&2
	echo "$wanted" >"$HOLD"
}

echo "updating $running -> $wanted"
git merge -q --ff-only "origin/$BRANCH"
git log --oneline "$running..$wanted" | sed 's/^/  /'

if ! build_log=$(docker compose build 2>&1); then
	echo "$build_log" | tail -n 30 >&2
	rollback
	exit 1
fi
if ! docker compose up -d --remove-orphans >/dev/null 2>&1; then
	rollback
	exit 1
fi
if listening; then
	echo "server at $(git rev-parse --short HEAD) listening on $PORT"
	rm -f "$HOLD"
	# Old build layers would otherwise pile up until the disk is full.
	docker image prune -f >/dev/null 2>&1 || true
else
	echo "server at $wanted never listened on $PORT:" >&2
	docker compose logs --no-log-prefix --tail 20 server >&2 || true
	rollback
	exit 1
fi
