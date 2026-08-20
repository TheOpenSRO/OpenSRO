# Dev tools

None of these tools bundle or commit any game data; you point them at your own files. All need a
real (even if software/offscreen) GL context — run them under `xvfb-run` with
`LIBGL_ALWAYS_SOFTWARE=1` on a machine without a display, or drop `xvfb-run` if you're already on
a machine with a display. See each script's header comment for full usage.

`render_asset.gd` — loads a real mesh + real texture from a real pk2 archive through this
project's own readers (`Pk2Reader`, `BmsReader`, `DdjReader`) and renders a screenshot to disk.

`render_skeleton.gd` — loads a real `.bsk` skeleton file (not necessarily from a pk2 — real
samples so far have only been found as loose files, see `docs/protocol/BSK_FORMAT.md`) through
`BskReader` and renders its bone hierarchy (a line segment per bone-to-parent connection, a small
sphere at each joint) to disk.

`render_skeleton_animated.gd` — loads a real `.bsk` skeleton and a real `.ban` animation, applies
the animation's rotation (relative to its own first keyframe) to one named bone and all of its
descendants via simple forward kinematics, and renders two screenshots (bind pose vs. animated
pose) so the movement is visible as a before/after comparison. The `.ban` and `.bsk` files don't
need to be from the same character/skeleton — this demonstrates the playback mechanism against
any real keyframe data landing on a matching bone name, not a claim that a specific animation
belongs to a specific skeleton.

`render_skeleton3d_animated.gd` — the real-engine counterpart to `render_skeleton_animated.gd`:
loads a real `.bsk` skeleton and a real `.ban` animation, builds an actual Godot `Skeleton3D` via
`Skeleton3DBuilder`, and applies the animation's rotation via `Skeleton3D`'s own pose-rotation
propagation (not manual per-bone math) — every descendant bone moves correctly through the
engine's real hierarchy. Renders the same bind-pose/animated-pose before/after comparison.

`render_map_objects.gd` — loads a real `.o` (`Map.pk2` object-placement) file through
`MapoReader` and renders a top-down scatter of every placed object's real world position, colored
by type ID, to disk. Doesn't resolve type IDs to real `.bsr` models — no mapping from a `.mapo`
type ID to a resource path has been found anywhere in this project's data (see
`docs/protocol/MAPO_FORMAT.md`), so this renders simple colored markers, not the actual scenery.
