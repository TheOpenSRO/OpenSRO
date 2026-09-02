# BAN animation format (JMXVBAN)

`.ban` is the bone-animation format: a named animation clip made of one or more bones, each with
its own array of keyframes (rotation + position over time).

Confirmed two ways, the same as pk2/bsr/bms/ddj: empirically against 3 real extracted `.ban`
files (all three parse to **exactly** their own file length with zero bytes left over — the
strongest possible confirmation for a format with no explicit "end" marker), and by decompiling
the real loader in `sro_client.exe` (`FUN_00c01e20` → `FUN_00c01ca0` → `FUN_00c00630`), which
confirmed the 28-byte keyframe record size directly from the `FUN_00410f90(ptr, count * 0x1c)`
read call. No decompiler output is stored in this repo — only the resulting facts about the
container format.

## Header

| Field | Encoding |
|---|---|
| Magic | `"JMXVBAN 0102"` (12 bytes) |
| (2 unconfirmed `uint32` fields, observed `0` in every real file checked) | |
| Animation name | `uint32` length + ASCII bytes |
| Unknown1, Unknown2, Unknown3 | 3× `uint32`, unconfirmed meaning (observed `(666, 30, 1)` in two samples, `(6666, 30, 1)` in a third — `Unknown2=30` and `Unknown3=1` were constant across all three; `Unknown1` varied, plausibly a duration/size field of some kind) |
| Offset table count | `uint32` |
| Offset table | that many `uint32`s, unconfirmed purpose (possibly per-frame timing or byte offsets — not needed to parse past it, only its count) |
| Bone count | `uint32` |
| Bones | that many bone records, back-to-back (see below) |

## Bone record

| Field | Encoding |
|---|---|
| Name | `uint32` length + ASCII bytes (e.g. `"Bone01"`) |
| Keyframe count | `uint32` |
| Keyframes | that many 28-byte keyframe records, back-to-back |

## Keyframe record (28 bytes)

| Offset | Size | Field |
|-------:|-----:|-------|
| 0x00 | 16 | Rotation: 4× `float32` (x, y, z, w) — confirmed as a **unit quaternion**: every keyframe in every real file checked has `x²+y²+z²+w² ≈ 1.0` |
| 0x10 | 12 | Position: 3× `float32` (x, y, z) — root-motion translation; all-zero in a pure in-place "spin" animation, real nonzero values (with a real character's own scale, e.g. ~1 unit) in a general-purpose character animation sample |

## Implementation notes

- `server/internal/ban` (Go) and `client/scripts/ban/ban_reader.gd` (GDScript) both parse the
  full structure; unit tested (`go test` / headless GDScript test) against synthetic fixtures
  (never real game data, same policy as the other formats), and cross-checked against each other
  on the same real file (`bandi.ban`) to confirm identical output.
- Not wired into any actual rendering/animation yet. Applying these keyframes to a Godot
  `Skeleton3D`/`AnimationPlayer` needs the bone hierarchy (parent/child relationships) from
  wherever that's defined — not yet located; `.ban` itself has no parent-bone field, only a flat
  list of named bone tracks.

## Public format documentation found (2026-09-02) — keyframes are parent-relative, and carry translation

Found the same public reference this project already used for `.m` terrain and `.bmt` material flags:
[`JellyBitz/srodevs-docs`](https://github.com/JellyBitz/srodevs-docs)'s `file-formats/jmxvban.md`
(fair game per [`docs/LEGAL.md`](../LEGAL.md) point 3 — long-published public community
documentation). It documents this exact format under the same `JMXVBAN` magic, and resolves two
things this project had not confirmed:

- The header carries a real `Duration` (ms), a real **`FPS`**, and a real `IsCyclic` flag, followed
  by a real per-keyframe `Time` (ms) table. This project currently plays every real animation back
  at a hand-picked `BAN_FPS` engineering guess — **the real per-file FPS and per-keyframe timings
  are right there in the file and simply aren't being read**. Wiring them would remove that guess
  entirely.
- Each animated bone's per-keyframe record is documented as a *"transformation matrix **relative to
  the parent bone/joint**"*, holding a `Quaternion Rotation` **and** a `Vector3 Translation`.
  `BanReader` already parses both fields correctly; the consumer
  (`Skeleton3DBuilder.apply_ban_pose`) discards the translation entirely and treats the rotation as
  a delta against keyframe 0.

**Three application strategies were tried against real data and all render worse than the current
one** (2026-09-02, real headless renders of a real assembled character, see
`docs/WORLD_ISSUES.md`'s forty-eighth/forty-ninth rounds):

1. Treating keyframe rotations as **global/world-space** and converting them to parent-relative:
   character scatters completely. Also independently contradicted by the public doc above, which
   says parent-relative.
2. Applying the documented parent-relative rotation **and** translation directly as the Godot bone
   pose (pose being the bone's live local transform): character scatters, with limbs flung far
   apart — the translations in particular do not land where this project's skeleton expects.
3. Applying the documented parent-relative rotation directly, keeping `.bsk`-derived rest positions:
   still scatters.

That all three fail while the documented semantics are clear points at a mismatch **between this
project's own `.bsk`-derived rest pose and the space `.ban` keyframes are expressed in**, rather
than at the `.ban` reader or the public documentation. `Skeleton3DBuilder.build_skeleton3d` derives
each bone's rest transform by converting real `.bsk` world-space bind rotations into parent-relative
form; if that derivation's convention (axis order, parent chain, or whether rest translations are
parent-relative or absolute) doesn't match what `.ban` assumes, every strategy above inherits the
same error. **That comparison is the next real step** — dump, for the same real skeleton, each
bone's `.bsk`-derived rest transform beside its `.ban` keyframe-0 transform and see exactly how they
differ, rather than trying further application strategies blind.

Animation playback stays disabled meanwhile (see `World3D._physics_process`), so the real character
renders correctly in its real bind pose instead of visibly broken.
