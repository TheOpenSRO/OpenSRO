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
directly from `Map.pk2`) — see "Empirical verification" below. The 6×6/3-list/30-byte-entry
structure below isn't just decompiled-and-trusted; it was checked byte-for-byte against a real
file and it holds.

## Structure

| Field | Encoding |
|---|---|
| Header | 12 bytes — a real 4-byte magic constant (`0x56584d4a`, i.e. ASCII `"JMXV"`, read as a sentinel and compared) + 8 more header bytes, read as one `int + uint32 + uint32` triple in the decompiled code. Real byte-for-byte layout beyond "12 bytes, starts with `JMXV`" not yet isolated. |
| Sector grid | a real **6×6 grid of sectors** (nested loops: outer `iStack_138c` 0..5, inner `iStack_13a0` 0..5 — confirmed via real loop-increment arithmetic: inner stride `0x31`=49, outer stride `0x126`=294=`6×49`, bound `0x6e4`=1764=`6×294`). This is the **same real 6×6 division** this project already confirmed for `.m`'s own terrain sub-patches — real, independent evidence the two formats share one real spatial indexing scheme, not just format-family coincidence. |
| Per-sector data | **3 separate counted lists**, read in a fixed order, each prefixed by its own real `uint16` count |

## The 3 counted lists

Each of the 36 real sectors contains three separate lists, read strictly in this order:

1. **List 1** — count (`uint16`), then that many 30-byte (`0x1e`) raw entries. Each entry is read
   via the same real generic buffered-read primitive `.m` uses (`FUN_00410f90`, confirmed
   non-reordering — see MAPM_FORMAT.md), then handed to `FUN_00a34c50` for further processing
   before being stored into a per-sector array.
2. **List 2** — same shape (`uint16` count, 30-byte entries via `FUN_00410f90`), but its per-entry
   processing (`FUN_00a1a1d0`, then a real lookup/link step referencing what look like portal or
   warp-linkage fields at real offsets `+0x1a`/`+0x1e` of the sector's own internal record struct,
   with equality checks against fields the decompiled code names via offsets `0x247b`/`0x247f`
   relative to another real per-map structure) is real but substantially more involved than list
   1's or list 3's — **plausibly a portal/warp-trigger list**, not confirmed.
3. **List 3** — same shape again (`uint16` count, 30-byte entries via `FUN_00410f90`), processed
   via `FUN_00a1a1d0` and stored into yet another per-sector array, structurally simpler than list
   2 (no portal-linkage-shaped branching).

All three lists' entries are a real, confirmed **30 bytes each**.

## Empirical verification (2026-08-23, real `100/100.o2`)

Pulled a real, populated Shape B region's `.o2` file (`100/100.o2`, 3,780 bytes) directly from
`Map.pk2` and parsed it in Python using exactly the structure above (12-byte header, then 36
sectors in real nested order, 3 `uint16`-prefixed 30-byte-entry lists per sector) — **it parses
cleanly with no structural errors**, and the entries decode into a real, plausible shape:

- **Header**: bytes 0-7 are literally `"JMXVMAPO"`, bytes 8-11 are the ASCII version `"1001"` —
  `.o2` shares `.o`'s exact magic string, just with the same `.o` format family's own versioning,
  not a distinct `"JMXVMAPO2"`-style magic. Sector data starts immediately at byte 12 (no
  additional header fields beyond magic+version).
- **30-byte entry, now decoded**: `uint32` **type ID** (4 bytes) + 3× `float32` **position** (x,
  y, z — 12 bytes) decode as immediately plausible real values — e.g. one real sector's list 3 had
  3 entries, all type ID `1489`, at positions `(56.8, 167.0, 23.0)`, `(128.5, 167.3, 179.3)`,
  `(210.5, 167.3, 119.0)` — a shared, constant Y (world height) with varying X/Z, exactly the shape
  real ground-clutter placement (e.g. 3 instances of the same object type scattered across one
  patch of terrain) would produce. This is the **same real record shape as `.o`** (type ID +
  position triple), not a coincidence — reinforces that `.o` and `.o2` are the same object-family
  format, just different real generations. Of the remaining 14 bytes (relative offsets 16-29
  within the 30-byte entry): offset 16-17 is `0xffff` (a likely no-link/no-parent sentinel),
  offset 18-19 reads zero, offset 20-21 also reads zero, offset 22-23 is a real, confirmed
  **1-based sequential index** (this session's 3-entry sample sector had indices `1, 2, 3` in
  file order there), offset 24-27 reads zero, and offset 28-29 is a constant `0x6464` across
  every entry checked so far (meaning/purpose unconfirmed).
- **All 4 distinct real type IDs seen across the whole file** (`669`, `1488`, `1489`, `1748`)
  **appear in all 3 lists**, not segregated by list — this is a real, concrete finding against
  this doc's earlier "3 lists = 3 categories" guess (static objects / portals / spawn points):
  if that were true, the same type ID showing up as (say) both a "static object" and a "spawn
  point" would be a strange coincidence repeated across dozens of real entries. What actually
  distinguishes the 3 lists remains unconfirmed — spatial/authoring-tool grouping rather than
  semantic categories is now the more likely explanation, but unconfirmed either way.
- **A real, unexplained gap remains**: parsing all 36 sectors' worth of lists consumed exactly
  100 real entries and landed at file offset 3,228 — but the file is 3,780 bytes long, leaving
  **552 bytes unconsumed** after the last sector. (Coincidentally the same *number* as the
  already-documented, unrelated `.m` Shape-B per-sub-patch overhead in MAPM_FORMAT.md — almost
  certainly not connected, given these are different formats/functions, but flagged in case a
  real connection turns up later.) The real decompiled function does have more code after its main
  6×6 loop finishes (real portal/link-table finalization logic, `FUN_00a16680` and onward) — the
  552 trailing bytes are a plausible match for that, not investigated further this pass.

## What this still doesn't tell us

- The exact meaning of the entry's `0xffff` sentinel, the sequential index's real scope (per-list?
  per-sector? per-file?), and the constant `0x6464` suffix.
- Confirmation of what (if anything) actually distinguishes the 3 per-sector lists, now that a
  same-type-ID-in-every-list finding has weakened the "3 categories" guess.
- The real 552-byte trailing structure after the 36-sector loop.
- No reader/renderer exists in this project's own code yet (`client/scripts` and `server/`) — `.o2`
  is currently not parsed at all; only the older `.o` format is (see [MAPO_FORMAT.md](MAPO_FORMAT.md)),
  meaning regions that have real `.o2` data are currently missing whatever real objects it would
  add beyond `.o`'s own (typically sparser) object list. Implementing a real `MapO2Reader` from
  the structure confirmed above (12-byte header, 36 sectors × 3 lists × entries, each entry
  type ID + position + the partially-decoded trailer) is now a well-scoped, low-risk next step —
  the hard structural unknowns are resolved; what's left is mostly plumbing plus the open
  cosmetic questions above.
