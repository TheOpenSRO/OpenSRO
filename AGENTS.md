# Working on OpenSRO

A clean-room reimplementation of a Silkroad Online–style MMO: Godot 4.2.2 client, Go server. This
file is what an agent needs before touching anything. It is tool-neutral; `CLAUDE.md` imports it.

The project was called srrevamp until 2026-10-03 (round 704). Commits and tags from before then,
and any box directory or memory note not yet moved, still use that name; the code, the docs and
the `OPENSRO_*` variables use the new one (`docs/WORLD_ISSUES.md`, round 704).

## Hard rules

- **Never commit game data.** No `.pk2`, no extracted meshes, textures, or map files, not even as
  test fixtures. Users bring their own retail archives; the client reads them at runtime. See
  `docs/LEGAL.md`.
- **Never present a guessed value as a real one.** If a colour, offset, or timing was not read out
  of real data or recovered from the binary, either verify it or leave it out — and say which it
  is. Fabricated constants dressed as findings have cost this project more time than missing
  features.
- **Never run Godot on the host machine.** Godot is only run on the dedicated render/RE box (`192.168.10.78`, see `docs/RENDER_BOX.md`), never locally on the developer's machine.
- **Branch policy**: work on `dev`, never push to `main` directly. See `CONTRIBUTING.md`.

## Layout

| Path | What |
|---|---|
| `client/` | Godot 4 client. `scripts/World3D.gd` is the world; format readers live under `scripts/<format>/`. |
| `client/tools/` | Dev tools. **Read `client/tools/README.md` before waiting on any render.** |
| `server/` | Go server. `cmd/` holds analysis tools as well as the server itself. |
| `docs/HANDOFF.md` | **Picking up the world lane cold? Start here.** NPCs, format readers, terrain — and exactly where the last session stopped. |
| `docs/HANDOFF_OPENSRO.md` | **Setting up a new agent on this repo?** Machine setup, the three lanes and how not to collide, and the server lane's own work. |
| `docs/UI_TODO.md` | **The ordered list of UI work**, with the recipe for building a window from the client's own authored data. |
| `docs/HANDOFF_UI.md` | **Picking up the UI lane cold? Start here.** The HUD, the minimap, and the file split that keeps the two lanes from colliding. |
| `docs/TODO.md` | **The ordered list of what is left**, with the state of each parked item and the facts not to re-derive. Start here. |
| `docs/WORLD_ISSUES.md` | The running log. Every non-obvious finding is a numbered "round" with the evidence. **Read the last few rounds before starting; append one when you finish.** |
| `docs/protocol/` | Recovered file-format specs (`.bms`, `.bsr`, `.o`, `.o2`, `.m`, `.nvm`, …). |
| `docs/RENDER_BOX.md` | The machine renders and reverse-engineering run on: what lives where, how the GPU is wired, how to check it, how to revert it. |

## Looking at the world

This is the thing to get right, because it is where the time goes.

`client/tools/qa_shot.sh` runs the client against real archives, puts the player somewhere, frames
the camera, and collects frames. It drives the `OPENSRO_QA_*` hooks documented at the top of
`client/scripts/World3D.gd`:

| Hook | Answers |
|---|---|
| `QA_AT` / `QA_YAW` / `QA_PITCH` / `QA_DIST` | stand here, look this way |
| `QA_SHOTS` | **visit many viewpoints in one boot** |
| `QA_RADIUS` | load fewer regions |
| `QA_LOOK` | what is the camera pointing at, and what is nearby |
| `QA_HIDE` | switch individual meshes off in the built world |
| `QA_SCAN` | where would a player stand under the geometry |
| `QA_FLOAT` | what scenery sits off the ground |
| `QA_THROUGH` | which spans of a wall are actually open |
| `QA_ZONE` / `QA_NOUI` / `QA_NOFOG` / `QA_FREE` / `QA_WALK` | zone change, clean shots, movement |

**Batch the pictures.** Startup dominates: roughly 65 seconds of loading against 0.33 seconds a
frame. Six pictures as six runs pays that six times. Plan every viewpoint a question needs and
take them in one `--shots` run at the smallest `--radius` that covers them — six viewpoints this
way is ~116 seconds against ~9.5 minutes as six runs.

**Check the GL path.** The runner uses the GPU when it can and says so on stderr. A log saying
`falling back to software GL` means renders just got 5–10x slower; fix that before waiting on
anything. Forward+ is the default renderer from round 693. It runs on Vulkan through
`client/tools/xwl_run.sh`, because Xvfb cannot present Vulkan. The run's banner names the device;
`llvmpipe` there means the CPU (docs/RENDER_BOX.md, "Vulkan (Forward+)").

## Verifying claims

This project's characteristic failure is **concluding from a rendered image**. It has produced
wrong answers about fog distances, shadow-map polarity, blob-shadow blending, ground tiling, and
most recently "decorative blind arches" that turned out to be three open gateways. Every one was
settled later by measurement, and the measurement was cheap.

So: **a claim about the world needs a measurement, not a screenshot.** Read the mesh's own
triangles, fire a ray, count the texels, diff against the authored minimap. Screenshots are for
showing a human what happened, not for deciding what is true. If something can only be asserted
from a picture, say so explicitly.

When a negative result comes back, check the probe before believing it — a sweep that found "zero
openings anywhere" was fired at a height where the ground swallowed every ray.

## Performance: every world round runs the gate

`client/tools/perf_gate.sh` boots the working tree and its base at fixed views on the render box
(the Jangan spawn, the Dunhuang reeds, a walk across a region boundary; 1280x720) and compares
four numbers from the client's own log: **ms per frame, seconds to enter the world, the longest
freeze, and frames over 100 ms**. It exits 1 when the branch is clearly slower.

- **Run it before a round that changes the world or its drawing goes to review** (client world,
  map, object, terrain, effect, animation or loading code), and put its table in the round's
  WORLD_ISSUES entry. A UI-only, server-only or docs-only round skips it. The reviewer re-runs
  only `--sites jangan` (6 minutes), not all three views.
- **A slowdown is fixed in the round, or recorded with the numbers and taken to the user.** It is
  never left for the final review to find: round 645's review measured only the reeds at 320x180,
  the final review found +3.3 ms a frame at Jangan, and fixing it cost a new round and a new
  review, about 3.5 of that batch's 8.5 hours. The gate reports it as `SLOWER (+3.0)` in about
  6 minutes (`--base 8658370 --head c306c51 --sites jangan`).
- **The CPU is what lanes share, not the GPU or RAM** (measured with `amdgpu_top` and `vmstat`,
  2026-09-30). One render uses about 3.3 of the box's 10 cores and 17 % of the GPU; six at once
  put the CPU at 89 % busy with a run queue of 12, and ran 2.8x slower a frame, while the GPU
  averaged 37 % and never reached 90 %, and 11 GB of RAM stayed free. So a speed number taken
  while another lane runs Godot is noise: the gate waits until no other lane's Godot is running,
  repeats a run one overlapped, and gates in all lanes queue on one lock. Parallel lanes still
  finish more work than serial ones (six renders: 148 s at once against ~372 s one by one).
  `gpu_sample [seconds]` on the box logs the GPU once a second; `amdgpu_top` is the live view.

The whole run is about 15 minutes of box time (3 views x 3 runs x 2 builds); `--sites jangan` is 6.

## Commands

Commands running Godot are executed on the render box (`192.168.10.78`), not on the local machine:

```
godot4 --headless --path client --import --quit                 # compile check on render box (see traps)
godot4 --headless --path client --script res://scripts/nav/nav_graph_test.gd
godot4 --headless --path client --script res://scripts/nvm/nvm_water_test.gd
cd server && go build ./... && go test ./...
git tag -a vX.Y.Z -m "..." && git push origin vX.Y.Z            # builds and publishes the release
```

## Traps that have each cost hours

- **A clean `--import` is not proof scripts compile.** It has reported 0 errors while serving
  cached scripts; a real run then showed hundreds. Run something that actually executes the code.
- **GDScript typed inference**: `for d in [-1, 0]` then `var t := r + d` fails to infer. Write
  `var t: int = r + d`.
- **`pkill -f "<pattern>"` over ssh matches its own command line** and kills the shell. Match on
  something the invocation does not contain.
- **`/tmp` on the render box is tmpfs (RAM).** Frames written there once took the box out of
  memory. Use `/var/tmp`, and clean up.
- **Runs kill each other.** `qa_shot.sh` stops any running client before it starts. Wait for a run
  to finish — a "done" file plus no live process — before launching the next.
- **A full disk renders empty frames, silently.** The movie writer keeps producing 0-byte PNGs
  and the run reports success; 97 of one run's 169 frames came out empty that way. Frame dumps
  under `/var/tmp` are the usual cause and are all regenerable — delete old ones rather than
  keeping them. `qa_shot.sh` now warns below 2 GB free.

## Facts that were expensive to establish

Do not re-derive or contradict these without new evidence; each is recorded with its proof in
`docs/WORLD_ISSUES.md`.

- **Region axes**: region `y` → world X, region `x` → world Z. Confirmed twice, from terrain edge
  matching and independently from how the authored minimaps tile.
- **Region span** is 1920 units; local coordinates run `[0, 1920)`.
- **Minimap filename** is `minimap\<y>x<x>.ddj` — the reverse spelling names real but *wrong*
  regions.
- **Object placements resolve against Map.pk2's own `object.ifo`**, not Data.pk2's
  `navmesh\object.ifo`. The map's table has more entries and the extras are really referenced.
- **An object's yaw turns the other way in Godot: `rotation.y = -yaw`** (`NavGraph.godot_yaw`,
  used by both the rendered object and its navigation mesh). Read from the client's own navmesh
  loader (`MapLoader::FUN_0042b8b0` -> `FUN_0043cda0`, a row-vector Y rotation) and measured
  against the navmesh's linked edges (round 506). The positive yaw had every shop in Jangan facing
  away from its street, and a picture of a straight wall "confirmed" it.
- **`.o2` list 2** is a region's own objects; the other lists cross-reference objects belonging
  elsewhere, and drawing them duplicates region-straddling structures.
- **Jangan**: town is region 97/168 (square and dragon at local ~1002, 917), palace is 98/168
  directly **north**, farmland is 96/x. **Stand at the game's own spawn, local (1002, 1020)** —
  (1002, 917) is the dragon's pedestal, a solid 11.45 tall; `QA_AT` teleports without
  collision and puts a player *inside* it, which reads as "legs missing" (round 198).
