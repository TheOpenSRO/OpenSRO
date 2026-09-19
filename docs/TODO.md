# What's left

The single ordered list of open work. Each entry says what is known, what is *not*, and the next
concrete step — so picking one up does not mean re-deriving how it got here. Detail and evidence
for every item live in `docs/WORLD_ISSUES.md`; this file is the index.

Ordered by value per unit of effort, not by how interesting the problem is.

Two lanes are running in parallel: the **world** lane ([HANDOFF.md](HANDOFF.md)) has items 1-3,
the **UI** lane ([HANDOFF_UI.md](HANDOFF_UI.md)) has items 4-5. Each handoff covers its own lane —
where it stopped, the tools for it, the traps — and points back here for everything else.

## The playtest list (2026-09-11, from the first two evenings on the public server)

In order. Each is checked off here when it ships in a release, with its round in
`docs/WORLD_ISSUES.md`.

- [x] Old release against new server; monsters by code name; English column first; name plates in
      range; remembered server; debug panel (v0.1.87, round 134)
- [x] Animations on the `.ban` files' own clock; camera keeps its orbit; click targets the ground;
      town buttons (v0.1.88, round 135)
- [x] Alexandria's black houses (v0.1.89, round 136); text whole at fractional UI scales (v0.1.90)
- [x] Camera on its own pivot with the three views; sword hangs tip-down; gear for a character that
      has none (round 137)
- [x] **Monsters out of town** (v0.1.92). Mangyang and the Weasel moved from the fountain (62/44,
      -55/58) to measured flat farmland at world (0,-840) and (340,-340), south of the walls.
- [x] **ESC -> System window** (`ifsystemwnd`: Option / Help / Restart / Exit) -- round 138.
      Restart = login screen, Exit = quit, Option = the F3 settings panel. Still open: the
      **authored Option window** (`ifoption` + `ifoption_video`, its View radios and our UI scale /
      chat font / name range as its Setting tab) in place of the F3 panel.
- [x] **NPC talk.** A click on an NPC opens `if_npctalk` titled with its name -- round 139. The
      greeting's service lines are now clickable; Buy opens the shop and Storage the warehouse
      (both below). Still open: the remaining services (guild, honour rank), each its own backend.
      - [x] **Storage (warehouse) -- items AND gold.** Talk -> Storage opens the authored
        warehouse window (`ifstorageroom`) with the bag beside it: click to deposit/withdraw items
        (each a quantity dialog), and the money button opens a gold deposit/withdraw dialog --
        rounds 168-169 / releases v0.1.139-140. The warehouse is a second inventory container
        (`storage_slots` table, `storage.Service`) plus a per-character `storage_gold` balance,
        reachable in real play from the grounded warehouse NPCs (`NPC_CH_WAREHOUSE_M`/`_W`). **Scope
        settled (round 215, v0.1.390)**: the warehouse and its gold are the ACCOUNT's, as the game's
        `_CHEST WHERE UserJID` / `_UPDATE_USER_N_CHAR_GOLD` say; every character on an account shares
        them, and the old per-character rows were moved over losslessly at boot. The capacity MODEL is
        read too (round 216, v0.1.391: per-user `_ChestInfo.ChestSize`, no in-binary default, ceiling
        112, paged by 30 in the client -- the authored page spinner now works); its DEFAULT is
        DISCLOSED as 50 (`storage.DefaultCapacity`) because the game writes it from the database's
        user-creation procedure, which no archive here holds. Still open: the expansion item's
        increment and the expander path.
      - [x] **Merchant shop -- buy AND sell.** Talk -> Buy opens the authored store window
        (`ifstore`) with the NPC's real goods, tabs, real prices, quantity buying, and selling
        from the bag -- rounds 165-167 / releases v0.1.134-138. Per-NPC goods come from the real
        shop chain (`ShopReader`: refshopgroup -> ... -> refscrapofpackageitem -> item), so a
        smith sells weapons, not the whole catalogue. **Prices are REAL** (itemdata `_RefObjCommon`
        Price col 26 / SellPrice col 31; the old stat formula is now a fallback -- see round 166
        and GROUNDING_AUDIT.md). Stackables stack to their real MaxStack (col 57). The in-memory
        server loads items via `-items-csv` (qa_shot feeds `items.csv` beside the pk2s); PostgreSQL
        imports them via `import-refdata` (regenerate/re-import to pick up price + stack columns).
        Repair **done** (round 212, v0.1.386): per-item durability exists now and the authored
        Repair / Repair All buttons charge itemdata's own repair price. Still open: paging past 30 goods (no current NPC needs it).
- [x] **Item tooltips** with the real stats -- round 140 (weapon attack, pinned against the Copper
      Sword +5 the user sent) and round 170 (armour/shield defence at columns 65-77, grounded from
      the DB column order + the cloth=magic / heavy=physical relationship). See ITEM_FORMAT.md.
- [x] **Paper doll** -- round 141: the equipment window (`O`) renders the dressed character live.
- [x] **Equipment slot icons** -- round 142: the worn slots show the equipped icons, slot i in
      GDR_EQUIPMENT_SLOT_(100+i), anchored to the user's screenshot. (Armour defence block now
      grounded -- round 170, above.)
- [x] **Skill window** -- round 143: the real China masteries (icons + names from
      `skillmasterydata` / the UI text table) at Lv 0, with the authored skill-point and
      mastery-total labels. **Now complete**: the per-mastery skill grid (the client-drawn
      `CIFSkillBoard`) is filled from `skilldata`, and the server tracks mastery levels and skill
      points (`OpSkillState`/`OpRaiseMastery`), so learning a skill and raising a mastery both
      work from the window. What is still own-design is the *mastery cost* (`masteryUpCost`).
- [x] ~~A new character spawns with placeholder 200/200 HP~~ -- **not a bug, checked 2026-09-19**:
      `MaxHPFor(StartingStr 20, level 1) = 200` exactly, and a respawn at 80 is the binary's
      `RespawnFraction 0.4` x 200. The two grounded numbers coincide with the old placeholder.
- [x] ~~Two `internal/session` full-flow tests race under host load~~ -- **not a race in the code**
      (2026-09-19): eleven packages' tests share the local `srrevamp_test` PostgreSQL database, and
      two `go test` processes on one host clobbered each other's rows (the trade test's 0x00DE was
      the system cancel from mismatched state). `internal/testdb.Lock` now serialises processes via
      an advisory file lock held in each such package's `TestMain`; two concurrent runs both pass.
- [x] ~~A non-gold drop's name plate shows the Korean column~~ -- round 210: the plate resolver used
      `textuisystem.txt` (zero `SN_ITEM_` keys) instead of `textdata_object.txt`; the potion's column 3
      is literally `HP ?? ??` in the archive. Every item-name site now resolves like the tooltips;
      a name the archive lacks shows nothing.
- [x] ~~Two ground-item drop models do not resolve~~ -- log noise, not a miss (2026-09-19): itemdata's
      drop paths are relative to `res\` (`Res\Item\Etc\drop_ch_money_large.bsr` exists, measured with
      pk2list); the client tried the bare path first and logged every miss before the `res\` retry drew
      the pile. It now tries `res\` first, so only a real miss is logged.
- [ ] **Drop content is still the placeholder table.** The mechanic is real (round 207); the per-monster
      tables are DB-only and in no archive we have (`smc.bak` is the manager DB). An operator with the
      shard DB supersedes it via `import-refdata -drops-csv/-drop-groups-csv`.
- [ ] **Exact fixed-function lighting**: a spatial shader whose `light()` scales the sun by the
      material's diffuse and the ambient by its ambient (round 136's stated approximation).
- [ ] **Attack distance.** Neither the client nor the server gates an attack by distance today: a
      monster can be hit from anywhere (an absent rule, by omission). Read in round 232: the SERVER
      never refuses on distance -- `0x3007 UIIT_SKILL_USE_FAIL_WRONGDISTANCE` occurs nowhere in its
      dump while its neighbours 0x3003-0x3009 all do (`Skill_CheckUseConditions`, `CanBeAttackedBy`);
      the original's CLIENT walks into range before it sends. Basic attacks (`SKILL_*_BASE_01`,
      `SKILL_PUNCH_01`) carry skilldata `Range` 0 = melee, so their reach is the WEAPON's range
      column; other skills carry 6..200 (150 for 6,889 rows). Next probe: the itemdata `Range` column
      (the tooltip's "0.6 m" on a sword) and the client's comparison that turns skill/weapon range
      plus the target's `BCRadius` (column 50) into world units -- then a client-side approach step.
- [ ] **Linear fog between the real planes.** Read in round 229: the client's fog is D3D linear fog
      from `channel 10 x view distance` to `channel 11 x view distance` (2500 by default) -- zero
      until the near plane (Jangan: 1250), complete at the far one (2250). `FOG_DENSITY` is an
      exponential-from-the-camera stand-in because Godot 4.2 has no depth-range fog; the honest
      fix is a full-screen depth pass (a quad with `hint_depth_texture`) or per-material fog code
      applying `(d - near) / (far - near)` with the zone's real FogColor. The planes are already
      computed and logged (`World3D: environment fog planes`, and in QA_LOOK).
- [x] ~~Day/night cycle~~ -- **not a gap** (round 226, `docs/protocol/game_clock.md`): the retail
      client renders the environment at a FIXED phase of 0.5 (SWorld's constructor sets it; the
      per-frame advance is gated by a flag nothing sets; the graphs are sampled at the raw phase), and
      the server clock (`0x34be`) feeds nothing in the sky. `ENVIRONMENT_REFERENCE_TIME = 0.5` is now
      read, not disclosed. The engine's dormant machinery (0.0005/s = a 2000 s day, sun angle
      `(phase-0.25)*2pi`) is recorded should a live cycle ever be wanted as our own design.
- [x] **"Stuck in a building"** (round 213): the cause was `NavGraph`'s own rule -- footing inferred
      from height let a terrain mover walk through a shop wall whose floor sat 5 units up, get
      lifted onto the floor, then be held by the same walls from inside. Replaced by the client's
      actual walk (`docs/protocol/NAVMESH_MOVEMENT.md`: on the terrain or on exactly one object;
      entry only through an outline edge with bit 0 clear; on an object only its own edges apply,
      directionally; `0x10` = underpass; push 0.01). `nav_graph_test` 55 checks; `tools/walk_probe.gd`
      traces it on real Jangan in ~10 s. "Floating things in Alexandria": the measured sweep found
      0 floats > 12 in Alexandria, Hotan, Constantinople, Samarkand and the three Jangan regions.
- [ ] Movement follow-ups from round 213: `_avoid_spawning_under_roof` relocates a QA start
      without consulting the graph (once onto a shop floor); linked edges (`0x08`, the hand-over
      between objects) and event gates (fortress/dungeon doors, `0xc0` bits) are documented but
      not implemented -- no town object uses either.
- [x] Battle stance (round 132, hold duration read in round 218 / v0.1.392): the player HOLDS
      the real STAND_BATTLE clip while recently in combat; the hold is now the server's own
      rule -- BattleState (SetCharacterState type 8) is entered with a 20-tick countdown in the
      PC's periodic update (`CGObjPC::vslot_415`) and reverts to peace at zero. What is still
      **read** in round 223: that update is the PC's 1.0-second timer job (`CGObjChar::Create`
      registers it with `fld1`; the timer vector is ticked by `CGObjChar::Update` with the main
      loop's seconds delta), so the stance lasts 20 s -- and berserk's 60 s and regen's 4 s are
      read in the same pass (`docs/protocol/character_state.md`). Left: srrevamp's server carries
      no battle-state byte, so other players do not see the stance.

## Next up

### 0. Monster HP bars, click-to-attack, target window, damage numbers — **done** (rounds 146-149)
Monsters show a name plate and a billboarded red HP bar that shrinks on each hit, a left click
on a monster attacks it (NPC->talk, monster->attack, ground->move), the current target shows at
the top of the screen, and every blow floats a damage number that rises and fades -- white for
damage the player deals, red for damage taken (round 149). Combat behind it is still the
placeholder damage until the round-145 refdata is imported (operator's call, `deploy/README.md`).

**The combat loop — done** (rounds 171-173, releases v0.1.142-144). The world has the real Jangan
monster ladder (Mangyang through Yeoha, 23 monsters across two hunting grounds; grounded
identity, one disclosed level-scaled stat curve). Leveling pays off: max HP grows with level, and
the level label, HP-bar maximum, underbar EXP gauge and SP are fed live from the stats packet
(the EXP curve itself, leveldata.txt, is real). And the berserk gauge fills through combat on the
authored five orbs, unleashing a damage burst on **R**.

Since then: **monster max HP is REAL** (characterdata col 59, recovered from the server binary --
round 175, v0.1.147), **mana exists and is spent** (skills pay their real `Consume_MP`;
v0.1.149-150, with the level curve's *growth* recovered and its base disclosed), and **potions
work** with the item table's own restore amounts (v0.1.151). Still disclosed own design: monster
defence/attack/gold, HP-per-level, the berserk numbers, and skill damage.

### 1. NPCs — **done, except that they are statues** (hundred-and-fifth round)
12,367 spawns and 5,423 models read from the player's own Media.pk2, each assembled from its own
`.bsr` by `SkinnedBsrAssembler`. 18 of 19 placed in Jangan town, 45 across the loaded grid.

**Names are done** (hundred-and-twenty-first round): 13,169 resolve from `characterdata*.txt`'s
`SN_` key through `textdata_object.txt`, and every placed NPC carries one. The plates are drawn
screen-space, which is why they are visible at all — and why the monster labels became visible at
the same time.

**Facing is settled as a negative**: `npcpos.txt` is 12,367 rows of exactly five columns (id,
region, x, y, z) and the archive has no other NPC table, so there is no authored facing anywhere.
Any direction this project turns an NPC would be invented. Not an open question.

**Blocking is done** (hundred-and-twenty-second round): each NPC carries a capsule sized from its
own geometry, on the layer the player masks and the camera does not. `SRREVAMP_QA_NPCBODY=1`
reports the capsule and whether a ray is actually stopped — 5 of 5 in Jangan town.

**What is left**: nothing on this item. NPCs stand, animate, are named, and are solid.

**Animated, and properly skinned** (hundred-and-tenth round). `.bms` does carry per-vertex
skinning after all -- a bone palette and two weighted influences per vertex, in their own section
pointed at by header word `0x10`, which is why an audit of the 44-byte vertex record found none.
NPCs now deform correctly and animate; `SRREVAMP_NO_IDLE_ANIM=1` turns animation off.

### 2. Monsters as real models — **done** (hundred-and-fourteenth round)
Verified against a live server rather than asserted: `Mangyang -> mob\china\mangnyang.bsr` and
`Weasel -> mob\china\gyo.bsr`, both assembling a real skeleton, both standing in Jangan beside
the player. The client logs what it resolved for each, so the three ways this can go wrong —
species not in the tables, model not assembling, model placed out of reach — tell themselves
apart in a playtest log. They used to be the third: 292 and 461 units from spawn.

### 3. Equipment on the character — **done, and now drawn from the game's own data** (hundred-and-thirty-first round)
A new character is dressed by the server and the client renders it. Two bugs were in the way and
neither was on the client: the starting kit could not be given at all (an item with no reference
row could not be *held*), and ten request handlers were rejecting the client's listings as
malformed. Both are fixed and tested end to end.

**What each item looks like is no longer chosen by the client.** The item table's column 52 names
the model every item is worn as, the model's own `.bsr` says how it hangs on the body, and the
body is a `characterdata` row like any NPC's -- see `docs/protocol/ITEM_FORMAT.md`. The wearing
rules (slot, race, gender, level) are the table's too, enforced by `equipment.Refusal`.

**Open on this**: requirements by mastery level and by stat are read but not enforced (nothing
tracks them); characters have a level but no way to gain one; accessories (slots 9-16) are not
modelled; the item `.bsr`'s effect attachments (`.efp` on `Bone04`/`Bone06` of a shoulder piece)
are not drawn.

### Rendering against a real server
`qa_shot.sh --server` starts the server in memory on a spare port and signs the client in
(`SRREVAMP_QA_SERVER`, `--say` to send a chat message). Every render before this was of a client
with no server, which is why the character was bare, the health bar blank and the panels empty in
all of them. Use it for anything the server owns.

### 4. A minimap (Implemented — one-hundredth round)
The live minimap is now wired through the authentic PK2 UI pipeline (`scripts/ui/hud/hud_minimap.gd`
loading `resinfo/ifminimap.txt`): displays the region's own art (`minimap\<y>x<x>.ddj`), aperture
clipping, rotating heading arrow (`mm_sign_character.ddj`), and real-time X/Y coordinate readout
derived from the ninety-seventh round's recovered coordinate math.

### 5. Break up `client/scripts/World3D.gd`
5,259 lines, against 800 for the next largest file — and now the file both lanes would edit at
once, which makes this deconfliction as well as tidying.

**The UI is the big piece and goes first**: 79 of the file's `@onready` node references and 75 of
its 162 functions are UI handlers, wired by 96 `.connect(` calls in code (the scene has only 2
`[connection]` entries). Moving them into `client/scripts/ui/` plus its own scene leaves the two
lanes touching disjoint files. Do it incrementally — one tab, run the suite, commit — since a
big-bang refactor of a file another agent is editing will not merge. See
[HANDOFF_UI.md](HANDOFF_UI.md)'s "Do not collide".

The QA harness at the bottom is a separate ~600 lines of pure diagnostics with no gameplay
coupling; it belongs to the world lane and moves out on its own. Region loading and streaming is
the next cohesive piece after that.

### The UI lane's own list is [UI_TODO.md](UI_TODO.md)
Panels, the window recipe, and the reference screenshots. The item below is the part of it that
touches this file.

### Retire the debug UI now the real HUD is in — **nearly done**
Gone: the ten-tab `ActionTabs`, the corner labels, and (hundred-and-sixteenth round) the chat
panel, which `HudChat` replaces with `ifchatviewer.txt`'s own window. Thirteen authored panels
are built and reachable from the underbar's MENU and from hotkeys.

**What is left**: the Change Zone box and the Log Out button. The zone box has to stay until
there is another way to travel — it is the only one — so this finishes with a real travel
mechanism rather than with a deletion.

### Tester tools: the chat console, GM commands, the Help window — **done, with these left**
`docs/DEBUG_TOOLS.md` and `docs/rounds/debug.md`. Left out of that lane: (1) the original's help
dialogs / web panel were not recovered — the Help window's interior is ours inside the authored
`ifgameguide` frame; (2) `/give` by item *code* is client-side only (the server's item table has no
code column), so a code the client has not loaded is refused; (3) a GM `/spawn` reaches other
clients only on their next monster list (there is no spawn broadcast); (4) ~~`client/docs/RELEASE_NOTES.md`
is a committed snapshot~~ — done at merge: the release workflow fetches tags and runs
`bundle_docs.sh` before the export, and `internal/systems/bundled_docs_test.go` keeps the committed
copies equal to `docs/`; (5) the GM run's `SRREVAMP_QA_COMMANDS` verification used frame ticks
because a `SceneTreeTimer` did not fire inside a movie-writer run — worth understanding; (6) ~~**a real bug
the tools surfaced**: every zone change prints `Trying to assign invalid previously freed instance` from
`_tick_idle_animations` (World3D.gd:3406) ~125 times~~ — fixed at merge (round 214): the raw
Variant is checked with `is_instance_valid` before the typed assignment.

## Parked, with the state written down

### Moat water
The moat is real, located exactly (96/168 local 1490, 1470 — the ninety-seventh round), and the
terrain carries its trench: **-40.00** in a narrow band against **+0.65** either side, with the
plane cell over it at level **-20**, which would fill the trench and nothing else.

**Why it is parked**: the same region sits at about **-45 across its southern third**, which that
same level would flood, and the art there is farmland. Neither the plane map (30 of 36 cells are
type 1) nor the tile map (no water tiles anywhere in the region) can separate the two.
**Cheapest next step**: a reference screenshot standing in that southern area — if it is dry in
the real game, the plane level alone cannot be the rule, and that halves the search.

### Scenery still off the ground
83 objects fell to 60 once each `.o2` entry was assigned to the region whose heightmap explains
its height (eighty-fifth round). The rule resolves small scenery reliably and **cannot** resolve a
large structure standing on its own platform, whose base has no reason to touch the terrain.

### The `cj_s` city wall's copies
Down from six to two or three. The surviving one currently lands correctly because an unauthored
band of zeroes beats the regions with real data — luck, recorded as luck in the eighty-sixth
round, not a working rule.

### Objects you could walk inside — **fixed** (hundred-and-twenty-third round)
It was 232 objects world-wide, not the eight Jangan ones the count named. The graph resolved an
object by its **first** mesh only, and a building's walkable surface is one piece among many in
alphabetical order — `cj_luxu_floor.bms` is the fourth of twelve. All of an object's meshes are
read and merged now. Every region around Jangan places 100% of its objects, and `SRREVAMP_QA_SCAN`
finds none of the eight among the spots that put a player under solid geometry; what it still
finds is tree canopies and balloons, which is what walking under a canopy looks like.

### Two `.bms` header sections nobody reads
**`hdr[2]` is decoded** (hundred-and-twenty-fifth round): one 8-byte record per vertex — a
`float32` on a 0.05 ladder and a `uint32` that is 1 in exactly the records whose float is zero.
801 of all 24,984 meshes carry it, and they are garments, banners and cobwebs. `BmsReader` reads
it into `vertex_motion` / `vertex_pinned`; what it is *for* is an inference, recorded as one.
**`hdr[3]` is decoded too**: a count and that many 12-byte links, each two vertex indices and a
distance — verified across 58,433 records with every index inside the mesh and every distance
positive. What is *still* open is the trailer after those records, small integers all below the
link count, in every one of the 801 files.
`hdr[5]` was checked at the same time and is empty in all 1,200, so nothing is missed there.
What the two carry is unknown, and the meshes render correctly without them.
`client/tools/audit_unused_header_words.gd` reproduces it. See
[protocol/BMS_FORMAT.md](protocol/BMS_FORMAT.md).

This audit exists because of a pattern worth reusing: **three settled conclusions in this project
were overturned by re-reading data, and the tell in every one was a header word parsed and never
used** — the `.bsr` offset table, the `UV_*` fields, and `.bms` skinning. Grepping the other
readers for the same shape found none, so this is the last of it for now.

### `.o2` list semantics
List 2 is a region's own objects and the others are cross-references, measured at 91% against 46%
on the sector check. What the three lists *are* is still unknown.

## Established, do not re-derive

Each of these cost real time and is recorded with its evidence. Check `docs/WORLD_ISSUES.md`
before contradicting one.

- Region axes: region **y** → world X, region **x** → world Z.
- Client position readout: `X = (region_y - 135) * 192 + local_x / 10`, `Y = (region_x - 92) * 192 + local_z / 10`.
- Minimap filename is `minimap\<y>x<x>.ddj`.
- Placements resolve against **Map.pk2's** `object.ifo`, not Data.pk2's.
- `.bmt` layer flag **bit 0** marks an alpha layer.
- A `.ban` keyframe **replaces** a bone's local transform; it is not a delta.
- Navmesh plane **type 1 is not water** — it covers a quarter to all of every region.
- A bind pose is a poor test of a rig: both character bugs this project had were invisible at rest.
