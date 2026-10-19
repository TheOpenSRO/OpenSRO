# Dynamic Animation: per-vertex cloth, and what a worn item plays (round 794)

The Video tab's **Dynamic Animation** row (case 0xe, TTDESC_14 "fabrics and hair") turns on a
per-vertex cloth simulation of every mesh that carries cloth data: robes, skirts, dresses, capes,
hair, wings, tassels, banners, flags, tents and cobwebs. It runs on characters, NPCs, monsters,
mounts and placed map objects alike. Everything below was read from `sro_client.exe` (the decompile
and disassembly on the render box) or measured across the retail archives.

Labels: **READ** means seen in the code. **MEASURED** means it comes from the data. **INFERRED**
means reasoning. **OPEN** means not established. OURS marks a choice of this client.

The client is `ClothSim` / `SrCloth` (one mesh), `ClothNative` (which of the two runs), `ClothDriver`
(the hosts, each frame) and `WornItemFx` (a worn item's particles and clips).

## 1. The data

**Only DYVERTEX is used (MEASURED, 8,524 of 8,539 `.bsr` parsed).**
- Mod kind 0x60000 appears in 1,235 `.bsr`, one mod each and always in the `ambient` set (2 in
  `default`, action type 4).
- Its 28-byte IModData header is identical in all of them: `0.5f, 1, 0, -1, 0, 0`, then four zero
  bytes.
- DYJOINT (0x60001) and DYLATTICE (0x60002) appear in **no** file.

**The mod does nothing at runtime (READ).**
- `FxModManager::FUN_00c797f0` case 6 builds CRTModDyVertex: ctor `FUN_00c842e0`, vtable 0xe0ea0c,
  type 8. Its slots are the CRTMod base init (`FUN_00c43750`), the base finished test
  (`FUN_00c43780`) and 1–3-byte `ret` stubs (0xc45600..0xc456b0).
- ModDataDyVertex has no body reader; the 28 bytes are the generic header (`FUN_00c5c2a0`).
- Nothing on the simulation path reads the mod. A mesh simulates because of its own data.
- DYJOINT (type 7, ctor `FUN_00c84380`, vtable 0xe0ea4c) and DYLATTICE (type 9, ctor 0xc84420,
  vtable 0xe0ea8c) are the same stubs. A skeleton-dynamics flag exists (`CCompChar+0x11c`, set by
  `FUN_00bcb220` when the `.bsk`'s two trailing arrays are non-empty), but the `.bsk` loader
  (`CPrimBranch::vslot_001` 0xbfb580) asserts both counts are 0, and all 1,244 real `.bsk` end in
  8 zero bytes (MEASURED). No code moves bones: hair is mesh cloth.

**The mesh's cloth sections (`.bms`, BMS_FORMAT.md hdr[2] / hdr[3]).** A mesh is cloth when hdr[2]
and the hdr[3] links are both non-empty (`ResObject::FUN_00bce1a0`, READ).
- hdr[2], per vertex: `f32 amount`, `u32 pinned` (1 exactly when the amount is 0).
- hdr[3]: `u32 count`, count × `{u32 v0, u32 v1, f32 rest}`, count × `u32` (an order over the
  links), then **36 bytes: the cloth's parameter block** (read inline, `CPrimGeometry` this+0x31).

| Block offset | Type | Use (READ, `FUN_00c0d720` / `FUN_00c0d010`) | Most common (MEASURED, 801 meshes) |
|---|---|---|---|
| +0x00 | u32 | non-zero: the gust blows along the file's vector | 1 in 706, 0 in 95 |
| +0x04 | vec3 | the file's gust vector | (0, 0, 1) in 176 |
| +0x10 | f32 | gravity | 9.8 in 465 |
| +0x14 | f32 | gravity's gain per amount | 1.0 in 406 |
| +0x18 | f32 | the gust's gain per amount | 0 in 375 |
| +0x1c | f32 | the velocity a step keeps | 0.95 in 381 |
| +0x20 | i32 | a gust when `rand() % n == 0` | 2 in 334; never below 1 |

MEASURED across all 801 cloth meshes:
- every order list is a permutation of the link indices;
- no link joins two vertices of amount 0 (the step divides by their sum);
- every rest length is the bind-pose distance, within 1.9e-5;
- vertices per mesh 4..3,294, free 1..935, links 4..2,182; 626 skinned, 175 rigid.

**Who carries cloth (MEASURED, DY files / files with a cloth mesh):** avatar items 522 / 327, bldg
107 / 99, mob 75 / 40, China man items 70 / 58, China woman items 65 / 56, China weapons 56 / 26,
Europe man items 49 / 38, artifacts 46 / 45, Europe woman items 37 / 29, NPCs 33 / 30, mounts 21 /
16, bodies 16 / 12 (the China-man hairs), dungeons 15 / 15, pets 8 / 6, China shields 5 / 2.
130 cloth meshes sit under no DY `.bsr`, among them the hair of every China-woman and Europe body;
since the runtime never reads the mod, they simulate too (INFERRED from the absent check).

## 2. One step (READ, `CCompChar::FUN_00c0d010`, asm 0xc0d010..0xc0d60c)

Particles: `dyn+0x24`, 24 bytes each, `{cur, prev}`, both the bind position at creation
(`FUN_00c1af60`). With `a` the vertex's amount, `S` the block, `w` the wind and `p` the third
argument:

```
p' = p > 0 ? (p < 0.2 ? 0.2f*900 : p < 1 ? p*900 : 900) : p          // 0xe1b8d0, 0xda95f8, 0xe0c720
for each vertex with pinned != 1:
    acc = (0, S.gravity * -5.0 * (S.gravity_gain * a + 1), 0)         // 0xde4fa0, 0xe1b7f0
    if rand() % S.divisor == 0:                                       // MSVC rand, 0xb44c36
        acc += (p' + 100) * (S.gust_gain * a + 1) * w                 // 0xe1b7d8
    old = prev; prev = cur
    cur += S.kept * (cur - old) + acc * 0.0004                        // 0xe0c718
repeat up to 7 passes, stopping after a pass that changed nothing:
    for k in the order list: (v0, v1, rest) = link k
        d = cur[v1] - cur[v0]; err = |d| - rest
        if err >= 0.01f:                                              // 0xe1b818
            cur[v0] += d/|d| * err * a0/(a0+a1)
            cur[v1] -= d/|d| * err * a1/(a0+a1)
```

Links only ever pull together. There is no collision and no clamp beyond the 7 passes and the 0.01
slack. `rand()` is the C library's one global generator (`holdrand * 214013 + 2531011`, bits
16..30).

## 3. Each frame (READ, the slot-14 update `c33230`, shared by every compound object)

1. The animation advances (20 ms sub-steps).
2. Only while the option is on (renderer 0x1112fb0 + 0x19c, `DAT_0111314c`; default 1, ctor
   0xbc1a72): `near = +0x80 < renderer+0x1a0` (1, ctor 0xbc1a20; its setter has no caller). A
   character with cloth: `FUN_00c526e0(char, near)`, the CPU skin (below).
3. If near: `+0x194 += dt_ms`. Under 50 nothing; else clamped to 200, `steps = acc / 50`,
   `acc %= 50`, and `FUN_00c0d720 -> FUN_00c0d610` runs `steps` steps, then copies every particle
   into the batch's vertex array.

**The skin, `FUN_00c52270`.** Near: only pinned vertices are skinned (two bones, weighted), their
position into the particle and the vertex array, their normal into the array. Far: every vertex is
skinned (a static skinned pose), and no step runs. The normals of free vertices are never written
while near: they keep the bind pose's, or the last far skin's. A mesh with no skin (rigid) never gets
a bone palette (`PrimGeometry::FUN_00c1ba00` needs a skeleton and skin records), so it is never
skinned: its pinned particles stay at the bind pose, in the object's own space.

**LOD (READ).**
- A character's factor is camera distance / 800 (`GlobalDataManager::FUN_009c4aa0`), times
  `k = -0.09 S + 1.3` when its `+0x728` record is set (S = `FUN_009c7740`; OPEN which characters'
  S), clamped to [0, 1] into `+0x7c`, and `+0x80 = trunc(4 f)` (`CCompChar::FUN_00c25620`). So cloth
  runs within 200 units (about 165 at S = 1).
- The factor is 0 for the exact class CICPlayer (0xef1b44: the own player; others are CICUser),
  for an exact CICMonster of rarity 3 or 8, and for a record with bit `+0x39 & 4`.
- A placed object (CCompBldg / CCompSimple) has LOD 0 always: reset to 0 (`c2edc0`), and nothing
  writes it after.

**The animate flag.** A character is updated with `flag = (ent+0xbc && !ent+0xbd)`. `+0xbc` is "in
view at the last draw" (`FUN_009c4aa0`'s frustum test). `+0xbd` is set by the Frozen status and
freeze skills. With the flag 0, the update returns before the skin and the step. A placed object is
updated by `SWorld::vslot_004` (0xa2d5b5, 0xa2d77a, 0xa2d9e3) with the flag 1 and p 0: no view test,
inside its fade range only. A dungeon block (`CRTDunBlock::vslot_008` 0xc687c0) is skipped when
culled.

**The wind (READ, `FUN_00c0d720`).** The mesh's own vector when its flag is set. Otherwise
`char+0x190`'s vector when set (a dungeon block's `+0xfc`, (0, 0, 1) by default, flipping sign every
period in mode 2: `RTDunBlock::FUN_00c6be00`, `FUN_00c67870`), else `-(+0xa0)` = (-sin t, 0, cos t),
t the object's yaw (`CCompChar::FUN_00c26e70`). It is a world vector used in the object's own space.
MEASURED: only 14 of 104 building cloth meshes and 10 of 16 dungeon ones (the Dunhuang cobwebs) use
it; the `china_wall*_flag` meshes carry their own.

**p (READ).** `ent+0xcc` = `speed[+0x678] * +0x6f4 * frame seconds` (`FUN_00a59710`): what the
character moved this frame, reset to 0 after each tick. Standing, the gust is 100. Running at 50 u/s
it is 850 at 60 fps (the original's gust depends on the frame rate). Placed objects pass 0.

**Turning the option (READ).** The setter 0xbc11f0 calls `Map::FUN_00bea840` on a change: every
object rebuilds its meshes (`CRTMeshDynamic` when on, `CRTMesh` when off), and the particles go back
to the bind pose. Off, a cloth mesh is drawn on the ordinary GPU-skinned path.

## 4. This client

- `ClothSim` (GDScript) and `SrCloth` (native/src/core/cloth.rs) step exactly section 2.
  `cloth_test.gd` holds them to each other (30 frames of skin and gusts, within 1e-3) and to
  retail's arithmetic.
- `ClothDriver`, one per viewport, steps every host in its group each frame, as section 3 does:
  - The rule for a far or switched-off host: the mesh goes back to its own GPU skin (the same static
    pose retail skins on the CPU).
  - When near, the mesh instance draws a per-host copy without bones. Its vertex region is written
    each frame: Godot 4.7's uncompressed stream, every position (12 bytes) and then a
    normal/tangent pair per vertex (octahedral u16, MEASURED on the box).
- Hosts: a body's Skeleton3D (`CharacterAppearance.build`, `SkinnedBsrAssembler`), and a placed
  object's root (`ObjectLoader._commit_node`, `OBJECT_META`). The own player and unique monsters are
  `ALWAYS_NEAR_META`.
- OURS:
  - p is the host's own displacement since the last frame.
  - The view test is the host's origin against the frustum, 20 units out.
  - The rule for a rigid cloth mesh on a character: it is simulated in its own mesh space.
- INFERRED: Godot's world axes are retail's (`rotation.y = -yaw`), so the yaw wind is the host's +Z.
- OPEN:
  - the frame the dynamic batch is drawn in;
  - a dungeon block's own wind modes;
  - the `+0x728` scale S for players.

## 5. Worn items (READ; `WornItemFx`)

**Particles.**
- Attaching a part (`vslot_067` 0xc1fa90 -> `CCompChar::FUN_00c32680`) gives it its own skeleton
  and FxModManager (0xc80140 -> 0xc7fa40).
- The equipment refresh (`0x9db940` -> `CObjCharacter` slot 8 0xa61c60 -> 0xa5ac60 -> slot 27
  0xc306c0 -> `CCompChar::FUN_00c46ab0`) collects every part's `ambient` set (0xc46b26). These are
  the item's always-on particles, on the named bone of the part's **own** skeleton
  (`CRTModParticle::FUN_00c818c0` -> 0xbf0580(part) -> `FUN_00c2c820`).
- The only gate is the 0.9 LOD test (0xc43780): 720 units for other players, always for the own
  player. MEASURED: no item entry has the glow (+0x50) or night (+0x51) byte.
- A China talisman (`clothes_NN_sa`) carries `system\item_equip_shoulder_<colour>.efp` on Bone04 and
  Bone06 (Bone07 for `_11`); 32 of 34 files.
- Here: EquipFx rows on the item skeleton, and in a far body's recipe (`CharacterAppearance._far_fx`).
- OPEN: entries placed by offset (mode != 0, only the fairy wings' sets), and the fairy wings'
  per-type sets.

**Clips.**
- Equipping plays the part's own clip, group `default`, type 0, speed 1
  (`CObjCharacter::FUN_00a5bc20(part, 0, 0)` from 0xa5f611). It binds tracks only inside that part's
  skeleton (0xc758f0).
- The body's stand, walk or run (0, 1, 7: slot 3 0xa5faf0 -> 0xa5e100) asks each part again. A
  part with a different clip of that type crosses to it over 200 ms (0xc8); one with none, or the
  same clip, keeps playing. Other actions leave part clips alone.
- MEASURED: the Europe robe talisman (`europe\clothes_sa.bsk`) has one clip,
  `prim\ani\item\europe\clothes_sa.ban` (type 0, 2,000 ms, Bone04 and Bone07 turning 150°), and
  its particles ride those bones. A China talisman has no clip: it stays at its bind pose. Wings
  switch between their stand and run clips.
- Here: the body's clip comes from AnimSounds.advance (`WornItemFx.BODY_CLIP_META`). A body posed
  by another driver (the select screen) keeps the type-0 clip.
- OPEN: riding forces type 0.

**Shimmer.** A fullset's `_ef` mesh carries MTRL, TEXANI and MULTITEX (`robe_line.ddj`) in the same
`ambient` set. MEASURED: every item TEXANI is method 1, a constant scroll per second. Here: bound on
the item's materials as a placed object's are (`SkinnedBsrAssembler.attach_item_from_archive`).

**Not done here:** an NPC's, monster's, mount's or pet's own `ambient` set. Retail plays it from
creation (`CResourceMgr::vslot_000` 0xbec442 -> 0xbec46c, `Map::FUN_009fe760` 0x9fe88e). OPEN for a
later round.
