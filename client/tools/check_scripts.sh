#!/bin/bash
# check_scripts.sh [script...] -- prove GDScript actually COMPILES.
#
# Two traps this exists for, both of which have silently passed in this repo:
#
#  1. `--import` reporting no errors is not proof anything compiled; it will
#     happily serve cached scripts. AGENTS.md has warned about this for a long
#     time. Loading a script executes its parser, which is the real check.
#  2. There is no `godot4` on the render box -- the binary lives at
#     /opt/godot-bin/. A check written as `godot4 ... | grep -i error` prints
#     nothing and looks clean *because the command did not run at all*. Every
#     client check in one whole session was a no-op for exactly this reason.
#
# Expected noise: "Compile Error: Identifier not found: NetClient". NetClient is
# an autoload, and a bare --script run does not instantiate autoloads, so every
# script referencing it reports that. It is not a failure -- trust the
# "failures: N" line, which counts scripts that would not load at all.
#
# Run it on the render box, from the client directory.
set -u
GODOT="${GODOT:-/opt/godot-bin/Godot_v4.2.2-stable_linux.x86_64}"
DIR="${CLIENT_DIR:-.}"

if [ ! -x "$GODOT" ]; then
  echo "check_scripts: no Godot at $GODOT (set GODOT)" >&2
  exit 2
fi

# Default to every script in the project.
if [ "$#" -gt 0 ]; then
  SCRIPTS=("$@")
else
  mapfile -t SCRIPTS < <(cd "$DIR" && find scripts -name '*.gd' | sed 's|^|res://|')
fi

TMP="$DIR/.check_scripts_tmp.gd"
{
  echo "extends SceneTree"
  echo "func _init():"
  echo "	var bad := 0"
  for s in "${SCRIPTS[@]}"; do
    echo "	if load(\"$s\") == null:"
    echo "		bad += 1"
    echo "		print(\"FAILED_TO_LOAD $s\")"
  done
  echo "	print(\"CHECKED ${#SCRIPTS[@]} scripts, failures: \", bad)"
  echo "	quit(1 if bad > 0 else 0)"
} > "$TMP"

OUT=$("$GODOT" --headless --path "$DIR" --script res://.check_scripts_tmp.gd 2>&1)
rm -f "$TMP"
echo "$OUT" | grep -iE "Parse Error|Compile Error|FAILED_TO_LOAD|CHECKED"

# A parse/compile error anywhere is a failure even if load() returned non-null.
if echo "$OUT" | grep -qiE "Parse Error|FAILED_TO_LOAD"; then
  exit 1
fi
exit 0
