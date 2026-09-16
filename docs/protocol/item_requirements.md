# Item requirements

What an item demands before it can be worn, recovered from the server's own
checker rather than from the shape of the columns.

## The structure

`_RefObjCommon` carries **four** requirement slots: an `int32` type at `+0xb4`
and a `uint8` value at `+0xb8`, stride 8. `RefObjCommon_ExtractData` fills them
from **columns 32..39** in a four-iteration loop (`0x6a36ab..0x6a3700`, trip
count from `mov eax,0x4` at `0x6a3690`).

The count of four is the *engine's* number, not the columns': the checker
asserts on a slot index above 3. Reading it off "where the columns stop" would
have been a guess that happened to agree.

## The checker

`CGItemEquip::CheckEquipRequirements` — server `0x004919e0`, called by
`CanBeEquipedAt` (`0x00497070`) before any of its other tests, and returning an
error code through its third argument.

```c
*err = 2;
for (n = 0; n < 4; n++) {
    assert(n < 4);                       // where MaxRequirements comes from
    id = common->ReqType[n];
    if (id == -1) { unused++; continue; }
    value = common->ReqValue[n];
    if (id == 1)                    { need |= 1; if (value <= GetLevel())  met |= 1; }
    else if (id >= 0x201 && id <= 0x206) { need |= 2; if (value <= Mastery()) met |= 2; }
    else if (id == 0x301)           { need |= 4; if (Tier() < value) { *err = 0x18f7; return 0; } met |= 4; }
    else if (id == 2 || id == 3 || id == 4 || id == 0x10) { /* accepted, no category */ }
    else { log("This Mastery Type is not exist! (DEC:%d)(Hex:%x), Item's RefObjID(%d)"); return 0; }
}
if (unused == 4) return 1;               // no requirements at all
for (cat = 0; cat < 3; cat++)
    if (need[cat] && !met[cat]) { *err = 0x186c; return 0; }
return 1;
```

## The vocabulary

| type | table value | meaning | refusal |
|---|---|---|---|
| `1` | 1 | the character's own level, against vtable `0x124` (`GetLevel`) | `0x186c` |
| `0x201..0x206` | 513..518 | a mastery's level | `0x186c` |
| `0x301` | 769 | a job/hwan tier | **`0x18f7`**, its own |
| `2`, `3`, `4`, `0x10` | 2, 3, 4, 16 | accepted, no effect | — |
| `-1` | -1 | slot unused | — |
| anything else | — | not this check's vocabulary | refuses, `err` stays 2 |

513..518 are **not** "the European masteries", as an earlier note in
`equipment/rules.go` had it. Real Chinese rows use 513/515/518 and real
European ones 514/516/517/518, so the range spans both races.

## Two rules that are easy to invert

Both change real answers, so both have a test.

1. **Within a category the slots are OR, not AND.** `need` and `met` are one
   bit per category, or-ed. Seven real rows carry two character-level
   requirements — all `ITEM_MALL_STATS_POINT_RECALL*`, e.g. `(1,1)` and
   `(1,40)`. Under the engine's rule that item needs level **1**; requiring
   every slot would lock it to 40.
2. **Across categories it is AND.** Every category that appears must be met.

## What the real data uses

Measured over a real client's 23,327 itemdata rows:

| pattern | rows | what |
|---|---|---|
| `(1, -1, -1, -1)` | 11,636 | an ordinary level-gated weapon or armour |
| `(-1, -1, -1, -1)` | 6,504 | no requirement at all |
| `(513, -1, -1, -1)` | 1,776 | mastery only |
| `(513, 515, 518, -1)` | 1,686 | Chinese, three masteries |
| `(514, 516, 517, 518)` | 1,686 | European, four masteries |
| `(10, -1, -1, -1)` | 24 | the guild soldier scrolls |
| `(1, 769, -1, -1)` | 8 | `ITEM_ETC_SECOND_HWAN_SCROLL_01..04` |
| `(1, 1, -1, -1)` | 7 | `ITEM_MALL_STATS_POINT_RECALL*` |

The 24 rows carrying type `10` would trip the engine's own
"This Mastery Type is not exist!" assert — but they are all
`ITEM_ETC_GUILD_*_SOLDIER*_SCROLL`, TypeID `3/3/12/1`: ETC items that are
*used*, never equipped. The equip checker never sees them, so the assert never
fires and this is not a data bug. Type 10 means something to the use path; it
simply is not part of this check's vocabulary.

The eight `0x301` rows are the second-job scrolls, pairing a tier of 1..4 with
character levels 95/100/105/110.

## What srrevamp does

`equipment.CheckRequirements` implements the rule above.
`equipment.RequirementsOf` reads all four slots off `refdata.Item`, which
carries them as of 2026-09-16 — only the first was carried before, which is
right for 11,636 rows and silently drops every requirement in the rest.

The mastery and tier categories take a lookup function, and **a nil lookup
means the category is carried but not enforced**. srrevamp tracks neither value
yet; refusing every mastery-gated item because nothing records a mastery level
would be further from the engine's answer, not closer. When mastery tracking
lands, passing a real lookup is the whole change.

Str/Int requirements are a separate mechanism: `CanBeEquipedAt` reads them from
`_RefObjCommon+0x1a0` and `+0x1a4` and compares against `GetParam(1)` and
`GetParam(2)`, refusing with `0x1830` and `0x1831`. Columns 59 and 60 hold them
and are **0 on all 23,327 rows**, so the mechanism is real and the data never
uses it — see the note in `equipment/rules.go`.
