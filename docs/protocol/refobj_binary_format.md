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

## Field 14 of the common prefix is DecayTime, kept in seconds (2026-09-19, round 227)

`RefObjCommon_ExtractData` reads field 14 as a signed dword, bumps the column counter
(`0x6a332a`), converts it through `fild` with the unsigned fix (`+ 2^32` at `0xb45ba4`
when negative), **divides by the double at `0xb45c68` -- 1000.0** -- and stores the float
at record `+0x84` (`0x6a334b: fstp DWORD PTR [esi+0x84]`). Counting the fields before it
(nine inline bumps, four `RefData_ReadStringField` calls, one schema skip) puts it at
field 14, which the rule above makes **text column 13** -- `DecayTime`, milliseconds in
the text, seconds in the record. `fields.py` misses the `fstp` store (it matches `mov`
stores only), which is why it reported field 14 at `+0x80`; the packed type word at
`+0x80` belongs to fields 10-13, the four TypeIDs. The same rule's anchor on the far side
holds: field 41 = `+0xd4` = column 40, the regen amount `internal/mana` had already placed.

Its use-site is `CGObj::Update` (`0x484d10`): for an object in life-state 2 it adds the
frame delta (seconds -- the main loop's, see `character_state.md`) to `obj+0x3c` and,
once the float at `ref+0x18 -> +0x84` is exceeded, calls slot 218, whose base is
`SetLifeState(3, 0xff, 0)` -- removal. A dropped item enters the world in state 2 with
the accumulator at zero (`CGObj::EnterWorld` -> slot 226 -> `SetLifeState(2, 0xff, 0)`),
so `DecayTime` is exactly how long a drop lies on the ground. `internal/grounditem` uses
it per item now; `FUN_004181d0` uses the same field the other way, pre-loading it to
remove an object on the spot.

## Fields 44-52 of the common prefix are nine 16-bit words (2026-09-19, round 230)

After field 43 (`+0xd8`, a dword the deserializer zeroes) the record pointer moves to `ebx`
and the next nine fields are read as **words** with a 2-byte stream advance each
(`0x6a3899..`): `+0xdc, +0xde, +0xe0, +0xe2, +0xe4, +0xe6, +0xe8, +0xea, +0xec` -- fields
44..52, text columns 43..51. `fields.py` reports them unresolved because it keys on the
`esi` base. By the schema this project's anchors have matched at every checked column
(13 DecayTime, 15 Rarity, 26 Price, 31 SellPrice, 32-39 the requirement pairs, 52-56 the
asset strings), those columns are `OffsetX, OffsetY, OffsetZ, Speed1, Speed2, Scale,
BCHeight, BCRadius, EventID` -- so a character's **walk speed is the word at `+0xe2`
(column 46) and its run speed the word at `+0xe4` (column 47)**, and a species' bounding
radius is at `+0xea` (column 50). In the player's own table every `CHAR_CH_MAN_*` /
`CHAR_CH_WOMAN_*` row reads `16 / 50` (Mangyang `8 / 22`, Tigerwoman `20 / 90`).

What is NOT read yet is the unit and the chain that applies it: the server's speed getter
`GObjPC::FUN_0048b840(kind)` dispatches to the character's current mover
(`CGObjMoverByDest` / `CGObjMoverByCmd`, at `this+0x14c/+0x150`, selected by the byte at
`+0x154`), whose slot 7 returns a published float, and the movers' slot 3 takes a
displacement the caller has already scaled by time. Until `PublishStats` is read handing
`+0xe2/+0xe4` to their params and a movement step is read multiplying by seconds, "50 world
units per second" is a plausible reading -- the client's feel-tuned `MOVE_SPEED` (47.8) sits
within 5% of it -- not a recovered one, and `MOVE_SPEED` stays as it is.

## The item-half stat block is countable once its synthesized slots are known (2026-09-19)

The dead end above is real for the table as a whole, but one stretch of the item
half converts cleanly, because it is an **array of `(L, U, Inc)` triples**, 12 bytes
each from `+0x1b0`, and the loader fills them in text-column order -- except that
where the text has no increment column it **writes `Inc = 0` without consuming a
field**. Read off `RefObjItem::ExtractData` (`0x006a3d50`): a two-dword loop into
`L, U`, then either a third consumed dword or a bare `= 0`.

| triple k (= variance group) | offsets L / U / Inc | text columns | Inc |
|---|---|---|---|
| 0 durability | `+0x1b0 / +0x1b4 / +0x1b8` | 63, 64 | **synthesized 0** |
| 1 physical defence | `+0x1bc / +0x1c0 / +0x1c4` | 65, 66, 67 | read |
| 2 (`ER`) | `+0x1c8 / +0x1cc / +0x1d0` | 68, 69, 70 | read |
| 3 parry rate (`PAR`) | `+0x1d4 / +0x1d8 / +0x1dc` | 71, 72, 73 | read |
| 4 block rate (`BR`) | `+0x1e0 / +0x1e4 / +0x1e8` | 74, 75 | **synthesized 0** |
| 5 magic defence | `+0x1ec / +0x1f0 / +0x1f4` | 76, 77, 78 | read |
| 6 (`MR`) | `+0x1f8 / +0x1fc / +0x200` | 79, 80, 81 | read |
| 7 (`PDStr`) | `+0x204 / +0x208 / +0x20c` | 82, 83 | **synthesized 0** |
| 8 (`MDInt`) | `+0x210 / +0x214 / +0x218` | 84, 85 | **synthesized 0** |
| bytes | `+0x21c .. +0x223` | 86 .. 93 | Quivered, Ammo1-5, SpeedClass, **TwoHanded** |

Anchored at both ends, independently of the count: `+0x1b0/+0x1b4` are what
`Char_BuildAggregateStats` interpolates into max durability (`+0x194`, the value
`ComputeRepair` divides by), and columns 63/64 are the durability pair
`export-refdata` already maps; `+0x223 == 1` is the test
`GObjPC_StorageManipulator::CGObjPC__AttachEquipItem` makes when equipping -- the
two-hander rule, column 93. Between the anchors the four synthesized slots fall
exactly on the four stats whose text has no increment column (durability, block
rate, `PDStr`, `MDInt`). Round 170's "defence at columns 65-77" is triples 1-5.

The triple index is also the **variance group**: `Item_VarianceFactor` takes
`(Variance >> 5*k) & 0x1f`, and `Char_BuildAggregateStats` walks the triples with
`ESI = 0, 1, 2, ...` (durability's `xor esi,esi` is read on the asm; the rest is
the same block repeated). So an item's twelve 5-bit variance groups are its
twelve stat triples in this order.

The seven text columns the item deserializer never consumes are therefore not in
63..93; they are elsewhere in the row, still unlocated.

