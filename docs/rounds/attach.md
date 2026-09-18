# Attach lane round: how an item hangs on a bone, read from the client

*Written 2026-09-18 on branch `worktree-agent-ac224f246bb987f6a`, for the coordinator to file as
the next `docs/WORLD_ISSUES.md` round. Evidence first; the decompile lives on the RE box
(`/var/tmp/decomp_client`, `sro_client.exe`), not in this repo.*

## The question

Round 137 hung an own-skeleton item (a weapon, the `_sa` collar) under a `BoneAttachment3D` with the
item skeleton's local transform set to the **item root's** rest inverse -- "chosen by rendering",
its own comment said. Round 141 measured that this floats the `clothes_01_sa` collar as a grey
rectangle by the neck. The lineup render of 2026-09-18 added that the spear and bow splay off the
hand. One rule was wanted, read from the client, that fits sword, blade, spear, bow and collar.

## What the `.bsr` and `.bsk` files carry (data)

`tools/dump_bsk_raw.gd` (new) prints a `.bsr`'s skeleton entry and every float of a `.bsk` record:

| item `.bsr` | own `.bsk` | attach bone | root rest (euler deg) |
|---|---|---|---|
| `sword_01` | `prim\skel\item\china\weapon\sword_01.bsk` (Bone01, Bone02, ai_start, ai_end) | `Bip01 R HandMid` | (89.2, -83.1, 95.3) |
| `blade_01` | `...\blade_01.bsk` (Bone01, ai_start, ai_end) | `Bip01 R HandMid` | (0, 180, 0) |
| `spear_01` | `...\spear_01.bsk` | `Bip01 R HandMid` | (0, 179.6, 0) |
| `bow_01` | `...\bow_01.bsk` (Bone01 only) | `Bip01 L Hand` | (0, 0, 0) |
| `clothes_01_sa` | `prim\skel\item\china\clothes_sa.bsk` (Bone01 + two flap chains Bone03/04, Bone05/06) | `Bip01 Neck1` | (0, -90, 90) |

The body (`chinaman_fighter.bsr`) names `prim\skel\char\europe\europeman_skel.bsk`; its bones sit
where `china\chinaman_skel.bsk`'s do (`Bip01 Neck1` (0, 15.45, 0.19), `Head` (0, 15.95, 0.09),
`R HandMid` (-7.97, 14.93, 0.33), clavicles (+-0.33, 15.0, 0.19) in both).

**The `.bsk` record, from its loader** (`CPrimBranch::vslot_001` = `FUN_00bfb580`,
`objengine\PrimSkeleton.cpp`; per-bone `PrimSkeleton::FUN_00bfae90` reads, `FUN_00bf9e60`
applies): header `uint32` at 0x0c = bone count; then per bone a kind byte (0 bone / 1 dummy --
`CRTBone`/`CRTDummy`, both `CRTSocket`), name, parent name (empty for a root -- the 92-vs-88 byte
"two shapes" of BSK_FORMAT.md), **three (quaternion, vector) transforms in order: local, world
bind, inverse bind**, then a `uint32` count of child names (the "announce" list). Verified on the
data: for every root the three rotations are q, q, q^-1; for `sword_01` Bone02 the second is the
root's rotation (its world), the third its inverse, and the third translation is `-R^-1 p`
(blade: p (0.0027, 0, 0.0058) -> (0.0027, -0, 0.0058); spear: (-0.0013, -0.026, 0.0081) ->
(-0.0012, 0.026, 0.0082)). BSK_FORMAT.md now says so.

## What the client does with it (binary)

- **Link.** `CCompChar::FUN_00c4fc70` (a part's `RTSkeleton`): if the part's attach-bone
  `std::string` (`owner+0x58`, size at `+0x6c`) is non-empty, the bone is found by name
  (`FUN_00c2c890`/`FUN_00c2c820`), the item skeleton is registered in the body skeleton's child
  list, and the item **root bone's parent socket** (`root+0xc`) is set to that body bone with
  update mode `root+0xa0 := 1`. `CCompChar::FUN_00c4c1e0` is the unlink (both back to 0).
- **Update.** `CRTBone::vslot_003` dispatches on the mode: 0 -> `RTSkeleton::FUN_00c49f20`,
  1 -> `CRTBone::FUN_00c48fe0`. Each bone owns three 4x4 matrices at `+0x80`: `mat0` local
  (the prim's local bind, or the animated quaternion/position at `+0x2c`/`+0x3c`), `mat1` world,
  `mat2` skin. Mode 0: `mat1 = mat0 x parent.mat1` (or `= mat0` with no parent),
  `mat2 = prim.mat2 x mat1` -- ordinary FK, `out = a x b` in D3D row-vector order, skin =
  inverse bind x world. **Mode 1: identical except the parent frame is `[R(parent.mat2) |
  t(parent.mat1)]`** -- the attach bone's skin rotation at the attach bone's world position
  (the temp matrix at `DAT_0111316c` is filled from `parent block+0x80`, then its row 3 from
  `+0x70..+0x78`, i.e. `mat1`'s translation).
- **Consequence.** For a root, local = world bind, so `invBind_root x local_root = I` and the
  root's skin matrix is `[R(attach.skin) | t(attach.world)]` (translation: `-t_L R_L^-1 R_L R_s +
  t_L R_s + t_w = t_w`). The item's **model space lands at the attach bone's position with the
  body's axes**, rotated only by the bone's rotation relative to its own bind. The item root's rest
  never shows. Item child bones (the collar's flaps, a weapon's `ai_*`) are mode 0 under that root
  and reduce to the same `[I | t_w]` at rest.
- **In Godot**, under a `BoneAttachment3D` (which applies the bone's full pose `[B_pose | p]`), that
  is the constant item-skeleton local transform `(B_rest_attach^-1, 0)`; the item skeleton keeps its
  file rests so its skin is identity at rest. `SkinnedBsrAssembler.attach_item_from_archive` now
  does that, replacing round 137's `get_bone_rest(0).affine_inverse()`.

## Measured, before and after (`tools/probe_attach.gd`, new)

Body space: Y up, arms along +-X, front -Z. "current" = round 137, "client" = the rule above;
the probe also re-measures the **shipped** code path (a real `attach_item_from_archive` under a
`BoneAttachment3D`, two frames later) and it matches the "client" rows to the printed precision.

| item | rest: current heading | rest: client heading | idle (standcity 0 s): current | idle: client | centroid-to-bone |
|---|---|---|---|---|---|
| sword_01 | (0.01,-0.02,-1.00) -Z | (-0.02,-0.02,-1.00) -Z | (-0.27,0.01,-0.96) | (-0.26,-0.02,-0.96) | 1.27 |
| blade_01 | (0.08,-1.00,0.02) **-Y** | (0.09,-0.02,-1.00) -Z | (0.96,0.06,-0.27) **+X** | (-0.27,0.09,-0.96) | 1.37 |
| spear_01 | (0.13,-0.99,0.01) **-Y** | (0.14,-0.01,-0.99) -Z | (0.96,0.11,-0.27) **+X** | (-0.27,0.14,-0.95) | 12.28 |
| bow_01 | (-0.25,-0.97,-0.03) -Y | (-0.26,-0.03,0.97) +Z | (-0.93,0.22,0.29) | (0.25,0.07,0.97) | 0.22 |
| clothes_01_sa | long axis (-0.08,0.43,**-0.90**) front-to-back | (-0.79,0.61,0.08) **across** | | | 1.63 |

Under round 137 the sword pointed forward while the blade and spear -- same hand, same clips --
pointed down at rest and sideways in the idle: it fitted `sword_01` only because that root's rest
(89, -83, 95) happens to equal the hand's global rest (89.5, -90, 90). Under the client's rule all
three hand weapons share one heading, and the collar lies across the shoulders, centred on the
neck: centroid (-0.15, 17.07, 0.22) = `Bip01 Neck1` + (0, 1.63, 0), i.e. jaw height, 6 wide.
That height is what the data plus the rule give (the mesh is authored 1.6 above its origin); I
have no original-client picture of the cotton collar to say it is a standing collar by design, so
that is stated, not claimed.

Renders (scratchpad `attach/`): `attach_lineup.png` (four outfits at rest), `attach_idle.png`
(heavy set + collar + sword posed with `standcity.ban` at 0 s), `attach_gizmo.png` (the same
with the item nodes' axes drawn -- `render_lineup.gd --gizmo=1`, new). The gizmo was needed: a
blade pointing **at** the camera from the upper right of the frame projects outward and up, which
I first misread as "along the arm"; the node's blue +Z runs toward the image centre and the blade
exactly opposite, as the numbers say.

## On the coordinator's datum (sword forward offline, tip-down in-world)

With a correctly following attachment, `standcity.ban` at 0 s puts the sword **forward,
horizontal, at hip height under both the old and the new rule** (hand at (-2.45, 8.63, 1.18);
its turn from the T-pose is about the body's Z axis, which leaves a -Z blade unchanged). Neither
composition produces tip-down at that clip and time, so an in-world tip-down hang is a difference
in the **pose** path (clip, time, or stance), not in attach. Round 137's "hangs tip-down" was
judged from a render; this round's rule explains the offline result and predicts in-world will
match it once the same clip is applied.

## Files

- `client/scripts/assets/skinned_bsr_assembler.gd` -- the rule, with its citation, replacing the
  render-picked transform.
- `client/tools/probe_attach.gd` (new), `client/tools/dump_bsk_raw.gd` (new),
  `client/tools/render_lineup.gd` (`--gizmo`).
- `docs/protocol/BSR_FORMAT.md` (composition section), `docs/protocol/BSK_FORMAT.md` (record
  semantics from the loader).
