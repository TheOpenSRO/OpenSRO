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
`_load_region_neighborhood`), and the two are summed per drawn frame. Nothing else counts as
work: the loading screen's own build (`LoadingScreen: up ... built in N ms`, 672-711 ms across
round 562's three runs) and the HUD's (`_try_initialize_pk2_ui`) run in `_ready` between physics
steps, so neither reaches `longest work frame` -- they are part of `D` below, and the screen's
cost is read from its own line. Three lines carry it:

- `World3D: cell 97/167 built in N ms at frame f (terrain T [...], objects O [...], npcs P
  [tables])` -- one per cell as it is built. The three group totals are
  the stopwatches around the phases (the same numbers the `region grid loaded` split has summed
  since round 156) and are **main-thread time only**; the bracketed sub-phases are laps inside
  them, and need not add up to the group. Since round 565 a region's terrain is a job built on the
  main thread (`_terrain_job`: the one-time tables and a snapshot of the caches), a *prepare*
  (`_terrain_prepare`: plain data) and a *commit* (`_terrain_commit`: everything that owns an RID
  or touches the tree), and the terrain list has two shapes:
  - a cell built on the main thread -- the grid's centre, always, and every cell under
    `SRREVAMP_SYNC_LOAD=1` -- lists all three halves in order: `terrain T [tiletable, objindex,
    snapshot, read, parse, env, lightmap, textures, mesh, faces, navmesh, walls, navgraph,
    images, upload, setup, collision, wallshape, water, graph]` (`env` the centre's alone;
    `tiletable` and `objindex` are cached after the first call, so only the centre's are
    non-zero);
  - a streamed neighbour (the default) lists the commit alone as its terrain and the prepare after
    the groups, off the main thread: `terrain T [images, upload, setup, collision, wallshape,
    water, graph], objects O [...], npcs P [...]; off the main thread: terrain P [read, parse,
    lightmap, textures, mesh, faces, navmesh, walls, navgraph]`. The off-thread figure is the
    task's own time and is **never** in `built in`, in a frame's work or in the `terrain` group
    totals; the job's snapshot ran between cells and is in no cell.

  Since round 566 the objects are split the same way -- `_objects_job` (main thread: the object
  index and a snapshot of the templates held, the textures uploaded and the heightmaps parsed),
  `_objects_prepare` (plain data: `ObjectLoader.prepare_object` per model) and `_objects_commit`
  -- and prepare on the same task, after the terrain (`_cell_prepare`). The objects list has the
  same two shapes: on the main thread `objects O [snapshot, parse, own, models, textures,
  templates, place]`; streamed, `objects O [textures, templates, place]` with `; off the main
  thread: terrain P [...], objects Q [parse, own, models]` after the groups (a lap with nothing to
  do is left out: a cell whose models the world already holds has no `templates`, one with no
  `.o` stops after `parse`). The objects line of a streamed cell (`World3D: loaded N/M real map
  objects from ...`) ends `-- prepared off the main thread, dispatched at frame f; K template(s)
  built unprepared`: K counts the templates the commit had to build whole on the main thread
  (one released or evicted between the dispatch and the commit), and is 0 when the prepare
  covered them all.

  What the laps are: `read`/`parse` the `.m`; `lightmap` the `.t` decoded to an Image; `textures`
  the ground tiles this world does not hold yet decoded to Images; `mesh` the surfaces as arrays;
  `faces` the collision face list (`MapmTerrainBuilder.surface_faces`, what
  `create_trimesh_shape()` used to read back out of the mesh); `navmesh` the `.nvm` read and
  parsed; `walls` the wall triangles; `navgraph` the object navigation meshes and
  `NavGraph.build`; then `images` the ImageTexture uploads; `upload` the ArrayMesh and its
  materials; `setup` the group, the untextured material, the placement and the nodes (round 564's
  lap); `collision` the `ConcavePolygonShape3D.set_faces` alone (round 156's bottleneck, now
  without the readback); `wallshape` the walls' shape and body; `water`; `graph` the walkable
  graph's registration. The objects': `snapshot` the job's; `parse` the `.o` and `.o2` read,
  parsed, merged and de-duplicated; `own` the placement-ownership test, whose neighbour heightmaps
  it reads and parses under Pk2Reader's lock when the grid does not hold them; `models`
  `ObjectLoader.prepare_object` for every model the world holds no template for (the `.bsr`,
  `.bms`, `.bmt` parsed, the mesh arrays and trimesh faces built, the textures decoded to Images
  and their alpha classified on them); then `textures` the ImageTexture uploads; `templates`
  `ObjectLoader.commit_object` (the ArrayMeshes, materials, shapes and nodes of each new
  template, or a whole unprepared build); `place` the container, and each placement's duplicate,
  transform and add. Every stopwatch is a lap (round 564's rule, held by `load_timings_test.gd`
  for both groups), so the laps cover each group less each lap's whole-ms truncation; outside
  them are only the path check before the job, the log lines the commit prints first, and its
  closing print, unmeasured.
- `World3D: region grid loaded in N ms (terrain T, objects O, npcs P) at frame f -- C cells S ms,
  D ms outside the cells over A awaited frames` -- the drain's total against the cells' own sum.
  **The check is `S <= N`, not equality**: under the loading screen (`SRREVAMP_QA_FORCE_LOADING=1`)
  `_ready` puts the screen up and awaits the frame that draws it before the centre cell (round
  562; the drain built it after the centre cell until then), the HUD is built between the centre
  cell and the drain, and the drain awaits a frame after every batch -- all of that is `D`, and
  `A` counts the screen's frame with the drain's own (`_ready` hands it on); on the synchronous
  QA path `D` is small. A sum above the total is a bug in the clock and the line says so. Since
  round 565 the line ends `; terrain X ms prepared off the main thread` when cells prepared on
  tasks -- not in the split or in `S`, which are the main thread's. Cells a frame under the
  screen: threaded (the default), the drain is the only pump while it runs and commits at most
  `LOADING_CELLS_PER_FRAME` = 2 prepared cells a frame, as many as have finished preparing
  (`TERRAIN_JOBS_IN_FLIGHT` = 2 prepare at once). Under `SRREVAMP_SYNC_LOAD=1` it is the
  pre-round-565 schedule: a batch is `LOADING_CELLS_PER_FRAME` = 2, but the frame builds three --
  the same frame's physics step runs `_process_stream_queue`, which pops `STREAM_CELLS_PER_FRAME`
  = 1 more from the same `_load_queue` -- the baseline's three `built in` lines a frame at frames
  14-21. Read the cells a frame from the log, not from the constants.
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

AFTER round 565 (a streamed cell's terrain prepared on a worker thread, committed on the main
thread), against BASE re-measured the same day on the same box -- round 561's BEFORE predates
rounds 562-563 (`docs/RE_COMPLETION.md`, round 565, has the full lines):

```
(a) BASE   cell 97/168 built in 5202 ms at frame 13; three cells a frame at 14-21
           region grid loaded in 22726 ms (terrain 7961, objects 4890, npcs 2331) at frame 22
               -- 25 cells 15181 ms, 7545 ms outside the cells over 10 awaited frames
           longest work frame 5265 ms at frame 13 (cell 97/168); p95 2841 ms; 9 over 100 ms
    565    cell 97/168 built in 5245 ms at frame 14 (synchronous by design); two a frame at 15-26
           region grid loaded in 19711 ms (terrain 2873, objects 5182, npcs 2375) at frame 27
               -- 25 cells 10430 ms, 9281 ms outside the cells over 14 awaited frames;
               terrain 5809 ms prepared off the main thread
           longest work frame 5306 ms at frame 14 (cell 97/168); p95 1772 ms; 13 over 100 ms
(b) BASE   95..99/165: 304, 304, 328, 271, 291 ms at frames 161-165 (terrain 231-262 each)
           longest work frame 334 ms at frame 163 (cell 98/165) over 575 frames; 5 over 100 ms
    565    95..99/165: 105, 127, 123, 73, 69 ms at frames 162-166 (terrain 39-44 each, and
               202-227 ms prepared off the main thread)
           longest work frame 144 ms at frame 163 (cell 96/165) over 570 frames; 3 over 100 ms
```

With `SRREVAMP_SYNC_LOAD=1` the same crossing command reads the old schedule back -- three cells a
frame under the screen, the column one a frame at 245-308 ms, `longest work frame 314 ms`.

AFTER round 566 (a streamed cell's objects prepared on the same task as its terrain, committed on
the main thread; the SHIPPED code, whose pump commits a finished cell before it dispatches the
next), against BASE (round 565's code) re-measured the same day on the same box
(`docs/RE_COMPLETION.md`, round 566, has the full lines and the per-phase sums). Until round 566's
second review this block held the first write's run, which dispatched first (crossing 112 ms,
entry p95 1025 ms):

```
(a) BASE   cell 97/168 built in 5208 ms at frame 14 (objects 1974 [.. own 308, templates 1573 ..])
           region grid loaded in 19795 ms (terrain 2810, objects 5346, npcs 2361) at frame 27
               -- 25 cells 10517 ms, 9278 ms outside the cells over 14 awaited frames;
               terrain 5795 ms prepared off the main thread
           longest work frame 5269 ms at frame 14 (cell 97/168); p95 1848 ms; 13 over 100 ms
    566    cell 97/168 built in 5073 ms at frame 13 (objects 1796 [.. own 318, models 1322,
               textures 6, templates 55 ..]; synchronous by design)
           region grid loaded in 18078 ms (terrain 2756, objects 2268, npcs 2434) at frame 29
               -- 25 cells 7457 ms, 10621 ms outside the cells over 17 awaited frames;
               terrain 5916 ms prepared off the main thread; objects 2869 ms prepared off the
               main thread
           longest work frame 5134 ms at frame 13 (cell 97/168); p95 990 ms; 8 over 100 ms
(b) BASE   95..99/165: 108, 123, 123, 70, 69 ms at frames 161-165 (objects 65, 83, 42, 30, 26)
           longest work frame 140 ms at frame 163 (cell 98/165) over 571 frames; 3 over 100 ms
    566    95..99/165: 50, 46, 87, 51, 49 ms at frames 159-163 (objects 11, 7, 11, 10, 5 on the main
               thread; 14-91 ms prepared off it)
           longest work frame 118 ms at frame 161 (cell 98/165) over 571 frames; 1 over 100 ms
```

An earlier run of the same shipped order (the review fix's, before the counter was corrected):
crossing `longest work frame 109 ms at frame 164 (cell 98/165)`, entry p95 947 ms, 7 over 100 ms.

The review fix of round 566 (`_pump_cell_jobs` commits a finished cell before it dispatches the
next; the `prepared again` line counts what a task prepared that another commit had cached),
dispatch-first (A, as first written) against finish-first (B), the same instrumented code, one run
each. Re-run by the second review fix with the corrected count (the first counter took textures a
job only NAMED from its snapshot for decoded ones, and the objects' `here` heightmap for one they
read; its A/B totals, 103 -> 66 and 145 -> 84, are withdrawn):

```
(a) A      region grid loaded in 17858 ms (terrain 2846, objects 2303, npcs 2510) at frame 29
               -- 25 cells 7659 ms, 10199 ms outside the cells over 16 awaited frames
           longest work frame 5090 ms at frame 14 (cell 97/168); p95 954 ms; 13 over 100 ms
           prepared again over the 24 streamed cells: 10 tiles, 8 object navmeshes, 2 heightmaps,
               16 models, 31 object textures (67); `decoded now` sum 58
    B      region grid loaded in 18078 ms (terrain 2756, objects 2268, npcs 2434) at frame 29
               -- 25 cells 7457 ms, 10621 ms outside the cells over 17 awaited frames
           longest work frame 5134 ms at frame 13 (cell 97/168); p95 990 ms; 8 over 100 ms
           prepared again: 3 tiles, 4 object navmeshes, 1 heightmap, 7 models, 13 object textures
               (28); `decoded now` sum 51
(b) A      95..99/165: 53, 51, 94, 49, 49 ms; longest work frame 114 ms at frame 164 (cell 98/165)
               prepared again over 29 streamed cells: 102
    B      95..99/165: 50, 46, 87, 51, 49 ms; longest work frame 118 ms at frame 161 (cell 98/165)
               prepared again: 32
```

The first pair (same code but the counter) read (b) 111 -> 109 ms and (a) p95 1004 -> 947 ms: at
one run each the order's effect on those frames is inside the run-to-run spread.

Alpha probes in the load path (`SRREVAMP_QA_ALPHA_LOG=1` on command (a); BASE through a throwaway
copy that prints the same line at each of its three `get_image()` probe sites): **0 before and 0
after** -- every layer of every material the 25 cells build is decided by its flag word
(`ObjectLoader.LAYER_FLAG_MASK`), so the readback path was never reached here. Forced with
`SRREVAMP_QA_MATS=1` as a control (every solid textured material then consults its fraction):
690 probes before, all texture readbacks; 690 after, 0 readbacks (449 on decoded Images, 241
statistics measured earlier), the same 341 texture/statistic pairs consulted the same number of
times and the same 52 `QA MAT` lines. 327 pairs read identically; 14 differ by at most 0.0002 of
a fraction, and 6 of those gave two values across the readback's own consults while the Image
gives one -- the readback is the unsteady side (none is near a threshold: 0.05 cuts, 0.20
reports).

Rules the off-thread loading items are held to, kept beside the benchmark so the two travel
together. Round 565 (terrain) implements them, and round 566 (objects) holds to them too.

1. **The prepare-thread rule.** A prepare constructs NO Node and NO RID-owning Resource --
   no `MeshInstance3D`, `StaticBody3D`, `ArrayMesh`, `Material`, `ImageTexture` or `Shape3D`;
   Images, packed arrays, Arrays, Dictionaries and the readers' RefCounted structs only -- touches
   neither the scene tree nor the RenderingServer nor the PhysicsServer, and prints nothing (its
   lines go in the job; the commit prints them in order). A main-thread commit builds the objects.
   World3D's `_terrain_prepare` is static, so it cannot reach the node's state;
   `terrain_prepare_test.gd` walks a prepared job and fails on any Node or Resource in it other
   than an Image. Round 566: `_objects_prepare` and `_cell_prepare` are static too, and
   `ObjectLoader.prepare_object` writes nothing static (what `_missing` would report and the QA
   lines go in its result, for `commit_object` to report); `objects_prepare_test.gd` and
   `object_loader_test.gd` walk the same way. No texture is read back to decide a material's
   alpha: the probes measure the Image the texture is uploaded from (`ObjectLoader._alpha_stat`),
   and `SRREVAMP_QA_ALPHA_LOG=1` prints one `QA ALPHA:` line per probe consulted -- the count of
   alpha probes in the load path, each saying it came from the decoded Image or from a statistic
   measured earlier.
2. **Reads and caches.** The scene tree is not thread-safe, and `Pk2Reader` was not until round
   565: one handle shares one `FileAccess` (a read is a seek then a get_buffer) and one directory
   cache, and it now takes a per-handle lock around both (`pk2_reader_test.gd` runs 4 tasks x 200
   concurrent reads). Every World3D cache a prepare consults is snapshotted into its job on the
   main thread before dispatch (`_terrain_job`: ground tiles by filename and a decoded flag, never
   the texture; the region's cached navmesh; a copy of the object navigation meshes;
   `_objects_job`, round 566: the template paths held, the uploaded textures by key, fourCC and
   measured alpha statistics, never the texture, and the heightmaps the grid holds), and the
   commit merges what the prepare read back into the caches, keeping an entry another commit
   cached first. `_pump_cell_jobs` commits a finished cell BEFORE it dispatches the next (round
   566's review; it dispatched first until then), so the next snapshot holds what that commit
   cached. Each committed streamed cell prints `World3D: cell x/y prepared again what an earlier
   commit had cached -- N ground tile(s), N navmesh(es), N object navigation mesh(es), N
   heightmap(s) the objects read, N model(s), N object texture(s) decoded` (`_prepared_again`,
   counted before its commit merges anything): what its task read or built that a commit landing
   after its snapshot had already cached, so it was thrown away -- a texture only if the task
   decoded it (one its snapshot held is named, not decoded, and not counted), a heightmap only if
   the objects read it (not the region's own, taken from the terrain prepare's parse). It can stay
   above zero: a job cannot see what the job preparing beside it will commit (the entry's 24
   cells: 28 finish-first, 67 when the pump dispatched first; `docs/RE_COMPLETION.md`, round
   566). The placement-ownership test's
   neighbour heightmaps are READ ON THE TASK, under the lock, not pre-parsed on the main thread:
   their parse is most of the `own` lap, which pre-parsing would put back in the frame.
3. **The QA-drain contract.** A QA run (`SRREVAMP_MAPM_PATH` set, no `SRREVAMP_QA_FORCE_LOADING`)
   must still have every cell committed before its first shot, so `_drain_initial_load`'s QA branch
   dispatches, waits for each task (`WorkerThreadPool.wait_for_task_completion`) and commits
   before it returns -- `--shots`, `--radius` and the movie writer keep their contract.
4. **Stale jobs.** A prepared cell is committed only if it is still wanted (not loaded meanwhile,
   still inside the player's window -- else `cell x/y prepared but not committed -- <why>`), and
   a zone change, a new grid and the world leaving the tree wait for every task still running
   and drop it (`N cell(s) still preparing dropped (<why>) -- waited M ms`), so a reconnect cannot
   commit into a freed world.

`SRREVAMP_SYNC_LOAD=1` is the escape hatch for one release after round 565: every cell's terrain
and (round 566) objects are prepared and committed on the main thread on the pre-round-565
schedule (above), for a tester to fall back to or compare against. It restores the SCHEDULE
only, not the old code: the terrain still runs `_terrain_prepare` then `_terrain_commit` with
the faces `MapmTerrainBuilder.surface_faces` builds, and the objects `_objects_prepare` then
`_objects_commit`, through the split `ObjectLoader` (`prepare_object` then `commit_object`) and
the trimesh faces `ObjectLoader._piece_faces` builds -- back to back on the main thread. The
grid's centre is built on the main thread either way -- its height anchors every neighbour and
its environment lights them.

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

