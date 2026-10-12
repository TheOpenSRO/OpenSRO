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
| Facing | wInitialDir 24424 (134.2°, compass 315.8: toward the town's spawn, local (1002, 1020)) | OURS |
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
  (`(ItemClass − 1)/3 + 1`, alchemy.md). The sold rows are the plain `ITEM_CH_*_11_A_RARE` /
  `ITEM_EU_*_11_A_RARE` / `ITEM_(CH|EU)_(M|W)_(HEAVY|LIGHT|CLOTHES)_11_xx_A_RARE` rows of ItemClass 31.
- **Left out, OURS:** the `_SWITCHnn` and `_ACTIVE` variants (16 + 17 per weapon; same names as the
  plain row), the `ITEM_EVENT_*` copies, and the Rarity-6 `_11_SET_A_RARE` / `_SET_B_RARE` rows
  (the "Asue" / "Azus" sets -- set items, not Seal of Nova by name).
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
The bought item is an ordinary instance (its own stats, durability, a Seal item's lack of blues on a
buy as from any shop).

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
