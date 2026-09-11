#!/bin/bash
# Installs the updater for this checkout and starts its timer.
#
# Run as the user that owns the checkout and can run docker; sudo is used
# only to write the two systemd units. Re-running it is harmless.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/.." && pwd)
user=$(id -un)

for unit in srrevamp-update.service srrevamp-update.timer; do
	sed -e "s|@REPO@|$repo|g" -e "s|@USER@|$user|g" "$here/$unit" |
		sudo tee "/etc/systemd/system/$unit" >/dev/null
done
sudo systemctl daemon-reload
sudo systemctl enable --now srrevamp-update.timer
systemctl list-timers srrevamp-update.timer --no-pager
