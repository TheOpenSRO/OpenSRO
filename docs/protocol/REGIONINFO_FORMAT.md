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

Real totals in the one real file checked: **15 sections, 1,619 region rows** — 1,572 `ALL`
and 47 `RECT`.

## Real `ALL` vs `RECT`, confirmed by counting

`RECT` is used exactly where a real region is **split between two zones**. Counting how
often each real region appears across all sections: **56 regions appear in exactly two
sections and every other region appears in exactly one**, which lines up with the 47 real
`RECT` rows. So `ALL` claims a whole region and `RECT` claims a sub-area of one, with the
region's two claimants partitioning it between them.

The four `RECT` numbers are region-local coordinates in the usual real 0–1920 space, but
**their exact semantics are not established** and no reader should guess: many real rows
are degenerate as a rectangle (`167 99 RECT 0 220 1920 220` has equal second and fourth
values; `169 97 RECT 1720 0 1720 1920` has equal first and third), which reads more like a
dividing line than an area. Establishing this needs the client's own consumer decompiled,
the same way the `.nvm` edge flags were — see `NVM_FORMAT.md`. Until then a reader can
honestly resolve every `ALL` region (1,572 of 1,619, over 97%) and report a `RECT` region
as ambiguous rather than picking a side.

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

Documented only — no reader yet. The structure above is parsed and counted directly from
the real file; what is deliberately left unresolved is `RECT`'s coordinate meaning and the
EUC-KR name decoding.
