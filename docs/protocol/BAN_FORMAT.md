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
