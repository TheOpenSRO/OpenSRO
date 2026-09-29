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
| 13 | **DecayTime**, ms on the ground before the world removes the drop -- read 2026-09-19 (round 227): the server stores field 14 at `+0x84` as `int / 1000.0` (`RefObjCommon_ExtractData` `0x6a334b`), `CGObj::Update` removes a state-2 object once its accumulated seconds pass it; 10000 for 6,494 of the 15,338 rows, 180000 for 8,402 | `10000` |
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

**Column 52 can name two models (round 626, READ).** 88 rows — every Degree-11 `SET_A`/`SET_B`
helm, shoulder or chest — write two, comma-separated:
`item\common\man_item\heavy_11_set_b_ba.bsr,item\common\man_item\heavy_11_set_b_ba_fullset.bsr`.
The `_fullset.bsr` lists the same mesh plus one more (`heavy_11_set_b_fly.bms`). The client:

- **splits the column on `","`** into a list kept on the item's record (+0x1b0), each token taking
  the `res\` prefix, `xxx` becoming empty (row parser `GlobalDataManager::FUN_00972910`, the
  delimiter `L","` at 0xd8c364, the prefix rule `FUN_0097f860`), and makes **element [0]** the
  record's drawn model (+0x124); the worn-item visual reads only +0x124
  (`CharacterVisualChange::CObjItem::vslot_002`, 0x4ea960);
- **switches to element [1] only while the whole set is worn**: `CObjCharacter::InstallEquipVisual`
  (0xa61010) asks `ItemSet_IsComplete` (0xa60220: the worn count of the set id at record+0x1d4
  against refsetitemgroup's slot count), and `FUN_00a60c60` then rewrites +0x124 to element [1] for
  every worn item in visual slots 0..5 with more than one model, detaches the old mesh, and the
  equip handler (`FUN_008a9260`) plays `ITEM_SETITEM_ACTIVE` / `snd_setitem_active`; taking any
  set piece off resets them all to element [0].

Taken as one path, the whole string named no file, so a set chest drew nothing.
`ItemTableReader.Item.model_paths` holds the list and `model_path` element [0]; the full-set switch
is not built (OPEN, docs/TODO.md).

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
light / heavy are 9 / 10 / 11, weapons 6, shields 4, **job suits 7**, accessories **5 (China) and
12 (Europe)**, avatar dress 13. TypeID1 is 3 for every item and TypeID2 is 1 for everything worn
or held — except ammunition, which is TypeID2 3 and still equips (see the slot table below).

*(This line said "accessories 7" until 2026-09-16. Seven is the job suit; every TypeID3 == 7 row
in a real itemdata is a trade outfit. The accessories are two families, one per race. Corrected
in `equipment/rules.go` at the time and here afterwards — a stale duplicate of a corrected claim
is how a fixed error comes back.)*

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

## What a held weapon does to the animations

The body's `.bsr` carries its animations in **groups keyed by weapon kind** — `default`, `sword`,
`spear`, `bow`, `cart` and the avatar groups on a China body — each entry tagged with an action
type (0 stand, 1 walk, 2 attack, 3 hit, 4 die, 6 battle stance, 7 run …; BSR_FORMAT.md has the
table). A held weapon selects its group and the action selects the entry, falling back to
`default` for anything the group does not list (`FUN_00a5b550` looks the action up in the
weapon's group and then in `default`): a sword has attacks and a run of its own
(`chinaman_fighter_runforward_sword`) but no stand or walk, a spear has all three.

Which group a weapon selects is a **switch on its `TypeID4`** in the client — `FUN_00a5a7d0` in
`CObjCharacter.cpp`, reached from the equip-visual refresh `FUN_00a5bd10` with the item in visual
slot 6 (the weapon), whose 16-bit packed type id it shifts down by 11 — and the real table's
weapon rows (`TypeID3` 6) agree with every case, 215–251 rows each:

| TypeID4 | The rows are | Group |
|---|---|---|
| 2, 3 | `CH_SWORD`, `CH_BLADE` | `sword` |
| 4, 5 | `CH_SPEAR`, `CH_TBLADE` (glaive) | `spear` |
| 6, 12 | `CH_BOW`, `EU_CROSSBOW` | `bow` |
| 7 | `EU_SWORD` | `onehand_sword` |
| 8 | `EU_TSWORD` | `twohand_sword` |
| 9 | `EU_AXE` | `dual_axe` |
| 10, 15 | `EU_DARKSTAFF`, `EU_STAFF` (the cleric rod) | `onehand_staff` — table entries 12 and 5, the same name twice |
| 11 | `EU_TSTAFF` | `twohand_staff` |
| 13 | `EU_DAGGER` | `dagger` |
| 14 | `EU_HARP` | `harf` |
| 16 | `FORT_FORTRESS` | `sword` for a China character, `onehand_sword` for a European one |
| 1 | `ETC_FIREWORK` | none — the switch returns null and the caller asserts `pStrAniNew` |

The race byte is the same `+0x9c` of the character's data that picks the China or the Europe
stall model in `FUN_009dd040`. Two rules sit beside the switch: while the character is pulling a
transport the group is `cart` whatever the weapon (`FUN_00a5bd10`, index 4), and the avatar groups
are not weapon-driven at all — `charactervisualchange.txt`'s `AnimationName` column names one
(`avatar_nasrun1`–`3` on the Nasrun and Amalrun mall-hat rows, about forty of them) and
`CharacterVisualChangeManager` (`FUN_004ea570`) resolves it through the same name table.
`WEAPON_ANIMATION_GROUP` in World3D is this switch.

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

This project's `equipment.Slot` and `EquipmentNet.SLOT_*` use that numbering through slot 12.

**The server agrees, and that is what settled the last four slots (2026-09-16).**
`GObjPC::FUN_00496c20` (`0x00496c20`) is the engine's own item-to-slot resolver: it reads the
item's packed type word and returns a slot. Its armour arm maps `TypeID4 -> slot` as
`1→0 2→2 3→1 4→4 5→3 6→5` — a permutation, and exactly the one between the table's piece order
and the artwork order above, so the two orderings were derived independently and agree.

| TypeID2 | TypeID3 | TypeID4 | slot | what lives there |
|---|---|---|---|---|
| 1 | 1, 2, 3, 9, 10, 11 | 1…6 | 0…5 | the six armour pieces, six families |
| 1 | 4 | 1, 2 | 7 | `ITEM_CH_SHIELD`, `ITEM_EU_SHIELD` |
| 1 | 6 | 1…16 | 6 | every weapon |
| 1 | 7 | 1, 2, 3, 5, 6, 7 | 8 | `ITEM_*_TRADE_TRADER/THIEF/HUNTER`, `FRPVP_VOUCHER` |
| 1 | 5 (China), 12 (Europe) | 1, 2, 3 | 9, 10, 11 | earring, necklace, ring |
| **3** | **4** | 1, 2 | **7** | **`ITEM_EVENT_QUIVER`, `ITEM_ETC_AMMO_BOLT`** |
| 1 | 13, 14 | — | *(none)* | avatars — the resolver asserts; separate container |

Checked cell by cell against a real client's complete itemdata: 11,772 `TypeID1 == 3` rows, no
disagreement anywhere.

Three consequences, all of which srrevamp had wrong:

- **Slot 8 is the job suit**, not an unexplained "extra". The client calls its artwork
  `equip_slot_specialdress.ddj`; every item the resolver sends there is a trade outfit.
- **There are two ring slots.** The equip check (`CGItemEquip::vslot_317`, `0x00497070`) demands
  an exact slot match everywhere except a ring, where it takes 11 or 12 — matching the client's
  `equip_slot_l_ring.ddj` / `equip_slot_r_ring.ddj`.
- **Ammunition is equipped, in the shield slot.** A bow user gives up the shield to carry arrows.
  srrevamp refused quivers entirely, and the note claiming that was correct reasoned about
  srrevamp's own code without asking the engine.

The check also bounds the set: `if ((slot == 0xff) || (0xc < slot)) return 0x1806` — **13 slots,
0…12**, with `0xff` the same not-set sentinel the skill table uses for an unused weapon
requirement. Slots 13–16 in the artwork list have no resolver arm and no items.

**The engine's own name for that check is `CanBeEquipedAt`** (its spelling, one `p`), recovered
2026-09-16. `CGPCInventoryOP::CheckEquipsetIntegrity` (`0x004bb020`) calls it through vtable
offset `0x4f4` — slot 317, which this project had been calling `vslot_317` — and names it when
the answer disagrees with what is already worn:

```
"Equiped already but CanBeEquipedAt() failed!! [Char: %s, Slot: %d, Item: %s]"
```

That same validator supplies three more things. **Ammunition is "Bullet" in the engine's own
word, and slot 7 is the only place it is legal** — the condition spells the exception out:

```c
if ((notEquip != 1) || (slot != 7))
    "Item is neither Equip nor Bullet! [Char: %s, Slot: %d, Item: %s]"
```

**An item's option level is bounded at 250**: `if (0xfa < item->optLevel)` →
`"Item OptLevel is invalid!!!..."`. The guard fires above `0xfa`, so 250 is legal. This is a
validation ceiling, not a balance figure — real items reach single digits, and reading it as a
design target would be a mistake (`equipment.MaxItemOptLevel` says so, and a test guards it).

**And its loop is a fourth witness for the slot count**: `local_c` runs from 0 and it returns
success at `0xc < local_c`, validating exactly slots 0..12.

Incidentally, the same function re-confirms four values this project already shipped, from a
source none of them came from: it compares the item's `ReqGender` against the character's and
passes on `2` (`ReqGenderAny`), compares `Country` and passes on `3` (`CountryAny`), and tests
`ReqStr`/`ReqInt` against `GetParam(1)` and `GetParam(2)` — the Strength and Intellect param ids.

## What a new character starts with

The table marks its own defaults: every row whose code name ends in `_A_DEF`. For a China
character that is three armour pieces per family — Cotton (garment) suit / trousers / shoes at
3643–3645 for a man and 3652–3654 for a woman, Cloth (protector) at 3640–3642 / 3649–3651,
Copper (armour) at 3637–3639 / 3646–3648 — plus one weapon of each kind: 3632 Copper Sword,
3633 blade, 3634 Crescent (spear), 3635 Glaive, 3636 Copper Bow, and 3655 arrows for the bow.
No hat, shoulder guard or gauntlet is a default. `equipment.StartingKitFor` gives the garment
set and the sword; the family and the weapon are this project's picks (the original chooses by
the class picked at creation, which this server does not record), the rows are the game's.

## A weapon's stats, and where they live in the row

A hover tooltip shows an item's stats, and those are columns of the same
row (0-indexed, as `ItemTableReader` counts them). They were pinned
against a real **Copper Sword (+5)** tooltip a player sent, every figure
of which is reproduced by reading these columns and backing the `+5` out
through the per-plus growth floats beside each attack:

| Stat | Columns | Copper Sword reads | The +5 tooltip showed |
|---|---|---|---|
| Physical attack | 95 (min), 97 (max), 99 (growth 2.4) | 15 ~ 16 | 15+5×2.4 ~ 16+5×2.4 = **27 ~ 28** |
| Magical attack | 100 (min), 102 (max), 104 (growth 4.1) | 25 ~ 28 | 25+5×4.1 ~ 28+5×4.1 = **45 ~ 48** |
| Durability | 63 | 62 | **62 / 62** |
| Attack rate | 113 | 24 | **24** |
| Critical | 116 | 3 | **3** |

**Two independent readers, one column map.** This project reads the item table
twice, from opposite ends and for different purposes: the client's
`item_table_reader.gd` builds tooltips straight from the archive, and the
server's `cmd/export-refdata` produces the CSV the server imports. They were
written at different times for different reasons, and they now agree on every
column either one reads:

| stat | client reader | exporter |
|---|---|---|
| durability | 63 | 63 |
| physical defence | 65 / 66 | 65 (+1) |
| block ratio | 74 / 75 | 74 (+1) |
| magical defence | 76 / 77 | 76 (+1) |
| physical attack | 95 / 97 | 95 / 97 |
| magical attack | 100 / 102 | 100 / 102 |
| attack rate | **113, scalar** | **113, scalar** |
| critical | **116, scalar** | **116, scalar** |
| required level | 32 / 33 | 32 / 33 |
| TypeID1–4 | 9 … 12 | 9 … 12 |

**A disagreement between those two files is a bug signal, not a style
difference** — and one has already been caught that way: the exporter emitted a
literal `"0"` for both defences while the client had been reading 65/66 and
76/77 correctly the whole time, so a Cotton Suit's tooltip showed its real
defence while the server treated the character as wearing nothing.

**Columns 114 and 117 are NOT the maxima of those two** (corrected 2026-09-15).
A Copper Sword reads 24 at 113 and **30** at 114, 3 at 116 and **15** at 117 —
and the +5 tooltip above showed *single* values, 24 and 3. A real maximum would
have displayed as a range, the way physical attack does (`27 ~ 28`). A 3,818-row weapon census confirms it from the data side: if 114 were the
hit-rate maximum the min/max ratio would be roughly consistent, and instead
`114/113` clusters at ~2.11 for some weapons and ~1.22 for others, while
`117 − 116` is **0** on 1,131 rows, 12 on 927, 13 on 892 and a scatter beyond.
Neither behaves like a proportional range — real ones do, defence running
2 → 2.5 and block 10 → 20.

The client settles it outright: `item_table_reader.gd` reads `COL_ATTACK_RATE :=
113` and `COL_CRITICAL := 116` as single ints and prints them as
`"Attack rate %d"` / `"Critical %d"`, while it reads defence and block as
`Vector2` pairs and prints them as `"%s ~ %s"`. It never reads 114 or 117 at
all. What they
actually are is not identified, so `cmd/export-refdata` exports zero for
`HitRateMax` and `CriticalMax` rather than handing those numbers out under a
max's name: an honest absence, not a value that would put 15 where a Copper
Sword's critical is 3.
| Phys. reinforce | 105 (min), 107 (max), tenths of a % | 306 / 342 | **30.6 % ~ 34.2 %** |
| Mag. reinforce | 109 (min), 111 (max) | 519 / 591 | **51.9 % ~ 59.1 %** |
| Required level | 33 (the ReqLevel1 pair) | 1 | **1** |

Each stat is a four-int group whose displayed range is element [0] ~ [2];
the attack groups carry a fifth `float` growth-per-plus. The server gives
`+0` items, so the tooltip shows the base range; nothing tracks an
enhancement level yet.

**Armour defence** is a *separate* column block, not a reuse of the attack
columns as an earlier note assumed: weapons leave the armour columns 0 and
armour leaves the attack columns 0. It sits at columns 65-77 (min/max pairs):

| Stat | Columns | Cotton (garment) reads | Copper (heavy) reads |
|---|---|---|---|
| Physical defence | 65 ~ 66 **~ 67** | 2 ~ 2.5, 0.3 | 2.5 ~ 3, 0.4 |
| Magical defence | 76 ~ 77 **~ 78** | 4.3 ~ 5.2, 0.7 | 3.2 ~ 3.9, 0.5 |
| Block ratio (shields) | 74 ~ 75 | — | (shield 10 ~ 20) |
| Parry-family pair (non-shields) | 68 ~ 69 | 5 ~ 7 | 5 ~ 7 |

**Column 61 is `ItemClass`** (identified 2026-09-15), derived from the ORDER of
the server's own deserialiser rather than by pattern-matching the data.
`RefObjItem::ExtractData` reads its fields consecutively off the row —
`+0x198` (4 bytes), `+0x19c` (1), `+0x1a0` (4), `+0x1a4` (4), `+0x1a8` (1) — and
`+0x19c` is confirmed as `ReqGender` by `CGPCInventoryOP::CheckEquipsetIntegrity`,
which compares it against the character's `GetGender()`. Columns 57/58/59/60 are
already pinned as MaxStack / ReqGender / ReqStr / ReqInt, exactly those four in
exactly that order, so the next field is **column 61** — and it is a one-byte
read, matching `m_btItemClass`.

Checked against the binary's own assertion rather than a curve: `ExtractData`
asserts *"ItemClass must be not zero"* / `m_btItemClass > 0`, and column 61 is
non-zero on **all 21,552** equipment rows. Values are small (1–14+), and one
family's five tiers walk it 1, 4, 7, 10, 13.

**Column 93 is `TwoHanded`** (identified 2026-09-15). A clean 0/1 that is
**constant within every weapon kind** (`TypeID4`) — never mixed — and 0 on all
511 shield rows.

Found by diffing a known one-hander against a known two-hander, then settled by a
source that knows nothing about this table: the **client's own
weapon-to-animation-group switch** (`WEAPON_ANIMATION_GROUP`, recovered in
`docs/WORLD_ISSUES.md`'s hundred-and-thirty-third round) names five kinds
explicitly, and column 93 agrees with all five:

| TypeID4 | the client's own name | col 93 |
|---|---|---|
| 7 | `onehand_sword` | 0 |
| 10, 15 | `onehand_staff` | 0 |
| 8 | `twohand_sword` | 1 |
| 11 | `twohand_staff` | 1 |

The remaining kinds fall out consistently: spear (4), glaive (5), bow (6),
axe (9), crossbow (12), harp (14) read 1; blade (3) and dagger (13) read 0.

**Corrected 2026-09-15: these are TRIPLES, not pairs.** A census of all 21,560
item rows shows columns 65/66/67 populated on exactly the same 10,163 items, and
76/77/78 likewise — a third value sits after each min/max. It scales with the
item tier alongside them (heavy body armour tiers 1→5 read 0.4, 0.6, 0.8, 1.0,
1.3 against physical defence 2.5→27.5) but not as a fixed fraction of either,
which is consistent with a per-enhancement gain and **is deliberately not
labelled here** — the shape is measured, the meaning is not.

The census also settles which defence families the data actually uses:

| columns | rows populated | what |
|---|---|---|
| 65–67 | 10,163 | physical defence triple |
| 68–69 | 9,663 | a pair on every armour **except** shields (10,163 − 500) |
| 74–75 | 500 | block ratio — shields only |
| 76–78 | 10,163 | magical defence triple |
| 70, 88–90 | **0** | never populated on any row |

That 9,663 = 10,163 − 500 is the useful part: 68–69 is present on exactly the
non-shield armour and 74–75 on exactly the shields, which is the parry/block
split the `_RefObjItem` order (PD, ER, PAR, BR, MD) predicts.

Grounded three ways that agree: the real DB `_RefObjItem` column order in
`refdata_schema.md` (PD, ER, PAR, BR, MD — PD first, block, then MD) maps onto
these positions; heavy armour reads more physical and cloth more magical
(the cloth=magic / heavy=physical characteristic); and shields alone carry the
block ratio. **Still** absent rather than guessed: the attack distance (0.6 m
on the sword, not located in these columns) and the ER/PAR/MAR columns whose
exact semantics `refdata_schema.md` records as not yet decoded.

## What the picture is evidence of

None of the above was concluded from a render, but the render is a check on all of it at once: a
new character, dressed by the server, draws in the white Cotton set the table names — where the
earlier code had chosen an ornate gold set by `item_id % 8` — and the first render of the six
`_RARE` Cotton pieces put the hat on the head, the talisman at the collar and the wristlet on
the forearm, each from its own file.

## Reuse cooltime: a descriptor names it, a group shares it (round 263)

The item record's `0x2a0` strided array is itemdata's 20 `(Param, Desc128)`
pairs (round 262). `RefObjItem::ExtractData` (`0x6a3d50`) reads every
element's descriptor, and when it contains **`cooltime`** (case-insensitive;
the retail rows write `COOLTIME:0x000000C8`) it parses the text after the
colon as the **cooltime group** -- hex after `0x`, decimal otherwise -- into
`ref+0x520`, and stores that element's `Param` at `ref+0x524` as the
**cooltime in milliseconds**. A descriptor that fails to parse logs `invalid
parameter has been assigned for item cooltime: %s, %s` (the item's code and the
descriptor). Element 0 without such a descriptor falls through the fortress /
skill-bound special cases and is divided by 1000 (the minutes-scale reuse span
the use-result packet carries -- the earlier reading of `+0x2a0`).

The use-site is `Item_HandleUseItem` (`0x510980`): when `ref+0x524` is
non-zero, `ItemCooldowns::IsReady(pc+0x1f40, ...)` (`0x64c040`, the same
cooldown block the skill gate uses) must pass or
the use is refused with **`0x185b` `UIIT_MSG_STRGERR_WAIT_FOR_REUSE_DELAY`**;
after the success reply, `ItemCooldowns::Arm(block, group, ms, ...)`
(`0x64c320`) starts the group's timer, and a delay of **300 000 ms or more**
takes the persisted branch (a `time32` stamp, so a long cooldown survives a
relog).

**What the retail table says.** 148 rows carry a descriptor; **no HP, MP or
vigour potion does**, so this descriptor puts no reuse delay on potions.
(Corrected in rounds 496 and 508: the server still paces potions, through a
separate per-kind lock in `CGItemExpendable` slot 308 -- `FUN_004eb410`
refuses with the same `0x185b`, `FUN_004e0ab0` arms it for a float32 number
of seconds, 1.1 for an absolute potion by a China character and 4.1 for a
percentage one. See `session.potionReuseBit` and RE_COMPLETION.md round 508.) Examples: the random-cure pills `ITEM_ETC_CURE_RANDOM_0x`
group `0xC8` **20 000 ms**; group `0xF0` 1 200 000 ms (20 min); group `0x71`
18 000 000 ms (5 h); group `0x00` from 5 000 ms to 7 200 000 ms; a handful at
`1` ms. Items in one group share the timer.

**The group map is shared with skills** (corrected in round 504; this page
said "item groups in their own map"). Each non-zero byte of the item's group is
looked up in the map at block `+0x2c` (`0x64c080` `lea eax,[ebp+0x2c]`). That
is the same map `SkillCooldowns::IsReady` (`0x64c1a0`, `0x64c245`) reads for a
skill's cooldown group, the high byte of its `Overlap` (`+0x8f`). Only the
per-id maps are separate: `+0x10` for items and `+0x1c` for skills. So an item
and a skill with the same group byte share a timer. On the real tables they
never do: the item groups are `0x71`, `0xA7`, `0xC8`-`0xCB`, `0xF0`-`0xF2` and
`0xF6`, and no skill uses any of those bytes (the skill groups stop at 114 and
skip 113).

**srrevamp** exports the pair as item columns 64-65 (`CooltimeGroup`,
`CooltimeMs`; `refdata.Item`), and `UseItemHandler` refuses a use inside the
group's timer with "wait for the reuse delay" and arms it on success
(`session/itemcooldown.go`, in memory; the 300 s persistence is not built --
disclosed). Potions are paced by slot 308's per-kind lock instead (round
508), which the same handler checks right after this one. Since round 632 the
rule is live: the berserk potions (TypeID 3/3/1/8) are usable, and two of
them carry a descriptor -- `ITEM_ETC_SECOND_HWAN` (23937, "Hwan regeneration
fill") `COOLTIME:0x000000C9` with 1,200,000 ms (20 minutes) and
`ITEM_ETC_GNGWC_WHAN` (22936) `COOLTIME:0x00000000` with 180,000 ms. A GM
account's berserk potion skips the delay (OURS, the user's request).

**A key of 0 is not a group (round 632 review).** The descriptor's value is a
KEY, handed to `ItemCooldowns::IsReady` (`0x64c040`) in EAX from ref+0x520
(`0x510d8f`). Key 0 reads the block's **per-item** map at `+0x10`, keyed by the
item; a non-zero key reads the group map at `+0x2c` once per non-zero BYTE of
the key. `ItemCooldowns::Arm` (`0x64c320`) always stores the per-item entry and
links each non-zero byte to a group timer. So the retail ids carrying
`COOLTIME:0x00000000` (37 of them, the review's count) each keep their own timer (22936's 3 minutes do not block
22941 or 23977), and round 632 was wrong to call key 0 "group 0x00".
`session/itemcooldown.go`'s `ReadyItem`/`ArmItem` do it this way; the engine
returns ready at the first non-zero byte whose group has run out, which on the
single-byte retail keys is the same as "no byte's group is running".

## Berserk potions and Energy of life (round 632)

Read from Media.pk2's itemdata and textdata_object and from SR_GameServer.exe.

| id | code | TID | name (textdata_object) | Param1 | COOLTIME |
|---|---|---|---|---|---|
| 23937 | `ITEM_ETC_SECOND_HWAN` | 3/3/1/8 | Hwan regeneration fill | 5 | group 0xC9, 1,200,000 ms |
| 22936 | `ITEM_ETC_GNGWC_WHAN` | 3/3/1/8 | Berserk Regeneration Potion | 5 | key 0 (its own timer), 180,000 ms |
| 24331 | `ITEM_ETC_E080723_HWAN_POTION` | 3/3/1/8 | Berserker Regeneration Potion | 5 | none |
| 24993 | `ITEM_EVENT_HWAN_POTION` | 3/3/1/8 | Berserker Regeneration Potion | 5 | none |
| 33884 | `ITEM_EVENT_RENT_HWAN_POTION` | 3/3/1/8 | Berserker Regeneration Potion | 5 | none |
| 5921, 10491 | quest items | 3/3/1/8 | Spirit Fragment, Memory of Red Hair | 5 | none |
| 23944-23947 | `ITEM_ETC_SECOND_HWAN_SCROLL_01..04` | 3/3/13/14 | Energy of life 1st-4th degree | 3600 | group 0xC9, 1 ms |
| 23938-23941 | `ITEM_ETC_INCREASE_HWAN_TIME_01..04` | 3/3/3/10 | (the scroll's buff) | 3600; then "ParamKeeper FourCC" 7366772 (`0x706874`) = 5/8/11/14 | none |

**The bag path** -- `CGItemExpendable` slot 308 (`0x0049b710`), TypeID3 1 /
TypeID4 8 (`0x49b9a4..0x49b9e9`): `GetBodyMode()` (vtable `+0x100`) == 1
answers `0x18ce` and the potion is kept; otherwise `AddHwanCount` with a
literal `mov esi,0x5` and the answer is 1. It neither asks the per-kind lock
nor reads the orb count, so at five orbs the potion is still spent.
`Item_HandleUseItem` (`0x00510980`) checks and arms the COOLTIME around it,
as for every item. `0x18ce` has no case in the client's error switch, but its
text is authored: textuisystem's `UIIT_MSG_QUEST_ERR_USE_WHANITEM`, "Selected
item cannot be used during berserk mode." (round 632 review).

**The Energy of life scroll** (3/3/13/14) is a COMPOSITE item, not a potion.
Its Param2 descriptor reads `[UIL1:ITEM_ETC_SECOND_HWAN,A,3600,1],[UIU1:
ITEM_ETC_INCREASE_HWAN_TIME_0n]`: `UseByKind` (`0x0049c2b0`) case `0xe` ->
`GObjPC::FUN_0049f590` walks those FourCC entries (`'UIL1'` = `0x55494c31`,
`'UIU1'` = `0x55495531`) and queues timed jobs -- a one-use, 3600 s
used-item-limit on the fill, and the berserk-time buff: a "ParamKeeper
FourCC" `0x706874` worth 5/8/11/14. **Traced (round 632 review):** it is not
one of `Stat_ApplyTaggedModifier`'s tags; it is a key of
`CTJ_CharParamKeeper`'s own table (`FUN_006552d0`, `0x6552fe`), whose record
is {index 0, **param 0x3c = 60**, slot 0}. The job's apply
(`CTJ_CharParamKeeper::vslot_012`, `0x655045` -> `0x655430`, EDX = the
record's param, `ParamKeeper_SetParam` `0x4b3510`) writes the value into
param 60's slot 0 keyed by the job, and slot 0 sums. Param 60 is the berserk
duration's base (the activation reads `EvaluateParam(60) + EvaluateParam(195)`
and `GObjPC_InitStats` sets 60.0), so the scroll's berserk lasts 65/68/71/74 s
while the job runs; `vslot_015` (`0x655180`, `ecx 0`) removes it. The client
is consistent with it: its `0x325F` handler (`FUN_0089a0d0`) stores the value
when the tag is `0x706874` and its berserk activation (`FUN_007b4f40`) reads
that field (READ); that the client treats it as seconds is INFERRED. The UIU1 buff shows no buff-bar icon: the
client adds one only when the item's Param4 is 1, and it is -1 on
23938-23941.
The fill is then spent through `CUsedItemLimit::vslot_007` (`0x00654080`),
which asks `FUN_004a05b0` first (dead `0x1889`, berserk `0x18ce`, **five
orbs already `0x183e`** -- a refusal the bag path does not have), arms the
fill's COOLTIME (`0xC9`, 20 minutes, which then blocks the scroll too: it
carries the same group), and calls `FUN_004a0600`, whose `AddHwanCount`
takes Param1's byte (5). The tooltip says it: "During the Effect, 100% gauge
charge can be used once. (After use of 100% Gauge charge, extend time will be
removed and unable to use Energy of life for 20 Mins)".

### The composite path, end to end (round 632 review; srrevamp builds it)

- **Which rows carry a list.** RefObjItem's ExtractData (loop `0x6a558e..0x6a55aa`)
  hands Desc_k to the list parser `ReferenceData::FUN_00864bc0` only for TID
  3/3/13/14 (k = 2..5) and 3/3/13/15 (k = 2..3), and only where Param_k is 1.
  Exported as item column 71, `CompositeDesc`.
- **UIL1's fields** (`FUN_00864500`, UIL slot 1): code, a flag (`FUN_00864240`:
  "A" -> 0, "P" -> 1; strings at `0xb12aa4`/`0xb12aa8`), seconds (+0x28), count
  (+0x2c). The type-5 job packs remaining<<16 | max; remaining is count, or
  count-1 for "P".
- **The scroll's refusals** (`FUN_0049f090`): `0x1894` UIIT_SKILL_USE_FAIL_OVERLAP
  ("The selected item cannot be used together or the skill is already in use.")
  when a type-5 job from this scroll runs, when a UIL1 job for the fill runs,
  and (`0x49fd09`) when a type-10 job with the same FourCC runs.
- **The UIU1 job**: the named item's Param1 is the seconds (`0x49fcc0`), Param2
  the FourCC, Param3 the value. Which job depends on the named row (composite
  review): a 3/3/13/4 row (`FUN_004929c0` 0x4929c0 = TypeID 3/3/13, and TID &
  0xf800 == 0x2000) makes a type-3 job (not modelled, refused); otherwise
  `FUN_00488db0` (0x488db0: TID bit 1 clear, TypeID **3/3/3/10**) gates the
  type-10 job, and on 0 the branch jumps to `0x49fd55` and makes **no job at
  all**, silently -- srrevamp skips such an entry the same way.
- **The fill**: client `0x715F` {u32 compositeRefId, u32 limitedRefId} ->
  `GObjPC_HandleCompositeItemMsg_15f` (`0x511640`): no job -> 2, no use left ->
  `0x18c6` ("Exceeded one day use limit."), else `CUsedItemLimit::vslot_007`:
  row checks, `FUN_004a05b0` (dead `0x1889`, berserk `0x18ce`, five orbs `0x183e`
  "The selected item is unusable."), on the last use end the UIL1 job, end the
  `0x706874` job and arm the fill's COOLTIME; then `FUN_004a0600`:
  `CGObjPC::vslot_300` (`0x4ef340`) with `FUN_0048b840(.., 1)`'s float
  (`0x4a0614..0x4a0629`), then `AddHwanCount(Param1 byte)`, and the handler
  decrements the count and answers `0xB15F` {1, A, B}. `vslot_300` is
  `GObjPC::FUN_004a9430`: when `+0x4c0` answers non-zero it calls
  `CGObjMobile::vslot_300` (`0x48b730`: both move controllers' `+0x18`), may
  send `0xB023` (a NetProcessInNavAndSkill message on the client), copies the
  position block and resets the stance from body state 2/3 -- INFERRED a
  movement stop. **OPEN, not mirrored**: no srrevamp item use stops movement.
  vslot_007 does not ask IsReady: the 20 minutes block the next scroll.
- **What the client shows** (retail client, READ): `0x3159` {compositeRefId,
  secs, limitedRefId, count} adds a kind-5 icon on CIFMagicStateBoard -- the
  COMPOSITE item's icon, gauge total = its Param1 x 1000 -- and a map entry;
  `0x315B` removes both; `0x3161` refills the count. A left-click on the icon
  (`CIFMagicStateBoard::vslot_029`, `0x800430`; guarded by `board+0x390 != 0`
  at `0x800501` -- the map of grant entries is the std::map at `+0x388`, whose
  iterators end at the head `+0x38c` (FUN_008052f0/FUN_00805430, READ), so
  `+0x390` is its size, INFERRED from MSVC's layout: "some grant exists")
  opens `CIFCompositeItemWnd`
  (`GDR_COMPOSITE_ITEM`, ID 36, 300,200,214,245; layout
  `resinfo\ifcompositeitemwnd.txt`), whose buttons (`FUN_007af830`:
  `sys_button.ddj`, 150 x 25 from (0x1f, 0x3a), step 0x22, label "%s(%d)") send
  `0x715F` (`FUN_00821720`). It builds **count + 1** buttons: the last is
  labelled with `UIIT_CTL_CANCEL`'s text (`0x7afb57`), and `FUN_007b03e0`
  hit-tests all count + 1 (composite review).
- **The end**: the CUsedItemLimit job sends `0x315B` {compositeRefId,
  limitedRefId} when it ends (`0x653e80`), consumed or expired, and the client
  (`FUN_008993b0`) removes the entry and the kind-5 icon. srrevamp pushes
  `OpCompositeEnd` (0x0108) from a timer and from the last use, before the
  use's result (vslot_007 ends the job before `0xB15F`), and sends the state
  after a refused fill too.
- **Texts**: 0x185b's authored text is `UIIT_MSG_STRGERR_WAIT_FOR_REUSE_DELAY`,
  "Still have time to reuse the item." -- every item path's reuse refusal now
  uses it.
- **srrevamp** carries this on its own opcodes 0x0104-0x0108 (OURS; see
  `session/composite.go`, `client/scripts/net/composite.gd`), keeps the jobs in
  memory (a restart loses them), and a GM account neither checks nor arms the
  scroll's or the fill's COOLTIME (OURS, the user's request).
