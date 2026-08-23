# MAPO2 object/event index format (`.o2`)

`.o2` files inside `Map.pk2` exist alongside `.m`/`.o` only for **newer-generation regions**
(confirmed via direct `Map.pk2` inspection — see [MAPM_FORMAT.md](MAPM_FORMAT.md)'s Shape A/B
split: a Shape B region like `100/100` has `.m`+`.o`+`.o2`+`.t`; a Shape A region like `0/0` has
only `.m`+`.o`, no `.o2`, no `.t`). Unlike `.o` (reverse-engineered entirely empirically — no
loader was ever found for it), `.o2` has a **real, precisely decompiled loader function**:
`FUN_00a361b0` in `sro_client.exe`, real source file
`D:\vss-od\Silkroad\Client\Landscape\MapEngine\MapCallBack.cpp` — the same function that also
opens the region's `.m` file (see MAPM_FORMAT.md's "real loader function" section; both files are
opened by the same function, `.o2`'s open guarded by a real, literal assert string
`"m_pFMMap->CreateFile(ar,chFileName,GENERIC_READ)"`).

**Empirically verified the same day** against a real sample (`100/100.o2`, 3,780 bytes, pulled
directly from `Map.pk2`) — see "Empirical verification" below, including a **real correction**
this same verification pass caught: an initial reading of the decompiled function found only 3
counted lists per sector, and a first empirical check seemed to confirm it (parsed cleanly, no
errors) — but left a real, unexplained 552-byte gap before EOF. Investigating that gap found a
real 4th counted field per sector this project's first pass had missed entirely. Corrected below;
the account of the "3 lists" mistake is kept rather than deleted, per this project's own standing
error-correction discipline.

## Structure

| Field | Encoding |
|---|---|
| Header | 12 bytes — a real 4-byte magic constant (`0x56584d4a`, i.e. ASCII `"JMXV"`, read as a sentinel and compared) + 8 more header bytes, read as one `int + uint32 + uint32` triple in the decompiled code. Real byte-for-byte layout beyond "12 bytes, starts with `JMXV`" not yet isolated. |
| Sector grid | a real **6×6 grid of sectors** (nested loops: outer `iStack_138c` 0..5, inner `iStack_13a0` 0..5 — confirmed via real loop-increment arithmetic: inner stride `0x31`=49, outer stride `0x126`=294=`6×49`, bound `0x6e4`=1764=`6×294`). This is the **same real 6×6 division** this project already confirmed for `.m`'s own terrain sub-patches — real, independent evidence the two formats share one real spatial indexing scheme, not just format-family coincidence. |
| Per-sector data | **4 separate counted fields**, read in a fixed order, each prefixed by its own real `uint16` count — see below. |

## The 4 counted fields per sector (corrected from an initial "3 lists" misreading)

Each of the 36 real sectors contains **four** separate `uint16`-prefixed fields, read strictly in
this order:

0. **Field 0 (missed on the first pass)** — a real `uint16` is read and the read pointer is
   advanced past it (`puStack_1250 = puVar11 + 1`, a real, easy-to-miss line in the decompiled
   function immediately preceding what this doc originally labeled "list 1"), but **the value is
   never stored anywhere** — no loop reads entries using it as a count. In this project's one real
   sample, this field's value was consistently small enough that treating it uniformly as "a count,
   then that many 30-byte entries" (the same shape as fields 1-3) still parsed correctly to EOF —
   but whether it's genuinely a count for entries the real client simply discards, or some other
   small integer field entirely unrelated to a list, is **not confirmed**. Parse it as "count +
   that many 30-byte entries, discard the result" until proven otherwise.
1. **Field 1** — count (`uint16`), then that many 30-byte (`0x1e`) raw entries. Each entry is read
   via the same real generic buffered-read primitive `.m` uses (`FUN_00410f90`, confirmed
   non-reordering — see MAPM_FORMAT.md), then handed to `FUN_00a34c50` for further processing
   before being stored into a per-sector array. **Always empty (count 0) in the one real sample
   checked.**
2. **Field 2** — same shape, but its per-entry processing (`FUN_00a1a1d0`, then a real lookup/link
   step referencing what look like portal or warp-linkage fields at real offsets `+0x1a`/`+0x1e` of
   the sector's own internal record struct, with equality checks against fields the decompiled code
   names via offsets `0x247b`/`0x247f` relative to another real per-map structure) is real but
   substantially more involved than the others — **plausibly a portal/warp-trigger list**, not
   confirmed. **Always empty (count 0) in the one real sample checked.**
3. **Field 3** — same shape again, processed via `FUN_00a1a1d0` and stored into yet another
   per-sector array, structurally simpler than field 2 (no portal-linkage-shaped branching). **This
   is the one field that actually held real data in the one sample checked** — every real entry
   this project has decoded so far (100 of them, across the whole file) came from this field.

All four fields' entries are a real, confirmed **30 bytes each**, matching `.o`'s own record shape
once decoded (type ID + position triple — see below).

## Empirical verification (2026-08-23, real `100/100.o2`)

Pulled a real, populated Shape B region's `.o2` file (`100/100.o2`, 3,780 bytes) directly from
`Map.pk2` and parsed it in Python:

- **First pass (wrong)**: assumed 3 fields/sector (missing field 0 above). Parsed "cleanly" for
  all 36 sectors with no structural errors — self-delimiting counted lists don't have a natural
  invalid-data signal, so a wrong field count can still produce a plausible-looking parse. Landed
  at file offset 3,228 with **552 bytes left over**, unconsumed.
- **The 552-byte "leftover" turned out to be real, valid entries**, not padding or a separate
  trailing structure: hand-decoding it found the exact same 30-byte entry shape, with type IDs
  (`669`, `1489`) matching ones already seen elsewhere in the file — far too specific to be
  coincidental garbage. That's what triggered re-examining the decompiled function and finding the
  missed field-0 read.
- **Second pass (corrected, 4 fields/sector)**: parses **all 36 sectors with zero errors and zero
  leftover bytes** — consumption lands exactly on the file's real 3,780-byte length. In this real
  sample, fields 0, 1, and 3 are empty (count 0) in every one of the 36 sectors; **all 100 real
  entries in the file come from field 2** (0-indexed third field). Whether this "only field 2 is
  ever populated" pattern holds for other real `.o2` files, or whether other regions populate
  fields 0/1/3 too, is **not checked yet** — only one real sample has been examined.
- **30-byte entry, decoded**: `uint32` **type ID** (4 bytes) + 3× `float32` **position** (x, y, z —
  12 bytes) decode as immediately plausible real values — e.g. one real sector had 3 entries, all
  type ID `1489`, at positions `(56.8, 167.0, 23.0)`, `(128.5, 167.3, 179.3)`, `(210.5, 167.3,
  119.0)` — a shared, constant Y (world height) with varying X/Z, exactly the shape real
  ground-clutter placement would produce. This is the **same real record shape as `.o`**, not a
  coincidence. Of the remaining 14 bytes (relative offsets 16-29 within the 30-byte entry): offset
  16-17 is `0xffff` (a likely no-link/no-parent sentinel), offset 18-19 reads zero, offset 20-21
  also reads zero, offset 22-23 is a real, confirmed **1-based sequential index** (this session's
  3-entry sample had indices `1, 2, 3` in file order there), offset 24-27 reads zero, and offset
  28-29 is a constant `0x6464` across every entry checked so far (meaning/purpose unconfirmed).
- **All 4 distinct real type IDs seen across the whole file** (`669`, `1488`, `1489`, `1748`) all
  came from the same field (field 2) in this sample, so this project's earlier "type IDs shared
  across lists, ruling out per-list categories" observation no longer applies the same way — with
  only one field ever populated in this sample, there's no cross-field mixing to observe either
  way. What (if anything) distinguishes fields 1/2/3 remains unconfirmed; a real sample where more
  than one field is populated would be needed to check.

## Cross-checked against 3 more real samples (2026-08-23)

Pulled 3 more real `.o2` files (`101/99.o2`, `100/101.o2`, `99/101.o2`) and ran the same corrected
4-field-per-sector parse against each: **all three parse cleanly with zero errors and zero
leftover bytes**, confirming the fix generalizes beyond the one original sample. New data points:

- Fields 0 and 1 were empty (count 0) in every sector of every one of these 4 real samples now
  checked — still no real evidence either ever holds data, though 4 samples isn't proof they
  never do.
- Field 2 was the primary populated field in every sample (`75`, `94`, `51` real entries
  respectively), consistent with the original sample.
- **New**: `101/99.o2` had **3 real entries in field 3** — the first evidence field 3 isn't always
  empty. This is a real, useful data point for whatever eventually distinguishes fields 1-3: field
  3 holding a small number of entries in an otherwise field-2-dominated file is at least consistent
  with the "field 3 = portal/warp-trigger list" guess (real regions typically have few real portals
  compared to many decorative objects), though still not confirmed.

## What this still doesn't tell us

- The exact meaning of the entry's `0xffff` sentinel, the sequential index's real scope (per-list?
  per-sector? per-file?), and the constant `0x6464` suffix.
- What field 0's discarded count actually represents, and whether it's ever genuinely nonzero.
- What (if anything) distinguishes fields 1, 2, and 3 — only one real sample has been checked, and
  it only ever populated field 2.
- Whether the "only field 2 populated" pattern holds generally, or is specific to this one sample.

## Implementation

`client/scripts/mapo/mapo2_reader.gd` (`MapO2Reader`) and `server/internal/mapo/mapo2.go`
(`mapo.Parse2`) both implement the corrected 4-field-per-sector structure above, and both are
re-verified against the real `100/100.o2` sample (36 sectors, 0 leftover bytes, 100 total real
entries, all in field index 2). Field 0's entries are parsed and then discarded, matching the real
client's own behavior, rather than exposed as a 4th "real" list — callers only see fields 1-3.
