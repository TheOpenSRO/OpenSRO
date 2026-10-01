#!/bin/bash
# Runs every GDScript suite (client/scripts/**/*_test.gd) with the Godot on PATH, one at a
# time, from client/. CI's two client jobs share it (ci.yml): "Validate client" with no
# native library present, "Native readers" with libsrrevamp_native.so built and loaded.
# Discovered, not listed: a hand-kept list once drifted to 55 entries against 56 test files,
# so a test could be added and silently never run.
set -o pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
godot="${GODOT_BIN:-godot}"
failed=0
count=0
for t in $(find scripts -name '*_test.gd' | sort); do
  count=$((count + 1))
  if ! "$godot" --headless --path . --script "res://$t"; then
    echo "::error file=client/$t::GDScript test failed"
    failed=1
  fi
done
echo "ran $count GDScript test(s)"
if [ "$count" -eq 0 ]; then
  echo "::error::no GDScript tests were discovered"
  exit 1
fi
exit $failed
