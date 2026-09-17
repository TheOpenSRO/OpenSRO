# The server's reference records are binary, and self-describing

This resolves the column-57 conflict opened in v0.1.256, and it corrects an
assumption that runs through every column note this project has written.

## The server does not read the text tables

`RefObjCommon::ExtractData` reads 4-byte fields straight out of a buffer and
strings through `RefData_ReadStringField`, which takes a **2-byte length then
that many bytes**. That is a binary record format. The
`itemdata_*.txt` / `characterdata_*.txt` tab-separated files are the **client's**
media data; the server loads a serialised form of the same tables.

The two agree on field order -- four independent anchors land exactly (ID at
index 1, Country at 14, the four requirement pairs at 32..39, the five asset
strings at 52..56) -- which is why treating "consumed field N" as "text column
N" has worked. **It stops working at the last common field.**

## The stream carries a schema

`FUN_006b1a80`, taking the stream in `edi` (`6a3191 push edi`), is not a field
reader. It is a **schema-driven field skipper**:

	ecx = stream                                  6b1a83
	call stream->vtable[3]                        6b1a90   -> the schema
	walk records at +0xe4/+0xe8, stride 0x54      6b1a9d..
	  match record->index (+0x30) == stream->col + 1       6b1b12/6b1b18
	on match:
	  stream->cursor (+0x1c) += record->width (+0x24)      6b1b4b/6b1b4e
	  stream->col    (+0x28) += 1                          6b1b55

So the binary tables are **self-describing**: each carries a per-column schema
of (index, width) records, and a parser can skip a column it does not want
without knowing its size. Field 5 is consumed after all -- the 58-field count
from v0.1.254 stands, now for a better reason than "it bumps the counter".

## `"xxx"` is the null placeholder, and the parser erases it

	eax = this+0x48 (or +0x4c for a long string)  6a3162..6a3170
	strcmp(eax, "xxx")                            6a3173/6a3179
	if equal: clear the string                    6a3185/6a318c

`"xxx"` (`0xae8110`) is the tables' own "no value". The parser normalises it to
an empty string rather than storing it, which is also why the `"GP:"` scan on
column 55 skips it first.

## The last common field is a link, and the text does not have it

`_RefObjCommon+0x184` is the 58th and last common field. All three `ExtractData`
overrides assert it non-zero and pass it to `CGameServer::FUN_006ba850`:

	FUN_006ba850(kind, key):
	  for each stream in the loaded list:
	    kind 3, 0x11   -> id = stream->field_0x30
	    kind 0xc,d,e   -> save cursor/col; cursor = col = 0;
	                      id = *(int *)(stream->base);      // the row's FIRST field
	                      restore cursor/col
	    if (id == key) return stream
	  return 0

failing with `"Can't find associated item data [RefObjCommon ID: %d, RefItem
ID: %d]"`. It compares the key against each candidate row's **first field**, so
the key is a **per-row foreign key**, not a table selector -- which is exactly
the test v0.1.256 recorded as the one that would settle this. The binary common
record ends by pointing at its type-specific record; the caller then reads the
type-specific fields off the stream that comes back.

**The client's text table is the denormalised join of the two**, and it does not
carry the link:

| table | per-row-unique columns |
|---|---|
| itemdata | none |
| characterdata | 1 (ID) and 2 (code name) only |

So binary field 57 and text column 57 are different fields that happen to share
an index, and `export-refdata`'s `fMaxStack = 57` -- 18 distinct values shaped
1 / 250 / 500 / 50 -- is reading the text correctly. The conflict was never two
readings of one field; it was one index in two formats.

## The extracted itemdata on the RE box is mixed and partial

Found while testing the above, and it affects **every itemdata count this
project has published**.

`/var/tmp/tables/itemdata_*.txt` is a mixture of two different extractions.
Globbing it yields 23,317 enabled rows but only **16,819 distinct IDs**, because
the coarse files are supersets of the fine ones:

	itemdata_15000.txt  contains all of 11000, 12000, 13000, 14000
	itemdata_5000.txt   contains all of 1000, 2000
	itemdata_30000.txt  contains all of 26000

The game ships its own index -- `/var/tmp/idparts/itemdata.txt` naming
`ItemData_1000.txt` .. `ItemData_63000.txt`, one per 1000-ID range. Only **20 of
those 63** are present on the box, and restricting to them still leaves 6,224
duplicate IDs, because names like `itemdata_55500.txt` are not index entries at
all.

**characterdata is clean**: 13,291 enabled rows, 13,291 distinct IDs.

What this does and does not invalidate:

- **Counts are wrong.** Any "N of 23,327 itemdata rows" in these docs is
  inflated by roughly 39% and drawn from a partial corpus. Read them as
  proportions, not censuses.
- **Shapes and existence claims survive.** "Zero TypeID values out of bounds"
  is a superset check. "No column equals the ID", "column 55 takes five
  values", "column 57 has 18 distinct values" are all unaffected by duplicates.

**Rule for future measurements**: deduplicate itemdata by ID before counting,
report distinct IDs rather than rows, and say the corpus is partial.

## The text column counts were one too many (2026-09-17)

This project recorded itemdata as **161** columns and characterdata as **105**.
Both counted one field too many, and a natural experiment in the data proves it:

| file | fields per line | lines ending in a tab |
|---|---:|---:|
| `itemdata_1000` | **160** | 0 |
| `itemdata_5000` | 161 | all 2,876 |
| `itemdata_10000` | 161 | all 2,267 |
| `itemdata_20000` | 161 | all 74 |
| `characterdata_5000` | 105 | all 1,698 |
| `characterdata_10000` | 105 | all 2,281 |

Every file with a trailing tab reports one more field than `itemdata_1000`,
which has no trailing tab. Splitting on tab turns that terminator into an empty
final field. So the real counts are **itemdata 160** and **characterdata 104**.

**No recorded column index changes** — real data still occupies 0..159 and
0..103, and every index this project has cited stays where it was. Only the
totals were wrong, and only by the one empty field.

## Counting binary fields does NOT give a text column past the common prefix

The section above establishes that binary field order and text column order
agree **through the last common field**. `client/tools/re/fields.py` now counts
binary fields reliably, and running it on all three deserializers shows exactly
where the agreement stops:

| deserializer | binary fields | real text columns |
|---|---:|---:|
| `RefObjCommon_ExtractData` | 58 | — (a prefix, not a table) |
| `RefObjItem::ExtractData` | **153** | **160** |
| `ReferenceData::RefObjChar_ExtractData` | **80** | **104** |

Both type-specific tables consume **fewer binary fields than their text has
columns** — item by 7, char by 24. So a type-specific offset cannot be turned
into a text column by counting, whatever the counting gets right.

**This is a dead end, identified rather than walked into.** The route for a
type-specific column is the **per-column schema** the stream carries — the
`(index, width)` records at `+0xe4`/`+0xe8`, stride `0x54`, that `FUN_006b1a80`
walks to skip a column. That is where a type-specific index lives; counting
reads is not.

The common prefix is unaffected: there the two orders agree by four independent
anchors, so **a common-record offset still converts**, as `field N → text
column N−1`.
