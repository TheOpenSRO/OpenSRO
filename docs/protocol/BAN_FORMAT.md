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
| Duration | `uint32`, milliseconds — equal to the last key time in every file checked (`chinaman_fighter_standcity` 2333, `spear_run_fighter` 666, `skill_ch_bow_power_a` 3000) |
| Authored FPS | `uint32`, 30 in every file checked: the grid the key times sit on (each is a multiple of 33.3 ms). Not a playback rate — a 2333 ms idle holds 14 keys, a 2000 ms stance 5 |
| Cyclic | `uint32`, 1 for stands, walks and runs, 0 for skills, sitting down and dying |
| Key time count | `uint32` — the same as every bone's keyframe count in every file checked |
| Key times | that many `uint32` milliseconds, ascending from 0: when each keyframe falls. **This is the clock.** Playing keyframes at a fixed 30 a second ran the idle five times too fast (measured 2026-09-11 over the China fighter's animations with `client/tools/dump_ban_times.gd`, every file parsing to exactly its own length); the client now poses between the two keys bracketing the elapsed time |
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
  by a real per-keyframe `Time` (ms) table. Measured and wired 2026-09-11 (the header table above):
  `BanReader` reads `duration_ms`, `authored_fps`, `cyclic` and `key_times`, and
  `Skeleton3DBuilder.apply_ban_pose_at` poses on that clock, blending between the bracketing keys.
  The `BAN_FPS` guess this project played everything at is gone.
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

### The rest-vs-keyframe-0 comparison, actually run (2026-09-02)

Ran the comparison the section above named as the next step: for the real `chinaman_skel.bsk` and
the real `chinaman_fighter_standcity.ban` (37 shared bones, 14 keyframes), dumped each bone's
`.bsk`-derived rest transform beside its `.ban` keyframe-0 transform. Result, all against real data:

- **They do not match**: only **2 of 37** rotations agree (dot > 0.999) and **1 of 37** positions
  (within 0.01 units).
- **Translations look axis-permuted, not merely different.** Magnitudes correspond closely while
  landing on different axes -- e.g. `Bip01 Neck` rest `(-0.029, 2.281, 0.257)` vs keyframe-0
  `(2.296, 0, -0.0004)`; `Bip01 Neck1` rest `(-0.0002, 0.4468, -0.0017)` vs `(0.4468, 0, -0.0004)`;
  `Bip01 L UpperArm` rest `(-0.260, 1.133, -0.122)` vs `(1.169, 0, 0)`. Nearly every real `.ban`
  translation is "a length along **local X**, other axes ~0", which is the classic 3ds Max Biped
  convention (bones extend down their own +X). This project's rest positions instead express the
  offset in the *parent's* world-rotation frame, so the length lands on a different axis.
  `Bip01 L Clavicle` swaps the other way (rest `(0.332, 0, -0.039)` vs keyframe-0 `(0, 0.334, 0.0004)`),
  so it is not one uniform axis relabel either.
- **The body's height offset sits at a different level of the hierarchy.** Real `.ban` keyframe 0
  puts `(0, 9.978, -0.067)` on the root `Bip01` and exactly `(0, 0, 0)` on `Bip01 Pelvis`. This
  project's rest does the reverse: `build_skeleton3d` *forces* the root to identity and puts
  `(-0.0007, 9.869, -0.067)` on Pelvis.
- **Chaining keyframe 0 down the hierarchy does not reproduce the `.bsk` bind pose.** Global bone
  positions come out a mean **9.26** / max **18.43** units away from the `.bsk`-derived global rest,
  on a character only ~15 units tall. Ignoring the root's own keyframe (to test whether the
  difference is purely the forced-identity root) makes it *worse*: mean **16.17** / max **23.33**.

**Conclusion**: real `.ban` keyframe 0 is genuinely **not** the same pose as the real `.bsk` bind
pose, in any simple re-expression of it -- so the fix is not "rebuild rest from keyframe 0", and it
is not a single axis swap. The two files really do use different per-bone frames, and reconciling
them needs the real client's own animation/skinning code (this project has the server decompiled,
not the renderer) or a substantially deeper derivation than trial application strategies can reach.
Four strategies have now been tried and measured against real data; recording this so a fifth blind
attempt isn't made.

**Genuinely actionable without solving the above**: the real per-file `FPS` and per-keyframe `Time`
table documented in the section above are unread, and would replace this project's hand-picked
`BAN_FPS` playback-rate guess with real values -- independent of the pose-space problem.

## Verified against the real client binary (2026-09-02)

Everything above came from public documentation plus this project's own parsing. The real
`sro_client.exe` is imported and analysed in a separate Ghidra project on the RE box
(`/home/ghidra/re_client`, alongside `GFXFileManager.dll`), which the MCP session does **not** have
open — it has the Agent/Gateway server project instead (confirmed: its class list is entirely
`CAgentServer`/`CNetEngine`/socket/thread types, with no graphics, skeleton or animation classes at
all). The client project can be driven with `analyzeHeadless -process sro_client.exe -noanalysis
-postScript <script>.java`, which is how the following was obtained. Function numbering matches this
project's existing notes (e.g. `FUN_0042a6e0`, already cited in `MAPM_FORMAT.md` as the real `.m`
loader, appears here as a `JMXV` magic site), so these addresses line up with earlier rounds.

**The real `.ban` loader is `FUN_00c01e20`.** It builds the expected signature inline as three
dwords -- `0x56584d4a` `0x204e4142` `0x32303130`, i.e. **`"JMXV" "BAN " "0102"`** -- validates it via
`FUN_00bfcfb0`, then calls `FUN_00c01ca0` to parse.

**`FUN_00c01ca0` (the parser) confirms the header exactly as publicly documented**: three
consecutive dwords (Duration, FPS, IsCyclic) stored at object offsets `0x20`/`0x24`/`0x28`, then a
`uint` count followed by that many keyframe-time dwords bulk-copied into the object's `0x40`/`0x44`
vector, then a `uint` animated-bone count followed by that many per-bone records, each **44 bytes
(`0x2c`)** in memory, parsed by `FUN_00c00630`.

**`FUN_00c00630` (per-bone track) is the important one**: it reads the transformation count, then
bulk-copies `count * 0x1c` bytes -- **28 bytes per keyframe** -- straight into the track's own
buffer via `memcpy` (`FUN_00410f90`). 28 bytes is exactly a 16-byte quaternion plus a 12-byte
`Vector3`, matching the public documentation, and the copy is **verbatim: the client applies no
conversion, normalisation, or reordering at load time**. It also pre-initialises a quaternion to
`(0, 0, 0, 1.0f)` (the `0x3f800000` immediate) before filling.

So this project's `BanReader` is reading the real format correctly, and the real per-keyframe values
it holds are byte-identical to what the real client holds. **Whatever the remaining pose problem is,
it is not in the reader and not a load-time transformation** -- it is in how the values are combined
with the skeleton at evaluation time, which lives elsewhere in the client and has not been located
yet.

Incidental, from enumerating every `JMXV` magic site in the client: the formats it validates inline
are `OBJI`, `CPD`, `RES`, `BMS`, `DOF`, `NVM`, `DDJ`, `BMT`, `BAN`, and `EFF`. Notably **no `BSK`
magic appears**, even though real `.bsk` skeleton files clearly exist and load — so the skeleton is
either validated differently or reached through one of the other loaders. Worth following up, since
the bind-pose side is exactly where the remaining problem is.

## The loader, read out of the client (2026-09-08)

Found by the same route as the `.bmt` writer -- cross-referencing the source-path string the
assert handler carries. The chain is:

| Function | What it does |
|---|---|
| `FUN_00c01e20` | Opens the file and drives the load. Builds the expected magic inline as three integers `0x56584d4a` `0x204e4142` `0x32303130` — `JMXV`, `BAN `, `0102`. |
| `FUN_00bfcfb0` | The header check, asserting against `…\objengine\PrimAnimation.cpp` with "File Version Error". Rejects a file under 0x14 bytes, then compares the magic and version words. |
| `FUN_00c01ca0` | Reads three dwords into the animation object (+0x20, +0x24, +0x28), then a count, then a second count, then loops over per-bone tracks at a **0x2c-byte in-memory stride** calling… |
| `FUN_00c00630` | …the per-bone reader: reads the bone's **keyframe count**, sizes the keyframe vector to it with `FUN_00bff9d0(count, 0, 0, 0, 0x3f800000)`, then reads `count * 0x1c` bytes into it. |
| `FUN_00bff9d0` | A `std::vector::resize` over an element size of **0x1c**, filling new elements with the default passed in. |

Two things this confirms independently of the file-shape work above:

- **A keyframe is 0x1c = 28 bytes**, and the array is read as one contiguous block of
  `count * 0x1c` — exactly the record documented above.
- **The default keyframe rotation is `(0, 0, 0, 1.0f)`** — `0x3f800000` is 1.0f, passed last.
  That is an identity quaternion with **w last**, which is the component order this project's
  reader already uses.

So the parsing is right, and the remaining problem is entirely **how the keyframes are applied**
(see `Skeleton3DBuilder.apply_ban_pose`, currently disabled, and `docs/WORLD_ISSUES.md`'s
forty-eighth round).

**Where to continue.** The application lives in `…\objengine\RTSkeleton.cpp`.
`FUN_00c51ef0` is skeleton *creation*, not animation. `FUN_00c4a180` is more interesting: it
copies a 16-dword (4x4) matrix out of `*(this+0x80) + 0x40`, multiplies elements 4/5/6 and 8/9/10
— the second and third basis rows — by a float at `this+0x88`, and hands the result on. A
per-bone scale applied to two basis rows is worth understanding before assuming a keyframe
rotation can be dropped straight into a bone's local pose.
