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
  28-29 was originally reported as "a constant `0x6464` across every entry checked" in
  `100/100.o2`. **Retracted (2026-08-23), not the real region ID**: `100/100`'s packed region ID
  (`(Y<<8)|X`, the same real scheme `.nvm` files are named by — see `NVM_FORMAT.md`) is `0x6464`
  exactly, which looked like a real match at first. But checking a second real sample
  (`101/99.o2`) more thoroughly (every entry, not just the first) found this field is **not
  constant within a file at all** — real values seen: `0x6562`, `0x6563`, `0x6463`, `0x6564`, all
  suspiciously *close to* (but not exactly) `101/99`'s own packed ID in either byte order
  (`0x6563`/`0x6365`), varying by ±1 in one byte entry-to-entry. `100/100`'s own sample simply
  couldn't reveal this variance, since every real neighboring-region encoding around a symmetric
  coordinate like `(100,100)` collapses toward the same `0x64`-ish bytes. Genuinely unresolved —
  plausibly a per-entry reference to a *specific* nearby region (not necessarily this file's own),
  or an unrelated field that coincidentally lands in the same byte range. Not the simple "this
  file's own packed ID" story first reported; corrected rather than left standing.
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

## SOLVED: relative offset 18-21 is a real Y-axis (yaw) rotation (2026-08-24)

An earlier pass of this doc reported relative offsets 18-19 and 20-21 as "reads zero" in the one
small real sample checked at the time. That was correct for that sample (most real objects there
happen to face the default direction, rotation `0.0`), not a real property of the field — a wider
real check found otherwise. This byte range is the same real per-entry rotation `.o`'s own record
turned out to have (see `MAPO_FORMAT.md`'s "Object record" section for the full derivation:
decompiled cos/sin construction plus an empirical range check): a single little-endian `float32`
spanning what was previously split into "two zero u16s". Checked against a real, densely-populated
Jangan-area `.o2` file (`98/168.o2`, 506 real entries across all fields/sectors): **100%** of the
values at this offset, read as `float32`, fall in the real `[0, 2*pi]` range — not a coincidental
reading of unrelated bytes. Implemented as `Entry2.Rotation` (Go) / `Entry.rotation` (GDScript),
wired into `World3D.gd`'s real object placement the same way `.o`'s own rotation was.

## Corrected (round 583): bytes 22-23, 27 and 28-29, read from the loader

Read in the decompiled loader (`FUN_00a361b0`, `/var/tmp/decomp_client` on the render box,
`/var/tmp/getfn.sh 00a361b0 /var/tmp/decomp_client`). Each record is read whole into one 30-byte
buffer (`FUN_00410f90(local_1370, 0x1e)`), and the loader then takes three fields from that buffer.
They are `uStack_135a` at +0x16, `bStack_1355` at +0x1b and `uStack_1354` at +0x1c:

- **Bytes 22-23: the object's uid, and bytes 28-29: its owner region.** They are the low and
  high halves of one 32-bit key, `CONCAT22(bytes 28-29, bytes 22-23)`. The loader looks the
  object up by that key (`Map::FUN_00a1a1d0`, and `FUN_00a34c50` for the first list). Bytes
  28-29 are the packed region id `(Y<<8)|X` of the region that owns the object, which is not
  always the file's own. `86/90.o2`'s own records carry `5a 56` (0x565a, 86/90). One list-2
  Halloween record in `98/169.o2` carries `a9 61` (0x61a9, 97/169). The other list-2 Halloween
  records in that file carry `a9 62` (0x62a9, 98/169). This explains the "not constant within a
  file, off by one in one byte" values `101/99.o2` showed above: a neighbour owns those entries.
  The retraction above stands, and the field is now identified. The `.nvm` object record has the
  same header shape, and `NvmReader` names the same two offsets `uid` and `region_id`. The
  "1-based sequential index" at 22-23 is this uid. Its "scope" is the owner region: the key is
  unique only together with bytes 28-29. **A lead:** Map.pk2's `layerobjectlist.ifo` starts
  each row with a 32-bit id. 561 rows were matched by position to an `.o2` record in the same
  region, with every axis within 0.05. In all 561, every matching record's
  `CONCAT22(bytes 28-29, bytes 22-23)` equals the row's id. So the map's layer list names
  objects by this same key. Nothing shows the client reading that file (see
  `client/scripts/world/seasonal_objects.gd`).
- **Byte 27, bit 0: the retail loader's skip bit.** In the second and third lists (MapO2Reader's
  `lists[1]` and `lists[2]`; the reader's `lists[0]` is always empty, measured below), a record
  with `(byte 27 & 1) != 0` is not built. The loader shrinks the sector's array by one
  (`FUN_00a35040(size - 1)`) and moves on. The first list does not test the bit. Measured over
  the 4,559 region `.o2` files in Map.pk2, the files under its numbered folders (round 583, a
  throwaway Go scan over `mapo.Parse2`). The 15 `.o2` files at the archive's root, `50.o2` to
  `64.o2`, were not scanned:
  - `lists[0]` holds 0 of 234,602 entries.
  - `lists[1]` holds 202,672 entries, and 760 of them have the bit set.
  - `lists[2]` holds 31,930 entries, and 240 of them have the bit set. They are in 41 regions,
    none of them Jangan's nine, and span 19 model paths:
    - Baghdad's `bagh_masin_lightwall` (120).
    - The guild `barricade_0x` pieces: 01 (2), 02 (10), 03 (18), 04 (14) and 07 (4), 48 in all.
    - The `bagh_city\event\bagh_barricade0x` set: 01 (1), 02 (4), 03 (16), 04 (7), 05 (3),
      06 (4), 07 (1), 08 (8) and 09 (2), 46 in all.
    - Petra's `bagh_petra_fire_down` (9), `_mid` (9) and `_up` (6), 24 in all.
    - `res\dun\jupiter\piety\piety_golddoor.bsr` (2).
    - The paths sum to 240: 120 + 48 + 46 + 24 + 2.
  
  **Since round 643 this client tests the bit** (`MapO2Reader.Entry.skipped()`,
  `World3D.region_placements`): those 240 `lists[2]` records and the 760 `lists[1]` ones are not
  built. Whatever puts them in the world (a siege, an event) is not traced; it stays open in
  `docs/TODO.md`. No seasonal record has the bit set. The
  same scan finds 878 seasonal entries (686 in `lists[1]` and 192 in `lists[2]`; christmas 262,
  halloween 156, obt 439, summer 21), and bytes 26-27 are zero in every one.
- **The field read before the first list is a bare `uint16`.** The loader reads it and moves the
  pointer past it (`puStack_1250 = puVar11 + 1`). No entry read follows it. So "count + that
  many 30-byte entries, discard the result" (field 0 above) has matched the loader only because
  the value has been 0. A non-zero value would make MapO2Reader and `mapo.Parse2` read entries
  that the loader does not. This is recorded here and not acted on: every file parsed so far ends
  exactly at EOF.

## Round 643: which records the world builds, and in whose frame

READ in `FUN_00a361b0` (`/var/tmp/getfn.sh 00a361b0 /var/tmp/decomp_client`) and its two lookups:

- Per sector, the loader reads the bare `uint16`, then three counted lists. The first
  (`lists[0]`) goes through `FUN_00a34c50` into the sector's array at +0x04; the second
  (`lists[1]`) and third (`lists[2]`) each go through `Map::FUN_00a1a1d0` into the arrays at
  +0x14 and +0x24. **Both of the populated lists are built.** Only the skip bit (byte 27, bit 0)
  keeps a record out, as round 583 read.
- `Map::FUN_00a1a1d0` and `FUN_00a34c50` are the same shape: find the key in a map; if found,
  add one to its count (+0x10) and return the stored object (+0x14); if not, call the creator
  stored at the map's +0x28 with the record and insert the result. So the key
  `CONCAT22(bytes 28-29, bytes 22-23)` names **one object**, however many sectors and regions list
  it (`MapO2Reader.Entry.object_key()`, `mapo.Entry2.Key()`).
- `sro_client.exe`'s strings hold `%d\%d.m`, `%d\%d.o2` and `K%d\%d.t`, and no `%d\%d.o`
  (MEASURED: `strings` over the executable and a grep of the decompile). No loader of `.o` has
  ever been found, and nothing names one, so retail does not read `.o`.

MEASURED over Map.pk2's 4,559 region `.o2` files (`server/cmd/mapobjcensus`):

| | |
|---|---|
| records in `lists[1]` / `lists[2]` | 202,672 / 31,930 (760 / 240 with the skip bit) |
| distinct keys built (the retail set) | **75,564** |
| keys in `lists[1]` only / `lists[2]` only / both | 52,366 / 23,191 / 7 |
| keys listed by more than one region | 10,703, and 10,682 of them at the identical local position and type in every file |
| keys listed by their owner region's own file | 75,543 (the other 21: `alex_harbor`, `alex_paros`, `alex_obelisk`, `pha_maze*`, two `tre_tree02`, seasonal pieces, ...) |

So **a record's position is local to its owner region** (bytes 28-29), not to the file's.
`MapO2Reader.owner_offset` moves it into the file's frame: the owner's second number steps
local x and its first steps local z, one 1920-unit span each, as `World3D._cell_offset` steps
the terrain groups.

`lists[1]` is not "cross-references to other regions' objects", as the seventy-eighth round took
it: 52,366 of the objects retail builds are listed there and nowhere else, among them Hotan's
stable (`oas_hot_stab`, 91/135), its north and south bridges (`oas_hot_b1_bridge` 90/135,
`oas_hot_b2_bridge` 93/135), and the Fertility Temple (`ruin_takla_temple_01`, 102/135) with its
two bridges (`ruin_takla_tembrig_01`, 101/135 and 102/134). Its entries fall outside their
position's sector more often (46 % against 91 %, round 78) because a big object is listed by
every sector it reaches.

## What this still doesn't tell us

- The exact meaning of the entry's `0xffff` sentinel. (The "`0x6464` suffix" is the owner region and
  the "sequential index" the uid: see "Corrected (round 583)" above.)
- What field 0's discarded count actually represents, and whether it's ever genuinely nonzero.
- What distinguishes `lists[1]` from `lists[2]`: both are built the same way (round 643), and a
  key sits in one or the other (7 of 75,564 in both). The loader does one more thing for a
  `lists[1]` record whose object has +0x1a bit 0 set (a link through a map at +0x247b, a portal
  or warp candidate); that branch is not read further.
- Whether the "only field 2 populated" pattern holds generally, or is specific to this one sample.

## Implementation

`client/scripts/mapo/mapo2_reader.gd` (`MapO2Reader`) and `server/internal/mapo/mapo2.go`
(`mapo.Parse2`) both implement the corrected 4-field-per-sector structure above, and both are
re-verified against the real `100/100.o2` sample (36 sectors, 0 leftover bytes, 100 total real
entries, all in field index 2). Field 0's entries are parsed and then discarded, matching the real
client's own behavior, rather than exposed as a 4th "real" list — callers only see fields 1-3.

Since round 643 the world builds its objects from the `.o2` alone, as retail does
(`World3D.region_placements`): `lists[1]` and `lists[2]`, skip bit clear, one object per key in
the owner's frame. `World3D._placed_objects` keeps each key once across the loaded regions (the
first region to commit it places it, later ones share it), and a region streaming out hands what
it holds to a region still listing it (`_release_region_objects`). `MapO2Reader.Entry` carries
`owner_region`, `build_flags`, `skipped()` and `object_key()`; `mapo.Entry2` has `OwnerRegion()`,
`Skipped()` and `Key()`. `server/cmd/mapobjcensus` compares the client's placement rule with the
retail set over every region (`-ownerframe` is the rule since round 643).
