# Working on srrevamp

A clean-room reimplementation of a Silkroad Online–style MMO: Godot 4.2.2 client, Go server. This
file is what an agent needs before touching anything. It is tool-neutral; `CLAUDE.md` imports it.

## Hard rules

- **Never commit game data.** No `.pk2`, no extracted meshes, textures, or map files, not even as
  test fixtures. Users bring their own retail archives; the client reads them at runtime. See
  `docs/LEGAL.md`.
- **Never present a guessed value as a real one.** If a colour, offset, or timing was not read out
  of real data or recovered from the binary, either verify it or leave it out — and say which it
  is. Fabricated constants dressed as findings have cost this project more time than missing
  features.
- **Branch policy**: work on `dev`, never push to `main` directly. See `CONTRIBUTING.md`.

## Layout

| Path | What |
|---|---|
| `client/` | Godot 4 client. `scripts/World3D.gd` is the world; format readers live under `scripts/<format>/`. |
| `client/tools/` | Dev tools. **Read `client/tools/README.md` before waiting on any render.** |
| `server/` | Go server. `cmd/` holds analysis tools as well as the server itself. |
| `docs/HANDOFF.md` | **Picking up the world lane cold? Start here.** NPCs, format readers, terrain — and exactly where the last session stopped. |
| `docs/HANDOFF_UI.md` | **Picking up the UI lane cold? Start here.** The HUD, the minimap, and the file split that keeps the two lanes from colliding. |
| `docs/TODO.md` | **The ordered list of what is left**, with the state of each parked item and the facts not to re-derive. Start here. |
| `docs/WORLD_ISSUES.md` | The running log. Every non-obvious finding is a numbered "round" with the evidence. **Read the last few rounds before starting; append one when you finish.** |
| `docs/protocol/` | Recovered file-format specs (`.bms`, `.bsr`, `.o`, `.o2`, `.m`, `.nvm`, …). |
| `docs/RENDER_BOX.md` | The machine renders and reverse-engineering run on: what lives where, how the GPU is wired, how to check it, how to revert it. |

## Looking at the world

This is the thing to get right, because it is where the time goes.

`client/tools/qa_shot.sh` runs the client against real archives, puts the player somewhere, frames
the camera, and collects frames. It drives the `SRREVAMP_QA_*` hooks documented at the top of
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
anything.

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

## Commands

```
godot4 --headless --path client --import --quit                 # compile check (see traps)
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
- **`.o2` list 2** is a region's own objects; the other lists cross-reference objects belonging
  elsewhere, and drawing them duplicates region-straddling structures.
- **Jangan**: town is region 97/168 (square and dragon at local ~1002, 917), palace is 98/168
  directly **north**, farmland is 96/x.
