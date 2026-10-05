# The teleport structures' effects

Round 720. The user (2026-10-04): "Most, if not all, of the town teleports have special glows or
effects to them. Find them all in the original code and implement that."

Labels: **READ** (sro_client.exe, address given), **MEASURED** (counted in the user's own
archives: `Data.pk2`, `Media.pk2`, `Map.pk2`), **INFERRED**, **OPEN**, **OURS**. No game data
here: paths and numbers only.

## The mechanism: an object's `ambient` particle mod (READ)

The glows are not a teleport feature. A `.bsr`'s mod section (BSR_FORMAT.md, "the mod-data
section") carries **particle mods**, kind `0x30000`, and a placed map object plays those of its
**`ambient`** mod set for as long as it stands. Every teleport structure's model has such a set.

- **The set.** `ModPalette::FUN_00c0b060` (`0xc0b060`) gives the mod set whose name compares equal
  to `"ambient"` over 7 characters (`FUN_004722d0(0, name, "ambient", 7)`) set kind **2**, any other
  name kind 0. Kind 2 is the set every draw applies (round 625, `FUN_00c7b540`).
- **The body**, `ModDataParticle::vslot_004` (`0xc643b0`): the IModData header (28 bytes), an i32
  count, then per entry a 0x60-byte record:

  | record | wire | what |
  |---|---|---|
  | `+0x00` | u32 | mode: **0** attaches at a bone, anything else places at the offset |
  | `+0x04` | lp-string | the effect file (`.efp`, under `Particles.pk2`) |
  | `+0x20` | lp-string | the bone or dummy name (mode 0) |
  | `+0x3c` | 3 x f32 | the offset in the object's frame (mode != 0) |
  | `+0x4c` | u32 | kept at the effect's `+0xcc`; use OPEN |
  | `+0x50` | u8 | **the glow bias** (below); 0 = drawn normally |
  | `+0x51` | u8 | bit 0: hidden while the effect manager's `+0x1a8` is 0 (FUN_00c81450, FUN_00c43100); no gate sets it |
  | `+0x52` | u8 | read, use OPEN |
  | `+0x53` | u8 | non-zero: a rotation follows |
  | `+0x54` | 3 x f32 | the rotation's angles, x / y / z radians (only when `+0x53`) |

  OpenSRO reads it as `BsrReader.ParticleMod` / `ParticleEntry` (`BsrReader.particle_mods`).
- **Placing it.** `CRTModParticle::vslot_001` (`0xc77a20`) builds one effect per entry: mode 0 through
  `FUN_00c818c0` (the bone found by name, `FUN_00c2c820`; no bone, no effect), otherwise
  `FUN_00c81820` (the offset copied to the effect's `+0x94`). The descriptor lands at the effect's
  `+0x5c` (`0xc818db lea ebx,[esi+0x5c]`). `FUN_00c81190` builds its world matrix: translate(scale x
  offset) x the object's world matrix, the scale being the object's own (`vt+0x20`; 1 for a placed
  map object); with a rotation, `FUN_00c67500`'s matrix is applied in the object's frame first.
- **The rotation**, `FUN_00c67500` (cos `0xb44a10`, sin `0xb44b40`), a D3D row-vector matrix:

      m00 = cy cz             m01 = -sz cy             m02 = -sy
      m10 = sz cx - sx sy cz  m11 = cz cx + sx sy sz   m12 = -sx cy
      m20 = sz sx + cx sy cz  m21 = cz sx - cx sy sz   m22 = cx cy

  Its Godot form has M's rows as the basis columns (`AmbientParticles.rotation_basis`); a y-only
  entry is `Basis(UP, y)`. Every gate rotation is y-only (MEASURED).

## The glow pass (READ)

An entry whose `+0x50` byte is not 0 is not drawn with the scene. `CRTModParticle::FUN_00c81450`
hands it to the glow pass `FUN_00c43100` when the effect's `+0x90` (that byte) is set and the
effect manager (`0x1112fb0`) has `+0x1a4` and `+0x1ac` set:

- `+0x1a4` is set to 1 by the manager's constructor (`0xbc1a26`) and its setter (`0xbc1230`) has no
  caller: always on.
- `+0x1ac` is 1 when the device creates an occlusion query (`0xc41c6f`, from `FUN_00c807f0`:
  `CreateQuery(9 = D3DQUERYTYPE_OCCLUSION)`, `D3DERR_NOTAVAILABLE` -> 0).

The pass:

1. **Every 500 ms** (its accumulator `+0xa4` against `0x1f5`, then `% 500`) it tests each glow with
   the occlusion query: `CVisibleChecker::vslot_002` (`0xc80d20`) draws **one point** with ZENABLE
   on and colour writes off (FVF `0x42`, XYZ|DIFFUSE) inside the query, at the effect's position
   moved toward the camera by `(byte - 1.0)` units (the double 1.0 at `0x00e1b7f0`). The glow is
   visible when the point passes the depth test.
2. **Each frame** its alpha (the effect's `+0x4c`, a byte) moves toward 255 when visible and toward
   0 when not, by `trunc(frame ms x 1.5)` (`CRTModParticle::FUN_00c81080`, the double 1.5 at
   `0x00e1b7e8`, `_ftol2` `0xb42d10`): 0 to 255 in about 170 ms. An effect the pass did not see the
   frame before restarts at 0.
3. **The draw** is done with ZENABLE off (render state 7, `FUN_00471360(7,0)`), and only while the
   alpha is not 0 (`FUN_00c81130`).
4. **The alpha reaches the particles** as `CEFEffect` `+0x4a` (`vslot_009`, `0xca94c0`; copied to
   `0x00edbd40` by `vslot_000`): when it is not 255, each particle colour's alpha byte becomes
   `(a x alpha) >> 8` (`EFEffect::FUN_00c893f0`, `0xc8affd`).

So a gate's glow sits on top of everything near it, fades in when its core comes into sight and
fades out behind a wall, the way a lens glow does.

## Census: every teleport structure (MEASURED)

The structures are the 77 rows of `teleportbuilding.txt`. A row names no model; the model is the
map object placed at its position (`server/cmd/whatishere`, nearest placements within 40 units of
the row's region-local x/z). Their `ambient` particle entries (`client/tools/dump_bsr_particles.gd`):

| structure (row) | region | placed object (distance from the row) | ambient effects (glow byte) |
|---|---|---|---|
| STORE_CH_GATE (Jangan) | 97/168 | `cj_portal` (3.6): none; `cj_portal_stone` (7.5) | `cj_pal_potal_blue` (25), `w_cd_potal_blue_g` (13) |
| STORE_WC_GATE (Donwhang) | 103/153 | `w_cd_portal` (3.3) | `w_cd_potal_blue`, `w_cd_potal_blue_g` (41), `w_cd_potal_blue_g` (49) |
| STORE_KT_GATE (Hotan) | 92/135 | `oas_hot_portal` (0.7) | `w_cd_potal_blue`, `w_cd_potal_blue_g`, `pajang` |
| STORE_TD_GATE (Thief village) | 96/182 | `thief_vill_t_01` (0.9) | `cj_pal_potal_blue` (15) |
| STORE_EU_GATE (Constantinople) | 105/79 | `euro_esteuro_fountain01` (2.6) | `rock_mt_portal` x2, `euro_constan_center` (95) |
| STORE_CA_GATE (Samarkand) | 107/107 | `samarkand_center_01` (1.0) | `cj_pal_potal_blue` x2 |
| STORE_SD_GATE1 / 2 (Alexandria N / S) | 90/48, 92/50 | `alex_portal` (8.4, 15.1) | `alex_potal_01` |
| STORE_DELTA_GATE_E / W | 92/56, 85/52 | `alex_fportal` (6.7, 15.3) | 59 entries: `alex_fprtal_02` around the rim, `alex_fprtal_01` x4 above |
| STORE_ROC_FRONT_GATE | 100/192 | `rock_mt_mteleport` (0.3) | `rock_mt_portal` x2 |
| STORE_KINGSVALLEY_GATE | 74/57 | `pha_gate` (1.9) | `dun\alex_indun_ent` (turned 90 deg) |
| the 16 guild FORT gates | various | `fort_gate` (0.1 - 26.0) | `guild\gate_potal`, `guild\waterup_blue_small_01` |
| the 3 CHARGE gates | various | `charge_gate` | `guild\sphere_light`, `guild\waterup_blue_small_01` |
| the 3 GLORY gates | various | `glory_gate` | `guild\light_gate_blue` x4 (turned 0/90/180/270 deg), `guild\light_gate_top` |
| the 3 REVIVAL gates | various | `revival_gate` (one row has no placement within 40) | `guild\waterup_blue_small_01`, `guild\waterup_blue_long`, `guild\light_gate_top_s` |

The other rows (tombs, the desert merchant/thief gates, survival arenas, instance-only rows at region
0) had no placed object within 40 units of their position: OPEN (their structure is placed
elsewhere, spawned by the server, or in a dungeon the map files do not place).

**Every entry above is mode 1** (an offset; MEASURED). Glow bytes not listed are 0.

Across the whole archive (MEASURED, `dump_bsr_particles.gd --census` over 8,539 `.bsr`): 1,526
files carry particle mods (11,600 entries), **1,300 of them an `ambient` set**; the rest are
characters' status sets (`status_bad_burn`, ...), action-type sets and `system_appear`. 19 files'
mod sections do not parse.

## What OpenSRO does (round 720)

- `BsrReader` reads the particle mods; `ObjectLoader` keeps a placed object's `ambient` entries on
  its committed node (`AmbientParticles.META_ENTRIES`).
- `World3D._attach_gate_effects`: for every teleportbuilding row in a region as it loads, the
  region's placed objects within **30 units** (OURS: the farthest gate object measured is 26.0)
  that carry ambient entries play them, each effect looped and following its object
  (`AmbientParticles.attach`), offset and rotation as READ.
- The glow pass is `AmbientParticles.update`, once a physics tick: the 500 ms test, the 1.5/ms
  fade, the restart at 0, and the draw without the depth test with the particle alpha scaled
  (`EfpEffect.make_glow` / `glow_shader`), as READ.

**OURS, labelled:**
- **Only the teleport structures** play their ambient effects. The original plays every placed
  object's `ambient` set; the other 1,300-odd sets (torches, fountains, banners) are a follow-up
  with its own perf measurement.
- **The occlusion query is a physics ray** from the camera to the moved point against the terrain,
  the placed objects and the characters' pick bodies (monsters, other players, the player; not the
  NPCs, whose layer is the invisible navmesh walls'). It **passes through alpha-tested pieces**:
  the original's depth buffer has holes where a leaf card's texels fail the test, a collision
  trimesh does not -- a bare tree's leaf cards hid Jangan's glow from 150 units until the ray
  passed them (MEASURED, the QA log's blocker). Their opaque texels then hide nothing either.
- **The fade runs per physics tick** (the original's per rendered frame).
- An ambient effect is **kept** (looping) while its object stands (INFERRED from the gates' steady
  glows in the user's screenshots; the effect's own restart rule in `CRTModParticle` was not read).

**OPEN:** `+0x4c`, `+0x52` and `+0x48` (the descriptor word the reader never writes); whether a
mode-0 entry on a placed object without a skeleton draws at all (no gate has one).
