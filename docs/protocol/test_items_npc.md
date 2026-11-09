# The Test Items NPC (round 783)

The user (2026-10-12): "can you put a test npc in Jangan between storage and so-ok? Use the model
"Potion Merchant Thiara" in Alexandria. Allow me to buy all alchemy items (11d only), seal of nova
items, all genders, races, and classes. … Make sure you put them in different options in the first
window then different tabs like the weapon, grocery, and armor vendors." Two follow-ups the same
day: the in-game name is exactly **"Test Items"**, and **everything it sells is free** (0 gold).

Labels: READ (from the archive or a binary, with where), MEASURED, INFERRED, OURS, OPEN. No game data
is in this file or in the repository: the NPC is defined by rules over the player's own item table,
resolved by the server at boot.

## What it is

| | Value | Label |
|---|---|---|
| Name (name plate, talk and store window titles) | `Test Items` | OURS (the user's) |
| Body | `NPC_SD_T_AREA_POTION`, characterdata id 26823, `npc\sd\sd_t_area_potion.bsr` -- "Potion Merchant Thiara" (`SN_NPC_SD_T_AREA_POTION`, textdata_object) | READ (the box's Media.pk2) |
| Where | region 25000 (97/168, Jangan), local (1070.0, -32.61, 950.0), on the square's deck east of the dragon fountain, 97 from the Storage-Keeper Wangu (`NPC_CH_WAREHOUSE_M`, npcpos row 2013 at 980.80, -32.43, 989.13) and 101 from Event So-Ok (`NPC_CH_EVENT_KISAENG1`, row 3861 at 1101.68, -32.28, 854.30) | the two NPCs READ (npcpos.txt); the spot OURS; its ground MEASURED (below) |
| Facing | wInitialDir 8192 (45°, compass 45: north-east -- the user, round 784: "rotate the npc 90 degrees to the right so it's facing north east"; it faced 24424, compass 315.8, toward the town's spawn, before) | OURS |
| Offers | interaction 1 (the store) only | OURS |
| Prices | 0 gold for its goods, at its store only | OURS (the user's) |
| Switch | `-test-items-npc` / `OPENSRO_TEST_ITEMS_NPC=1`, default off | OURS |

**The spot, MEASURED** (`OPENSRO_QA_SHOP_STEPS=cols:...`, the walkable graph of region 97/168 on the
render box): the straight midpoint of the two NPCs, (1041.2, 921.7), is in the dragon fountain's
basin -- its only surface is the basin floor at -54.39, and the first build stood the NPC there,
22 units under the square (the client's own placement line: "height -54.39 (record -32.40)"). Over a
5 x 7 grid from x 1040..1100, z 870..990 the square's deck (-32.61) covers every column but x 1040..1055
at z ≤ 910 and x 1070 at z ≤ 890 (the basin). (1070, 950) is on the deck, 40 from the basin's edge,
about equally far from both NPCs -- the way round the fountain on its east side.

## The goods (the definition)

`server/internal/testnpc/test_items.json` (embedded in the server). Each tab is a list of rules; a rule
is any of a CodeName128 prefix, suffix or regular expression, a TypeID pattern (`3/1/6/*`), an
ItemClass. Nothing else is listed. The vocabulary is READ:

- **Seal of Nova** is the client's `PARAM_RARE_FIRST2` (textuisystem.txt "Seal of Nova"), shown for a
  Seal item (Rarity 2 or 6) whose ItemClass is 31 or more with tier `(ItemClass − 1) mod 3 = 0`
  (docs/protocol/item_tooltip.md, round 731). The 11th degree is ItemClass 31..33
  (`(ItemClass − 1)/3 + 1`, alchemy.md). The sold rows are the **unlocked** ones (round 786, the
  user: "Make all the items level 101, not 111"): `ITEM_CH_*_11_A_RARE_ACTIVE` /
  `ITEM_EU_*_11_A_RARE_ACTIVE` / `ITEM_(CH|EU)_(M|W)_(HEAVY|LIGHT|CLOTHES)_11_xx_A_RARE_ACTIVE` of
  ItemClass 31, each pattern anchored with `$`.
- **Locked and unlocked, READ** (the box's itemdata and the prod refdata database, 2026-10-13):
  every 11th degree Seal of Nova piece has two rows with the same name. The plain `_A_RARE` row is
  the LOCKED one -- `ITEM_CH_SWORD_11_A_RARE` (id 4044, "Reaper Ghost Sword") asks level **111**
  and its description key is `SN_ITEM_LOCKED_TT_DESC`. The `_A_RARE_ACTIVE` row is the UNLOCKED
  one -- `ITEM_CH_SWORD_11_A_RARE_ACTIVE` (id 62605, the same name) asks level **101**, with
  `SN_ITEM_UNLOCKED_TT_DESC`. MEASURED: all 94 `_A_RARE_ACTIVE` rows the rules take ask 101, and
  have ItemClass 31 and the TypeIDs of the tab they land in (3/1/6, 4, 5 or 12, and 3/1/1..3,
  9..11), so the per-tab counts are the locked rows' (the table below).
- **Left out, OURS:** the locked `_A_RARE` rows (level 111); the `_SWITCHnn` and
  `_SWITCHnn_ACTIVE` variants (the `$` after `_ACTIVE` keeps them out: `[A-Z]+` matches no digit
  or underscore; same names as the plain row); the `ITEM_EVENT_*` copies; and the Rarity-6
  `_11_SET_A_RARE` / `_SET_B_RARE` rows (the "Asue" / "Azus" sets -- set items, not Seal of Nova
  by name).
- **Alchemy, 11th degree:** the items whose code ends `_11` in the families
  `ITEM_ETC_ARCHEMY_UPPER_REINFORCE_RECIPE_` (Advanced Elixir (lv 11)), `_REINFORCE_PROB_UP_`
  (Lucky Powder (11th) and Lucky Magic Powder), `_MAGICSTONE_` (incl. luck, steady, immortal, astral
  and assimilation prevention), `_ATTRSTONE_`, `_MAGICTABLET_` (Jade), `_ATTRTABLET_` (Ruby) and
  `_ELEMENT_`; plus the four plain and four intensifying elixirs (`ITEM_ETC_ARCHEMY_REINFORCE_RECIPE_*`,
  3/3/10/1), which have no degree and are what an 11th degree item is reinforced with (OURS: kept).
  Left out, OURS: the `_POTIONTABLET_SPEED_11` "Sapphire tablet of typoon" (its `11` is a tier, not
  a degree: its Param1 is 56 and its name has no "(Lvl.11)"), the monster materials (3/3/11/4), the
  event and GM copies.

**The window (OURS, in the retail vendors' shape -- READ from refshoptab.txt):** the store builds at
most four tabs (`x = 16` stepping 56 while `x < 240`, READ) and shows 30 goods a tab (the 6 x 5
lattice; OpenSRO has no page spin yet), so the goods are cut into eight store lines:

| # | Store line (talk window) | Tabs (goods, MEASURED on the box's archive) | Shaped after |
|---|---|---|---|
| 1 | Purchase 11th Degree Elixirs and Alchemy Stones | Elixir 26 · Magic 19 · Attribute 14 | the grocery's Alchemy tab |
| 2 | Purchase 11th Degree Alchemy Tablets and Elements | Jade 18 · Ruby 14 · Element 4 | |
| 3 | Purchase Chinese Seal of Nova Weapons and Accessories | Weapon 5 · Shield 1 · Accessory 3 | STORE_CH_SMITH (Weapon / Shield), the grocery's Accessory |
| 4 | Purchase European Seal of Nova Weapons and Accessories | Weapon 9 · Shield 1 · Accessory 3 | STORE_EU_SMITH |
| 5 | Purchase Chinese Male Seal of Nova Protector | Armor 6 · Protector 6 · Garment 6 | STORE_CH_ARMOR_GROUP1 |
| 6 | Purchase Chinese Female Seal of Nova Protector | Armor 6 · Protector 6 · Garment 6 | STORE_CH_ARMOR_GROUP2 |
| 7 | Purchase European Male Seal of Nova Protector | Armor 6 · Protector 6 · Garment 6 | STORE_EU_ARMOR_GROUP1 |
| 8 | Purchase European Female Seal of Nova Protector | Armor 6 · Protector 6 · Garment 6 | STORE_EU_ARMOR_GROUP2 |

189 goods: 95 alchemy, 94 Seal of Nova (16 weapons and shields, 6 accessories, 72 protector pieces).

**Round 789: the avatar lines (OURS).** The user: "an Avatars tab on the Test Items NPC". The archive
has **1,381** avatar ids (1,355 of 3/1/13 and 26 of 3/1/14, MEASURED: per gender about 260 hats, 227
dresses, 170 attachments, 20 flags and 13 devil's spirits), far past a tab's 30 goods and its four
tabs a line, and the client has no page spin. So three lines, split by gender (a new rule field,
`"gender"`, the row's ReqGender, itemdata column 58) and by kind:

| # | Store line | Tabs |
|---|---|---|
| 9 | Purchase Avatars (Men) | Hat · Dress · Attachment (`UIIT_STT_SILKMALL_HAT/_DRESS/_ATTACH`, the grant window's own keys, READ) -- each the first 30 by id of the item mall family (`ITEM_MALL_AVATAR_`, 64..93 rows per kind and gender, MEASURED) · Devil's Spirit (all 13) |
| 10 | Purchase Avatars (Women) | the same for women |
| 11 | Purchase Avatar Flags and Devil's Spirit Extensions | Flag (Men) 20 · Flag (Women) 20 · Extension (3/3/13/16, the Nasrun extension) |

The boot log's `(+n dropped)` counts what a tab leaves out; every other avatar is one `/give` away.
**Avatars and devil's spirits are sold plain** (round 789, OURS): +0, no blue options, a devil's spirit
not awakened -- not the +12 full-blue of the other equipment -- so the blacksmith's grant and the
awakening have something to do (`testShopInstance`). The extension tab's label and the "Devil's
Spirit"/"Flag" labels are OURS text.
**Round 790: the avatar set lines (OURS).** The user (2026-10-16): "add some male/female avatar sets
to the item npc including the akatsuki one". Two more lines, **Purchase Avatar Sets (Men)** and
**(Women)**, four tabs each ("Sets 1".."Sets 4", OURS text), from one rule with `"sets": true`
(`Rule.Sets`): the item mall avatars of that gender, grouped by code name with its `HAT`, `ATTACH`
and `DRESS` words taken out (`_M_PIRATE_HAT_2` joins `_M_PIRATE_2`; `_M_ANGEL_WING`, an attachment,
joins `_M_ANGEL_WING_DRESS`). A set is a group with a dress and one more piece; sets are listed
newest first (by their highest id), each hat, dress, attachment, and never split across tabs (a tab
ends where the next set does not fit, the line's next tab goes on from there; what the last tab
cannot take is its `(+n dropped)`). On the box's archive plus `z_akatsuki.pk3` (MEASURED, the round
789 export, 15,342 rows): the first set on both lines is the Akatsuki robe and straw hat (78901 +
78903, 78902 + 78904), then 2015_NEW_ARABIA, ADMIRAL_2017, 2016_REDHOOD, 2015_FOX ...; about 40 sets
a gender are listed and 122 items a gender are left to `/give`. An archive without the pack simply
starts at its own newest set.

The Seal of Nova tabs are labelled with the retail vendors' own keys (`SN_TAB_WEAPON`,
`SN_TAB_SHIELD`, `SN_TAB_ACCESSORY`, `SN_TAB_HEAVYARMOR[_EU]`, `SN_TAB_LIGHTARMOR[_EU]`,
`SN_TAB_CLOTHES[_EU]`; READ, refshoptab.txt column 5), so the client words them from its own text
table; the alchemy tabs and the line texts are OURS. A tab's goods are in rule order, then TypeID3,
TypeID4 (head to foot) and id.

## How the client learns it: OpNpcShopDef 0x00BA (OURS)

A retail NPC's store lines and tabs are the client's own (`ShopReader`: refshopgroup →
refmappingshopgroup → refmappingshopwithtab → refshoptabgroup / refshoptab → refshopgoods →
refscrapofpackageitem). This NPC is in no archive, so the **server** resolves the definition and sends
the result; one definition, one resolver, in the server. Chosen over applying the rules on the client
too (two resolvers that must agree).

```
S->C 0x00BA, just before the 0xB045 select reply of such an NPC:
  u32 NPC unique id
  u16 n, n bytes   greeting (UTF-8)
  u8 lines
    u16 n, n bytes   line label (UTF-8: a text key or text)
    u8 tabs
      u16 n, n bytes   tab label
      u16 goods, goods x u32 item id
```

0x00BA was free in `server/` and `client/scripts` (grep). The spawn record is retail's: the body's
RefObjID, and the name in the record's own name field (flag bit 0, `CGObjNPC::SetCharName 0x4c3f20`;
npc_spawn.md) with interaction set {1}. The client (`NpcShopDefNet`, World3D) keeps the definition by
uid; the talk window's store lines are its lines (keyed `shop:custom:<i>`), and the `0xB046` open of
such a line fills the store with that line's tabs, each id named through the client's own item table.
Its greeting is the definition's; it has no fortress tax line.

## Buying

The buy is OpenSRO's `OpShopBuy` (item id, quantity), as at every store. **Free (OURS, the user's):**
`OpShopList` answers 0 and `OpShopBuy` takes no gold -- and tests none, so a character with 0 gold
buys -- for an item that is one of the NPC's goods **while the session's open interaction is that
NPC's store** (INTERACTMODE 6 from its `0x7046 {1}`). The same item with no store open, or at any
retail store, keeps its own price; no other store's price changes (`TestTestItemsNPCSelectOpenBuyFree`).
**Its equipment comes perfect (round 786, OURS, the user's):** a piece of equipment (TypeID 3/1)
bought here is +12, every white-stat variance group at 31 (100 %), and full blue -- every standard
blue option its kind can carry, at its degree and highest value -- with the durability those make
(`session/testshopgear.go` `testShopInstance`; docs/WORLD_ISSUES.md round 786). Stackables, and the
same item bought anywhere else, are ordinary.

## The listing: OpNpcShopGoods 0x00BB (OURS, round 786)

The user: "The items in the shop don't reflect full blue or +12 status." The store showed each
good as its reference item; it now shows the piece the buy gives.

**How retail does it (READ, docs/protocol/npc_gui.md §2):** a store good is a package whose scrap
row (refscrapofpackageitem) carries OptLevel, Variance, Data, MagParamNum and MagParam1..12
(`0x9824e0`). The client builds each package's `SOItem` from it (`0x8bf3a0`: the OptLevel and each
MagParam, not the Variance) and copies that whole item into the store's slot (`0x6d2310` →
`0x6d1ff0`), whose hover then reads it as any owned item: "(+N)" in the name and the blue lines.
The slot draws no plus or blue mark of its own (`0x6871d0` tests only the seal).

**Ours:** the server sends each equipment good's instance right after OpNpcShopDef:

```
S->C 0x00BB, after 0x00BA, once or more (each adds to the last; each fits one frame):
  u32 NPC unique id
  u16 n
    n x (u32 item id, the retail item record)
```

- The record is the one the bag, warehouse and worn lists carry (`session.AppendItemRecord`;
  item_tooltip.md, "The item instance on the wire"); the u32 before it is the good's item id where
  those lists put a slot, so the client reads the block with its own decoder
  (`ItemInstance.decode_block`). Only equipment goods are listed.
- The instance is `testShopInstance`'s -- the very one the buy creates -- built once at boot
  (`session.TestShopGoodsPayloads`, after the magic option tables are installed), so the listing and
  the bought piece are identical record for record (`TestTestItemsNPCSelectOpenBuyFree`). With no
  item table for the options (no `-magic-option-assign-csv`) there is no instance at the buy and
  no listing either.
- **Variance:** retail's store never applies a package's Variance (above), so a retail good reads 0 %.
  This listing carries the variance the piece is bought with, so it reads 100 % (OURS: the user's
  "100% white stats"). The durability line reads "(+99%)", the client's own `trunc(31 / 0.31)`
  (item_tooltip.md, round 732), as on the bought piece.
- **Compatibility:** a message of its own, not more bytes on 0x00BA, because a client from before
  round 786 refuses a 0x00BA with trailing bytes (its decoder wants the payload exactly) and would
  lose the whole store, while an unknown opcode it only logs and drops. So the server and the client
  can be updated in either order: an old client shows the reference items as before; a new client
  against an old server too. 0x00BB was free in `server/` and `client/scripts` (grep, 2026-10-13).
- **The client:** `NpcShopDefNet.decode_goods` and `merge_goods` add the instances to the uid's
  definition (World3D `_on_npc_shop_goods`); `NpcShopDefNet.tabs` puts each beside its good
  (`ShopReader.Tab.instances`, null for a reference good, empty on a retail tab); the store's tooltip
  (`HudPanels.item_tip_lines`, site "store") reads it through `ItemTooltipInstance.fields`, as an owned
  item's. The slot is unchanged (the seal edge only, as retail).
- Prices are untouched: `OpShopList` still answers 0 here and each item's own price elsewhere.
- Tests: `session/testshopgoods_test.go` (the bytes pinned, the split across frames, no listing
  without an item table), `TestTestItemsNPCSelectOpenBuyFree` (0x00BB after 0x00BA, none from a
  retail NPC, listing = bought piece), `client/scripts/ui/hud/store_listed_tip_test.gd` (the same
  bytes decoded; the tooltip's "(+12)", two blue lines, every white stat "(+100%)"; an unlisted or a
  retail good stays the reference item).

**OPEN (a risk the user should weigh):** a free good still SELLS at its own SellPrice at any NPC
(MEASURED on the box's archive: 250,000 for a Seal of Nova piece, 15,000,000 for a Magic stone of
luck (Lvl.11), 1,000 for most stones), so the NPC is a gold source on a server where it is switched
on.

## Deploying

No new export and no new CSV: the goods resolve against the item reference data the server already
loads (the refdata database or `-items-csv`), and the body against `-npcs-csv` (every TypeID 1,2,2,x
row, Thiara's included). Needed: the NPC rows (`-npcpos-csv` and `-npcs-csv`, as for every NPC), an
item import with code names (round 497 or later), and the switch. The boot log names the result:
`Test Items NPC resolved ... goods=189 tabs="1/1:Elixir=26 ..."` and `Test Items NPC spawned ...
uid=... ref=26823`. deploy/README.md, "The Test Items NPC (round 783)".

**Round 870: the Dimension Holes line (OURS).** The user (2026-11-09): "add them to the test item npc
please" (the Forgotten World's Dimension Holes). Line 18, **Purchase Dimension Holes (Forgotten World)**,
three tabs by theme: Togui (`ITEM_ETC_TELEPORT_HOLE_TOGUI_*`, 6 holes: 35-50, 51-60, 61-70 x grades 1-2),
Flame (`_FLAME_*`, 8: 71-80, 81-90 x grades 1-4) and Wreck (`_WRECK_*`, 8: 91-100, 100-110 x grades 1-4),
each rule the prefix and TypeID 3/3/12/7 (`docs/protocol/forgotten_world.md` 3). The band-less
`ITEM_ETC_TELEPORT_HOLE`, `_ARABIAN_GARDEN` and `_DUNGEON` rows are not Forgotten World holes and stay out.
Free, as every good here; the hole keeps its own rules when used (a town, its level band, the shared
5-hour cool time).
