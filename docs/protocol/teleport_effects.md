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

- **The set.** `ModPalette::FUN_00c0b060` (`0xc0b060`, `0xc0b0ca..0xc0b0e1`) gives the mod set
  named exactly `ambient` set kind **2**, any other name kind 0: `FUN_004722d0` is
  `compare(0, size(), "ambient", 7)` (`0x4722d0..0x47233b`), equal only for exactly `ambient`, and
  case-sensitive. Kind 2 routes the runtime set into the palette's own slot: `FxModManager::
  FUN_00c7fa40` at `0xc7fcea` (`cmp [edi+0x18],2` -> `mov [ecx+0x5c],esi`), which `0xc7c060` returns
  and `CCompChar::FUN_00c46ab0` (`0xc46b26`) collects -- the set an object plays with no clip running.
  (Round 720 first cited `FUN_00c7b540` for it: that tests a mod's own dispatch word, and the slot it
  calls on a particle mod is a bare `ret` -- corrected by the review.)
- **Two gates in front of the draw.** Every `CRTModParticle` slot first runs `0xc43780`, which passes
  only when the mod's `+0x3c` (0.9, the float at `0xde3148`, stored by the constructor `0xc77a00`) is
  at least the host's LOD `+0x7c`. `+0x7c` is written by `0xc25620` (clamped 0..1, x4.0 into `+0x80`),
  slot 2 of `CCompChar` / `CCompBldg` / `CCompSimple` / `CCompoundObj`, whose one caller found is the
  game-object LOD change (`GlobalDataManager::FUN_009c4aa0`). A placed building most likely keeps its
  default LOD and passes: **INFERRED**. And the effect draws only while its `+0xb0` or `+0xb4` is set
  (`0xc81472`); `+0xb4` is `vslot_001`'s fifth argument, whose value on the ambient path was not
  traced (**OPEN**).
- **The body**, `ModDataParticle::vslot_004` (`0xc643b0`): the IModData header (28 bytes), an i32
  count, then per entry a 0x60-byte record:

  | record | wire | what |
  |---|---|---|
  | `+0x00` | u32 | mode: **0** attaches at a bone, anything else places at the offset |
  | `+0x04` | lp-string | the effect file (`.efp`, under `Particles.pk2`) |
  | `+0x20` | lp-string | the bone or dummy name (mode 0) |
  | `+0x3c` | 3 x f32 | the offset in the object's frame (mode != 0) |
  | `+0x4c` | u32 | the key `CRTModParticle::vslot_009` files the effect under in a lookup map (`0xc778ee..0xc77914`); also the effect's `+0x8c` / `+0xcc` (READ) |
  | `+0x50` | u8 | **the glow bias** (below); 0 = drawn normally |
  | `+0x51` | u8 | bit 0: **night only** -- hidden while the effect manager's `+0x1a8` is 0 (`FUN_00c81450`, `FUN_00c43100`); `SWorld::vslot_004` sets it through the thunk `0xbbdbf0` at `0xa2d1c6` to 1 when the shifted day phase `+0x26a7` is above 0.5 (game_clock.md's night flag). At this client's fixed phase it is 0, so such an entry is not built (READ; no gate sets it) |
  | `+0x52` | u8 | never copied: `vslot_001`'s descriptor takes `+0x3c..+0x51` only (`0xc77b40..0xc77b72`) (READ) |
  | `+0x53` | u8 | non-zero: a rotation follows |
  | `+0x54` | 3 x f32 | the rotation's angles, x / y / z radians (only when `+0x53`) |

  OpenSRO reads it as `BsrReader.ParticleMod` / `ParticleEntry` (`BsrReader.particle_mods`).
- **Placing it.** `CRTModParticle::vslot_001` (`0xc77a20`) builds one effect per entry: mode 0 through
  `FUN_00c818c0` (the bone found by name, `FUN_00c2c820`; no bone, no effect), otherwise
  `FUN_00c81820` (the offset copied to the effect's `+0x94`). The descriptor lands at the effect's
  `+0x5c` (`0xc818db lea ebx,[esi+0x5c]`). `FUN_00c81190` builds its world matrix: translate(s·ox,
  s²·oy, s·oz) x the object's world matrix, s being the object's own scale (`vt+0x20`;
  `FUN_00c81820` already multiplied oy by s at `0xc81872..0xc8187e`; 1 for a placed map object, the
  premise not re-verified); with a rotation, R x (that matrix with its translation zeroed), the
  translation put back (`0xc812be..0xc81310`). The descriptor's `+0x48` lands at the effect's
  `+0x88` (`0xc8169e`), which no `CRTModParticle` code reads (READ).
- **Mode 0** (`FUN_00c818c0`): the host's `+0xf4` (its skeleton) is tested (`0xc818e8`) and the bone
  found by name (`0xc2c820`, `0xc81908`); when either fails the call returns 0 and `vslot_001` frees
  that effect and **returns at once** (`0xc77b9f..0xc77bc4`): no later entry of the same mod is
  built. A mode-0 effect sits at the bone's full matrix x the world (`0xc811c5..0xc811e0`).
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

- `+0x1a4` is the **Light Effect** video option: the constructor sets it to 1 (`0xbc1a26`), and its
  setter `0xbc1230` is reached through the thunk `0xbbdad0` (`mov ecx,0x1112fb0 ; jmp 0xbc1230`) from
  `SWorld::vslot_043` case 0xb (`0xa19810`), OPTION_VIDEO.md's Light Effect row. Round 720 first read
  it as always on (it found no direct caller -- the thunk trap); the review corrected it. Off (the Low
  and War presets), `FUN_00c81450` takes the ordinary branch (`0xc814fe`): drawn with the scene,
  depth-tested, at full alpha, and nothing reaches the glow list.
- `+0x1ac` is 1 when the device creates an occlusion query (`0xc41c6f`, from `FUN_00c807f0`:
  `CreateQuery(9 = D3DQUERYTYPE_OCCLUSION)`, `D3DERR_NOTAVAILABLE` -> 0).
- The pass takes only the effects whose object was drawn this frame: `FUN_00c81450` queues them as it
  draws them, and `FUN_00c43100` clears the list every frame.

The pass:

1. **Every 500 ms** (its accumulator `+0xa4` against `0x1f5`, then `% 500`) it tests each glow with
   the occlusion query: `CVisibleChecker::vslot_002` (`0xc80d20`) draws **one point** with ZENABLE
   on and colour writes off (FVF `0x42`, XYZ|DIFFUSE) inside the query, at the effect's position
   moved toward the camera by `(byte - 1.0)` units (the double 1.0 at `0x00e1b7f0`). The glow is
   visible when the point passes the depth test. A point behind the eye or outside the view is
   clipped by D3D and counts 0 pixels (INFERRED: no `D3DRS_CLIPPING` write found), so a camera nearer
   than `(byte - 1)` hides the glow: Constantinople's `euro_constan_center` (byte 95) shows only from
   more than 94 units away.
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

**TEXANI and MTRL (round 722).** The `ambient` sets of `oas_hot_portal` (Hotan),
`euro_esteuro_fountain01` (Constantinople) and the guild `charge_gate` carry a TEXANI mod (`0x10000`)
and an MTRL mod (`0x0`); `pha_gate` an MTRL.
- **TEXANI is now drawn.** Hotan's water (material 3, `Oas_hot_potal_water`) scrolls v at 0.48/s;
  the fountain's water (material 6) grows its 2x2 matrix at (+0.02, +0.03, -0.02, +0.03)/s; the
  charge gate's (material 3) scrolls v at -0.7/s. The reading (CRTModTexAni's steps, the archive's
  `vss0.c`/`vss2.c`; a mode-1 mod animates stage 1 and is not bound), the census (359 files) and the build are in docs/rounds/r722.md and
  BSR_FORMAT.md.
- **The MTRL mods were already drawn.** Round 625's ambient-set path (`mtrl_mod_for`) blends them.
  Round 720's "not drawn" said otherwise and was wrong.
- No gate model carries a sound mod.

**The blend (round 722).** The effects' plates are D3D-blended (most SRCALPHA/ONE). The original
blends in the display values (no D3DRS_SRGBWRITEENABLE), Forward+ in a linear buffer, where
Samarkand's additive plates over the sky barely show (MEASURED: the arch's mean 175,220,238 against
Compatibility's 214,233,243 and the effects-off 164,210,205). The ambient effects now blend in
display values under Forward+ (`EfpEffect.display_shader`, a screen read; OURS method): 208,229,240.
Donwhang's low glow (byte 41) tests hidden by its own platform floor (`W_CD_portal_04`) from the
bridge, as the original's depth test would. Its visible light is the scene-drawn `w_cd_potal_blue`
and the high glow (49). docs/rounds/r722.md has the measurements.

**USER DECISION (2026-10-05):** keep the exact display-value blend for the gate effects, accepting
+1.5 ms a frame at 4K while a gate effect is on screen (Samarkand 4.70 -> 6.15 ms at 3840 x 2160;
SAME at 1280 x 720).

**Light Effect in the user's screenshots (settled by the user's answer, 2026-10-05, not READ):** the
user's original client runs Light Effect off. With it off, glow entries draw as ordinary
depth-tested particles (READ), which is why the bell hides Donwhang's high glow in their picture.
This client does the same with Light Effect off.

Across the whole archive (MEASURED, `dump_bsr_particles.gd --census` over 8,539 `.bsr`): 1,526
files carry particle mods (11,600 entries), **1,300 of them an `ambient` set**; the rest are
characters' status sets (`status_bad_burn`, ...), action-type sets and `system_appear`. 19 files'
mod sections do not parse.

## What OpenSRO does (round 720)

- `BsrReader` reads the particle mods; `ObjectLoader` keeps a placed object's `ambient` entries on
  its committed node (`AmbientParticles.META_ENTRIES`).
- `World3D._attach_gate_effects`: for every teleportbuilding row in a region as it loads, the
  placed objects within **30 units** (OURS: the farthest gate object measured is 26.0) that carry
  ambient entries play them, each effect looped and following its object
  (`AmbientParticles.attach`), offset and rotation as READ.
  - **Round 723 correction:** until then only the row's OWN region's container was searched, so a
    gate whose model sat in a neighbour's container played nothing. That is what the user saw at
    Samarkand: on their teleport in, a neighbour region loaded first and placed the shared
    `samarkand_center_01` (MEASURED, their client log). The match now covers the rows of the
    committed region and its eight neighbours against the objects of all nine containers, in the
    committed region's frame, on every region's commit (`GateEffectMatch`), so either load order
    finds the pair. The rounds 720-722 renders loaded the gate's region at boot, an order that hid
    this, so "every gate attaches" held only for that order.
- **Round 774, the walk-in portals.** A walk-in teleport has no teleportbuilding row, and its
  model's origin can stand far from the zone: the Donwhang cave's mouth, `w_cd_dondunenter.bsr`,
  places its `system\system_dungeonpotal.efp` 1,056 units from its origin; the Qin-Shi tomb's
  door is `cj_jin_entdoor01_01.bsr` (MEASURED, `dump_bsr_particles.gd --ambient-index`). The
  zones' centres are `navmesh\objectstring.ifo`'s points whose name is a teleportdata codename
  (`ObjectStringReader`; the two open-world walk-ins, MEASURED), and an object pairs by the place
  of each of its ambient entries -- the entry's offset in the object's frame -- within the same 30
  units (`World3D._walk_in_pairs_around`). MEASURED on the box: the cave's at 0.8, the door's at 2.7.
- **Round 774, dungeons.** Every room and object of a dungeon plays its whole `ambient` set
  (dungeon.md, "Light"): the dungeon portals, flames, lanterns and crystals.
- The glow pass is `AmbientParticles.update`, once a physics tick: the 500 ms test, the 1.5/ms
  fade, the restart at 0, and the draw without the depth test with the particle alpha scaled
  (`EfpEffect.make_glow` / `glow_shader`), as READ.

**OURS, labelled:**
- **Only the teleport structures** (and, from round 774, the walk-in portals' models and every
  dungeon room and object) play their ambient effects. The original plays every placed
  object's `ambient` set; the other 1,300-odd sets (torches, fountains, banners) are a follow-up
  with its own perf measurement.
- **"Drawn"** is the object's mesh box against the camera's frustum (the original queues an effect
  as its object draws), and the test point must be on screen and in front of the eye before the ray.
- **The occlusion query is a physics ray** from the camera to the moved point against the terrain,
  the placed objects and the characters' pick bodies (monsters, other players, the player; not the
  NPCs, whose layer is the invisible navmesh walls'). An alpha-tested piece hides the point only
  where its texel is kept (round 722: the hit's face, its UV, the texture's mip-0 alpha against the
  material's threshold -- `AmbientParticles.texel_kept`); round 720 **passed through every
  alpha-tested piece**:
  the original's depth buffer has holes where a leaf card's texels fail the test, a collision
  trimesh does not -- a bare tree's leaf cards hid Jangan's glow from 150 units until the ray
  passed them (MEASURED, the QA log's blocker). Their opaque texels then hide nothing either.
- **The fade runs per physics tick** (the original's per rendered frame).
- An ambient effect is **kept** (looping) while its object stands (INFERRED from the gates' steady
  glows in the user's screenshots; the effect's own restart rule in `CRTModParticle` was not read).

**OPEN:** the LOD gate's value for a placed building (INFERRED open), `+0xb4` on the ambient path,
and the TEXANI / MTRL mods above. Mode 0 and the night bit are done as READ (no gate uses either).
