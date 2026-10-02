#!/bin/sh
# Starts SRRevamp on the Compatibility (OpenGL) renderer, for a machine without Vulkan.
# The game remembers the choice (override.cfg beside it), so after this one start
# ./srrevamp.x86_64 opens on Compatibility too. Delete override.cfg, or set
# display.renderer: forward_plus in setting/config.yaml, to go back to Forward+.
here="$(cd "$(dirname "$0")" && pwd)"
exec "$here/srrevamp.x86_64" --rendering-driver opengl3 "$@"
