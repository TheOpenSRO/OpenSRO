# Dev tools

None of these tools bundle or commit any game data; you point them at your own files. All need a
real (even if software/offscreen) GL context — run them under `xvfb-run` with
`LIBGL_ALWAYS_SOFTWARE=1` on a machine without a display, or drop `xvfb-run` if you're already on
a machine with a display. See each script's header comment for full usage.

`qa_shot.sh` — **the way to look at the world.** Runs the client against real pk2 archives, puts
the player at a given region-local spot, frames the camera, and collects the rendered frames. It
drives the QA hooks documented at the top of `client/scripts/World3D.gd` (`SRREVAMP_QA_*`), which
also cover walking a heading, hiding meshes by name, reporting what the camera is pointing at,
sweeping a region for spots where a player would stand under the geometry, and firing rays through
a wall to see which arches are actually open.

Two things about it are worth knowing before you wait on a run:

**It uses the GPU when there is one.** Godot's Linux GL backend draws through GLX on X11 and Xvfb
has no DRI, so without help every frame is rasterised on the CPU and a screenshot costs minutes.
When `vglrun` and a readable `/dev/dri/renderD128` are both present the script routes GLX through
EGL on the render node instead, and says which path it took on stderr. If a log ever says
"falling back to software GL", something about the render node changed — that is worth fixing
before waiting on anything else.

**Startup dominates, so batch the pictures.** Loading the region grid costs roughly 65 seconds
against 0.33 seconds a frame, so six pictures taken as six runs pays that cost six times. Use
`--shots` to visit several viewpoints in one boot, and `--radius` to load fewer regions when the
check only looks at one:

```
qa_shot.sh --out /var/tmp/tour --frames 220 --region '97\168.m' --radius 1 \
  --shots "square@1002,1020:0,-25,700;gate@1062,1560:0,2,45;shops@300,1100:270,-8,60"
```

Each viewpoint prints `QA SHOT <name> frame <n>` in the log; pull that numbered frame from the
output directory. Six viewpoints this way took 116 seconds against about nine and a half minutes
as six separate runs.

`dump_ddj.gd` — writes any real `.ddj` texture out as a PNG, and reports its fourCC, the format it
decompresses to, and how many texels are opaque, transparent or partial. Written to settle which
spelling of the region minimap filename was real (`<y>x<x>.ddj`), and useful whenever a texture
renders wrong and the question is whether its alpha survived decoding.

`check_object_yaw.gd` — measures which yaw convention places map objects where a region's own
`.nvm` says they are: every navmesh object's navigation mesh is placed under eight candidate
conventions and scored against the cells that list it and the object-to-object linked edges, with
`--scan` to sample regions across the map and `--list` to name the objects whose yaw can tell the
conventions apart. Written for round 506, where it confirmed (with the client binary's own matrix)
that the game's turn is the negated yaw.

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

`render_character.gd` — loads a real `.bsk` skeleton and a directory of real body-part `.bms`
meshes (loose files — see `docs/protocol/BSK_FORMAT.md`), assembles them rigidly via
`CharacterAssembler`, and renders a screenshot. Rigid, because it predates the finding that
`.bms` carries per-vertex skinning after all (`docs/protocol/BMS_FORMAT.md`); the game itself
assembles a character through `SkinnedBsrAssembler` from its `.bsr`.

`check_item_requirements.gd` — characterises the item table's equipment rows against a real
archive: that column 52's worn model exists in Data.pk2 for every row (7,264 of 7,264), that the
code name's race/gender/piece letters agree with `Country`/`ReqGender`/`TypeID4`, and which
requirement types occur (1, and the six European mastery ids). The measurements behind
`docs/protocol/ITEM_FORMAT.md`.

`extract_pk2_file.gd` — copies one file out of a pk2 archive to disk, for picking a format apart
offline against several files at once (how the `.bsr` animation-group layout was settled). What
comes out is game data: keep it in a scratch directory, never in the repo.

`dump_text_table.gd` — prints any `server_dep\silkroad\textdata\*.txt` table with every column
numbered, so a column index can be read off rather than counted; several of those tables carry
their own header row naming the columns. `dump_ddj_sizes.gd` prints the pixel size and
compression of named `.ddj` textures — a frame's insets, a name plate's cap width — so those
numbers are measured rather than eyeballed. Both take forward slashes in archive paths, because
backslashes do not survive ssh and su to the render box.

`render_map_objects.gd` — loads a real `.o` (`Map.pk2` object-placement) file through
`MapoReader` and renders a top-down scatter of every placed object's real world position, colored
by type ID, to disk. Doesn't resolve type IDs to real `.bsr` models — no mapping from a `.mapo`
type ID to a resource path has been found anywhere in this project's data (see
`docs/protocol/MAPO_FORMAT.md`), so this renders simple colored markers, not the actual scenery.

## Godot runs on the render box, never here

AGENTS.md's hard rule. `remote_godot.sh` ships the working copy to
`192.168.5.78` and runs the command there, so following it is one line:

```
client/tools/remote_godot.sh check     # every script and scene compiles
client/tools/remote_godot.sh tests     # all 59 *_test.gd suites
client/tools/remote_godot.sh script '--script res://tools/dump_layout.gd -- --pk2=... --file=ifinventory'
client/tools/remote_godot.sh sync      # ship the working copy, run nothing
```

`check` and `tests` run the import first, because `check_scripts.gd` cannot
tell a broken script from an unregistered `class_name` on a cold cache.

