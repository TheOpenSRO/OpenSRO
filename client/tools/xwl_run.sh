#!/bin/bash
# Runs one command on a private, headless X server that the GPU can present
# Vulkan to -- the Forward+ counterpart of `xvfb-run -a ... vglrun -d egl0`
# (round 693; docs/RENDER_BOX.md, "Vulkan (Forward+)").
#
#   xwl_run.sh [-s WxH] <command> [args...]
#
# Why not Xvfb: Mesa's Vulkan X11 presentation needs DRI3, which Xvfb does not
# have, and VirtualGL is GL-only. Under plain Xvfb Godot's Forward+ silently
# picks llvmpipe, the CPU (MEASURED on the box, 2026-10-02: "Using Vulkan
# Device #1: Unknown - llvmpipe"); with MESA_VK_WSI_DEBUG=sw it gets the RX 7600
# but every frame is copied back through the CPU, 17.5 ms a frame at 1280x720
# for an empty scene (4.7 at 640x360), which would swamp every frame time.
# Xwayland has DRI3 through glamor on the render node, so here a headless
# weston (GL renderer, on the GPU) hosts an Xwayland, and RADV presents to it
# directly: the same empty scene draws in 0.24 ms a frame (MEASURED).
#
# The compositor and its Xwayland are this call's own: started in a private
# XDG_RUNTIME_DIR under /var/tmp, found by the display number weston logs,
# and stopped by PID when the command exits -- nothing else on the box is
# touched. The exit status is the command's.
set -u
SIZE=1280x720
if [ "${1:-}" = -s ]; then SIZE="$2"; shift 2; fi
[ $# -gt 0 ] || { echo "usage: $0 [-s WxH] <command> [args...]" >&2; exit 2; }
command -v weston >/dev/null || { echo "xwl_run: weston is not installed (docs/RENDER_BOX.md, \"Vulkan (Forward+)\")" >&2; exit 2; }
rt=$(mktemp -d /var/tmp/xwl-run.XXXXXX)
chmod 700 "$rt"
XDG_RUNTIME_DIR="$rt" weston --backend=headless --renderer=gl --xwayland \
  --width="${SIZE%x*}" --height="${SIZE#*x}" --socket=wl --idle-time=0 \
  --log="$rt/weston.log" >/dev/null 2>&1 &
wp=$!
cleanup() { kill "$wp" 2>/dev/null; wait "$wp" 2>/dev/null; rm -rf "$rt"; }
trap cleanup EXIT
trap 'exit 143' TERM INT
d=""
for _ in $(seq 1 100); do
  d=$(grep -o "xserver listening on display :[0-9]*" "$rt/weston.log" 2>/dev/null | tail -1 | grep -o ":[0-9]*$")
  [ -n "$d" ] && break
  kill -0 "$wp" 2>/dev/null || break
  sleep 0.1
done
if [ -z "$d" ]; then
  echo "xwl_run: weston/Xwayland did not come up -- its log:" >&2
  cat "$rt/weston.log" >&2 2>/dev/null
  exit 1
fi
echo "xwl_run: weston (headless, GL renderer) with Xwayland on $d, ${SIZE}" >&2
DISPLAY="$d" WAYLAND_DISPLAY="" "$@"
