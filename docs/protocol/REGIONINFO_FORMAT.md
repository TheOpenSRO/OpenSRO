# Region-to-zone name table (`regioninfo.txt`)

The real table mapping every real map region to the real named zone it belongs to — the
data behind a client's "Zone:" label, which this project has so far left empty because
nothing was known to fill it with.

## Real location — an unexpected one

`Data.pk2`'s **`Shader\regioninfo.txt`** (27,364 bytes). That is genuinely where it lives:
a plain-text region table inside the shader folder, alongside `terrainps14.psh` and the
rest. Nothing else in `Shader\` is remotely like it, and this project's earlier archive
survey listed it among the map files with no reader precisely because its name suggests
map data while its location does not.

## Real encoding

**EUC-KR**, not UTF-8 — the zone names are real Korean. `iconv -f EUC-KR -t UTF-8`
decodes the whole file cleanly. This matters for any reader: Godot has no built-in EUC-KR
decoder, so the *names* need a codepage mapping even though the *structure* is plain ASCII
digits and tabs. The region→zone mapping is therefore usable immediately; rendering the
names is a separate problem.

## Real structure

Tab-separated, with trailing empty columns padding most lines. Sections, then rows:

```
#TOWN <zone name>            section header, name in EUC-KR
<y>   <x>   ALL              this whole region is in the zone
<y>   <x>   RECT  a b c d    only part of this region is in the zone
...
#FIELD <zone name>
...
```

**Column order is `<y>` then `<x>`**, the opposite of the `<x>\<y>.m` region-file naming
this project uses everywhere else. Confirmed two ways: real Jangan is region `98\168`
(x=98, y=168) and appears here as the row `168  98  ALL`; and the second column's real
range across the file is 96–99 while the first column's is 165–169, matching this
project's own independently-derived Jangan cluster (README: "x=97-99, y=166-169").

Real totals in the one real file checked: **15 sections and 1,619 region rows** — 1,572
`ALL` and 47 `RECT` — covering **1,563 distinct real regions**. Rows and regions are not
the same count, because 56 real regions are listed twice.

## Real `ALL` vs `RECT`, and the real duplicates

Of the **56 real regions listed twice**, the split is not uniform:

| shape | regions | meaning |
|---|---:|---|
| `ALL` + `RECT` | 47 | one zone owns the region, the other carves a box out of it |
| `ALL` + `ALL` | 9 | two sections both claim the whole region |

The 47 are the interesting case and are covered in the next section. The 9 are a genuine
quirk of the real data rather than a second mechanism: two sections claim the same whole
region outright, and in one pair (`y=154 x=102` and `y=154 x=103`) it is *the same zone*
(`돈황필드`) listed twice. The rest pair a town with its own field, e.g. `y=153 x=102` is
claimed `ALL` by both `돈황` and `돈황필드`.

**The later row wins.** That is not a tie-break this project chose — the client's own loader
looks up the region's existing record and, when it finds one, overwrites its kind and zone
index rather than keeping what was there. So a reader that takes the first `ALL` names
those 9 regions differently from the real client.

## Real `RECT` semantics, recovered from the client (2026-09-05)

The four numbers are `[x_min, z_min, x_max, z_max]` in the usual real region-local 0–1920
space, and the test is **inclusive on all four sides**. That is not inferred from the
numbers; it is the client's own test, which decompiles to exactly:

```c
rect[0] <= pos.x && pos.x <= rect[2] && rect[1] <= pos.z && pos.z <= rect[3]
```

The real parser is `CRegionManager`'s (`JMX_Library\navmesh\RegionManagerBody.cpp`), and it
also settles the column order independently of the counting argument above: it reads the
first number, then the second, and packs them as `(second << 8) | first` — the same real
`(x << 8) | y` region id `.nvm` filenames use, so the second column really is `x`.

Real resolution order, likewise straight from the client:

```
for each RECT claim on this region, in file order:
    if the point is inside -> that zone
otherwise                  -> the region's ALL zone   (-1 if it has none)
```

`#TOWN` and `#FIELD` are not just labels either: the real parser tags a claim with kind
**2 for TOWN and 1 for FIELD**, and a separate real query uses that tag alone to answer
"is this position in a town?".

### What the real rows actually look like under that test

Measured over all 47 real `RECT` rows: **37 are proper boxes, 4 are zero-width in x, 6 are
zero-depth in z, and 1 is inverted** (`x_min > x_max`). Under the client's own inclusive
test a zero-thickness box matches only an exact coordinate and an inverted one matches
nothing, so those 11 rows are effectively no-ops and their regions resolve to their `ALL`
default in practice. That is faithfully what the real client does, and a reader should
reproduce it rather than "correct" the data.

Every one of the 47 real regions carrying a `RECT` **also has an `ALL` row from another
zone**, which is what makes the fallback meaningful: the `ALL` zone owns the region and the
`RECT` carves an exception out of it for its neighbour. Real example, region `y=169 x=98`:
`#TOWN 장안` claims it `ALL`, and `#FIELD 장안필드` claims the box `1720 0 1720 1920` — a
zero-width sliver on its eastern edge.

So a reader with a real position resolves **all 1,563 real regions** exactly. A reader with
only a region and no position can still answer for the **1,516** that carry no `RECT`, and
should decline the other 47 rather than pick a side.

## The real zones

All 15 real section names, as they decode:

| kind | real name (EUC-KR) | the usual English name |
|---|---|---|
| TOWN | 장안 | Jangan |
| FIELD | 장안필드 | Jangan field |
| TOWN | 돈황 | Donwhang |
| FIELD | 돈황필드 | Donwhang field |
| TOWN | 호탄 | Hotan |
| FIELD | 호탄필드 | Hotan field |
| FIELD | 카라코람 | Karakoram |
| FIELD | 돈황던젼 | Donwhang dungeon |
| FIELD | 타클라마칸 | Taklamakan |
| FIELD | 로크산 | Roc mountain |
| TOWN | 콘스탄티노플 | Constantinople |
| FIELD | 동유럽 | East Europe |
| FIELD | 소아시아 | Asia Minor |
| TOWN | 사마르칸트 | Samarkand |
| FIELD | 중앙아시아 | Central Asia |

The English column is the ordinary transliteration of the Korean, given for orientation
only — it is **not** read from this file, and this file carries no English at all. A client
that wants English zone labels needs the real localized text resource, not this table.
Note also that the real `소아시아`/`동유럽` names line up exactly with the real
`"Asia minor"`/`"East Eurpoe"` (sic) tile-category strings `TILE2D_FORMAT.md` already
records, which is independent corroboration that this really is the world's own zone
vocabulary.

## Status

Implemented: `client/scripts/regioninfo/regioninfo_reader.gd` parses the structure from raw
bytes (so the EUC-KR names survive intact) and reproduces the client's own resolution order,
including the degenerate rows. `regioninfo_names.gd` maps a name to a display string with
per-key overrides. `World3D` resolves the player's region through it to fill the zone label.

What remains open is only the **EUC-KR name decoding**: Godot has no built-in decoder, so
the shipped display names are this project's own transliterations, supplied as an
overridable default rather than as a claim about real client text. The file itself carries
no English at all.
