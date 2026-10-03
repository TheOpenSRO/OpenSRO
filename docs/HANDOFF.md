# Handoff: current state of the work

For an agent picking up the **world lane** cold — NPCs, format readers, terrain, object placement.
A second agent is working the **UI lane** in parallel (`docs/HANDOFF_UI.md`); the file split that
keeps the two apart is in that document's "Do not collide" section, and the short version is that
the UI is moving out of `World3D.gd` into `client/scripts/ui/`. Expect that file to shrink under
you, and rebase rather than fight it.

This document says what the world lane is working on, exactly where the last session stopped, and
what to do next. It is a snapshot, not a spec — when it disagrees with `docs/TODO.md` or
`docs/WORLD_ISSUES.md`, those are newer and win.

**Last updated**: 2026-09-08, at commit `c475885` on `dev`.

## Read these first, in this order

1. **`AGENTS.md`** (repo root) — the hard rules, the layout, how to look at the world, and the
   traps that have each cost hours. Non-optional. `CLAUDE.md` just imports it.
2. **`docs/TODO.md`** — the ordered list of what is left, plus a "do not re-derive" section of
   facts that were expensive to establish.
3. **`docs/WORLD_ISSUES.md`, last two or three rounds** — the running log. Every non-obvious
   finding is a numbered round with its evidence. The newest sits at the top of the descending
   block (`grep -nE "^## Two-hundred"`); as of 2026-09-19 it is the 213th. **Append a new round
   when you finish something**; that is the project's memory.
5. **`docs/protocol/NAVMESH_MOVEMENT.md`** before touching how the player moves — the client's
   own walk (recovered from the binary, round 213): a character is on the terrain or on exactly
   one object, entered only through a doorway edge; nothing is inferred from height. Do not put
   height-guessed footing back.
4. **`docs/RENDER_BOX.md`** and **`client/tools/README.md`** — the machine renders run on, and how
   to take a picture without waiting ten minutes for one.

## The two rules that matter most

These are in `AGENTS.md` but bear repeating, because breaking them is how this project has lost
the most time.

**Never present a guessed value as a real one.** If a colour, offset, or timing was not read out
of real data or recovered from the binary, either verify it or leave it out — and say which it is.

**A claim about the world needs a measurement, not a screenshot.** This project's characteristic
failure is concluding from a rendered image; it has produced wrong answers that way about fog
distances, shadow-map polarity, ground tiling, and "decorative blind arches" that turned out to be
three open gateways. Read the mesh's triangles, fire a ray, count the texels. Screenshots are for
showing a human what happened, not for deciding what is true. And when a negative result comes
back, check the probe before believing it — a sweep that found "zero openings anywhere" was fired
at a height where the ground swallowed every ray.

A corollary that came up twice in the last few sessions: **measure the thing you are claiming
about.** One wrong conclusion ("the skeleton has no root bone") came from measuring `BskReader`'s
bone list instead of the `Skeleton3D` that was actually built from it.

## What is being worked on: NPCs

Item 1 in `docs/TODO.md`. The reference server has named NPCs standing in town (`Grocery Trader
Jinjin`, `Magic POP Guide Gori`, arena managers); this project renders none, and they are most of
what makes a town look inhabited.

### What is already solved — do not redo this

**Spawn data.** A server pack's `SR_GameRefData\npcpos.txt` is UTF-16LE, tab-separated: *NPC id,
region id, X, Y, Z*. The region id is the same `(x << 8) | y` key already used for navmesh
filenames, so `25257` reads as region 98/169. `CharacterData*.txt` maps the id to a code name and
a model — id `2023` is `NPC_CH_PRIEST` → `npc\npc\chinaquest_priest.bsr`. Plain tables, nothing to
reverse engineer.

**The model format.** An NPC is a *character*, not scenery: its `.bsr` carries mesh pieces, a
`.bsk` skeleton and `.ban` animations. The `uint16` at `0x40` is an authored object type —
**1 character, 2 building, 4 nature** — and the header's offset table at `0x0C` addresses a
material, mesh, skeleton and animation section, each count-prefixed. `BsrReader` (GDScript) and
`server/internal/bsr` (Go) both read type 1 through that table now, and both assert the sections
chain (each ends exactly where the header says the next begins), falling back to the old scan if
they don't. Full details in `docs/protocol/BSR_FORMAT.md`.

**Assembly.** `client/scripts/assets/skinned_bsr_assembler.gd` takes an open `Pk2Reader` and a
`.bsr` path and returns a `Skeleton3D` with every mesh piece attached and materials applied. It
needs nothing supplied from outside — the `.bsr` names its own skeleton. The piece-to-bone mapping
is computed (nearest bone bind position to the piece's vertex centroid), which reproduces the two
hand-derived dictionaries in `MonsterAssembler` exactly, 10/10 pieces.

### Exactly where the last session stopped

`SkinnedBsrAssembler` is written, compiles, and passes the suite — **and has never been drawn**.
Nothing has rendered an NPC yet.

The next concrete task is a render tool, `client/tools/render_npc.gd`, modelled on the existing
`client/tools/render_character.gd`: open the archive, call
`SkinnedBsrAssembler.assemble_from_archive`, frame a camera on the skeleton's bind-pose bounds,
and save a PNG. `render_character.gd` already has the camera/light/environment setup to copy — it
frames from the bone global-pose bounds, which works here too.

Run it the way that file's header says (real GL context, no `--headless`):

```
xvfb-run -a vglrun -d egl0 godot4 --path client --rendering-driver opengl3 \
  --script res://tools/render_npc.gd -- \
  --pk2=/opt/sro-files/client/Data.pk2 \
  --model="npc\npc\chinaquest_priest.bsr" --out=/var/tmp/priest.png
```

**The question that render answers**: does the priest read as a person standing up, or as
scattered pieces? If scattered, the thing to check is *not* the bone mapping — in the bind pose
`attach_rigid` cancels the bone's rest transform, so every piece lands at the absolute coordinates
baked into its vertices regardless of which bone it hangs from. It would mean something is wrong
in the skeleton build or the piece transforms instead.

After that, in order: resolve an NPC's model path from `CharacterData`, spawn from `npcpos.txt`
into the region grid (the server already streams a monster list the client renders, so NPCs can
follow that path), then wire `.ban` playback.

## Known limits of what just landed — do not mistake these for bugs to "fix" blindly

**The bone mapping is an approximation under animation.** In the bind pose it affects nothing. It
only matters once the skeleton animates, and there a humanoid whose lower body is one 400-vertex
piece hangs off whichever single bone that piece's centroid sits nearest, so animating that bone
swings the whole piece. This is inherent: `.bms` carries no per-vertex skinning data at all
(settled in `docs/protocol/BMS_FORMAT.md`, with the full 44-byte vertex record accounted for), so
rigid per-piece attachment is what the real client must do too. Adequate for NPCs standing in a
town. Do not go looking for bone weights in `.bms`; that ground is covered.

**Every multi-piece building draws one piece twice.** Real, measured, and deliberately left
unfixed: `cj_monstad_door01.bsr` yields 17 mesh references for 16 distinct meshes. A building
(type 2) carries a duplicate reference to its first piece *ahead of* its header-declared mesh
section, and the scan-based reader takes that as the primary while also reading the real section
as sub-meshes. Type 2 chains exactly the way type 1 does, so routing it through the header table
fixes it — but it wants a sweep over every `.bsr` in `Data.pk2` comparing old and new results
before it lands, and it was kept away from the NPC work on purpose. Type 4 (nature) is *not*
pinned down and should stay on the scanner: its mesh entries carry a trailing `uint32` per piece
that types 1 and 2 don't, and its animation section doesn't chain consistently.

## Tools you will want

All under `client/tools/`. Each has a header comment with full usage; these are the ones relevant
to the current work.

| Tool | What it answers |
|---|---|
| `qa_shot.sh` | **The way to look at the world.** Batch viewpoints with `--shots`; see below. |
| `dump_bsr.gd` | A `.bsr`'s real structure — every string with its offset, *and the raw words in the gaps*. The gaps are the point: a list count in front of a run of strings is invisible if you only print the strings. |
| `check_npc_models.gd` | Whether a model loads at all: pieces, vertices, bounds, and whether the `.bsr` gave up its skeleton and animations. |
| `check_piece_bones.gd` | The computed piece-to-bone mapping and the distance each was decided by; checks itself against the two hand-derived maps. |
| `render_character.gd` | Renders a `.bsk` + loose body-part `.bms` files. The template for `render_npc.gd`. |

**Batch your pictures.** Startup dominates: ~65 seconds of loading against ~0.33 seconds a frame.
Six pictures as six runs pays that six times. Plan every viewpoint a question needs and take them
in one `--shots` run at the smallest `--radius` that covers them — six viewpoints this way is ~116
seconds against ~9.5 minutes.

**Check the GL path.** The runner says on stderr which it took. `falling back to software GL`
means renders just got 5–10× slower; fix that before waiting on anything.

## The render box

`192.168.10.78`, reachable as `root` over ssh. `docs/RENDER_BOX.md` is authoritative; the short
version:

| Path | What |
|---|---|
| `/opt/sro-files/client/` | Real archives — `Data.pk2`, `Map.pk2`, `Media.pk2`, plus `sro_client.exe` byte-identical to the image in Ghidra |
| `/opt/opensro-client/` | A checkout the tools run against. **There is no `rsync` on this box** — use `scp` per file. |
| `/opt/opensro-server/` | Go checkout; `go` is at `/usr/bin/go` |
| `/opt/godot-bin/Godot_v4.2.2-stable_linux.x86_64` | The engine. Set `GODOT_SILENCE_ROOT_WARNING=1`. |

Ghidra with the client loaded is on the same box, reachable through the `mcp__ghidra__*` tools.
Use it — the standing instruction from the user is *"stay true to form and review ghidra if need
be"*, and it has repeatedly been the difference between an authored fact and an invented
threshold. One concrete example: an attempt to detect cutout foliage by inventing texel-statistics
thresholds was replaced, on that instruction, by finding the actual authored `.bmt` flag bit.

**Do not take down `192.168.5.121`.** `192.168.5.120` is expendable per the user, and Ghidra
should be preserved on `.78`.

### Traps specific to this box

- **`pkill -f "<pattern>"` over ssh matches its own command line** and kills the shell (exit 255).
  Match on something the invocation does not contain.
- **`/tmp` there is tmpfs, i.e. RAM, in an 8 GB container.** Frames written there once filled it
  to 6.9 GB and wedged the box so hard sshd could not complete a handshake. Write to `/var/tmp/`
  and clean up.
- **Runs kill each other.** `qa_shot.sh` stops any running client before it starts. Wait for both
  a "done" file *and* no live process before launching the next.
- **`fs.protected_regular`** blocks root overwriting ghidra-owned files in sticky `/var/tmp` —
  `rm -f` first.

## Verifying before you commit

```
godot4 --headless --path client --import --quit     # then run something that executes the code
for t in $(find client/scripts -name '*_test.gd'); do
  godot4 --headless --path client --script "res://${t#client/}" || echo "FAILED $t"
done
cd server && go build ./... && go test ./...
```

**A clean `--import` is not proof scripts compile.** It has reported 0 errors while serving cached
scripts, and a real run then showed hundreds. Always execute something. Also note a new
`class_name` is not visible to other scripts until after an `--import`.

**GDScript typed inference**: `for d in [-1, 0]` then `var t := r + d` fails to infer — write
`var t: int = r + d`. Same for `var x := some_func()` when the function returns an untyped
`Array`/`null` union; use `var x = ...`.

**Keep the two readers in sync.** Several formats are parsed twice, in GDScript under
`client/scripts/<format>/` and in Go under `server/internal/<format>/`. A format change belongs in
both, with tests on both sides, in the same commit.

Work on `dev`, never push to `main`. Commit messages end with the co-author and session trailers
already used throughout the log.
