# SRRevamp

A from-scratch, clean-room reimplementation of a Silkroad Online–style MMO client and server.

See [docs/LEGAL.md](docs/LEGAL.md) for the full policy.

## Layout

- `client/` — Godot 4 client. Loads user-supplied `*.pk2` archives at runtime; ships with none.
- `server/` — Go server (world/login/gateway services).
- `docs/` — architecture, protocol notes, decomp/RE tracking log.

## Running locally

**Docker Compose** (server + Postgres, no local Go/Postgres install needed):

```
docker compose up --build
```

Server listens on `localhost:15779` (plain TCP by default). Postgres data persists in a named
volume across restarts; `docker compose down -v` wipes it for a clean slate. Requires a Docker
host that can actually run containers — an LXC container needs nesting enabled for this to work.

**Without Docker** (needs a local Postgres at `localhost:5432`, user/pass `postgres`/`postgres`,
databases `srrevamp` + `srrevamp_test`):

```
cd server
go run ./cmd/server
```

Either way, then open `client/` in the Godot 4.2 editor (or `godot4 --path client`) — it boots to
the login screen and connects to `127.0.0.1:15779` by default (see `client/scripts/Login.gd`).
Log in, pick a character, and hit "3D View" in the World HUD to walk around in 3D.

**Optional — see real game assets in the 3D view**: this project ships with no game data (BYO,
see `docs/LEGAL.md`). If you have your own real Silkroad client files, set these environment
variables before launching the client to have `World3D.tscn` load and place them live (see
`client/scripts/World3D.gd`):
- `SRREVAMP_PK2_PATH` + `SRREVAMP_BSR_PATH` — a pk2 archive and a `.bsr` path inside it, loaded
  as real, textured scenery via `ObjectLoader`.
- `SRREVAMP_BSK_PATH` + `SRREVAMP_BAN_PATH` — a real `.bsk` skeleton and `.ban` animation (loose
  files, not inside a pk2 — see `docs/protocol/BSK_FORMAT.md`), built into a real, live-animated
  `Skeleton3D` via `Skeleton3DBuilder`.

Leave any of them unset and that piece is skipped — the scene works fine with none of them set.

Run the test suites from `server/` (`go test ./...`, needs the same local Postgres) and `client/`
(`godot4 --headless --path . --script res://scripts/net/<name>_test.gd` for each file, or see
`.github/workflows/ci.yml` for the full list CI runs).

## Branching

- `main` — protected, production. Requires PR + passing CI. Repo admins can bypass (force push)
  when truly necessary.
- `dev` — integration branch, default target for feature branches and day-to-day work.

## Status

Server-side protocol (accounts, characters, world/chat, combat/loot, inventory/equipment, shop,
quests, party/guild, duels, trade, friends) is implemented and tested end-to-end, with a matching
2D client HUD (`client/scenes/World.tscn`) wired to all of it. This is genuinely playable today:
`docker compose up --build` (or a local Postgres + `go run ./cmd/server`) plus opening `client/`
in Godot gets you a real login → character select → 2D world loop against a real server.

There's now also a first real 3D scene (`client/scenes/World3D.tscn`, reachable from the 2D HUD
via a "3D View" button): a `CharacterBody3D` player with WASD movement and a third-person camera,
synced to the server over the same movement protocol the 2D client already decoded but never
sent or rendered anything for — see `docs/PROGRESS.md` for that finding. Other connected
characters render as labeled capsules at their real, server-authoritative positions (placeholder
primitives on purpose — no real character/ground assets wired in yet). **Verified against the
real running stack**: the full connect → register → login → create character → enter world flow,
and two concurrent real client instances genuinely seeing each other enter and move in real time,
both confirmed by actually running the Go server + client together, not just unit tests.

3D asset formats are reverse-engineered and have real, tested readers on both sides
(`server/internal/{pk2,bsr,bms,ddj,bmt,ban,bsk,mapo,mapm,efp}` in Go,
`client/scripts/{pk2,bsr,bms,ddj,bmt,ban,bsk,mapo,mapm,efp}` in GDScript) — **every container
format found so far has at least a working reader**, 10 total: the pk2 archive container, `.bsr` composite "static object" descriptors, `.bms` mesh
geometry, `.ddj` textures (a thin wrapper around standard DDS), `.bmt` materials (zlib-compressed
color + texture-reference layers — decompressed with a from-scratch pure-GDScript DEFLATE decoder,
`client/scripts/bmt/inflate.gd`, after Godot's own built-in decompressor was confirmed to fail on
real zlib streams that a standard library decodes correctly), `.ban` bone-animation data
(quaternion + position keyframes per named bone), `.bsk` skeleton/bone-hierarchy data (the
parent-bone references `.ban` itself lacks), and `.o` (`Map.pk2`'s per-region object-placement
list — type ID + world position for everything placed in a map region).

All of this has been verified against real extracted game archives, not just synthetic
fixtures — including an actual rendered screenshot (real mesh + real DXT3 texture from
`Particles.pk2`, decoded and displayed correctly by this project's own readers, no engine-native
DDS/model import involved).

`client/scripts/assets/object_loader.gd` ties all of them together end-to-end: given an open pk2
archive and a `.bsr` path, it resolves every mesh piece, its material, and that material's
texture, and returns a real, renderable, **textured** Godot `Node3D`/`MeshInstance3D` tree —
verified against a full synthetic pk2 archive exercising the whole pk2→bsr→bms→bmt→ddj chain, not
just parser-level unit tests. `.bsr` sub-mesh pieces need no extra per-part transform — confirmed
against two real sub-mesh pieces of the same object, each already carries its own absolute
position baked into its vertex data. `.bsk` (bone hierarchy — the piece `.ban` itself lacks) is
also reverse-engineered and has real, tested readers on both sides (`server/internal/bsk`,
`client/scripts/bsk/bsk_reader.gd`) — **fully cracked**, verified against 8 real files spanning
two structurally different skeleton styles (a mirrored-decoration rig, and the common real-world
"3ds Max Biped" naming convention used by real creature/character rigs, `Bip01`, `Bip01 Pelvis`,
...), every one parsed to complete, exact end-of-file consumption. `client/tools/render_skeleton.gd`
renders a real `.bsk` file's bone hierarchy to a screenshot — run against a real 66-bone Biped
creature skeleton, it produces a genuinely recognizable humanoid figure with correctly
left/right-mirrored arms (including individual fingers) and legs.
`client/tools/render_skeleton_animated.gd` goes further: applies a real `.ban` animation's
rotation to a real `.bsk` bone chain via basic forward kinematics and renders bind-pose vs.
animated-pose screenshots, showing real, visible movement driven by real keyframe data. That
bind-pose/FK logic is now real, tested library code —
`client/scripts/assets/skeleton_pose.gd` (`SkeletonPose`) — not just inline in the dev tools.
There's also a real engine-backed version now: `client/scripts/assets/skeleton3d_builder.gd`
(`Skeleton3DBuilder`) builds an actual Godot `Skeleton3D` from a parsed `.bsk` skeleton and drives
it with real `.ban` keyframe rotations through `Skeleton3D`'s own pose-hierarchy propagation
(verified to reproduce the exact same result as the manual FK math) —
`client/tools/render_skeleton3d_animated.gd` is its dev-tool counterpart, run against the same
real data with the same visible-movement result.

`.o` (`Map.pk2`'s per-region object-placement list — very likely where a `.bsr` object's real
world position lives, since `.bsr` itself has none) is now also reverse-engineered and has real,
tested readers on both sides (`server/internal/mapo`, `client/scripts/mapo/mapo_reader.gd`),
verified against 11 real map regions: type ID + world position recovered correctly across all of
them (up to 11 distinct object types seen), including a real bug found and fixed via that broader
cross-check — some regions use a header 2 bytes narrower than originally assumed, which silently
produced zero recovered objects until fixed to scan for the real boundary instead of trusting a
fixed offset. Rotation doesn't appear to be present in any recovered field yet — open question,
see `docs/protocol/MAPO_FORMAT.md`. `client/tools/render_map_objects.gd` renders a real region's
placements as a top-down scatter (colored markers standing in for real models, since no
type-ID-to-`.bsr` mapping has been found) — run against a real 95-object region, it shows a
genuinely sensible spatial layout, not noise.

`.m` (`Map.pk2` terrain/heightmap) also now has a real, working reader on both sides
(`server/internal/mapm`, `client/scripts/mapm/mapm_reader.gd`) — a real-looking elevation float
per tile, recovered via the same plausibility-based resync scan `.mapo` needed for its
variable-length records. Cross-checked against 10 real files pulled from `Map.pk2`, which turned
out to use **two different tile record shapes** depending on region file-size class; both readers
auto-detect which one applies (try every shape/offset combination in a small window, keep
whichever produces the longest run of plausible tiles) rather than assuming one. All 10 real files
now parse to ~100% completion, including 2 that were originally thought to hit a genuine
unreadable section partway through — that turned out to be a wrong conclusion, corrected after
further investigation found real tile data resumes past a wider-than-expected (up to 509-byte)
gap; the resync bound was widened accordingly, and both files now recover their full tile counts.
**The grid width is now confirmed**: one of Shape A's two `uint16` fields was found to be a real
per-tile column index (increments by a fixed step, wraps after exactly 17 values, in every real
file checked) — not a statistical guess, a directly observed field. This mechanistically confirms
a periodicity signal this project had recorded but explicitly distrusted across several earlier
sessions. The matching row field is real and structured but doesn't decode cleanly across a whole
file yet — still an open question. See `docs/protocol/MAPM_FORMAT.md` for the honest detail, and
`client/scripts/assets/mapm_terrain_builder.gd` for the real terrain mesh this unblocked.

`.efp` (particle-effect definitions — structurally a self-describing, nested, tagged property
system rather than a fixed record, closer to a small serialization format than a struct) now also
has a real, tested reader on both sides (`server/internal/efp`, `client/scripts/efp/efp_reader.gd`),
parsing all 30 real files sampled from `Particles.pk2` without error. It recovers a **flat**
sequence of every `(name, value)` pair in a file rather than the format's true nested tree — the
value-boundary-finding technique doesn't need to know the tree structure to find where each
property's raw bytes end, so nothing is lost data-wise, but parent/child relationships between
properties aren't reconstructed. See `docs/protocol/EFP_FORMAT.md` for what that tradeoff means
and what a deeper future pass would need.

`World3D.tscn` now loads real `.bsr` scenery (via `ObjectLoader`) and a real, live-animated
`Skeleton3D` (via `Skeleton3DBuilder`) if pointed at real game data through environment variables
(see "Running locally" above) — the same pipelines previously only exercised by standalone
`client/tools/` screenshots are now live in the actual playable scene.

The player's own body is no longer a bare skeleton or a placeholder capsule: setting just
`SRREVAMP_PK2_PATH` auto-loads a real assembled character — a real `.bsk` skeleton with real
body-part `.bms` meshes rigidly attached via `client/scripts/assets/character_assembler.gd`
(`CharacterAssembler`), textured with the character's actual real skin texture (resolved from a
real `.bmt`/`.ddj` pair, matched to each body part by its own `material_name` field — see
`docs/protocol/BMT_FORMAT.md`). This settled a real open question: `.bms` was confirmed to carry
**no per-vertex bone-weight/skinning data at all** (the entire 44-byte vertex record is fully
accounted for), and real character meshes instead bake both left and right sides of each paired
body part into one file as mirrored triangle ranges — see `docs/protocol/BMS_FORMAT.md`. This is a
fixed default body (always the same China-man), not real per-account race/gender selection — see
"Not yet done" below. Fixing the real texture also surfaced and fixed a real bug: live-client
`.bmt` files (as opposed to the patch-staging-tree samples originally checked) are stored
**uncompressed**, not zlib-wrapped — both `BmtReader` and `server/internal/bmt` now detect and
handle both real variants.

Other connected players still render as labeled capsules, and a bare *decoration* `Skeleton3D`
(loaded separately via `SRREVAMP_BSK_PATH`/`SRREVAMP_BAN_PATH`, not the player's own body) still
renders with joint/bone debug visualization, not a real mesh — see "Not yet done" below.

The ground is no longer just a placeholder box either: setting `SRREVAMP_MAPM_PATH` (+ its own
`SRREVAMP_MAP_PK2_PATH`, since `Map.pk2` is a separate archive from `Data.pk2` in a real retail
install) loads a real `Map.pk2` region's real elevation data and builds a real triangulated
terrain mesh via `client/scripts/assets/mapm_terrain_builder.gd` (`MapmTerrainBuilder`), replacing
the placeholder's *visual* mesh (not yet its collision shape — see "Not yet done"). Verified
against a real region file: 12417 real tiles in, 584 complete real rows recovered and rendered as
genuine undulating terrain the player stands on, not a flat box.

Not yet done: real terrain collision (the visual mesh is real now, but the ground's collision
shape is still the flat placeholder box) and confirmed real-world terrain positioning/scale
relative to a player's actual spawn coordinate (currently placed for visibility, not accuracy); a
newly-found, entirely unparsed real file type (`Map.pk2` region folders also contain a `.t` file,
magic `JMXVMAPT1001` — not mesh-shaped data, not yet decoded); no automatic asset selection for
*other* players or map objects (nothing maps a server-side character or a `.mapo` type ID to a
real asset path — see `docs/protocol/MAPO_FORMAT.md` — so only the local player's own body
auto-loads; everyone/everything else still needs manual environment variables or shows a
placeholder); and no real equipment/armor rendering (the assembled character is bare-skinned, not
wearing the weapons/armor real screenshots show — no equipment-to-mesh mapping has been
investigated yet). That's the current focus (see `docs/PROGRESS.md`). The material-layer-to-
mesh-piece pairing when a `.bmt` has multiple layers and no name match is available is still a
documented, unconfirmed heuristic (pairs by index when counts match, used by `ObjectLoader` for
`.bsr` scenery); `.efp`'s nested tree structure (see above). See
`docs/protocol/{PK2,BSR,BMS,DDJ,BMT,BAN,BSK,MAPO,MAPM,EFP}_FORMAT.md` and `docs/PROGRESS.md` for
the detailed running log.
