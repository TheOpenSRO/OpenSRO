# Items: what is worn, who may wear it, and the model it is worn as

How the client turns an item id the server sends into a piece of armour on the character, and
what the item table says about who is allowed to wear it. Recovered 2026-09-10; the reader is
`client/scripts/npc/item_table_reader.gd`, the dressing is
`client/scripts/assets/skinned_bsr_assembler.gd`, the server's rules are
`server/internal/equipment/rules.go`, and `client/tools/check_item_requirements.gd` measures
every claim below against a real archive.

No game data is committed here — only the structure.

## The item table

`Media.pk2\server_dep\silkroad\textdata\itemdata.txt` is an index naming the parts
(`itemdata_5000.txt` … `itemdata_25000.txt`), each UTF-16LE, tab separated, ~160 columns, no
header row. The layout is the game's own `_RefObjCommon` + `_RefObjItem`, and it is the same in
every part. The columns that matter here, checked against real rows:

| # | Column | The Cotton Suit (id 4842) reads |
|---|---|---|
| 1 | id | `4842` |
| 2 | code name | `ITEM_CH_M_CLOTHES_01_BA_A_RARE` |
| 3 | display name | `Cotton Suit` |
| 9–12 | TypeID1…4 | `3 / 1 / 1 / 3` |
| 14 | Country | `0` |
| 32, 33 | ReqLevelType1, ReqLevel1 (and three more pairs at 34–39) | `1, 1` |
| **52** | **the model it is worn as** | `item\china\man_item\clothes_01_ba.bsr` |
| 53 | the model it lies on the ground as | `item\etc\drop_ch_equip_rare.bsr` |
| 54 | the inventory icon | `item\china\man_item\clothes_01_ba.ddj` |
| 58 | ReqGender | `1` |
| 59, 60 | ReqStr, ReqInt | |

Column 52 is the whole reason a character can be dressed from an id. Across a real table,
**7,264 of 11,772 rows name a worn model**, and **every one of them exists** under `res\` in
Data.pk2 (`res\item\china\man_item\clothes_01_ba.bsr`; the tables omit the `res\` prefix, the
same accommodation `object.ifo` needs). A row with no worn model writes `xxx` there — the Cotton
Hood, a consumable, a quest item.

### The code name is a summary of the row

`ITEM_CH_M_CLOTHES_01_BA_A_RARE` is race, gender, family, degree, piece, variant, rarity — and
each part agrees with a column, measured over every equipment row:

| Code name | Column | Agreement |
|---|---|---|
| `CH` / `EU` | Country 0 / 1 | 2,768 + 2,968 rows, no exceptions; `MALL` items are country 3, either race |
| `M` / `W` | ReqGender 1 / 0 | 2,527 + 2,488 rows; weapons, shields and unisex items are 2 |
| `HA` `SA` `BA` `LA` `AA` `FA` | TypeID4 1 2 3 4 5 6 | 136–140 rows each, no exceptions |

So **TypeID4 is the piece**: 1 helm, 2 shoulder guard, 3 mail, 4 pants, 5 gauntlet, 6 boots. Its
numbering is its own, not the equipment slot order (below). `AA` — the forearm piece this
project could not name for a long time — is the **gauntlet**, and the equipment window's slot
artwork calls it exactly that (`equip_slot_gauntlet.ddj`).

**TypeID3 is the family**: China's garment / protector / armour are 1 / 2 / 3, Europe's robe /
light / heavy are 9 / 10 / 11, weapons 6, shields 4, accessories 7, avatar dress 13. TypeID1 is
3 for every item and TypeID2 is 1 for everything worn or held.

## Who may wear it

The table states three requirements outright, and the client's own mastery table settles what
the fourth means.

- **Race** — `Country`: 0 China, 1 Europe, 3 either.
- **Gender** — `ReqGender`: 1 a man's, 0 a woman's, 2 either.
- **Level** — four `(ReqLevelType, ReqLevel)` pairs. Across a real table only seven type values
  occur: **1**, and **513 through 518**. `skillmasterydata.txt` is the table that names them:
  its row 1 is `캐릭터` — *character* — and rows 513–518 are Warrior, Wizard, Rogue, Warlock,
  Bard and Cleric, the six European masteries. **`ReqLevelType` is a mastery id, and 1 is the
  character itself.** A China item asks for a character level (4,406 rows carry type 1 in their
  first pair); a European item asks for a mastery level (1,668 first pairs are 513 or 514, and
  the later pairs list the other masteries). That is the "sometimes skill level" of the
  original: an item can be gated by how far a *mastery* has been trained rather than by the
  character's level.
- **Stats** — `ReqStr`, `ReqInt`, the two the original refuses with
  `UIIT_MSG_STRGERR_HIGHER_STRENGTH_REQUIRED` / `_HIGHER_INTELLECT_REQUIRED`.

What this project enforces on the server (`equipment.Refusal`): the slot from TypeID3/4, the
race, the gender, and the level where the requirement is by character level. Mastery-level and
stat requirements are read and kept but not enforced — nothing tracks a mastery level or a stat
yet, and refusing on a number the server does not have would be inventing one. An item the
reference data does not know at all is allowed through: reference data is brought by the
operator, and "unknown" is not "forbidden".

Characters have a level now (`character.Level`, `StartingLevel` 1) so that the table's most
common requirement can be checked at all. Nothing raises it yet.

## The model it is worn as

An item's `.bsr` is **type 5** in its header (see BSR_FORMAT.md) and names its material, its mesh
and, sometimes, a skeleton of its own plus the body bone that skeleton hangs from. That last
field decides how the piece attaches, and there are exactly two cases:

| Item | Skeleton | Hangs from | Its mesh is weighted to |
|---|---|---|---|
| `clothes_01_ba.bsr` (suit) | none | — | nine body bones, `Bip01 Neck1` first |
| `clothes_01_aa.bsr` (wristlet) | none | — | four body bones, `Bip01 R Forearm` first |
| `clothes_01_sa.bsr` (talisman) | `prim\skel\item\china\clothes_sa.bsk` | `Bip01 Neck1` | its own `Bone05` |
| `blade_01.bsr` (a blade) | `prim\skel\item\china\weapon\blade_01.bsk` | `Bip01 R HandMid` | its own `Bone01` |

- **No skeleton**: the mesh's bone palette names the body's own bones, so it is skinned to the
  body's skeleton exactly as a body piece is, and deforms with it.
- **A skeleton of its own**: the item's skeleton is built, its mesh skinned to *that*, and the
  whole thing put under the named body bone at identity — the item's root sits where the bone is.

The second case is what the shoulder piece needed all along. This project spent a round on
"the `sa` piece renders down by the pelvis": its vertices are in its *own* skeleton's space, and
reading them as body-space geometry put them there. The `.bsr` says so in two strings.

The weapon bone is likewise authored per item — `Bip01 R HandMid` for `blade_01`, not the
`Bip01 R Hand` this project had chosen — and read from the file.

## The body itself

The player's body is a row of `characterdata` like any NPC's: ids 1907–1932 are the 26 playable
China classes (`CHAR_CH_MAN_FIGHTER` → `char\china\chinaman_fighter.bsr`, 13 to a gender), and
the `.bsr` — type **0** in its header — lists the skeleton, nine skinned body pieces, the
material and 217 animations. `GENDER_BODY_CODE` in World3D picks the fighter for each gender,
a fixed choice until the server stores a class.

## Equipment slots

The client's equipment window loads its slot artwork in this order, and its avatar's
equip-visual struct keeps the first eight twelve bytes apart in the same order (EQUIP_SLOTS.md):

```
0 helm  1 mail  2 shoulderguard  3 gauntlet  4 pants  5 boots  6 weapon  7 shield
8 specialdress  9 earring  10 necklace  11 l_ring  12 r_ring  13 cloth  14 pandernt  15 plag  16 extraneous01
```

This project's `equipment.Slot` and `EquipmentNet.SLOT_*` now use that numbering for the first
eight plus `SlotExtra` at 8; the starting kit dresses all six armour slots, gauntlet included
(`4914 Cotton Wristlet`).

## What the picture is evidence of

None of the above was concluded from a render, but the render is a check on all of it at once: a
new character, dressed by the server in the six Cotton items, draws with the Cotton Hat on its
head, the talisman at its collar, the wristlet on its forearm and the suit on its back — the
white cotton set the table names, where the earlier code had chosen an ornate gold set by
`item_id % 8`.
