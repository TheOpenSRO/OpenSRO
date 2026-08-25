# Compound object format (JMXVCPD, `.cpd`)

`.cpd` is a real "Compound" object container: a real name plus a list of real independent `.bsr`
references it groups together — a full character equipped with armor pieces, a decorated tree with
ornament attachments, or a small multi-piece scenery prop. See [BSR_FORMAT.md](BSR_FORMAT.md) for
the `.bsr` format itself.

## Found 2026-08-23, live-testing real Jangan palace scenery

`ObjectLoader` previously tried to parse every real `object.ifo`-resolved path as a `.bsr`, and
failed outright (`bsr: bad magic JMXVCPD 0101, want JMXVRES 0109`) on 11 real placements in one
real region alone. `.cpd` is a real, genuinely different container format, not a `.bsr` variant.

## Source

No public documentation covers this format. Found and confirmed via the same clean-room technique
used throughout this project: decompiling the real client's own loader on RE infrastructure this
project controls (per `docs/LEGAL.md` — no decompiler output is stored in this repo, only the
resulting facts), cross-checked against real extracted `.cpd` files until the recovered data made
sense (real, sensible `.bsr` paths; a real character's compound listing its body plus a full,
plausible armor set; a real decorated tree's compound listing its trunk plus real ornament names).

**Method**: found the real literal string `.cpd` referenced by a loader dispatch function
(`FUN_00c6be00`, the same real function that also handles `.bsr` loading via file-extension
dispatch — confirming these two formats share a load path at the object-engine level, not just by
convention). Traced through the real CPD-specific loader (`FUN_00bec690` → `FUN_00bebc60`,
"CompoundObject Data Loading Failed" error string) into the real `CompoundObject` class's own
`Load` virtual method (found via its real vtable, at slot 0xa4). That method receives an
**already-tokenized real linked-list structure**, not raw file bytes — the true raw
byte-for-byte deserialization happens in an earlier step this project didn't trace further, since
the real value (which `.bsr` sub-objects to spawn) was already recoverable another way (see below).

## Real structure: solved enough to be useful, not fully solved

```
12   string  Signature           // "JMXVCPD 0101"
4    uint    Unconfirmed          // observed values 66, 68, 57 across 3 real samples
4    uint    Unconfirmed          // observed values 70, 115, 61
20   bytes   Reserved             // zero in every real sample checked
2    uint16  Unconfirmed          // observed values 2, 2, 0
2    uint16  Unconfirmed          // observed value 3 in every real sample checked
4    uint    NameLength
NameLength  string  Name          // e.g. "st_sand_01", "x_mas_tree_b", "1"
...  real, but NOT fully understood -- see below
```

**The real trailing structure (name onward) is not fully solved.** Three real samples pulled
directly (`Compound\particle\st_sand_01.cpd`, 148 bytes; `Compound\Struct\China\event-xmas\
x_mas_tree_b.cpd`, 541 bytes; `Compound\Char\China\1.cpd`, 467 bytes) each showed a **different**
real shape after the name:

- `st_sand_01.cpd`: 8 real reserved-looking zero bytes, then a real flat sub-count (`2`), then 2
  real length-prefixed `.bsr` paths back-to-back.
- `x_mas_tree_b.cpd`: two real nonzero fields (`3`, `2`) directly after the name (no zero gap at
  all), then **one** real `.bsr` path, then another real field (`8`) sitting *between* two
  entries, then 8 more real `.bsr` paths — including a real **duplicate** of the very first path.
- `1.cpd`: 12 real zero bytes, then a real flat sub-count (`7`), then 7 real length-prefixed
  `.bsr` paths (a real character body plus a real, sensible 6-piece armor set) back-to-back.

These three real shapes are not the same structure with different values — the byte layout itself
differs (a flat count vs. a nested count-then-mid-list-field vs. an unindicated duplicate). This
project's own decompiled trace didn't reach the raw deserialization step (see above), so rather
than guess at a structure that doesn't hold up across all 3 real samples, this project uses the
same real, already-proven fallback technique its own `BsrReader`/`BmtReader` use for their own
unconfirmed inter-field gaps (see BSR_FORMAT.md's material/mesh-path scan, BMT_FORMAT.md's
next-layer scan): **scan forward from right after the name for every real, plausible
length-prefixed string ending in `.bsr`** (case-insensitive), collecting each one as a real
sub-object reference. Confirmed byte-exact correct against all 3 real samples above — recovers
exactly 2, 9, and 7 real entries respectively, including the real duplicate in the Christmas tree
sample, with no false positives.

**What this scan does not tell us**: any real per-sub-object transform, index, or group
membership the unconfirmed fields might carry.

**Confirmed live, 2026-08-24**: no extra transform is needed anyway, the same real convention
already established for `.bsr` sub-mesh pieces (see BSR_FORMAT.md's "Sub-mesh pieces need no
separate transform"). Rendered `x_mas_tree_b.cpd` end-to-end through `ObjectLoader` (all 9 real
sub-objects placed at the compound's own origin, no transform applied) and got a genuinely correct
decorated Christmas tree — the trunk, candles, and ornament balls/stars all land in their real,
sensible real-world positions purely from each real `.bms` piece's own baked absolute vertex data,
exactly like `.bsr` sub-mesh pieces already do. (Also tried `Compound\Char\China\1.cpd`, a real
character + armor set — inconclusive on its own, since 6 of its 7 real `.bsr` references turned
out to be genuinely absent from this client install, a separate real data gap unrelated to this
finding; only the bare body loaded.)

## Implementation

`client/scripts/cpd/cpd_reader.gd` (`CpdReader`) and `server/internal/cpd/cpd.go` both parse the
real header + name, then scan for real `.bsr` references as described above. Both have test
coverage against synthetic fixtures matching all 3 real sample shapes found; the GDScript reader is
additionally live-verified against all 3 real files directly (exact match: 2/9/7 real entries, in
real file order, duplicate preserved).

`client/scripts/assets/object_loader.gd`'s `ObjectLoader.load_object()` dispatches to
`_load_compound_object()` for any path ending in `.cpd` (case-insensitive), recursing back into
`load_object()` once per real sub-`.bsr` and grouping the results under one root `Node3D` named
after the real compound name — no per-piece transform applied (see "What this scan does not tell
us" above).
