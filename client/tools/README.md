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
as six separate runs. Beside each, a `QA GRID <name> frame <n> at <x/y> local <lx>,<lz>: cells=..
queued=.. npc_regions=.. nav_graphs=.. navmesh=.. heightmaps=.. collisions=.. object_templates=..
objects=.. orphans=.. static_mem=..` line (round 563) names the region the player is standing in
and reads the region grid's bookkeeping (`RegionGridState`) and the process's object and memory
counts at that moment. A viewpoint's `x,z` are local to the region
under the player, so a spot just past its edge hops one region over -- `w@-30,1020` lands 30
units into the region to the west, `e@1950,1020` into the one to the east -- which is how a
boundary-crossing tour is taken in 28 ticks a hop instead of a 38-second walk: round 563's
`w1..w3@-30,1020;e1..e3@1950,1020` at `--radius 1` unloads 97/168 at the third hop and streams
it back in at the fifth, and its `region x/y unloaded` / `region x/y forgotten` / `NPC(s) placed
in x/y` lines are the measurement. `qa_shot.sh` runs no import, so a script that names a new
`class_name` needs one `remote_godot.sh check` (or `tests`) shipped first, or `World3D.gd` fails
to parse with `Identifier "..." not declared` (round 563 lost one run to it).

**A reconnect is a run, not a hand test.** `--reconnect <tick|drain>` leaves the world and
re-enters it in the same process -- the tester's "disconnect and reconnect without closing the
client", after which the ground came back white (round 558). Direct by default (World3D ->
World3D; until round 560 the route that isolated `World3D.gd`'s `static var` caches, which are
instance state since); `--reconnect-via-login` takes the
tester's route through Login and CharacterSelect, which sign back in with the QA account. Every
hook re-arms on the second entry, so `--shots` names each viewpoint once per entry, and each
entry prints a `QA ENTRY <n> loaded ...` line (renderer texture/buffer/video memory, object and
orphan counts, the world's ground/water/environment caches, its scenery template and texture
caches, the viewport's `debug_draw`, the fog and baked-light inputs)
and one `QA TEXPROBE <n> surface <i> ...` line per surface material of the centre cell's
terrain; a zone change's drain prints the same lines tagged `zone` (`QA ENTRY <n> zone loaded`),
so a count of `QA ENTRY <n> loaded` stays one per entry. What a second entry pays to decode its
own textures is on its `ground textures for <region> -- N ids, N resolved, D decoded now in M ms`
lines and its `water animation -- 30 of 30 frames decoded in M ms` line (round 560).
Measure, do not look: the lower 40% of the two `QA SHOT` frames from the same camera
(`convert f<n>.png -gravity south -crop 100%x40%+0+0 -format "%[fx:mean.r] %[fx:mean.g]
%[fx:mean.b]" info:`), pass 2 against pass 1's own mean, with >= 0.9 the "white" bound; the
`QA ENTRY` numbers of pass 2 against pass 1's; and `grep -c 'SCRIPT ERROR\|previously freed'`
split at the `QA RECONNECT` line. `--reconnect drain` fires while the entry's loading screen is
still up (the drop that lands on a tester mid-load); it needs the loading-screen drain, which
`--reconnect` exports (`SRREVAMP_QA_FORCE_LOADING=1`), and hides the HUD (`SRREVAMP_QA_NOUI=1`)
because the HUD sits in the measured band:

```
qa_shot.sh --out /var/tmp/reconnect --server --region '97\168.m' --radius 1 --frames 400 \
  --reconnect 200 --shots "square@1002,1020:0,-25,700"
```

### Load benchmark

Every map and loading change is measured on the two runs below, before and after, and on nothing
else. The numbers are log lines from `World3D.gd`'s `LoadTimings`
(`client/scripts/world/load_timings.gd`, round 561), never a frame.

**The metric is main-thread work time per frame, not `delta`.** `qa_shot.sh` always passes
`--write-movie`, and Godot's movie writer forces `--fixed-fps`, which "disables real-time
synchronization" (Godot 4.2, command line reference); `editor/movie_writer/fps` is 60 and the
project does not override it, so `_process`/`_physics_process` receive `delta` = 1/60 s on every
frame however long the frame took -- a hitch metric built on `delta` reads 16.7 ms for ever. The
wall clock is no better, because every movie frame pays the writer's readback and PNG (the 0.33 s
a frame above). So `World3D._physics_process` times its own step with `Time.get_ticks_usec()`,
each cell's build is timed around `_load_region_cell` (and the centre cell in
`_load_region_neighborhood`), and the two are summed per drawn frame. Three lines carry it:

- `World3D: cell 97/167 built in N ms at frame f (terrain T [read, parse, lightmap, tiletable,
  textures, mesh, collision, walls, water, navgraph], objects O [parse, own, templates, place],
  npcs P [tables])` -- one per cell as it is built. The three group totals are the stopwatches
  around the phases (the same numbers the `region grid loaded` split has summed since round 156);
  the bracketed sub-phases are laps inside them, and need not add up to the group (`collision` is
  `create_trimesh_shape` alone, round 156's bottleneck; the centre cell also has `env`, and
  `tiletable` and `tables` are cached after the first call, so only the centre's are non-zero).
- `World3D: region grid loaded in N ms (terrain T, objects O, npcs P) at frame f -- C cells S ms,
  D ms outside the cells over A awaited frames` -- the drain's total against the cells' own sum.
  **The check is `S <= N`, not equality**: under the loading screen (`SRREVAMP_QA_FORCE_LOADING=1`)
  `_ready` puts the screen up and awaits the frame that draws it before the centre cell (round
  562; the drain built it after the centre cell until then), the HUD is built between the centre
  cell and the drain, and the drain awaits a frame after every batch -- all of that is `D`, and
  `A` counts the screen's frame with the drain's own (`_ready` hands it on); on the synchronous
  QA path `D` is small. A sum above the total is a bug in the clock and the line says so. A batch is `LOADING_CELLS_PER_FRAME` = 2, but the frame builds three: the same frame's
  physics step runs `_process_stream_queue`, which pops `STREAM_CELLS_PER_FRAME` = 1 more from the
  same `_load_queue` (nothing gates it on the drain) -- the baseline's three `built in` lines a
  frame at frames 14-21. A later change to `LOADING_CELLS_PER_FRAME` alone changes two of the
  three; read the cells a frame from the log, not from the constant.
- `World3D: longest work frame W ms at frame f (cell x/y) over F frames since the last summary;
  p95 Q ms; H over 100 ms; longest wall gap G ms at frame f; run longest ...; grid C cells terrain T
  objects O npcs P ms` -- at the end of each drain, every 600 physics ticks (`_qa_step` runs for
  every player, so a real player's log carries it too) and when the world leaves the tree. A
  summary covers the window since the previous one, so the drain's summary is the
  entry and the tick-600 summary is the play after it (a crossing). 100 ms is a reporting bucket,
  not a game value. The wall gap carries the movie writer's floor: compare on the work column.
- `LoadingScreen: up at frame f (media reused|opened|none, N ms; backdrop decoded|missing, N ms;
  built in N ms)` -- the frame the "NOW LOADING" screen joined the tree in (drawn from the next
  one on), whether it read its backdrop through the Media.pk2 the world already held (`reused`,
  every login and teleport since round 562) or opened a reader of its own (`opened`, what every
  screen did before), what that open and the backdrop's decode cost, and the screen's whole
  build. Its place in the log is the entry's first check: it comes before the centre cell's
  `ground textures for` and `built in` lines, or the player watched a black window for the
  centre cell. `SRREVAMP_QA_NOUI=1` hides `$UI/Control`, which the screen is a child of, so a
  benchmark run's frames never show it; the log order is the measurement, and a run without
  `NOUI` shows the art from the first drawn frame after the line.

The two runs, verbatim, so before/after numbers come from identical commands. Both hide the HUD
and take the real awaiting drain (the QA path would build the whole grid in `_ready`, one frame);
both sign in to a server, so the entry is the player-shaped one. While the box lock is held by
round 558's orphaned run (2026-09-25), export `GODOT_LOCK=/var/tmp/<lane>/lock` first.

(a) Entry -- the 5x5 grid a player waits for:

```
SRREVAMP_QA_FORCE_LOADING=1 SRREVAMP_QA_NOUI=1 qa_shot.sh --out /var/tmp/loadbench --server \
  --region '97\168.m' --radius 2 --frames 200
```

(b) Crossing -- a walk west out of 97/168 into 97/167, so in-play streaming is measured too:

```
SRREVAMP_QA_FORCE_LOADING=1 SRREVAMP_QA_NOUI=1 qa_shot.sh --out /var/tmp/loadcross --server \
  --region '97\168.m' --radius 2 --at 120,1020 --walk 270 --frames 600
```

The start (120, 1020) was picked with `walk_probe.gd` (`--region=97/168 --from=120,1020
--heading=270 --steps=400`, round 561): open terrain at y 0.0 all the way past local x = 0 with no
wall contact, where (150, 1020) stands on `cj_armo` and meets a wall at x = 138. World heading 270
is local -x; at the character table's 50 units a second (`World3D.gd`, `_move_speed`) the edge is
2.4 s, 144 movie frames, in, so the new column streams well inside 600. Read the first
`NAV <tick>: footing settled on terrain at local x, z` line and the `QA 60 local x, y, z` line to
see where the walk really began (the roof-escape can move a start near a building; in the
baseline run tick 60 stood at local 71, 0, 1020 -- fifty units west of the start, as 50 a second
says), and take the crossing's longest frame from the tick-600 summary, not the drain's -- or from
the exit summary if no tick-600 summary printed: `_qa_tick` counts physics steps from `_ready` on,
less the frames `--at` waits for its region (`_qa_step`), so with `--frames 600` the tick-600
summary lands on the run's last frame or two (in the baseline, 576 frames after the drain's at
frame 23), and a run where it lands after `--quit-after` leaves the same window to `_exit_tree`'s
summary. To read a run:
`grep -E 'LoadingScreen: up|built in|region grid loaded|longest work frame|footing settled|^QA +[0-9]+ local' <run>.log`.
The BEFORE for the whole map/loading epic (round 561, 2026-09-25, hardware GL, the commands
above; the full lines and the per-phase sums are in `docs/RE_COMPLETION.md`, round 561):

```
(a) cell 97/168 built in 5373 ms at frame 13 (terrain 1609 [.. tiletable 944, navgraph 212 ..],
        objects 2093 [.. own 319, templates 1670 ..], npcs 1671 [tables 925])   -- the centre
    24 neighbours 231..1120 ms, mean 417, three a frame at frames 14-21 (2 drain + 1 stream)
    region grid loaded in 22752 ms (terrain 7996, objects 5037, npcs 2355) at frame 22
        -- 25 cells 15388 ms, 7364 ms outside the cells over 9 awaited frames
    longest work frame 5374 ms at frame 13 (cell 97/168); p95 2844 ms; 9 over 100 ms
    in play (exit summary, 177 frames): longest work frame 6 ms; p95 6 ms; wall gap 368 ms
        standing at the server's spawn: QA 60 local 960, -32, 960 on object cj_jang_gate at -32.6
(b) longest work frame 328 ms at frame 162 (cell 98/165) over 576 frames; p95 5 ms;
        5 over 100 ms; longest wall gap 723 ms   -- the tick-600 summary; the column
        95..99/165 streamed one cell a frame at frames 160-164, 270..323 ms each
```

AFTER round 562 (the screen before the centre cell, on the archive the world already holds; the
same command, the same box, 2026-09-25; `docs/RE_COMPLETION.md`, round 562, has the full lines and
the frame measurements of a run with the HUD shown):

```
(a) LoadingScreen: up at frame 13 (media reused, 0 ms; backdrop decoded, 674 ms; built in 676 ms)
    cell 97/168 built in 5200 ms at frame 14 (terrain 1575 [.. tiletable 937, navgraph 195 ..],
        objects 1951 [.. own 323, templates 1532 ..], npcs 1673 [tables 939])   -- the centre,
        the frame after the screen's
    24 neighbours three a frame at frames 15-22 (2 drain + 1 stream)
    region grid loaded in 22884 ms (terrain 8004, objects 5015, npcs 2347) at frame 23
        -- 25 cells 15365 ms, 7519 ms outside the cells over 10 awaited frames
    longest work frame 5259 ms at frame 14 (cell 97/168); p95 2919 ms; 9 over 100 ms
    in play (exit summary, 176 frames): longest work frame 7 ms; p95 6 ms; wall gap 366 ms
(b) not re-run: nothing in play changed.
```

The tenth awaited frame is the one `_drain_initial_load` now draws after the centre cell and
before its first batch (the gauge's first tick, which counts the centre): without it round 562's
first run had the first two neighbours in the centre's frame and the longest work frame read
7,506 ms for a 5,234 ms centre cell. The centre cell is what the next rounds are measured on, so
a change that merges it with a batch would show here as a regression and later as an improvement
without either being one; read the cells a frame from the log when the longest frame moves.

Rules the later, off-thread loading items are held to, kept beside the benchmark so the two
travel together: (1) nothing that owns a Node or a RenderingServer/PhysicsServer RID
(`MeshInstance3D`, `StaticBody3D`, `ArrayMesh`, `Shape3D`, `Material`, `ImageTexture`) is
constructed off the main thread -- a prepare job produces plain data (bytes, parsed structs,
arrays) and a main-thread commit builds the objects; (2) `Pk2Reader` is not thread-safe and
neither is the scene tree -- a job gets its own reader or a snapshot of what it reads, and reaches
the tree only through `call_deferred`; (3) the QA-drain contract: a QA run (`SRREVAMP_MAPM_PATH`
set, no `SRREVAMP_QA_FORCE_LOADING`) must still have every cell committed before its first shot,
so a threaded loader's synchronous branch waits for its jobs and commits before
`_drain_initial_load` returns -- `--shots`, `--radius` and the movie writer keep their contract.

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

`probe_monster_front.gd` — measures which way each roster monster's body faces in the space its
skeleton is placed in: the mean toe-minus-foot bone vector and the head-minus-pelvis offset, at the
bind pose and at the walk clip's first frame, with the player's body (`CHAR_CH_MAN_FIGHTER`, local
-Z) as the control -- the run counts only if its last line says the control reads -Z. It resolves
each species the way World3D does (by code, then by display name) and prints one `MODEL <bsr>
<front>` line per model; those are `MonsterMotion.FRONT_BY_MODEL`. Headless, renders nothing; ship
the working copy first (`script` does not sync):
`client/tools/remote_godot.sh sync && client/tools/remote_godot.sh script res://tools/probe_monster_front.gd -- --pk2=/opt/sro-files/client/Data.pk2 --media=/opt/sro-files/client/Media.pk2`.
Written for round 533, where all seven roster models read -Z.

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
client/tools/remote_godot.sh tests     # every *_test.gd (discovered, not listed)
client/tools/remote_godot.sh script '--script res://tools/dump_layout.gd -- --pk2=... --file=ifinventory'
client/tools/remote_godot.sh sync      # ship the working copy, run nothing
```

`check` and `tests` run the import first, because `check_scripts.gd` cannot
tell a broken script from an unregistered `class_name` on a cold cache.

`tests` marks a suite failed on a `FAIL` line, a `Parse Error`, or a
`SCRIPT ERROR` -- Godot's line for a GDScript runtime error (a call on a
freed instance, a script that failed to compile). Such an error aborts only
the function it happened in and lets the suite go on to `ALL PASS`, so
until round 556 a suite could pass while a script errored (round 522 saw
`hud_window_test.gd` do it on every run; round 551's freed-panel negative
printed the error and `ALL PASS` in one output). The `at:` line under the
error is printed with it. `ERROR:` does not fail a suite: readers
`push_error` on the bad input their negative cases feed them (20 of 85
suites in round 556's audit), and the dummy renderer reports leaked RIDs
at exit (3 more: `character_assembler`, `monster_assembler`, `hud_window`).
A suite that errors in `_init` before its `quit()` does not fail;
it hangs, because the run never ends -- put the checks in a callee, or
reach a method through `has_method`/`call` so a missing one FAILS instead.

