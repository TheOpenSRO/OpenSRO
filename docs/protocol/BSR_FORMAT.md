# BSR resource format (JMXVRES)

`.bsr` is a lightweight "static object" descriptor: a header, a name, a reference to a primary
`.bms` (mesh) + `.bmt` (material) pair, a bounding box, and a count-prefixed list of further
`.bms` paths for objects assembled from multiple pieces (e.g. a building made of separate
wall/column/stair/tile meshes). See [BMS_FORMAT.md](BMS_FORMAT.md) for the mesh format itself.

Confirmed two ways: empirically against real extracted `.bsr` files (the same black-box technique
used for pk2/bms/ddj), and by decompiling the real runtime loader in `sro_client.exe` — traced
through `FUN_00bed8d0` (identified via a literal path string reading `...SimpleViewer\objengine\
ResourceMgr.cpp`, error message `"ResObj Data Loading Failed [%s]"`) down to `FUN_00bce3b0`
(`ResObject.cpp`), which validates the magic byte-for-byte: bytes 4-7 must equal `"RES "`, bytes
8-11 must equal `"0109"`. No decompiler output is stored in this repo — only the resulting facts.

## Header (fixed 0x44 = 68 bytes before the name string's length field)

Same general shape as `.bms`'s header (magic + an offset table + reserved fields), but 4 bytes
shorter before the name string.

**Correction (2026-09-08).** This document previously called the offset table "unconfirmed" and
said the field at 0x28 was a constant `152` that "did not hold for one real file", so neither
reader used it. Both statements were wrong, and for the same reason: **the table starts at 0x0C,
not 0x10.** Read off by one field, every entry lands on the wrong thing. Read correctly, all four
of the first entries are exact byte offsets to the count word that begins a section, in every
real file checked across all three categories — the table was trustworthy all along:

| File | 0x0C material | 0x10 mesh | 0x14 skeleton | 0x18 animation |
|---|---|---|---|---|
| `chinaquest_priest.bsr` (character) | 193 = 0xC1 | 246 = 0xF6 | 511 = 0x1FF | 400 = 0x190 |
| `mangnyang.bsr` (character) | 249 = 0xF9 | 341 = 0x155 | 1097 = 0x449 | 431 = 0x1AF |
| `cj_monstad_door01.bsr` (building) | 262 = 0x106 | 340 = 0x154 | 1524 | 1512 |
| `tre_bank02.bsr` (nature) | 235 = 0xEB | 290 = 0x122 | 465 = 0x1D1 | 407 = 0x197 |

The 0x28 field isn't a constant either: it is `name_end + 48`, tracking the name's length exactly
(`chinaquest_priest`, 17 chars → 137; `mangnyang`, 9 → 129; `tre_bank02`, 10 → 130). It points 4
bytes ahead of the bounding-box floats.

| Offset | Size | Field |
|-------:|-----:|-------|
| 0x00 | 12 | Magic, `"JMXVRES 0109"` — confirmed via the real client's validator |
| 0x0C | 4 | Offset of the **material** section |
| 0x10 | 4 | Offset of the **mesh** section |
| 0x14 | 4 | Offset of the **skeleton** section |
| 0x18 | 4 | Offset of the **animation** section |
| 0x1C | 4 | Offset of the **mesh group** section (2026-09-10; see below) |
| 0x20 | 4 | Offset of the **animation group** section (2026-09-10; see below) |
| 0x24 | 4 | Offset of the **mod-data** section, which carries the per-animation **sound tracks** (and material, particle and dynamics mods): see "Sound tracks" below |
| 0x28 | 4 | Offset of the bounding-box block; equals `name_end + 48` in every file checked |
| 0x2C | 4 | **Flag word** (round 625, READ): `CResObject::Load` (`ResObject::FUN_00be41d0`) copies it to the object (`param_1[1]`); **bit 0 set means every mesh entry carries one more `uint32` after its path** (see "Mesh entries" below). 1 on the swaying trees, 0 in the files checked before |
| 0x2C bit 1 | | **Two passes** (round 625 review, READ): `CObjRendererVS::vslot_038` then draws with `FUN_00bf5780` — every material back faces (CULLMODE CW), then front faces (CCW) |
| 0x30 | 4 | Copied beside it (`param_1[2]`); meaning not read |
| 0x34-0x3C | 12 | Reserved (observed 0) |
| 0x40 | 2 | **Object type** — eight values across the archive; `1` is character (see below) |
| 0x42 | 2 | Observed `2` in every file checked |
| 0x44 | 4 | Name length (`uint32`) |
| 0x48 | ... | Name string (ASCII, not null-terminated — length-prefixed) |

## Object type (0x40)

The low `uint16` at 0x40 is the game's own classification of the object, authored in the file.
It is what distinguishes the layouts below — the field order differences this document previously
attributed to a path-prefix convention (`res\bldg\...` vs `res\nature\...`) are really a
consequence of type.

**Corrected 2026-09-09.** An earlier version of this table listed only 1, 2 and 4, from five
sampled files. Sweeping a real `Data.pk2`'s 8,539 `.bsr` files finds **eight** distinct values:

| Value | Files | Meaning |
|---|---:|---|
| 5 | 3,421 | **Item** — a piece of equipment as it is worn: one mesh, its material, and sometimes a skeleton of its own plus the body bone it hangs from (`clothes_01_ba`, `blade_01`; see ITEM_FORMAT.md) |
| 2 | 2,592 | Building / static scenery (`cj_monstad_door01`, `cj_monstad_status_l`) |
| 4 | 946 | Nature (`tre_maple01`, `tre_bank02`) |
| 1 | 838 | Character — skinned, has a skeleton (`chinaquest_priest`, `mangnyang`) |
| 3 | 357 | unconfirmed (`npc\npc\gacha_machine` is one) |
| 6 | 205 | unconfirmed |
| 0 | 174 | **Player character** — the 26 playable classes `characterdata` names at ids 1907–1932 (`char\china\chinaman_fighter`), same layout as type 1. The client's factory (`FUN_00be9250`) builds a `ResChar` for case 0 |
| 8193 | 6 | unconfirmed (`0x2001` — the only value above 8 bits) |

Types 0 and 1 select the character path; type 5 is read through the section table like the rest
and its skeleton entry, when it has one, carries the attach bone described below.

## Character layout (type 1)

NPCs, monsters and the player's own body are all type 1, and they are a genuinely different
layout rather than a reordering of the scenery one. Every section is reached through the header
table above; nothing needs to be scanned for. Each section begins with a `uint32` count, and its
entries abut one another exactly, so a section ends precisely where the header says the next one
begins — which is what makes this checkable rather than guessed, and is asserted by both readers.

| Section | Layout |
|---|---|
| Material (0x0C) | `uint32` count, then per entry: one `uint32` (unconfirmed — an index or flag, always small) followed by a length-prefixed `.bmt` path |
| Mesh (0x10) | `uint32` count, then that many length-prefixed `.bms` paths back to back, no per-entry field |
| Animation (0x18) | two `uint32`s (observed `4096` then `0` in every file checked, meaning unconfirmed), then a `uint32` count, then that many length-prefixed `.ban` paths |
| Skeleton (0x14) | `uint32` count, then per entry a length-prefixed `.bsk` path **and a length-prefixed bone name** — the body bone this skeleton hangs from. A body writes an empty string there (`chinaman_fighter.bsr`: a zero length word after the path); an item with a skeleton of its own names the bone, `Bip01 R HandMid` for `blade_01`, `Bip01 Neck1` for `clothes_01_sa`. At most 1 entry in every real file checked; 0 for an item weighted straight onto the body |
| Mesh group (0x1C) | `uint32` count, then per group a length-prefixed name, a `uint32` count and that many `uint32` indices into the mesh list. A body has one, `default`, listing every piece |
| Animation group (0x20) | `uint32` count, then per group a length-prefixed name and a `uint32` count of entries. Each entry: `uint32` **action type**, `uint32` index into the animation list (`0xFFFFFFFF` for none), `uint32` event count, that many events of four `uint32`s (a key time, an event type, two parameters), `uint32` walk-point count, that many `(float, float)` points (two in every entry checked), and a trailing `float` (1.0 in every entry checked) |

The animation-group parse ends exactly on the sound-effect pointer in every file checked —
`chinaman_fighter`, `chinawoman_fighter`, `chinaman_warrior`, `mangnyang`, `chinaquest_priest`,
`sword_01`, `clothes_01_sa` — which is what makes the entry layout a reading rather than a guess.

### How an item with its own skeleton hangs on the body

The skeleton entry's bone name is the only placement data an item carries -- there is no attach
matrix in the file -- and the composition is the client's, read out of `sro_client.exe`
(2026-09-18, `docs/rounds/attach.md` has the evidence; the decompile is on the RE box, not in
this repo):

- **Link.** `CCompChar::FUN_00c4fc70`: if the part's attach-bone string (a `std::string` at
  `+0x58` of the part; its size at `+0x6c`) is non-empty, that bone is looked up in the body and
  stored as the item **root bone's parent socket** (`root+0xc`), and the root's update mode
  (`root+0xa0`) is set to **1**. The item skeleton is also registered in the body skeleton's
  child list so it updates after the body.
- **Update.** Every runtime bone (`CRTBone`, base `CRTSocket`; dummies are `CRTDummy`) keeps
  three 4x4 matrices: `mat0` local, `mat1` world, `mat2` skin. Mode 0
  (`RTSkeleton::FUN_00c49f20`) is ordinary forward kinematics, `mat1 = mat0 x parent.mat1`
  (D3D row vectors, `out = a x b`), then `mat2 = primInvBind x mat1`. **Mode 1**
  (`CRTBone::FUN_00c48fe0`) differs only in the parent frame: `mat1 = mat0 x [R(parent.mat2) |
  t(parent.mat1)]` -- the attach bone's **skin rotation** (its rotation relative to its bind,
  `invBind x world`) at the attach bone's **world position**.
- **What that means.** A root's local is its bind, so `invBind_root x local_root` cancels and the
  item's skin matrix is `[R(attach.skin) | t(attach.world)]`: the item's **model space lands at
  the attach bone's position with the body's axes**, rotated only by how far the bone has turned
  from its rest. Its own root rest never shows. Child bones of the item (a collar's two flap
  chains, a weapon's `ai_start`/`ai_end`) are mode 0 under that root and come out the same way.
  In Godot terms, under a `BoneAttachment3D` (which applies the bone's full pose) the item
  skeleton's local transform is the constant `(B_rest_attach^-1, 0)`; `SkinnedBsrAssembler
  .attach_item_from_archive` does exactly that.

Measured on the man's body (`tools/probe_attach.gd`), this puts `sword_01`, `blade_01` and
`spear_01` -- one hand, one set of clips -- on one heading (forward, -Z, in the T-pose; forward at
hip height in the town idle), and `clothes_01_sa` centred on `Bip01 Neck1`, 1.6 above it, across
the shoulders. The earlier "undo the item root's own rest" (round 137) only ever fitted
`sword_01`, whose root rest happens to equal the hand's global rest; it pointed the blade and spear
down and turned the collar front-to-back (round 141).

### Animation groups: which animation plays for what

The groups are keyed by **weapon kind**, and the client's own table of the names is built by one
static initialiser (`FUN_00d77650`) into an array of twenty `std::string`s at `0xec6280`, 28 bytes
apart, seventeen of them named: index 0 `default`, 1 `sword`, 2 `spear`, 3 `bow`, 4 `cart`,
5 `onehand_staff`, 6 `onehand_sword`, 7 `twohand_sword`, 8 `dagger`, 9 `dual_axe`, 10 `harf` (the
harp, spelt so in the binary), 11 `twohand_staff`, 12 `onehand_staff` again, 13 `avatar_wing`,
14–16 `avatar_nasrun1`–`3`, and 17–19 empty — the `nDefaultWearNum < DEFAULT_WEAR_NUM` assert
beside it names the index. A group is resolved by name (`FUN_00a5b300` walks the array comparing
strings), and a held weapon picks its index by `TypeID4` (`FUN_00a5a7d0`; ITEM_FORMAT.md has the
table). A China body carries `spear`, `bow`, `sword`, `default`, `cart` and the four avatar groups.

Within a group, each entry's **action type** says what the animation is for. Read off the China
man's `default` group, where every number is paired with a self-describing file name:

| Type | File | Type | File |
|---|---|---|---|
| 0 | `chinaman_fighter_standcity` (town idle) | 9 | `chinaman_a_behardhit` |
| 1 | `chinaman_fighter_walkforward` | 13 / 14 / 15 | sit down / sit / stand up |
| 2 | `chinaman_a_handstraightl` (plain attack) | 16 / 17 | `_handhookl` / `_handhookr` |
| 3 | `chinaman_a_benormalhit` | 22 | `chinaman_a_blocking` |
| 4 | `chinaman_a_diehardhit` | 23 | `chinaman_walkbackward` |
| 5 | `chinaman_a_handstraightr` | 36 | `chinaman_a_diehardhit_loop` |
| 6 | `chinaman_standbattle` | 38 | `chinaman_pickup` |
| 7 | `chinaman_fighter_runforward` | 50–57 | emotes; 26 and up are skills |

A monster's `default` group reads the same way — `mangnyang`: 0 `stand01`, 1 `walk`, 2 `attack01`,
3 `damage01`, 4 `die`, 5 `attack02`, 7 `run`, 8 `stand02`, 9 `damage02` — and an NPC's has 0
`chinaquest_priest_basic` and 122 `_time`, the idle fidget.

A weapon group only lists what differs: `sword` has its own attacks and run
(`chinaman_fighter_runforward_sword`) but **no stand or walk**, so those fall back to `default`;
`spear` has its own stand, walk and run. `BsrReader.ParsedObject.animation_for(type, group)` does
exactly that lookup with that fallback.

The four plain attacks are types 2, 5, 16, 17 — `sword_base_01` to `_04` in the sword group, and
bare-handed straight-left, straight-right, hook-left, hook-right in `default` — the chain the game
plays on successive hits.

### Events and walk points

Each entry's events are four words: a key time, a type, two parameters. Two event types occur:
**1 on every attack** (once or twice per swing — the moment the blow lands: `sword_base_01` at
200 and 566, `mangnyang_attack01` at 651) and **2 on every walk and run** (twice per cycle, with
parameters `(0, 1)` then `(1, 0)` — one per foot). The key time reads as milliseconds — a run's
footsteps at 305 and 633 of a cycle about 950 long, a walk's at 445 and 973 of one about 1,300 —
consistently across every entry checked, but that unit is inferred from the numbers, not read
from the client's use of them.

The walk points are two `(float, float)` pairs on every player entry — `(33.3, 0)` and `(0, 1)`
on a run, `(17, 0)` and `(0, 1)` on a walk, `(0, 0)` and `(0, 1)` on everything that stands
still — and up to four on a monster's walk. The first value looks like the speed the animation
was authored for (a run's 33.3 to a walk's 17, a monster's 10); **what the pairs mean is not
established** and nothing uses them.

Worked example, `chinaquest_priest.bsr` (717 bytes), every offset verified to chain:

```
0xC1  count 1                            material section
0xC5  uint32 0
0xC9  prim\mtrl\npc\china\chinaquest_priest.bmt      ends 0xF6
0xF6  count 3                            mesh section (== header 0x10)
0xFA  ..._al.bms      ends 0x12A
0x12A ..._part1.bms   ends 0x15D
0x15D ..._part2.bms   ends 0x190
0x190 4096, 0, count 2                   animation section (== header 0x18)
0x19C ..._basic.ban   ends 0x1CE
0x1CE ..._time.ban    ends 0x1FF
0x1FF count 1                            skeleton section (== header 0x14)
0x203 prim\skel\npc\china\chinaquest_priest.bsk
```

**Why this mattered.** The scan-based reader below finds only the *first* `.bms` in a type-1 file,
so it reported the priest as one 25-vertex piece — a fragment, not a person — and exposed no
skeleton at all, which is what blocked NPCs from being built. With the section table read
correctly the priest is 3 pieces / 665 vertices, `chinasystem_bookmakergirl` is 4 / 747, and
`mangnyang` is 2 / 440 with 15 animations. Because these models are skinned, the mesh pieces are
meaningless without the skeleton: a type-1 object should be assembled through `CharacterAssembler`,
not placed as rigid scenery. Both readers therefore refuse to report a character with no skeleton
path, falling back to the scan instead of returning something that would render as disconnected
limbs at the origin.

### Mesh entries (round 625, READ)

Nature files (type 4) also carry a skeleton and animations — that is how trees sway — and their
mesh entries carry a trailing `uint32` per piece that type 1 and type 2 do not (`tre_bank02`: mesh 1
ends 0x15A, a `0` word, mesh 2 begins 0x15E). **The client says when:** `ResObject::FUN_00be41d0`
reads each mesh entry's path, loads the mesh, and calls its `CPrimMesh` slot 4
(`FUN_00c12510`) with `flags & 1` — the header word at 0x2C — and that slot reads **one more
`uint32` into mesh +0x1f8 when the bit is set**. Load then marks the object (`param_1[0xc4] = 1`)
when any of those words is non-zero. So:

```
mesh section:  u32 count, then per mesh:  lp path  [u32 word, only when header 0x2C & 1]
```

**This used to read: "Those files simply fail the chaining check and fall back to the forward
scan, which is why no special case is needed for them." It was wrong, and it cost the leaves.**
The forward scan's nature-file branch returns the FIRST mesh only (`BsrReader.parse`, "nothing
past the mesh path is understood for this layout"), which is the trunk. MEASURED (round 625,
`client/tools/foliage_census.gd`): **149 of the 309 tree and foliage models Map.pk2's `object.ifo`
names fell back that way, 580 of 779 pieces loaded; with the word read, 0 fall back and all 779
load.** Every swaying tree in Jangan — `tre_maple01`/`02`/`03`, `tre_tree01`, `tre_smalltree01`,
`tre_bank01`/`02`, `tre_frie01`, the willows, `tre_pine01`..`04` — drew its trunk alone.

**What the word means (round 645, READ).** It is not animation. Its only readers are the object
ray test `FUN_00bd3c50` (a mesh is tested only when its word is non-zero; reached through
`FUN_00c337f0` from RTDunBlock/CCompChar picking) and `CResAttachable::FUN_00bd3130` (sets resource
flag bit 0 when any mesh's word is 0). So it marks the meshes that take ray hits, and Load's
`param_1[0xc4] = 1` means "has pickable meshes". A tree sways through its skeleton, as below.

### How a map object animates (round 645, READ from sro_client.exe)

A map object animates exactly as a character does, and only through its `.bsr`'s skeleton and
animation lists. There is no wind, sway or wave anywhere: the exe has no such strings, and the object
vertex-shader permutations (`CObjRendererVS::FUN_00bf67c0`, `shader\vss0.c`/`vss2.c`) have no wave
axis. Measured on the census in docs/WORLD_ISSUES.md (round 645), this puts 2,276 of the map's
placements in motion.

| Question | Answer | Where |
|---|---|---|
| What animates | A compound builds its AniMixer (compound+0xf8) only when the resource has a skeleton (res+0x250) AND at least one animation (res+0x184..0x188). Every animation slot starts with `if (compound+0xf8 != 0)` | `CCompChar::FUN_00c2b930`; creates the skeleton with `FUN_00c28210`, the mixer with `FUN_00c28280` |
| One path for all types | The factory builds CCompChar (type 0), CCompBldg (type 2) or CCompSimple (types 1, 3, 4, 5, 6). All four vtables share update (slot 14, 0xc33230) and play (slot 42, 0xc2bbb0) | `ResourceMgr::FUN_00be92b0` |
| Which clip | The sector's objects are started by `Map::FUN_00a34140` (the `.o2` list at +0x14, "list 2"), `FUN_00a342b0` (+0x24) and `FUN_00a34a90` (the region-level +0x247f list). Each calls `Map::FUN_00a38dc0(obj, "default", 0)`. The string is `DAT_00ec5934`, built at 0xd76980 from the literal at 0xd9bac8. That is group `default`, **action type 0**, and there is **no fallback** to animation index 0. Of two type-0 entries the **last** wins: the group reader `ResObject::FUN_00c0f500` hands each entry to `FUN_00c0f470`, which overwrites an existing type's clip in place (asm 0xc0f4e6); a file index below 0 stores a null clip (asm 0xc0f58d), and nothing plays | `AniMixer::FUN_00c551a0`: `FUN_00bd68e0` (group by name), `FUN_00c0e950` (entry by type) |
| Looping | CPrimAnimation +0x60 is the `.ban` IsCyclic word (the header is parsed into prim+0x38: +0x58 Duration, +0x5c FPS, +0x60 IsCyclic). Non-zero selects CRTAniCyclic (0xc75c80); zero selects CRTAniOneShot (0xc75ce0), which plays once | `FUN_00c530f0` / `FUN_00c53160`; `CRTAniOneShot::vslot_002` 0xc749a0 |
| Speed and clock | Speed 1.0 (`FUN_00c55360` → `FUN_00c72fd0(.., 1.0)`). Each frame does `t += round(speed*dt + frac)` and `t %= Duration`, in ms. FPS is unused | `CRTAniCyclic::vslot_002` 0xc74790 |
| Phase | No `rand()` is on the path. The constructor sets t = 0 (vslot_001), so objects start in step when their sector's objects start | the path above; the `_rand` callers in 0x9f0000-0xa60000 and 0xbc0000-0xc90000 checked |
| Cull and draw | A list-2 object is updated only while its fade state obj+0x1e is not 0. The state is advanced by `SWorld::FUN_00a38a50(state, dist, range)`: out of range when `range <= dist - radius`, so in range strictly below. `dist` is the 3D distance from the camera (camera struct +0x4, copied to SWorld +0x20a6) to the object's **placement origin** obj+0x57/+0x5b/+0x5f (asm 0xa2d92a). `radius` is `sqrt((dx/2)^2 + (dz/2)^2)` of the union of its mesh bounds (asm 0xa389f0). **`range` = `DAT_00ec54b0 - 480.0`** (asm 0xa2d961 `fld [0xec54b0]`, 0xa2d967 `fsub qword [0xde4f58]` = 480.0) = **2020** at the start value of 2500; the view-distance option sets `DAT_00ec54b0` to `min(0.8 × view distance, 2500)`, so the range is 720 / 1520 / 2020 / 2020 / 2020. States: 0 hidden; entering range from 0 goes to 2 (shown, alpha 255) when `range >= 1.5 × (dist - radius)` (the double at 0xe1b7e8), i.e. within two thirds of the range, else to 1 (fading in); 1 steps its alpha up by `512 × dt` (the double at 0xde5148) to 255 (0xd83108), then 2; leaving range, 1 or 2 go to 3, which steps the alpha down to 0 and then 0; an object out of range not visited for 50 frames drops straight to 0. Only sectors the frustum touches are visited (byte +0xba2, `Map::FUN_00a2b370`); the object is updated after the call only while its state is not 0 (asm 0xa2d9dd), and drawn only then (`Map::FUN_00a1e530`, asm 0xa1e791-0xa1e7d5, beside a per-object frustum test), with states 1 and 3 at alpha obj+0x23 (compound slot 5). Out of range the clock is **paused**. List +0x24 is visited only in the 9 nearest sectors, at range 480 (`DAT_00de4f64`). object.ifo flag bit 0 (the first hex column) puts an object on the region-level list, updated every frame | `SWorld::vslot_004` 0xa2cf60, `SWorld::FUN_00a38a50`, asm 0xa389f0/0xa2d92a/0xa2d961, `SWorld::vslot_043` 0xa194a0 |
| Pause is per object (round 647) | The fade state is the object's own byte obj+0x1e, tested against the object's own `dist - radius` (above). The update after it (asm 0xa2d9dd: `cmp byte [ebp],0`, ebp = obj+0x1e; then the compound's slot 14, the update, `call [vtable+0x38]` with `DAT_0110f7f8`, 1 and 0.0) runs per object; every object of the pass gets the same `DAT_0110f7f8` (one global; that it is the frame's elapsed time is INFERRED, beside the float dt at 0x110f7fc the fade uses). obj+0x27 is stamped with SWorld +0x6720 and an object already stamped is skipped (asm 0xa2d91b/0xa2da08), so an object listed by two sectors is updated once a pass (that +0x6720 counts frames is INFERRED). So two objects' clocks are equal exactly when they started in the same frame and were updated in the same frames since; a sector leaving the view pauses all of its objects together, and crossing the range edge pauses one object alone | `SWorld::vslot_004` asm 0xa2d904-0xa2da08 |
| Pose skip | `AniMixer::FUN_00c54200` skips frames when `DAT_01113194 != 0`. That global has no writer, so this is INFERRED off | asm 0xc54207 |
| Skinning | The characters' path: AniMixer → runtime skeleton (compound+0xf4) → CObjRendererVS SKIN0/SKIN2 | as above |
| After a one-shot | The mixer unlinks the finished clip (`AniMixer::FUN_00c53e80`). With no clip left, the pose evaluation `AniMixer::FUN_00c54200` only clears each bone's blend weights (`FUN_00c4c3f0` → `CRTBone::vslot_004`, asm 0xc47a20: +0x98 and +0x9c = 0); the apply (`vslot_005`) and the skeleton update (`FUN_00c4c320`) run only when a clip was evaluated, so the bones and skin matrices **keep their last pose** | as named |
| Unskinned pieces of a skeletal object | OPEN (mesh+0x3c bit 0x400 selects a second triangle test) | |

**How this client runs them (round 647; OURS on the READ rules above).** `MapAnimation.Driver`
keeps retail's per-object pause and per-frame dt and saves work three exact ways:
- **Shared poses.** Clips of one model's Animation that start in the same frame at the same clock
  are one `PoseGroup`: one AnimationPlayer and one Skeleton3D under World3D's
  `MapAnimationPoses`, with every member's skinned pieces bound to that skeleton. Godot skins a
  piece from the skeleton-space bone poses (`pose_global * bind`, `Skeleton3D`
  NOTIFICATION_UPDATE_SKELETON) and the piece's own transform, never the skeleton node's
  (READ, Godot 4.2.2 `scene/3d/skeleton_3d.cpp` and `mesh_instance_3d.cpp`
  `_resolve_skeleton_path`), so a member stands and turns where it is placed. A member whose clock
  stops leaves at once: its own player is set to the group's clock and its pieces are bound back.
  A start never joins a group already running (a group already processing advances in that frame
  and a newly started clip does not: Godot copies the process list before the frame's first node,
  `scene_tree.cpp` `_process_group`). One-shot clips are never shared.
- **Per-sector range bounds.** With `rho` the farthest origin from a sector's centre, every object
  is in range when `d + rho - rmin < 2020 - 1` and out when `d - rho - rmax >= 2020 + 1` (a 1-unit
  guard band); a sector decided the same way as last frame is not visited, and a sector wholly out
  of range whose objects are already off is not even view-tested.
- **A camera held still** re-tests nothing: every decision would come out as the last tick's.

**TEXANI (READ in outline, not drawn).** `ModDataTexAni::vslot_004` (0xc5c5a0) reads the IModData
header (its four bytes are the start frame, the end frame and flags), then five words to
+0x24..+0x34 (fps at +0x2c, rows at +0x30, columns at +0x34) and a 64-byte matrix. `CRTModTexAni`'s
step (asm 0xc82640) accumulates dt and advances one frame per `1000.0 / fps` ms. Flag bit 0 loops
and bit 1 ping-pongs; otherwise it clamps at the end. The UV offset is `(frame % cols) / cols,
(frame / cols) / rows` (`FUN_00c825f0`), uploaded to VS register 0x17 by `CRTModTexAni::vslot_004`
0xc82970.

### Material-state mods (round 625 and its review, READ)

The mod-data section below carries `ENVMAP` (0x40000) and `MTRL` (0) mods that change how a
material is drawn. Each has an `IModData` header (`FUN_00c5c2a0`: six words into +0x08..+0x1c,
then four bytes):
- **word 1, +0x0c** — the dispatch. `FUN_00c7b540` runs a mod with 2 on each material's draw, and
  `FUN_00c7b4e0` runs one with 1 once per object with material index −1.
- **word 3, +0x14** — the material index.
- **word 5, +0x1c** — the flag word.

`BsrReader.ParsedObject` keeps them:
- `material_mods` holds every such mod.
- `env_map_flags` holds the last live ENVMAP (ambient set, word 1 of 1 or 2). **It governs every
  material of the object.** `CRTModEnvMap::vslot_004` switches the material's test off and sets
  its own before its index compare.
- `mtrl_mod_for(index)` gives the MTRL body's states for a material.
- `two_pass()` gives header flag bit 1.

`BUMPENV` (0x40001) sets no alpha state and is not counted. BMT_FORMAT.md, "The flag word, READ",
has the states. **12 China weapon and shield files carry a live ENVMAP of their own**
(`blade_14` and `tblade_14` among them; round 625 had said "only those two").

## Every type is read through the table

**Since 2026-09-09**, both readers take the section table for *every* object type and fall back to
the forward scan only when it doesn't chain. Measured with `client/tools/sweep_bsr.gd` over a real
`Data.pk2`'s 8,539 files: the table parses 7,978 (93%), and on a verified 1,500-file sample every
mesh path it produces resolves to a real file — **zero unresolved**. The scan it replaced returned
a **duplicated mesh for 2,787 files** (a third of the archive drawing a piece twice) and a
different mesh count for 3,770, including `W_CD_boat.bsr`, where the scan found one mesh and the
table finds six — geometry that was simply not being drawn.

## After the name

| Field | Encoding |
|---|---|
| (2 unconfirmed `uint32` fields, observed values 10 and 2) | |
| (reserved padding, observed ~40 zero bytes in well-formed files) | |
| Mesh path | `uint32` length + ASCII bytes |
| Bounding box + tail | 6× `float32` (min xyz, max xyz), then `float32` ×6 sentinel padding (`FLT_MAX`/`-FLT_MAX`, an "uninitialized" idiom) and 3× `uint32` (observed `0, 1, 0`) — 60 bytes total, confirmed in 2 of 3 real files; one had 4 extra leading zero bytes and effectively no mesh path (see below) |
| Material path | `uint32` length + ASCII bytes |
| Sub-mesh count | `uint32` |
| Sub-mesh paths | that many `uint32`-length-prefixed ASCII paths, back-to-back, no gaps |

The sub-mesh count is self-validating: in every real file checked, it exactly matched the number
of further `.bms` paths actually present before the file's trailing boilerplate. A fixed 20-byte
block (byte-identical in every file checked: `0010000000000000000000000000000001000000`) followed
by a length-prefixed string `"default"` appears at the very end of every file checked — likely a
default material/group name — but its exact role isn't confirmed.

**Correction (2026-08-23, live-tested against real Jangan palace buildings)**: the sub-mesh count
is *not* always self-validating for a real, bigger multi-piece building — at least one real
Jangan building's declared count didn't exactly match how many further real length-prefixed path
strings were actually present afterward. The real cause isn't confirmed (most likely a real
trailing per-piece field this project's earlier, simpler 2-4-piece samples never had enough real
sub-mesh pieces to expose — see the "default"-block boilerplate above, which might not always sit
cleanly after the *last* sub-mesh path the way every earlier sample showed). Both readers
(`BsrReader`/`bsr`) now keep whatever real sub-mesh paths parse successfully and stop there rather
than discarding the whole real object (including its already-confirmed-real primary
`mesh_path`/`material_path`) over one bad trailing piece — see `docs/PROGRESS.md`'s 2026-08-23
"found real Jangan" entry.

**Further correction, same day**: a bad trailing sub-mesh read doesn't always fail outright — it
can succeed with a real but obviously-wrong value, since the read has simply spilled into the
file's own trailing boilerplate (the fixed 20-byte block + "default" string above) rather than
running past the end of the file. Two real shapes confirmed live: a real empty string
(`tre_bank02.bsr`, a real tree whose declared sub-mesh count included one more entry than real
sub-meshes existed) and a real single stray byte, `"6"` (`tre_maple01.bsr`, same shape). Both
readers now also stop the sub-mesh loop when a read succeeds but produces something that isn't a
plausible `.bms` path (reusing the same plausible-path-character check already used for locating
the mesh/material path strings), not just when the read fails structurally.

## Sub-mesh pieces need no separate transform

Confirmed against two real sub-mesh pieces of the same `.bsr` object (`asiaminor_theater02_
brokenwall01.bms` and `asiaminor_theater02_column01.bms`, pulled from a full unpacked client data
tree, not a pk2): each piece's own bounding box is already large-scale and independently
positioned (e.g. `x:[-1024, 761], z:[-1720, 271]` vs. `x:[-1397, 1446], z:[-1427, 304]`) — not
centered at the origin. Each `.bms` piece carries its own absolute position baked directly into
its vertex data. There is no missing per-part transform to find in `.bsr`; placing every piece at
`Vector3.ZERO` relative to the object root, exactly what `ObjectLoader` already does, is correct.

## A known edge case

One of the three real files checked (`asiaminor_theate06r_brokenwall01.bsr`, notably a
typo'd/oddly-named file whose *material* path referenced a different object, `theater04`, not
`theater06`) appears to have an **empty mesh path** — the byte sequence right after the two
unconfirmed header ints is a much longer run of zero padding (76 bytes instead of ~40) leading
straight into the bounding-box block and then the material path, with no mesh path string at all
in between. This looks like a stray/incomplete authoring artifact rather than the norm, but it
means the format can have a legitimately-empty mesh path that our reader doesn't yet handle — it
fails with a clear error on that file rather than silently returning wrong data, which is the
correct failure mode until this is understood better.

## SOLVED: `res\nature\...` (tree/grass) files use a genuinely different field order

Found while wiring up real `.mapo` object rendering (see `docs/protocol/MAPO_FORMAT.md`'s object
index section): real `res\bldg\...` (building) files — the category this format was originally
derived against, e.g. `cj_ferry_stone01.bsr` — parse correctly, sub-meshes and all. Real
`res\nature\...` files (e.g. `center_asia_plant01_01.bsr`, `oas_grs_weed04.bsr`) initially didn't:
the scanned-for "mesh path" came out pointing at a `.bmt` (material) file instead of a `.bms`, and
the "material path" that followed was a garbage 1-character string.

**Root cause, confirmed by hex-dumping a real `center_asia_plant01_01.bsr` byte-for-byte**:
nature-category files genuinely put these fields in the opposite order from building-category
ones. Building order: `[name][2 fields][padding][mesh path][bounding box + tail][material path]
[sub-mesh count + list]`. Nature order: `[name][2 fields][padding][bounding box + tail]
[material path][a "1" field][mesh path]` — bounding box and material path come *first*, with the
mesh path last, and there's no confirmed sub-mesh-list convention for this order. The original
reader assumed "whichever plausible path string is found first is the mesh path, the next one is
the material path" — correct for buildings, silently wrong for nature files, which put the
material path first.

**Fixed** by scanning independently for the first string ending in `.bms` (the mesh path) and the
first ending in `.bmt` (the material path), rather than assuming an order — this finds the right
field in either layout without needing to detect which category a file belongs to first. The
bounding box and sub-mesh list are still only attempted for the building order (mesh before
material); the nature order's bounding-box position isn't confirmed, so it's left unclaimed
(`HasBounds`/`has_bounds` false) rather than guessed at. Verified against a real
`center_asia_plant01_01.bsr` end-to-end: real mesh, real material, and (via `ObjectLoader`) a real
rendered, textured plant — see `docs/PROGRESS.md`.

## SOLVED (the common case): real sub-mesh pieces carry the same name-matched material_name field character parts do

**Previously**: `ObjectLoader` had no confirmed way to know which `.bmt` layer belongs to which
mesh piece when a material has multiple layers and no name match is available — it fell back to
pairing layer `i` with mesh piece `i` only when the two counts happened to match, and layer 0
otherwise.

**Confirmed real, directly, on 4 real sub-mesh pieces**: pulled a real 27-piece building
(`bagh_city_palace.bsr`, `Res\Bldg\arabia\bagh_city\structure\`) and its real 28-layer material
(`bagh_city_palace.bmt` — one extra layer than pieces; not investigated further). Every real
layer's `layer_name` is literally a piece number (`Bagh_City_Palace_01`, `_04`, `_15`, `_27`, ...,
in a shuffled order that does **not** match mesh-piece order in the file). Parsed 4 of those real
piece `.bms` files directly (`_01`, `_04`, `_15`, `_27`) and found each one's own `material_name`
field (the same real per-mesh field `.bms` already carries for character body parts, see
`BMS_FORMAT.md`) exactly equals the matching real layer's `layer_name`, in all 4/4 checked. So the
same name-matching mechanism `CharacterAssembler` already used for character parts also applies to
`.bsr` sub-mesh pieces — this project's reader just wasn't using it there.

**Fixed**: `ObjectLoader.load_object` (`client/scripts/assets/object_loader.gd`) now looks up each
mesh piece's own real `material_name` against the material's real `layer_name`s first
(`_find_layer_by_name`), falling back to the old index-based heuristic only when no name matches —
which is now the honestly-still-unconfirmed remaining case, not the common one. Verified with a
dedicated synthetic test (`object_loader_test.gd`) using two pieces and two layers in deliberately
shuffled order (mirroring the real `bagh_city_palace` shape) — confirms each piece gets its real
name-matched layer, not whatever the old positional pairing would have picked.

## A deeper real mechanism also found, not yet mapped to byte offsets or implemented

The name-matching fix above resolves the common case (a mesh piece's own `.bms` carries a
`material_name`), but doesn't explain what happens when it doesn't — decompiling the real client
surfaced a second, deeper real mechanism for that case, described below.

**Investigated by decompiling the real client's actual `ResObject::Load`** (`sro_client.exe`),
traced from the known `FUN_00bed8d0`/`FUN_00bce3b0` entry points documented above, through the
real type-dispatch factory (`FUN_00be9250`, a switch on an object-type code — case 0 turned out to
be `ResChar` per a real `"D:\...\ResChar.cpp"` string, a different real class; the correct branch
for static scenery objects is one of cases 1/2/3/4/6/7, `FUN_00be8dc0`) down to the concrete
`ResObj` vtable's `Load` method, `FUN_00be41d0` — confirmed as the real target by a literal
`"D:\...\ResObject.cpp"` string and a `"m_PrimMeshGroups.size() == 0"` assertion message right
where the mesh-group list is read.

**The real mechanism, as decompiled**: for each of `m_PrimMeshGroups`'s real count of entries, the
loader reads one mesh-group's own path string, then a real `uint32` count, then that many further
`uint32` values — each one used as an index into a separate shared array (`param_1[0x5d]` in the
decompilation, plausibly the object's material/layer list) which gets copied into that mesh
group's *own* per-group index array. In plain terms: **each mesh piece carries an explicit,
file-encoded list of which material-layer indices apply to it** — not an implicit pairing inferred
from matching counts, and not always "layer 0" as this project's fallback currently assumes. This
directly answers the open question, in principle.

**Not yet done**: mapping this decompiled mechanism to concrete byte offsets in a real `.bsr` file
(i.e. hex-dumping a real multi-layer, multi-piece object and locating this count-prefixed index
list in the actual bytes, the same way every other field in this doc was pinned down). The
currently-documented flat struct above doesn't have a slot for it, and the real `Load` function
reads noticeably more real sections than that struct currently models (bounding-box-adjacent
fields, several tagged skip/seek points) — this pass found the *mechanism*, not (yet) its exact
place in the byte layout, so nothing here has been implemented or wired into `ObjectLoader` yet.
Flagged as a real, promising, correctly-scoped next step rather than guessed at further.

## Implementation notes

- `server/internal/bsr` (Go): parses name, mesh path, bounding box (best-effort, building-order
  only — see above), material path, and the sub-mesh path list. Rather than trust the header's
  offset table (shown above to be unreliable), it locates the mesh and material path strings by
  scanning forward for the first plausible length-prefixed ASCII path ending in the expected
  extension (`.bms`/`.bmt`) — the same technique used to cross-check every real file during RE,
  and the only approach confirmed to work correctly on both real field orders. Unit tested
  (`go test`) against synthetic fixtures for both orders (never real game data).
- `client/scripts/bsr/bsr_reader.gd` (GDScript): mirrors the Go implementation field-for-field,
  used at runtime by `ObjectLoader` to build real, textured `Node3D`/`MeshInstance3D` trees.


## Skill animations are ACTION TYPES, not filenames (2026-09-20)

The table above notes "26 and up are skills". Counted, with
`client/tools/probe_anim_types.gd` on `char\china\chinaman_fighter.bsr`:

| group | entries | action type >= 26 |
|---|---:|---:|
| `default` | 92 | **74** |
| `spear` | 58 | **50** |
| `sword` | 52 | **47** |
| `bow` | 49 | **46** |
| `cart`, `avatar_wing` | 3, 1 | 0 |

So each weapon group carries around fifty skill animations, keyed by action
type. **The union across `sword` and `default` is 99 distinct types**, running
26..220.

**This settles how a cast animation is selected, and it is not by filename.**
The decompiled client contains **zero** references to the `.ban` extension: it
never builds a clip path in code, it looks an entry up in this table by action
type and follows the index into the animation list. srrevamp's client derives
`Prim\Ani\Char\China\<gender>\<basic_code>.ban` instead, which is why only
**59 of 338** skills find anything (`docs/protocol/skill_fields.md`) -- it is
the wrong mechanism, not a broken path.

**Which skilldata column carries the action type is NOT settled.** Scanning
every column for values inside the 99-type set puts column 36 first at 64 % of
rows -- and column 36 is already documented as the **required mastery level**,
which simply lives in the same numeric range. With 99 permitted values spread
over 26..220 any numeric column scores, so the test cannot discriminate and
nothing is promoted from it.

**That probe was run (round 317) and returned a NEGATIVE.**
`client/tools/probe_skill_action_types.gd` prints every entry as
`group, action type, clip path`; 276 entries for the China man. Joining the 519
skill rows whose derived clip appears there against every numeric column:

| column | rows carrying that skill's own action type |
|---|---:|
| 36 | 14 of 519 (**3 %**) |
| 80 | 9 (2 %) |
| everything else | <= 5 |

**No column carries it.** Column 36 leads by chance and is the documented
required mastery level. The action type is not in skilldata.

**And the BSR table is not a better index than the directory:**

| | |
|---|---:|
| distinct CH skill clip names | 338 |
| present in the man BSR table | **57** |
| present on disk in `prim\ani\char\china\man` | **59** |
| in the BSR but not on disk | **0** |

The entries point at exactly that directory (`prim\ani\char\china\man\...`),
so srrevamp's path construction was never wrong, and switching to the BSR
lookup would find **two fewer** clips rather than more.

**What this leaves.** The body carries 217 distinct clips against 338 skills, so
sharing is certain, and the link for the ~280 skills with no clip of their own
is **not name-based, not a skilldata column, and not in the BSR table**. It is
in the client's code or in a table not yet identified. Three independent routes
are now exhausted, which is why the client's weapon-swing fallback stays and is
labelled disclosed rather than treated as a temporary patch.

**Found (round 616-618 integration): the link is skilleffect.txt's `#section skillaniset2`.**
READ in sro_client.exe: the loader `FUN_00a9eb60` hands `skillaniset`/`skillaniset2` rows to
`FUN_00a9c470`, keyed by the SkillID column (col 2, the Basic_Code without its level). After
Priority, AniTRUE, Hide Weapon and AniGroup (cols 3-6) it reads six comma-separated lists of up to
nine `ANI_` names (cols 7-12: AniReady, AniWait, AniShot, Ani play Timing, Act W, Act S), each
name through the ANI_ name map (`FUN_00a94f50`, -1 and dropped when absent), stored as action
types at record `+0xe`/`+0x20`/`+0x32`... with counts at `+8`.. . `FUN_009e5240` registers the
map: `ANI_SKILL_1` 0x1a (26) .. `ANI_SKILL_10` 0x23, `ANI_SKILL_11` 0x44 .., `ANI_READY01` 0x28 ..,
`ANI_WAIT01` 0x5b .., and the early names agree with the action types read off real bodies (STAND1
0, WALK 1, ATTACK1 2, ATTREADY 6, RUN 7, SIT_DOWN 13, SIT 14, STAND_UP 15, WALK_BACK 23) --
`SkillEffectReader.ANI_TYPES` holds the table. The deco start `FUN_00a54f00` plays WAIT on the
body at once as vslot 0xb4(group, type, 200) where **the group is the row's AniGroup** (record
`+4`, interned by `FUN_00a9a6f0`), not the held weapon's; it keeps READY and SHOT for later
phases, and **when all three are empty plays nothing** (it ends the deco and returns). Type 32 in
the man body is `skill_china_lightning_bobeop` in `default` but `skill_ch_sword_downattack_a` in
`sword` (MEASURED, `probe_skill_action_types.gd`), so the group matters. In `skillaniset2` the
loader reads col 0 first and skips the row when it is 0 (the manager's `+0x10` flag, set to 1 for
that section by `FUN_00a9eb60`); a SkillID met again reuses its record, appending to each list and
overwriting the scalars (READ in `FUN_00a9c470`; the 616-618 integration review). MEASURED over the box's 1,044
skillaniset2 skill rows: 52 distinct names resolve; `ANI_SHOT` (47 cells) and `DOWN_UP` (2) are in
no registration. Wired so far only for self and ground casts (`World3D._play_self_cast_anim`):
Grass Walk and the lightning imbues name no list and play nothing; Ghost Walk's WAIT is
`ANI_SKILL_7`, action type 32, in group DEFAULT (the AniGroup name matched to the body's group
name lower-cased: INFERRED). Targeted casts still take the name route and the swing (OPEN: the
READY/SHOT phase timing, the per-deco pick among several entries).


## How the group is chosen, from the client's own code (round 318)

`CObjCharacter::RefreshAnimationGroup` (`0x00a5bd10`) is the function that
decides which animation group a body uses:

	weapon = GetEquipVisual(6)                  ; slot 6 IS the weapon
	race   = charData[0x9c]
	group  = FUN_00a5a7d0(weapon.TypeID4, race) ; the recorded TypeID4 switch
	assert(group, "pStrAniNew")                 ; CObjCharacter.cpp:0x847
	char[0x18c] = group                         ; cached; a change restarts the body

**Slot 6 is the weapon on arithmetic, not on assumption**: `EQUIP_SLOTS.md`
puts the visual array at base `0x38` with stride `0xc` and WEAPON at `0x80`, and
`(0x80 - 0x38) / 0xc = 6`.

So the group is a function of **the held weapon's TypeID4 and the race byte**,
and of nothing per-skill. That is exactly what srrevamp's client already does
(`_weapon_group_for`), which is now confirmed rather than assumed — and it means
the skill -> **action type** link, still unfound after four routes
(`skill_fields.md`), cannot be hiding in the group selection either.

`char+0x18c` holds the current group string, which is the field to watch when
tracing further.


## Sound tracks: the section at 0x24 (round 613)

**READ** from `sro_client.exe` (decompile `/var/tmp/decomp_client`, asm `/var/tmp/sro_client.asm`)
and **verified against every character `.bsr` in the box's Data.pk2** with
`client/tools/sweep_bsr_sound.gd`, which runs `BsrReader.parse_sound_section` -- the reader the
client uses. Nothing here is guessed; what is inferred is marked.

### Layout

The loader is `ResObject::FUN_00c0b740`, called from `ResObject::FUN_00be41d0` right after the
bounding box and before `CResAttachable::vslot_007`:

```
i32 set count      -- list 1, kept in a map by name
  set x count
i32 set count      -- list 2, kept in an array
  set x count
```

A **set** (`FUN_00c0b640`):

```
u32 kind           -- 1 in list 2; 0 in list 1, or 2 for the set named "ambient" (FUN_00c0b060)
i32 action type    -- list 2: the animation entry's action type; list 1: -1
lp  name           -- list 2: the animation group ("default", "sword", ...); list 1: a clip name
i32 mod count
  per mod: u32 kind word, then that kind's body
```

The kind word is `category << 16 | subtype`, the switch of the factory `FUN_00c0b460`. Every body
starts with `IModData`'s header (`FUN_00c5c2a0`: six words and four bytes, 28 bytes):

| Kind | Class | Body after the 28-byte header (each class's `vslot_004`) |
|---|---|---|
| 0x00000 | ModDataMtrl (`0xc626c0`) | u32, u32 flags, u32; i32 n, n x 20 bytes; if `flags & 4`: i32 m, m x 8 bytes; then 36 bytes |
| 0x10000 | ModDataTexAni (`0xc5c5a0`) | five u32, 64 bytes |
| 0x10001 / 0x10002 | ModDataMultiTex / Rev (`0xc613b0` / `0xc61430`) | u32, lp-string, u32 |
| 0x30000 | ModDataParticle (`0xc643b0`) | i32 n; per entry u32, lp, lp, 12 bytes, u32, 4 bytes, and 12 more bytes when the fourth of those is non-zero |
| 0x40000 | ModDataEnvMap (`0xc5c4e0`) | four u32 |
| 0x40001 | ModDataBumpEnv (`0xc62cf0`) | the EnvMap body, six floats, i32 n; per entry a byte and, when it is 1, an lp-string |
| **0x50000** | **ModDataSound** (`0xc63f30`) | i32 n; **only if n > 0**: 44 bytes (`FUN_00bbe240`), then n x { lp key, track list } |
| 0x60000..0x60002 | ModDataDyVertex / DyJoint / DyLattice | nothing |
| 0x70000 | ModDataProgEquipPow | nothing |

A **track list** (`IResModData::FUN_00c62ff0`): i32 count, asserted `0 <= n <= 15`
(`MAX_SOUND_TRACK_PER_ANI`, `IResModData.cpp` line 0x344), then that many tracks. A **track**
(`FUN_00c614b0`; the writer `FUN_00c60000` agrees):

```
u32 flag           -- when it is not 1, nothing else follows
lp  wav            -- only when flag == 1
u32 key time
lp  event name
```

So a flag-0 track is **four bytes**. (The research notes said the key time and name always
follow; they do not -- 989 flag-0 tracks in the archive prove the four-byte reading, since the
sections chain only with it.) The embedded `.wav` is loaded only when the resource manager's
`+0x190` flag is 1, which nothing sets (INFERRED, strongly): the game plays the effect-table row
behind the **event name**, not this file. Every ModDataSound in the archive has exactly one
list, keyed `default`; the runtime takes the list by key and falls back to the first
(`CRTModSound::FUN_00c5fa20`).

After the section a character file ends, or carries the block `CResAttachable::vslot_007` reads
next -- three words, i32 n, n x 8 bytes -- and the one word `CResChar::vslot_007` asserts is 0
(`nComboNum == 0`).

### The parse-all check (MEASURED)

`sweep_bsr_sound.gd --pk2=/opt/sro-files/client/Data.pk2 --durations`, over the **1,012** `.bsr`
files of object type 0 or 1:

- **1,006 parse.** Of those, the section ends **exactly at EOF in 724**, and exactly where the
  attachment block begins -- which itself ends at EOF -- in **270**. **12** leave bytes that do
  not form that block (2 to 27 bytes of zeros, or a `-1, 13, 0, ...` block with extra bytes; all
  under `Res\COS\` and `Res\pet2\`, mounts and pet saddles): the section ends there, what the
  client makes of those tails is not read.
- **6 do not parse.** Five are **4,096 bytes long in the archive's own directory** (`c_lunar`,
  `lavahound`, `nightfury`, `pet_cyberdog_a`, `pet_lunar_a`): truncated files, the section runs
  past their end. The sixth, `Res\NPC\NPC\tt.bsr` (1,215 bytes), breaks inside its first list.
- **Counts:** 3,730 sets by clip (list 1), **19,733 by type** (list 2); tracks with an event:
  4,357 in list 1, **35,894 in list 2**; 989 flag-0 tracks. Mod kinds: 20,637 sound, 1,270
  particle, 158 dyvertex, 117 material, 33 envmap, 29 texani, 8 multitexrev, 5 bumpenv,
  4 multitex. (Whether any set carries two sound mods was not counted; the reader would join
  their tracks.)
- **Event names:** in list 2 the top names are `snd_swing_s1` 12,473, `snd_swing_s2` 4,525,
  `voc_shout2` 4,365, `snd_swing1` 3,556, `voc_shout1` 2,513, `snd_swing2` 1,727, `snd_walk1`
  1,490, `snd_run1` 1,186, `voc_moan` 770, `voc_death` 409, `voc_emo` 400, `snd_death` 390,
  `snd_stand` 227. Names the handler table does not have (so silent in retail): 628 empty names,
  `snd_swing_s` 279, `snd_run` 101, `snd_walk` 94, `snd_swing_2` 36, `snd_shout2` 16,
  `voc_moan1/2` 9 each, `snd_stand5/6`, typos (`snd_swign1`, `smd_swing1`). **`voc_avoid` occurs
  in no track at all.** List 1 is dominated by `snd_run` 2,274 and `snd_walk` 1,056 -- names
  with no handler, which is why the type-keyed list is the one that plays.
- **Key times against clip lengths:** of the list-2 tracks whose entry resolves to a clip in
  the same group, **25,166 fall within the clip's own length and 39 past it** (for example a
  walk's `snd_walk1` at 1,336 of a 1,333 ms clip, and the China woman's die clip `snd_death` at
  2,496 of 1,666). That is the evidence for reading key times as **milliseconds of the clip**
  (INFERRED; how they scale with playback speed is OPEN).

### Which set plays (INFERRED)

The runtime lookup of a list-2 set was not found in the decompile. srrevamp plays the set keyed
by **the entry the clip was found as**: the action type and the group
`ParsedObject.animation_group_for` finds it in (the weapon group, or `default` when the weapon
group has no entry of that type). Measured over the same files, for the basic types
(0-9, 16, 17, 36): 5,600 sets match an entry in their own group; weapon-group entries with their
own set 1,580, without one but with a `default` set 794, with none 320. A weapon group's own clip
therefore never borrows the default clip's key times, at the cost of silence in those 794 cases
(avatar groups, mostly). 747 of 20,108 (file, clip) pairs are reachable as more than one entry,
nearly all skill clips.
