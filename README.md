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
- `SRREVAMP_PK2_PATH` — a real pk2 archive (e.g. `Data.pk2`). On its own, this auto-loads a real
  assembled, textured player character (see "Status" below).
- `SRREVAMP_PK2_PATH` + `SRREVAMP_BSR_PATH` — also loads a real, textured static scenery object
  (a `.bsr` path inside the archive) via `ObjectLoader`.
- `SRREVAMP_BSK_PATH` + `SRREVAMP_BAN_PATH` — a real `.bsk` skeleton and `.ban` animation (either
  loose files or paths inside `SRREVAMP_PK2_PATH` — see `AssetSource`), built into a real,
  live-animated decoration `Skeleton3D` via `Skeleton3DBuilder`.
- `SRREVAMP_MAP_PK2_PATH` + `SRREVAMP_MAPM_PATH` — `Map.pk2` (a separate archive from `Data.pk2`
  in a real retail install) and a region `.m` path inside it (e.g. `100\100.m`), loaded as real
  terrain via `MapmTerrainBuilder`.
- `SRREVAMP_MEDIA_PK2_PATH` + `SRREVAMP_MAPM_TEXTURE_PATH` — `Media.pk2` (a third separate
  archive) and a real per-region minimap image inside it (e.g. `minimap\100x100.ddj`, matching the
  same region number as `SRREVAMP_MAPM_PATH`), textures that terrain with real, region-accurate
  art instead of the procedural per-tile color fallback.
- `SRREVAMP_MAPO_PATH` — a real `Map.pk2` region's `.o` object-placement file (via
  `SRREVAMP_MAP_PK2_PATH`, e.g. `0\0.o`), rendered with each placement's real resolved `.bsr`
  model (via `SRREVAMP_PK2_PATH`'s `Data.pk2` and a real object-index table — see "Status" below).

Leave any of them unset and that piece is skipped — the scene works fine with none of them set.

**Finding real asset paths in your own pk2 files**: `go run ./cmd/pk2list -pk2 "<path>"` (from
`server/`) lists every real file path inside a real pk2 archive, optionally filtered by substring
(`-filter grass`) — useful for finding real texture/mesh paths this project doesn't already have a
sample of to reverse-engineer against, without needing to send the archive itself anywhere. A
directory can span multiple chained blocks (a real mechanism found by decompiling the actual
client's directory-read code, not guessed — see `docs/protocol/PK2_FORMAT.md`); both readers follow
it, confirmed against a real 3.8GB `Data.pk2` whose file count went from 41 to 73139 once the fix
landed.

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
position baked into its vertex data. Multi-piece objects now get their real per-piece material
correctly, too: each real sub-mesh's own `material_name` field (the same one character body parts
carry) is matched against the material's real layer names first — confirmed by pulling a real
27-piece building (`bagh_city_palace.bsr`) and its real 28-layer material and checking 4 real
pieces directly, all matching — falling back to the old index-based guess only when no name
matches. `.bsk` (bone hierarchy — the piece `.ban` itself lacks) is
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

Equipment now uses a real, decompiler-confirmed 8-slot layout instead of an earlier own-design
single catch-all "armor" slot: searching `sro_client.exe` for equip-related strings turned up a
real literal debug-print block naming 8 real slots in a real confirmed order — `HELM`, `MAIL`,
`SHOULDERGUARD`, `PANTS`, `BOOTS`, `WEAPON`, `SHIELD`, `EXTRA` — each reading from its own real,
fixed struct offset in the same real function. Five of those map directly, by real-world meaning,
to the bone-slot codes `CharacterAssembler` already uses for rendering (`ha`→`HELM`, `ba`→`MAIL`,
`sa`→`SHOULDERGUARD`, `la`→`PANTS`, `fa`→`BOOTS`) — see `docs/protocol/EQUIP_SLOTS.md` for the
full derivation, including the one real bone code (`aa`, forearms) that has no confirmed real slot
name of its own and renders alongside `MAIL` instead. `server/internal/equipment.Slot` now has one
constant per real confirmed slot, and a character can genuinely mix pieces — equip just a real helm
with nothing else, for instance — instead of the old all-or-nothing bundle. The 2D equipment HUD
(`World.tscn`) exposes this via a real slot picker (`OptionButton`), mirroring the gender picker's
pattern.

Whether each real armor piece actually shows is gated on the player's actual,
server-authoritative per-slot equip state via the same `EquipmentNet` protocol the 2D equipment
HUD uses (`World3D.gd`'s `_real_player_equipped_slots()`), queried on world entry. A newly-created
character has nothing equipped, so it renders bare-skinned until the player actually equips real
pieces — and renders exactly the pieces actually equipped, not a fixed bundle. The armor meshes
themselves are still a fixed set per gender (one arbitrary real pick among many found, see below),
not real per-account item variety. Skips the query entirely (defaults to nothing equipped, not a
hang) when there's no live server connection — e.g. the standalone dev-tool/screenshot contexts
used throughout this project's asset work.

The player wears real armor pieces from a real, full 6-piece per-gender set
(`Prim/Mesh/Item/China/{man,woman}_item/clothes_03_{aa,ba,fa,ha,la,sa}.bms` — arm/body/foot/head/
leg/shoulder) that attaches via `CharacterAssembler.assemble_equipment`, the same rigid-attachment
mechanism as the body, textured the same real name-matched way. Which slots are genuinely paired
(mirrored L/R in one file) vs. single-piece was determined by a real triangle-centroid-X gap scan
on the actual files, not a guess — see `docs/PROGRESS.md`.

Other connected players are real assembled characters too now, not just labeled capsules, each
rendering their own real per-account `Gender` (China Man or China Woman — see above), not a single
shared fixed body. Their armor pieces and weapon are genuinely per-player too: the server
broadcasts each entity's real, live per-slot equip state as part of `OpEnterWorldResult`/
`OpEntityEntered` (`EntitySnapshot.ArmorSlotsMask`/`HasWeapon`, queried fresh from
`server/internal/equipment` at broadcast time, not cached) — verified with a real, live two-client
test over actual TCP (`TestWorldFullFlow`): one character with a real armor piece equipped but no
weapon, one with a real weapon equipped but no armor, and both the initial world snapshot and the
live entity-entered broadcast carry the correct real per-piece flags for each. The
character/equipment assets are parsed and cached once at scene startup and reused to build one
independent `Skeleton3D` per connected player — see `World3D.gd`'s `_build_assembled_character()`.
Falls back to the labeled capsule if the shared assets never loaded. A bare *decoration*
`Skeleton3D` (loaded separately via `SRREVAMP_BSK_PATH`/`SRREVAMP_BAN_PATH`, not any player's body)
still renders with joint/bone debug visualization, not a real mesh — see "Not yet done" below.

Equipped armor now actually matters in combat, not just cosmetically: each real piece's item-data
`PhysDefenseMax` is summed across whatever's equipped in `equipment.ArmorSlots` and subtracted from
incoming damage (a monster's counterattack, or an opponent's hit in a duel), floored at 1 so armor
can reduce a hit but never negate it entirely — see `server/internal/session/combat.go`'s
`defenderArmor` and `docs/PROGRESS.md`.

The player also wields a real weapon now, gated the same honest way as armor: a real one-handed
blade (`Prim/Mesh/Item/China/weapon/blade_01.bms`, an arbitrary fixed pick among many real numbered
weapons found, faction-wide rather than per-gender — `Prim\Mesh\Item\China\weapon\` has no man/
woman split, unlike body/armor meshes) attaches to a real, directly-confirmed hand bone
(`CharacterAssembler.WEAPON_BONE`, "Bip01 R Hand" — found by pulling a real skeleton and locating
that exact bone name string, not assumed from the naming convention) via the same rigid-attachment
mechanism as body parts and armor. Textured the same real name-matched way: a real `blade_01.bms`'s
own `material_name` field ("blade1_5") matches a real layer inside a real `blade1_5.bmt`. Only
shows once the player's account actually has something equipped in `SLOT_WEAPON` — a newly-created
character renders bare-handed, same as bare-skinned for armor. Rendered and verified against real
pulled data (real 37-bone skeleton, real weapon mesh, real material layer match confirmed).

A real off-hand shield renders the same way: real, faction-wide shield item meshes exist under the
same real weapon folder (`Prim/Mesh/Item/China/weapon/shield_11.bms`, an arbitrary fixed pick among
many real numbered shields found) and attach to a second real, directly-confirmed bone
(`CharacterAssembler.SHIELD_BONE`, "Bip01 L Hand" — the off-hand counterpart to the weapon's "Bip01
R Hand", found the same direct way). Textured the same real name-matched way
(`shield_11.bms`'s `material_name` matches a real layer in `shield_11.bmt`). Gated on real
`SLOT_SHIELD` equip state, broadcast per-player the same way as armor and weapon.

The ground is no longer just a placeholder box either: setting `SRREVAMP_MAPM_PATH` (+ its own
`SRREVAMP_MAP_PK2_PATH`, since `Map.pk2` is a separate archive from `Data.pk2` in a real retail
install) loads a real `Map.pk2` region's real elevation data and builds a real triangulated
terrain mesh via `client/scripts/assets/mapm_terrain_builder.gd` (`MapmTerrainBuilder`), replacing
both the placeholder's visual mesh and its collision shape (the latter built straight from the
same real triangle data — see below). Verified
against a real region file: 12417 real tiles in, 584 complete real rows recovered and rendered as
genuine undulating terrain the player stands on, not a flat box. It's also texturable with real
game art: `SRREVAMP_MAPM_TEXTURE_PATH` + `SRREVAMP_MEDIA_PK2_PATH` load a real per-region minimap
image (`Media.pk2\minimap\<region>.ddj`) and apply it, tiled, as the terrain's real texture —
found via `server/cmd/pk2list` after no live 3D ground-texture system could be confirmed anywhere
in this project's available real data (every real terrain shader found samples one continuous
color texture, not a multi-layer type blend — see `docs/protocol/MAPM_FORMAT.md`). It's real,
region-accurate painted art, not confirmed to be the literal thing the game's terrain shaders
sample at runtime — but it looks like the real game instead of a flat or procedural color. Falls
back to real per-tile vertex-color variation (driven by an already-decoded real per-tile byte) if
no texture is set.

Real placed objects have automatic asset selection now too: `SRREVAMP_MAPO_PATH` (a real `Map.pk2`
region's `.o` file, via `SRREVAMP_MAP_PK2_PATH`) resolves each real placement's type ID through a
real object-index table (`object.ifo`, root level in `Data.pk2`, magic `JMXVOBJI1000` — a real,
plain-text table this project had previously called a confirmed dead end, found once the pk2
directory-chain bug above was fixed) and renders it with its real `.bsr` model — see
`server/internal/objidx`/`client/scripts/objidx/objidx_reader.gd` and
`docs/protocol/MAPO_FORMAT.md`. Both real building-category (`res\bldg\...`) and nature-category
(`res\nature\...`, trees/grass) objects render correctly — the latter needed a real fix to
`server/internal/bsr`/`client/scripts/bsr/bsr_reader.gd`, which had only ever been tested against
building-category files: nature-category `.bsr` files genuinely order their mesh/material/
bounding-box fields differently, not a corrupt file — see `docs/protocol/BSR_FORMAT.md`.
Real-world placement scale/position relative to a player's actual spawn coordinate isn't confirmed
yet (same honest caveat as terrain above).

Terrain and placed objects have been verified rendering together, from the same real region, not
just each in isolation: `100/100`'s real `.m` terrain (13211 tiles) and real `.o` placements
(58 objects, resolving to 4 distinct real `.bsr` models) load into the same `World3D` scene at
once and produce a genuinely recognizable establishing view — real textured ground and a real
tree with bark texture together in frame. Repeat placements of the same real model are cached and
`duplicate()`d rather than re-parsed (`_try_load_real_map_objects` in `World3D.gd`), since real
regions turn out to reuse very few distinct models across many placements.

Real terrain collision is wired up too: whenever `SRREVAMP_MAPM_PATH` loads real terrain, the
ground's collision shape is rebuilt from that same real triangle data (`Mesh.create_trimesh_shape()`
on the exact `ArrayMesh` `MapmTerrainBuilder` produced — no separate collision geometry to keep in
sync), replacing the flat placeholder box. Verified against a real region: the player capsule
rests directly on the real terrain surface with a real cast shadow, not floating above it or
clipping through, confirmed visually via a headless render.

Real per-account gender selection is now in too: at character creation, a real `OptionButton`
(`CharacterSelect.tscn`) lets a player choose China Man or China Woman — the only two real,
RE-confirmed options this project's available client data has *complete* parallel body/skeleton/
armor asset sets for (China-woman's real forearm mesh is named differently, `woman_arm_fore` vs.
China-man's `man_arm_lower`, but both real skeletons share the same real `Bip01 R/L Forearm`
bones — confirmed directly, not assumed, and aliased in `CharacterAssembler.BODY_PART_BONES`). A
real race check (Europe) was also done: its skeletons exist in this project's available client
data but its base body meshes don't, so Europe stays out of scope rather than being
half-implemented. The choice is stored server-side (`character.Gender`) and broadcast to every
peer (`EnterWorldResult.Gender`/`EntitySnapshot.Gender`, live-looked-up per broadcast — see
`server/internal/session/world.go`'s `genderOf`), so other players now see each character's real
chosen body too, not just the local player. Verified with a real, live two-client TCP test
(`TestWorldFullFlow`) asserting the real gender propagates correctly both ways, a direct real
material-name-match check (pulled `woman_thigh.bms`/`chinawoman_warrior.bmt`, confirmed the same
name-matching `CharacterAssembler` already relies on works for this gender too), and an actual
rendered screenshot: a real China-woman skeleton plus real pelvis/thigh meshes assembled and
rendered via `client/tools/render_character.gd`, showing two correctly mirrored legs attached to
a real 39-bone skeleton — see `docs/PROGRESS.md`.

Not yet done: confirmed real-world terrain/object
positioning/scale relative to a player's actual spawn coordinate (currently placed for visibility,
not accuracy); a newly-found, entirely unparsed real file type (`Map.pk2` region folders also
contain a `.t` file, magic `JMXVMAPT1001`, with a real byte pattern consistent with a texture
blend/weight map — a real, previously-investigated RE gap this project couldn't fully close, see
`docs/protocol/MAPM_FORMAT.md`). That's the current focus (see `docs/PROGRESS.md`). `.efp`'s
nested tree structure (see above). See
`docs/protocol/{PK2,BSR,BMS,DDJ,BMT,BAN,BSK,MAPO,MAPM,EFP}_FORMAT.md` and `docs/PROGRESS.md` for
the detailed running log.
