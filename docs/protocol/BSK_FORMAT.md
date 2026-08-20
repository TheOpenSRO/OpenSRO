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
