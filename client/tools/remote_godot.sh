#!/bin/bash
# Runs Godot on the render box, never on the developer's machine.
#
# AGENTS.md's hard rule: "Never run Godot on the host machine. Godot is only
# run on the dedicated render/RE box (192.168.5.78, see docs/RENDER_BOX.md)."
# This ships the working copy there and runs the command, so following the
# rule is one line rather than five.
#
#   client/tools/remote_godot.sh check          # every script and scene compiles
#   client/tools/remote_godot.sh tests          # every *_test.gd
#   client/tools/remote_godot.sh script res://tools/dump_layout.gd -- --pk2=...
#   client/tools/remote_godot.sh sync           # ship the working copy, run nothing
#
# The import step runs before anything else, because check_scripts.gd needs
# every class_name registered before it can tell a broken script from one
# that simply has not been seen yet -- see its own doc comment.
#
# Environment: RENDER_HOST, RENDER_DIR, RENDER_GODOT, PK2_DIR.
set -euo pipefail

RENDER_HOST="${RENDER_HOST:-root@192.168.5.78}"
RENDER_DIR="${RENDER_DIR:-/opt/srrevamp-client}"
RENDER_GODOT="${RENDER_GODOT:-/opt/godot-bin/Godot_v4.2.2-stable_linux.x86_64}"
PK2_DIR="${PK2_DIR:-/opt/sro-files/client}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

sync_client() {
  tar cf - -C "$repo_root" client/scripts client/tools client/scenes client/project.godot \
    | ssh "$RENDER_HOST" "tar xf - -C '$RENDER_DIR' --strip-components=1 \
        && chmod +x '$RENDER_DIR'/tools/*.sh \
        && chown -R ghidra:ghidra '$RENDER_DIR'"
}

# Godot runs as the unprivileged user that owns the project and the X setup.
#
# `-n` matters: without it ssh reads the caller's stdin, which ate the rest
# of the test loop's file list below and left it running one suite out of
# fifty-nine while reporting success.
# One Godot at a time on the box: qa_shot.sh kills every running Godot/Xvfb
# before it starts, so a headless run launched beside a render would be
# killed mid-flight. Every Godot here takes the same box-wide lock (as
# ghidra, so the lock file stays ghidra's); a second caller waits its turn.
GODOT_LOCK="${GODOT_LOCK:-/var/tmp/godot-lock/lock}"

remote_godot() {
  ssh -n "$RENDER_HOST" "su - ghidra -c \"flock '$GODOT_LOCK' $RENDER_GODOT --headless --path '$RENDER_DIR' $*\""
}

import_project() {
  remote_godot "--import --quit" >/dev/null 2>&1 || true
}

cmd="${1:-check}"
shift || true

case "$cmd" in
  sync)
    sync_client
    echo "shipped to $RENDER_HOST:$RENDER_DIR"
    ;;
  check)
    sync_client
    import_project
    remote_godot "--script res://tools/check_scripts.gd"
    ;;
  script)
    # A bare `res://tools/foo.gd` is NOT a script to Godot: without `--script`
    # it ignores the path, boots the project's main scene (the login screen)
    # headless and sits there for ever. One lane lost 15 minutes to exactly
    # that on 2026-09-19, so supply the flag when the caller left it out.
    if [ $# -eq 0 ]; then
      echo "usage: $0 script [--script] res://tools/<tool>.gd [-- --flag=value ...]" >&2
      exit 2
    fi
    case "$*" in
      *--script*) remote_godot "$@" ;;
      res://*)    remote_godot "--script" "$@" ;;
      *)          remote_godot "$@" ;;
    esac
    ;;
  tests)
    sync_client
    import_project
    # Discovered, not listed: a hand-kept list drifted to 55 entries against
    # 56 real test files, so a test could be added and silently never run.
    failed=0
    count=0
    while IFS= read -r path; do
      count=$((count + 1))
      rel="res://${path#client/}"
      if ! out=$(remote_godot "--script '$rel'" 2>&1) || echo "$out" | grep -qE "FAIL|FAILURES|Parse Error"; then
        echo "FAILED: $rel"
        echo "$out" | grep -E "FAIL|Parse Error" | head -5
        failed=$((failed + 1))
      fi
    done < <(cd "$repo_root" && find client -name '*_test.gd' | sort)
    echo "ran $count suite(s), $failed failing"
    [ "$failed" -eq 0 ]
    ;;
  *)
    echo "usage: remote_godot.sh {sync|check|tests|script <godot args...>}" >&2
    exit 2
    ;;
esac
