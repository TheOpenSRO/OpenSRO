# SRRevamp

A from-scratch, clean-room reimplementation of a Silkroad Online–style MMO client and server.

See [docs/LEGAL.md](docs/LEGAL.md) for the full policy.

## Layout

- `client/` — Godot 4 client. Loads user-supplied `*.pk2` archives at runtime; ships with none.
- `server/` — Go server (world/login/gateway services).
- `docs/` — architecture, protocol notes, decomp/RE tracking log.

Working on this with an AI agent? Start at [AGENTS.md](AGENTS.md) — it covers how to look at the
world without waiting ten minutes for a screenshot, which claims need measuring rather than
eyeballing, and the traps that have each cost this project hours.

## Downloading a pre-built client

Every tagged release publishes ready-to-run Windows and Linux client builds under
[GitHub Releases](../../releases) — no Godot install needed.

1. Download and unzip `srrevamp-windows.zip` (or `srrevamp-linux.zip`).
2. Copy your own real Silkroad Online client's `*.pk2` files (`Data.pk2`, `Map.pk2`, `Media.pk2` —
   BYO game assets, see [docs/LEGAL.md](docs/LEGAL.md)) into the `pk2` folder sitting next to the
   executable. No environment variables or config editing needed — the client looks in that folder
   automatically (see `Pk2Config` in `client/scripts/assets/pk2_config.gd`).
3. Run the executable. On boot it checks GitHub Releases for a newer tagged build and offers an
   opt-in update (never applied silently) before continuing to the login screen — see
   `client/scripts/update/auto_updater.gd`. At login, type the server's address (`host` or
   `host:port`, defaults to `127.0.0.1:15779`) into the "Server IP[:port]" field — useful for
   connecting to a friend's server on the same LAN instead of your own machine.

**Controls**: WASD/arrow keys walk directly, or left-click a spot on the ground to walk there.
Right-click-drag orbits the camera around your character; the scroll wheel zooms. Press **F10** (or
the "Hide UI" button, top-right) to hide the HUD for a clean view.

**If something looks wrong**: the client always writes a log file, printed once at startup (look
for a line like `SRRevamp log file: <path>`) — Windows: `%APPDATA%\Godot\app_userdata\SRRevamp\
logs\srrevamp.log`, Linux: `~/.local/share/godot/app_userdata/SRRevamp/logs/srrevamp.log`. Attach
that file (not just a description) when reporting a bug — no terminal needed to get it.

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
see `docs/LEGAL.md`). Either drop your own real Silkroad client's `*.pk2` files into a `pk2` folder
next to the editor/exported binary (see "Downloading a pre-built client" above — `Pk2Config`
resolves them automatically), or, for development/testing a single specific file without touching
the `pk2` folder, set any of these environment variables before launching the client (each one
takes priority over the matching real `pk2/<Name>.pk2` file when set) to have `World3D.tscn` load
and place them live (see `client/scripts/World3D.gd`):
- `SRREVAMP_PK2_PATH` — a real pk2 archive (e.g. `Data.pk2`). On its own, this auto-loads a real
  assembled, textured player character (see "Status" below).
- `SRREVAMP_PK2_PATH` + `SRREVAMP_BSR_PATH` — also loads a real, textured static scenery object
  (a `.bsr` path inside the archive) via `ObjectLoader`.
- `SRREVAMP_BSK_PATH` + `SRREVAMP_BAN_PATH` — a real `.bsk` skeleton and `.ban` animation (either
  loose files or paths inside `SRREVAMP_PK2_PATH` — see `AssetSource`), built into a real,
  live-animated decoration `Skeleton3D` via `Skeleton3DBuilder`.
- `SRREVAMP_MAP_PK2_PATH` + `SRREVAMP_MAPM_PATH` — `Map.pk2` (a separate archive from `Data.pk2`
  in a real retail install) and a region `.m` path inside it (e.g. `100\100.m`), loaded as real
  terrain via `MapmTerrainBuilder`, tiled into a real 3x3 grid of regions around it (see
  `World3D.gd`'s `_load_region_neighborhood` — this project's own multi-region layout, since real
  per-region world scale/adjacency isn't confirmed; see `docs/protocol/MAPM_FORMAT.md`).
- `SRREVAMP_MEDIA_PK2_PATH` + `SRREVAMP_MAPM_TEXTURE_PATH` — `Media.pk2` (a third separate
  archive) and a real per-region minimap image inside it (e.g. `minimap\100x100.ddj`, matching the
  same region number as `SRREVAMP_MAPM_PATH`), textures the *center* region of that grid with real,
  region-accurate art instead of the procedural per-tile color fallback (neighbors always use the
  fallback — no minimap texture is looked up per-neighbor yet).
- `SRREVAMP_MAPO_PATH` — a real `Map.pk2` region's `.o` object-placement file (via
  `SRREVAMP_MAP_PK2_PATH`, e.g. `0\0.o`), rendered with each placement's real resolved `.bsr`
  model (via `SRREVAMP_PK2_PATH`'s `Data.pk2` and a real object-index table — see "Status" below).
  Also tiled per-region across the same 3x3 grid as terrain.

Leave any of them unset and that piece is skipped — the scene works fine with none of them set.

**Finding real asset paths in your own pk2 files**: `go run ./cmd/pk2list -pk2 "<path>"` (from
`server/`) lists every real file path inside a real pk2 archive, optionally filtered by substring
(`-filter grass`) — useful for finding real texture/mesh paths this project doesn't already have a
sample of to reverse-engineer against, without needing to send the archive itself anywhere. A
directory can span multiple chained blocks (a real mechanism found by decompiling the actual
client's directory-read code, not guessed — see `docs/protocol/PK2_FORMAT.md`); both readers follow
it, confirmed against a real 3.8GB `Data.pk2` whose file count went from 41 to 73139 once the fix
landed.

**Checking whether your own pk2 files are fully mapped**: `go run ./cmd/audittextures -data "<path
to Data.pk2>"` (from `server/`) walks every one of `navmesh\object.ifo`'s real entries — the
client's own complete real object catalog — and resolves each one's full chain (`.bsr` mesh(es) +
material → each texture) end to end, reporting every real failure with its exact path and reason.
Useful for spotting real gaps (a different client version/region missing some content, a corrupted
file) before assuming this project's own readers are at fault — a genuinely missing/renamed file in
your own pk2s shows up the same way it would in-game (a `push_error` naming the exact path), just
without needing to actually load the 3D view first.

**Checking whether your character/equipment assets are fully mapped**: `go run
./cmd/auditcharacters -data "<path to Data.pk2>"` (from `server/`) walks a
gender/skeleton/body-part/armor-set/weapon/shield matrix of conventional paths and reports any
file that exists but fails to parse. The client itself no longer uses that matrix -- it dresses a
character from the item table's own model column (see `docs/protocol/ITEM_FORMAT.md`) -- and
`client/tools/check_item_requirements.gd` is the check for that: it resolves every worn model the
table names against Data.pk2 and reports the ones that are missing.

Run the test suites from `server/` (`go test ./...`, needs the same local Postgres) and `client/`
(`godot4 --headless --path . --script res://scripts/net/<name>_test.gd` for each file, or see
`.github/workflows/ci.yml` for the full list CI runs).

## Branching

- `main` — protected, production. Requires PR + passing CI. Repo admins can bypass (force push)
  when truly necessary.
- `dev` — integration branch, default target for feature branches and day-to-day work.

## Status

Server-side protocol (accounts, characters, world/chat, combat/loot, inventory/equipment, shop,
quests, party/guild, duels, trade, friends) is implemented and tested end-to-end, with
`client/scenes/World3D.tscn` as the one real client, wired to all of it via a UI overlay (chat,
monsters/combat, inventory, equipment, quests, shop, party, guild, duel, trade, friends) on top of
a real 3D scene. This is genuinely playable today: `docker compose up --build` (or a local Postgres
+ `go run ./cmd/server`) plus opening `client/` in Godot gets you a real login → character select →
3D world loop against a real server.

There used to be a separate 2D scene (`World.tscn`) this project's HUD lived in first; its UI was
ported into `World3D.tscn` and the 2D scene was deleted once that port had full parity — see
`docs/PROGRESS.md`. The 3D scene itself started as a `CharacterBody3D` player with WASD movement
and a third-person camera, synced to the server over the same movement protocol the 2D client
had decoded but never sent or rendered anything for — see `docs/PROGRESS.md` for that finding.
Other connected characters render as labeled capsules at their real, server-authoritative
positions, or a real assembled character once real game data is loaded (see below).
**Verified against the real running stack**: the full connect → register → login → create
character → enter world flow,
and two concurrent real client instances genuinely seeing each other enter and move in real time,
both confirmed by actually running the Go server + client together, not just unit tests.

There's also a real multi-zone concept now: `OpChangeZone`/`OpChangeZoneResult` let a character
warp between zone labels (`server/internal/world.Hub.ChangeZone`), broadcasting a real
`OpEntityLeft`/`OpEntityEntered` pair the same way entering the world or disconnecting already did.
A zone is just an opaque string as far as the server's concerned, but this project's own real
`.mapo`/`.mapm` region-file naming (`<x>/<y>.m`/`.o`, e.g. `100/100`) is the convention a client
pointed at real map data is expected to use. Every zone change lands at the same fixed spawn point
— there's still no confirmed real coordinate transform between one region and another (see "Not
yet done" below), so this is a discrete warp, not a continuous cross-region walk. `World3D.gd` now
reacts to a real zone change too: a zone label shaped like this project's real region naming
(`"100/100"`) resolves (`_zone_paths`) to that region's real internal paths and the scene tears
down/reloads its terrain and map objects for the new zone — a small dev UI (`ZoneInput`/
`ChangeZoneButton`) lets you actually trigger and watch this happen. The server's own default spawn
zone, `"jangan"`, resolves to a real, verified region (`98/168`) rather than clearing to placeholder
ground — see "Real ground textures" below for how this project found where Jangan actually is. Any
other zone not shaped like a real region still clears to the placeholder honestly, rather than
guessing a path.

3D asset formats are reverse-engineered and have real, tested readers on both sides
(`server/internal/{pk2,bsr,bms,ddj,bmt,ban,bsk,mapo,mapm,efp,cpd,environment}` in Go,
`client/scripts/{pk2,bsr,bms,ddj,bmt,ban,bsk,mapo,mapm,efp,cpd,environment,mapt,tile2d,nvm}` in
GDScript) — **every container format found so far has at least a working reader**: the pk2 archive
container, `.bsr` composite "static object" descriptors, `.bms` mesh geometry (two real per-vertex
record sizes, 44 and 52 bytes — self-validating detection, no reliable per-file flag distinguishes
them), `.ddj` textures (a thin wrapper around standard DDS), `.bmt` materials (zlib-compressed
color + texture-reference layers — decompressed with a from-scratch pure-GDScript DEFLATE decoder,
`client/scripts/bmt/inflate.gd`, after Godot's own built-in decompressor was confirmed to fail on
real zlib streams that a standard library decodes correctly), `.ban` bone-animation data
(quaternion + position keyframes per named bone), `.bsk` skeleton/bone-hierarchy data (the
parent-bone references `.ban` itself lacks), `.o`/`.o2` (`Map.pk2`'s per-region object-placement
lists), `.t` (per-region ambient-occlusion lightmap), `.nvm` (per-region navmesh/walkability data),
`tile2d.ifo`/`object.ifo`/`environment.ifo` (plain-text and binary lookup tables), and `.cpd`
("Compound" multi-object groupings, e.g. a decorated tree or a fully-armored character).

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
with nothing else, for instance — instead of the old all-or-nothing bundle. `World3D.tscn`'s
Equipment tab exposes this via a real slot picker (`OptionButton`), mirroring the gender picker's
pattern.

What the character wears is the server's word, and each piece is drawn from its own model. The
equipment list (`EquipmentNet`) says which item id is in which slot; the client's own item table
(`Media.pk2`'s `itemdata*.txt`) names, in column 52, the `.bsr` every item is worn as --
`4842 Cotton Suit` reads `item\china\man_item\clothes_01_ba.bsr` -- and that file says how the
piece hangs: weighted onto the body's own bones (a suit, trousers, a hat, boots, wristlets) or on
a skeleton of its own under one named body bone (a blade on `Bip01 R HandMid`, a shoulder piece on
`Bip01 Neck1`). The body itself is a row of `characterdata` like any NPC's
(`CHAR_CH_MAN_FIGHTER` -> `char\china\chinaman_fighter.bsr`), skinned by its own per-vertex
weights. See `docs/protocol/ITEM_FORMAT.md` and `client/scripts/assets/skinned_bsr_assembler.gd`.

An earlier version of this README said a per-item model mapping "doesn't exist anywhere this
project can reach"; it is column 52 of the item table, and everything that followed from its
absence -- a look picked by `item_id % 8`, guessed bone tables, a shoulder piece at the pelvis --
is gone. Other connected players are dressed the same way: every entity snapshot carries slot and
item id for each worn slot.

Who may wear what is the item table's rule too, enforced server-side (`equipment.Refusal`): the
slot from the item's type ids, its race, its gender, and its required level where the requirement
is by character level. Requirements by mastery level (the European items) and by strength or
intellect are read and kept but not enforced yet -- nothing tracks those numbers.

A real off-hand shield renders the same way: real, faction-wide shield item meshes exist under the
same real weapon folder and attach to a second real, directly-confirmed bone
(`CharacterAssembler.SHIELD_BONE`, "Bip01 L Hand" — the off-hand counterpart to the weapon's "Bip01
R Hand", found the same direct way). **The local player picks one of 5 real, individually-verified
shields** (`shield_11`/`15`/`16`/`90`/`91` — `World3D.gd`'s `SHIELD_VARIANTS`; `shield_14` was
checked and dropped after its own real `material_name` ("China_shield_14") turned out not to match
any real file anywhere in the archive) deterministically from the real equipped shield item's ID.
Gated on real `SLOT_SHIELD` equip state, broadcast per-player the same way as armor and weapon.

The ground is no longer just a placeholder box either: setting `SRREVAMP_MAPM_PATH` (+ its own
`SRREVAMP_MAP_PK2_PATH`, since `Map.pk2` is a separate archive from `Data.pk2` in a real retail
install) loads a real `Map.pk2` region's real elevation data and builds a real triangulated
terrain mesh via `client/scripts/assets/mapm_terrain_builder.gd` (`MapmTerrainBuilder`), replacing
both the placeholder's visual mesh and its collision shape (the latter built straight from the
same real triangle data — see below). `.m`'s real structure is fully solved and confirmed
byte-for-byte (see `docs/protocol/MAPM_FORMAT.md`): a region is a real 6×6 grid of 36 blocks, each
a real 17×17 vertex mesh, stitched into one real 97×97 heightmap covering the region's actual
1920×1920-unit footprint — `MapmReader` parses this fully deterministically (no plausibility
scanning needed), and `MapmTerrainBuilder.build_full_region_mesh` builds the full stitched mesh
directly from it. Verified against real region files: a single, coherent, natural-looking
mountainous terrain with correct shading and no seams, not a flat box or an elongated ribbon.

**Real ground textures**: an earlier pass wrongly concluded these were absent after checking
`Data.pk2`/`Media.pk2`/`Particles.pk2` — they actually live in `Map.pk2`'s own `Tile2D\` folder (752
real `.ddj` files), an archive that search never checked. `MapmTerrainBuilder.
build_full_region_mesh_textured` resolves each real vertex's confirmed `TextureInfo.ID` (via
`tile2d.ifo`, `TileIndexReader`) to its real `.ddj` file and renders each ground quad with its own
real texture on its own mesh surface — real gravel, sand, and grass art, not a stand-in color. Each
quad also gets a deterministic one-of-8 UV rotation/mirror to reduce the "stamped grid" look of a
repeated texture with no blend data (a rendering technique, not a data claim). Falls back to
real per-vertex color variation (by real `TileType`) for any texture ID that doesn't resolve. A
real `.t` file's embedded lightmap (`MapTReader`) is applied as ambient occlusion on top. See
`docs/protocol/{TILE2D,DDJ,MAPT}_FORMAT.md`.

**Real Jangan, found and wired into the default spawn zone**: no table in this project's real data
names regions by city — `server/cmd/findregionassets` finds them empirically instead, by scanning
every region's placed objects for a given real resource-path substring. Found Jangan's real region
cluster this way (x=97-99, y=166-169; `98/168`, the real palace core, has the densest match). The
server's own symbolic default spawn zone, `"jangan"`, now resolves to this real region
(`World3D._resolve_zone_region`) instead of clearing to placeholder ground — live-verified with
`SRREVAMP_MAPM_PATH` deliberately unset, confirming the zone-label path alone loads real Jangan
terrain. A real `.nvm` navmesh format (per-region walkability/pathfinding, `docs/protocol/
NVM_FORMAT.md`) and a real `.cpd` "Compound" object format (groups several real `.bsr` references
under one name — a decorated tree, a fully-armored character — `docs/protocol/CPD_FORMAT.md`) were
also solved along the way, both live-verified against real samples.

`.nvm`'s real walkability is wired in now, not just parsed. Which edge flag actually blocks was the
long-standing blocker, and it was settled by decompiling the client's own collision traversal
rather than guessed: it tests `(m_nFlag & 3)`, so flag 2 blocks, flag 4 is passable, and flag 8
(every real global edge) is the region hand-off — see `docs/protocol/NVM_FORMAT.md`'s "Edge flag
semantics: solved". Cross-checked three more ways: 264 real files split with zero counterexamples
(every flag-2 edge has no cell on one side, every flag-4 edge joins two walkable cells), the
polarity is forced because global edges must stay passable or no region could ever be left, and the
blocking set forms closed contours. Each streamed region now loads its own
`navmesh\nv_%04x.nvm` and adds those edges as real collision on their own layer — the player is
stopped by them, the camera deliberately is not. `SRREVAMP_DEBUG_NAVMESH_WALLS=1` draws them, which
is how the placement was checked: over real Jangan they wrap each building and leave the streets
open.

Individual objects turn out to carry navmeshes of their own, and that is what makes real stairs
climbable. A real `.bms` can hold a complete per-object navigation mesh at the offset in header
field `0x28` — this project previously documented that field as "reserved, observed 0", which it
genuinely was in the only samples then to hand (particle and character meshes, neither of which a
character stands on). 507 of a 4,395-file real sample carry one. The real client never collides a
character against a building's *render* geometry: it walks that cell/edge graph and takes the
character's height from the cell underfoot, which is why a real staircase is walked as a **ramp**.
The real Jangan palace centre stairs render as 16 triangles across 5 tread levels; their navigation
mesh is 6 cells across **2**. Colliding against the render mesh instead put a vertical riser in
front of the player at every step, which is exactly the "can't climb the temple stairs, but can
finangle up the edges" a real playtest hit.

The format was validated the same way `.nvm` was — read every section in order and see whether it
lands exactly on the file's end. **507 of 507 do**, with zero leftover bytes and no special cases;
see `docs/protocol/BMS_FORMAT.md`.

**Driving Godot collision from it was tried and reverted** (v0.1.38, reverted the same day):
in isolation a capsule climbs the ramp, but in the world the player lands on the surface and cannot
move along it, because real placed objects sit under the world's mirrored transform, which flips
which face is front and so forces two-sided collision — and a two-sided single-thickness surface
pins the capsule against the very ramp it stands on.

**The player now moves on the navmesh instead**, which is what the real client does: `NavGraph`
unifies a region's terrain `.nvm` with every placed object's own navigation mesh, the character's
height comes from the cell underfoot, and an edge is tested as a 2D line. No capsule, no gravity,
no collision shape — so none of the problems above exist. Verified in a real running world against
the exact failure it was built to fix: dropped at the foot of the real Jangan palace stairs (a
22.1-unit ramp) with the step-up assist disabled, the player walks y=2.12 → 10.74 → 19.64 → 21.94,
arriving at the ramp's own top height and holding it for 450 further frames while still moving —
where the collision-shape approach produced *zero* displacement. Set
`SRREVAMP_NO_NAVMESH_MOVEMENT=1` to compare against the old physics movement.

How objects attach to a region was measured rather than assumed, and one measurement saved a wrong
design: `MapObject.linked_edges` looks like the object-to-terrain link but is not — only 4 of 122
objects carry any, all pointing at *other objects* in symmetric pairs (bridge spans stitched
together). The real link is spatial, via each cell's own object list. See
`docs/WORLD_ISSUES.md`'s sixty-fourth round.

The "Zone:" label is real now too, and the table behind it turned up somewhere unexpected:
`regioninfo.txt` ships inside `Data.pk2`'s **`Shader\`** folder, not anywhere map-shaped
(`docs/protocol/REGIONINFO_FORMAT.md`). It is EUC-KR, its rows are `<y> <x>` — the opposite column
order to the `<x>\<y>.m` naming used everywhere else — and it names 15 real zones (장안/Jangan,
돈황, 호탄, 콘스탄티노플, 사마르칸트 and so on) across 1,619 rows covering 1,563 regions.
`RegioninfoReader` parses it from raw bytes so the Korean survives, and `RegioninfoNames` maps each
name to a display string with per-key overrides; the shipped English names are this project's own
transliterations, since the file carries no English at all.

`RECT`'s meaning came out of the client too, so nothing here is guessed: it is an inclusive
`[x_min, z_min, x_max, z_max]` box in region-local space, the first matching box wins, and a region
otherwise falls back to its `ALL` zone — with the *later* `ALL` winning where two sections claim the
same region, exactly as the client's loader overwrites. Given a position that resolves all 1,563
regions; the region-only query still answers for the 1,516 carrying no `RECT` and declines the rest
rather than picking a side. Live against a real install, real Jangan (`98/168`) reads
"Zone: Jangan".

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
just each in isolation: `100/100`'s real, fully-stitched `.m` terrain (36 blocks, 97×97 vertices)
and its real `.o` + `.o2` placements (158 total objects, resolving to 4 distinct real `.bsr`
models — see `docs/protocol/MAPO2_FORMAT.md` for the newer-generation `.o2` object/event index)
load into the same `World3D` scene at once and produce a genuinely recognizable establishing
view — real textured ground and a real tree with bark texture together in frame. Repeat placements
of the same real model are cached and
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

Not yet done: confirmed real-world terrain/object positioning/scale relative to a player's exact
real spawn coordinate (the default `"jangan"` zone now resolves to a real, verified region, `98/168`
— see above — but that's a representative point within the confirmed real Jangan cluster, not a
claim about the game's exact canonical spawn tile or a real cross-region coordinate transform);
`environment.ifo`'s real per-channel semantic meaning (the record structure is fully solved —
`docs/protocol/ENVIRONMENT_FORMAT.md` — but no rendering uses it yet, since guessing at "channel 0
is ambient color" without confirmation risks the same overclaiming this project has caught and
corrected itself on before); `.cpd`'s exact real trailing field layout (3 real samples showed 3
different byte shapes — a scanning fallback recovers the real data anyway, see
`docs/protocol/CPD_FORMAT.md`); real per-quad ground-texture blending (each quad gets its own real
texture with a rotation/mirror to reduce an obvious repeat pattern, but there's no real blend data
between adjacent quads of different textures to recover); `.efp`'s nested tree structure (see
above). The `EXTRA` equip slot's rendering was also investigated and dead-ended: a real cosmetic
"avatar item" system exists (`resinfo\avataritemdata.txt`, wings for both genders, a dedicated real
UI slot button), but none of its referenced `.bsr` meshes actually ship with this client build —
see `docs/protocol/EQUIP_SLOTS.md`. See `docs/protocol/*_FORMAT.md` and `docs/PROGRESS.md` for the
detailed running log.
