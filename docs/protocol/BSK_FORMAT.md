# BSK skeleton format (JMXVBSK)

`.bsk` is the piece `.ban` (bone animation) is missing: the bone **hierarchy**. `.ban` has a flat
list of named bone tracks with no parent references; `.bsk` has exactly that — a named skeleton
tree, each bone with an explicit parent-bone name.

Found in a full, unpacked client data tree bundled with a private-server package (`/opt/sro-files/
server/.../Blitzkrieq_Bin_Data/.../Data/data/prim/skel/...`), not inside any `.pk2` archive — see
`docs/PROGRESS.md` for how that was found. No decompiled loader was found for this format
(searched `sro_client.exe` for the same "magic constructed via immediate `mov`s" pattern used to
find every other `JMXV*` loader in this project; no hits, so this format may be loaded through a
different, more generic mechanism) — so this is confirmed entirely empirically (byte-level,
black-box), cross-checked against **8 real files spanning two structurally different skeleton
styles** (a mirrored-decoration rig, and six 3ds Max "Biped"-style creature/character rigs from
38 to 265 bones), every one of which the parser here consumes **completely**, down to the file's
constant 8-byte zero trailer, with zero leftover/unresolved names. No decompiler output is stored
in this repo regardless — only the resulting facts about the container format.

## Structure

| Field | Encoding |
|---|---|
| Magic | `"JMXVBSK 0101"` (12 bytes) |
| (unconfirmed `uint32`) | at offset 0x0c |
| (1 extra byte, unconfirmed) | at offset 0x10 — the root bone's name starts at 0x11, one byte later than a plain header field would predict |
| Root bone name | `uint32` length + ASCII bytes (observed literally `"[root]"` or a Biped rig's own root bone name, e.g. `"Bip01"`) |
| Root transform | 92 raw bytes (see "Transform data" below) |
| Bone name/record stream | see "The announce/resolve model" below, until the trailer |
| Trailer | 8 bytes, observed all-zero |

## The announce/resolve model

The bone list isn't a simple linear scan of one-record-per-bone. Every bone name in the file is
first **announced** — a bare `uint32`-length-prefixed name with nothing recognizable immediately
after it — and later **resolved**, when the same name reappears, this time followed by its real
record (parent name and transform data, see below). An announcement's resolution can be:

- **Immediately next** (the common case): the name repeats right away, with nothing in between.
  This is what earlier analysis of this format described as an "ordinary bone record."
- **After a run of other announcements**: e.g. `Bip01 Neck`'s announcement is followed by
  `L_chain_01`, `R_chain_01`, `Spine1_ice` (three more announcements) before `Bip01 Neck` itself
  reappears and resolves. Each of those three names goes on to get its own resolution later,
  parented back to `Bip01 Neck`.
- **Thousands of bytes later, with many other bones' full announce/resolve cycles interleaved
  in between**: e.g. in `dubhe.bsk`, `Bip01 L Thigh` is announced at file offset 391, right after
  `Bip01 Spine`'s own record closes — but doesn't resolve until offset 7899, after dozens of
  other bones (the whole spine→neck→head→arms→fingers chain) have been fully announced *and*
  resolved in between.

There's no count or terminator for a run of announcements — a reader just keeps reading names
until one of them turns out to match something already pending (a resolution) or matches
immediately-following itself (an immediate resolution); anything else is a fresh announcement.

**There's no distinct "alias/mirror table" as a separate concept from ordinary bone records** —
earlier analysis of this format (against the one non-Biped sample available at the time) treated
the file's opening run of announcements as a special, file-position-anchored construct ("names of
every bone with no parent, immediately after the root's transform"). Re-examined against the
fuller set of real samples, that's just the *same* announce/resolve mechanism, coincidentally all
bunched into one contiguous run at the very start of that particular file. Biped-style files
spread their announce/resolve pairs out across the whole file instead, proving the two are the
same mechanism, not two different ones.

## Bone record shapes

Once a name resolves, its record takes one of two shapes — and **both can appear within the same
file**, decided per-bone, not as a whole-file convention (confirmed on real Biped files, which
earlier analysis — based on only one non-Biped sample — didn't anticipate):

- **Type A** (no parent field): straight into **92 raw bytes** of transform data. Used by root's
  direct children in the one non-Biped sample checked, and by at least one deeper bone
  (`Bip01 L Thigh`, in `dubhe.bsk`) in a Biped file — so this isn't reliably "root-attached
  bones only."
- **Type B** (ordinary): `uint32` length + **parent bone name**, then **88 raw bytes** of
  transform data. The gap before this parent name (and before a resolving name's own repeat, in
  general) is sometimes 0 bytes and sometimes 1 (both observed on real files); the reader tries
  the exact offset first and falls back to +1 throughout.

There's no tag in the file saying which shape applies to a given resolution. The reader handles
this the same way it disambiguates everything else here — by checking whether what follows is
*plausible*, not by trusting a flag: it tries Type A first, and accepts it only if what comes
right after those 92 bytes looks like a valid next token (a readable length-prefixed name) or the
file's trailer; otherwise it falls back to Type B. This resolved cleanly, with no ambiguous case,
on every one of the 8 real files checked.

A bone's `ParentName` (empty for Type A) is the **only** reliable source of truth for the tree
structure — the position where a name was first *announced* does **not** reliably indicate its
real parent. `Bip01 L Thigh` is announced right after `Bip01 Spine`'s record (which might suggest
it's Spine's child), but its own resolved record's parent name is also literally `"Bip01 Spine"`
— so in that particular case the announcement position and the real parent do agree, but nothing
in the format guarantees that in general; only the resolved record's own parent field is
authoritative.

## Transform data (88 or 92 raw bytes)

Not exposed as parsed fields (kept as raw bytes on `Bone.Transform`) since the exact semantic
split isn't fully confirmed, but the following **was** confirmed by decoding a real Type-B bone's
88 bytes as 22 floats:

| Offset | Size | Field |
|-------:|-----:|-------|
| 0x00 | 16 | A unit quaternion (magnitude ≈1.0 on every bone checked) — plausibly the bone's local rotation |
| 0x10 | 4 | A float, plausibly bone length (values like `49.8`, `54.8`, `56.6` — consistent with each other and with real-world skeleton scale) |
| 0x14 | 8 | Two near-zero floats, unconfirmed |
| 0x1c | 16 | A **second** unit quaternion — and critically, its first 3 components are the exact negation of the first quaternion's, with the same `w` — i.e. this is the **conjugate/inverse** of the quaternion at 0x00. Strongly suggestive of a bind-pose / inverse-bind-pose pair used for skinning. |
| 0x2c | 12 | A position vector (real-world-scale values, e.g. `(-344.9, 198.0, 16.8)`) |
| 0x38-0x54 | remaining | A second quaternion+position-shaped region, not fully decoded |

**Type-A bones' 4 extra bytes (92 vs. 88) are one leading field inserted before everything
else** — confirmed on two independent fields: the rotation quaternion at 0x00 only has magnitude
≈1.0 when read from offset 0x04 instead on a Type-A bone, and the position vector only forms a
sensible chain when read from 0x30 instead of 0x2c (both a consistent +4 shift). Confirmed
visually too: rendering all real bones' positions with this shift applied
(`client/tools/render_skeleton.gd`) produces a smooth, continuous, correctly left/right-mirrored
skeleton shape on every real file checked — consecutive bones in a chain are a consistent
distance apart (matching the "bone length" scalar at what becomes offset 0x14 after the shift),
not noise, and a real Biped rig (`dubhe.bsk`, `mob/dm/dubhe.bsk`) renders as a genuinely
recognizable humanoid figure — head, spine, mirrored arms with fingers, mirrored legs. The
leading field's own content (4 bytes) isn't identified.

### Confirmed from the client's own loader (2026-09-18)

The loader this file said could not be found is `CPrimBranch::vslot_001` (`FUN_00bfb580`,
`objengine\PrimSkeleton.cpp`, asserting `nCount == 0` twice on the trailer), with the per-bone
record read by `PrimSkeleton::FUN_00bfae90` and applied by `PrimSkeleton::FUN_00bf9e60`
(decompile on the RE box, not in this repo; `docs/rounds/attach.md`). The header's `uint32` at
0x0c is the **bone count** (read by `FUN_00410f50` straight after the magic); then one record per
bone:

| Field | Meaning |
|---|---|
| 1 byte | bone kind: `0` -> a bone (`CPrimBone`/`CRTBone`), `1` -> a **dummy** (`CPrimDummy`/`CRTDummy`, a 3ds Max helper); both derive from `CPrimSocket`/`CRTSocket` |
| length-prefixed string | bone name |
| length-prefixed string | parent name (empty for the root -- that empty string's 4-byte length is the "leading dword" / "1 extra byte" puzzle above) |
| 3 x 28 bytes | **three (quaternion, vector) transforms, in this order: local (parent-relative), world bind, inverse bind.** Each is read into the record at +0x3c/+0x58/+0x74 and turned into the prim's three 4x4 matrices one-to-one (`FUN_00bf9e60` builds the rotation from the quaternion and drops the vector into row 3). The "second quaternion" at 0x1c is therefore the world bind rotation (only equal to the local one for a root), and the third is its inverse |
| `uint32` count + that many strings | **child bone names** -- the "announced" names of the announce/resolve model; a leaf writes 0 |

The 22nd "float" of the 88-byte reading above is this child count. Root records are 92 bytes
because the empty parent name costs 4; there are not two record shapes, only an empty or
non-empty parent field.

## Implementation notes

- `server/internal/bsk` (Go) and `client/scripts/bsk/bsk_reader.gd` (GDScript) both parse the
  full announce/resolve model above; unit tested against synthetic fixtures (never real game
  data, same policy as the other formats) covering immediate resolution, a deferred/interleaved
  resolution, and an unresolved-announcement error case. Cross-checked against each other on the
  same 8 real files — identical bone counts and structure on both sides, every file consumed
  completely.
- Combined with `.ban`, this is enough to build a real bone hierarchy + keyframe animation
  pipeline for a Godot `Skeleton3D`. `client/scripts/assets/skeleton_pose.gd` (`SkeletonPose`) is
  the tested library form of that: bind-pose position extraction and a small forward-kinematics
  helper (rotate a bone and all its descendants around that bone's own position), unit tested
  against a synthetic 3-bone skeleton. `client/tools/render_skeleton{,_animated}.gd` use it to
  produce real screenshots from real data, including a real Biped creature rig — see
  `docs/PROGRESS.md`.
- `client/tools/render_skeleton.gd`'s joint-sphere/bone-cylinder radius is now derived from each
  skeleton's own shortest real bone length rather than a fixed size — a fixed radius tuned for
  one skeleton's bone spacing fused into an unrecognizable blob on a different skeleton with much
  tighter bone spacing (face/hand/finger bones).

## Solved (2026-09-02): the transform block holds the bone's parent-relative LOCAL transform

The 88-byte bone transform's leading fields were previously read as a bind-pose *world* rotation
(`SkeletonPose.bone_rotation`, offset `0x00`) with the bind *world* position taken from `0x2c`
(`bone_position`). `Skeleton3DBuilder.build_skeleton3d` then converted those world values into
parent-relative rest transforms. **That was wrong**, and it was the root cause of real `.ban`
animation never composing with the rest pose.

Proved by dumping a real bone's raw transform floats beside the matching real `.ban` keyframe (real
`chinaman_skel.bsk` against real `chinaman_fighter_standcity.ban`):

```
Bip01 Neck   .bsk floats [0..3] = (-0.0000, -0.0586, 0.0000, 0.9983)
             .ban keyframe rot  = (-0.0000, -0.0586, 0.0000, 0.9983)   <- identical
             .bsk floats [4..6] = ( 2.2956, -0.0000, -0.0004)
             .ban keyframe pos  = ( 2.2956,  0.0000, -0.0004)          <- identical
```

So:

- **floats `[0..3]` (offset `0x00`) are the bone's parent-relative LOCAL rotation**, not a world
  rotation.
- **floats `[4..6]` (offset `0x10`) are the bone's parent-relative LOCAL translation** — a distinct
  field from the bind world position at `0x2c` that this project was already reading.
- Both are in **exactly the same convention real `.ban` keyframes use**, which is what makes bind
  pose and animation composable at all.

Corroborated across the whole skeleton: of 37 shared bones, **33 of 36** non-root local translations
match the corresponding `.ban` keyframe translation to within 0.02 units (the three that differ are
one finger bone and the two thighs, which the animation genuinely translates slightly). Chaining the
`.ban` keyframes through the hierarchy also produces a coherent humanoid — extent
`(15.65, 16.05, 6.05)` against the bind pose's `(17.05, 15.95, 1.60)`, i.e. same height and width,
with more depth exactly as a relaxed idle pose should have versus a flat T-pose.

`SkeletonPose.bone_local_position()` now exposes the local translation, and `build_skeleton3d` uses
the stored local rotation and translation **directly** as each bone's rest transform, with no
world-to-local conversion. `bone_position()` (the `0x2c` bind world position) is kept, since it is
still the right field for anything that genuinely wants world bind positions.

**This also retires an earlier wrong conclusion.** A previous round compared `.bsk` rest against
`.ban` keyframe 0, found they disagreed, and concluded the two files were "genuinely different poses
in different per-bone frames" that could not be reconciled without the client's own animation code.
That reasoning was doubly flawed: it compared against a rest pose that had already been mangled by
the bad world-to-local conversion, and it assumed a bind pose must appear as a frame of some
animation, which is not true in general. See `docs/protocol/BAN_FORMAT.md` for the four application
strategies that were tried and measured before the actual cause was found.

## The remaining blocker, precisely located (2026-09-02): meshes and bones live in two different spaces

Measured directly from real data (real `Data.pk2`, real China-man body parts against the real
`chinaman_skel.bsk`), by dumping each part's raw vertex extents beside the skeleton's own rest
extents:

```
mesh man_arm_lower    x = -9.128 .. +9.128     y = 14.510 .. 15.356    z = -0.497 .. +0.833
mesh man_calf         x = -3.183 .. +3.183     y = -0.005 ..  4.263    z = -1.970 .. +0.862
mesh man_torso_upper  x = -1.725 .. +1.725     y = 13.294 .. 15.609    z = -1.401 .. +1.199
bone rest (all)       x = -0.547 .. +1.055     y = -9.868 ..  6.076    z = -8.525 .. +8.525
```

Two independent differences, both unambiguous:

- **The left/right axis is different.** Real mesh vertices mirror across **X** (the arms span
  ±9.13 in X and only ±0.8 in Z), while the rest skeleton built from the stored *local* transforms
  spreads its arms across **Z** (±8.52, with X only ~1.6 wide). This also settles an axis question
  raised the same day: `CharacterAssembler._build_side_mesh` splitting paired limbs on triangle
  centroid **X** is **correct** — an attempt to "fix" it to Z was made on the strength of the bone
  positions above and is wrong, because those bones are not in mesh space. Reverted; the original
  X split stands, and this file's long-standing note about `man_thigh.bms` mirroring at x=±0.872 is
  confirmed rather than superseded.
- **The origin is different.** Real meshes are authored with the **feet at y≈0** (calf bottom
  -0.005, head top 15.609). The rest skeleton has its **origin at the hips** (feet at y=-9.868, head
  at +6.076). Note the two heights agree — 15.61 versus 15.94 — so this is a pure offset of about
  9.87, not a scale difference. That offset is exactly what the real `.ban` root track supplies:
  `Bip01`'s keyframe-0 translation is `(0, 9.978, -0.067)`.

So the stored **local** rotation/translation chain (offsets `0x00`/`0x10`) and the stored **bind
world** position (offset `0x2c`) are two different, both-real representations in two different
frames, and the meshes are authored in the *latter*. Rigid attachment cancels exactly at rest, which
is why the bind pose renders as a correct T-pose either way and why this went unnoticed for so long
— but under animation the mismatch is no longer cancelled, and limbs fly apart.

**The concrete fix this implies** (specified, not yet implemented): keep rest as the bind pose in
mesh space, and map each animated pose into that same space per bone —

```
G_mesh[b] = R_mesh[b] · B_local[b]⁻¹ · A_local[b]
```

where `R_mesh[b]` is the bind global from the `0x2c` world positions, `B_local[b]` is the global
obtained by chaining the stored `.bsk` local transforms, and `A_local[b]` is the global obtained by
chaining the real `.ban` keyframes. Every term is real data this project already parses; nothing
needs to be invented. `G_mesh` then converts to a Godot bone pose as
`pose_local[b] = G_mesh[parent]⁻¹ · G_mesh[b]`.

### The frame-mapping fix was implemented and it does not work (2026-09-02)

The mapping specified above was implemented and measured, not left as theory. It builds, per bone,
`correction[b] = R_world[b] * B_local_global[b]^-1` (cached on the Skeleton3D), chains each real
`.ban` frame's locals to `A_global[b]`, forms `G_mesh[b] = correction[b] * A_global[b]`, and converts
back to Godot bone poses via `pose_local[b] = G_mesh[parent]^-1 * G_mesh[b]`.

It is algebraically sound at the bind frame — where `A_global == B_local_global`, it collapses
exactly to `R_world`, the rest pose — but a real render against real data comes out **worse than any
previous attempt**: the character disperses completely, limbs scattered across the ground and sky.
Reverted.

That outcome is itself evidence. Since the algebra is exact at the bind frame, the failure means one
of its inputs is not what it is assumed to be — most likely that `SkeletonPose.bone_rotation()`
(offset `0x00`) is **not** the parent-relative local rotation for *every* bone, even though it
demonstrably is for the ones spot-checked (`Bip01 Neck` matches its `.ban` keyframe exactly). The
88-byte record holds four quaternion-or-vector-shaped fields (two quaternions, one the conjugate of
the other, plus two position vectors); this project has confidently identified only two of them.
**The next real step is to identify all four fields**, by chaining each candidate pairing across the
whole skeleton and testing which one reproduces the known-good bind pose — a measurement, not
another application strategy.

Running tally of what has been tried and measured for real `.ban` playback, so none of it is
repeated: delta-against-keyframe-0 as a local rotation (the long-standing original); treating
keyframe rotations as global and converting to parent-relative; applying the documented local
rotation and translation directly as the bone pose; applying only the rotation; and the frame
mapping above. All five are worse than a static bind pose, which is what currently ships.

### The bind WORLD rotation is at 0x1c, and the two frames differ by one constant (2026-09-02)

Two further real measurements, both useful regardless of the failed attempt they were made for:

- **Floats `[7..10]` (offset `0x1c`, `0x20` on a 92-byte bone) are the bone's bind-pose WORLD
  rotation** -- the quaternion immediately preceding the bind world position `bone_position()`
  already reads at `0x2c`. Confirmed by building a bind pose from that pair across a real skeleton:
  it gives **feet at y=0, head at 15.95, and arms spanning +/-8.5 in X**, which matches real body-mesh
  vertex extents exactly (real meshes measure feet at ~0, head 15.61, arms +/-9.13 in X). The local
  chain, by contrast, puts the origin at the hips with limbs spread in Z. So the 88-byte record is
  now fully accounted for as **two complete copies of the same bone**: local pair at `0x00`/`0x10`,
  world pair at `0x1c`/`0x2c`, plus the conjugate/negated inverse-bind pair after it.
- **The two frames differ by very nearly a single constant transform.** Computing
  `R_world[b] * B_local[b]^-1` per bone gives an origin of `(-0.0007, 9.8687, -0.0667)` for the
  pelvis, spine, spine1, neck and neck1 alike -- i.e. exactly the hips-origin-to-feet-origin offset,
  the same ~9.87 that shows up as the root track's keyframe-0 translation.

**A sixth animation attempt built on this still fails.** Setting rest from the world pair, computing
`correction[b] = R_world[b] * B_local[b]^-1`, chaining real `.ban` keyframes and mapping them through
that correction renders a **vertically stretched** character -- torso and one leg on the ground with
the arms and hands floating roughly a body-height above. Reverted. Since the mapping is exact at the
bind frame by construction, the failure means the per-bone correction is *not* uniform enough for the
limb chains even though it is dead constant along the spine, so the two frames are not related by a
single rigid transform for every bone after all.

Running tally of real `.ban` playback strategies tried and measured, none of which beat a static bind
pose: delta-against-keyframe-0 as a local rotation; keyframe rotations treated as global and
converted to parent-relative; documented local rotation *and* translation applied directly as the
pose; rotation only; frame mapping using the local rotation misread as a world rotation; and this
one, frame mapping using the genuine world rotation. The remaining unknown is narrow and specific --
why the local-to-world relationship holds constant along the spine but not the limbs -- and that is
what to measure next, rather than trying a seventh application strategy.
