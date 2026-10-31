# The tools used on another item (3/3/13/8)

Round 838, lane 2. The item mall sells 34 rows of TypeID 3/3/13/8: the retail gender switch
tool (`ITEM_MALL_EQUIP_TRANSGENDER_4`) and 33 tools of the private server whose archive the
player has (Pandora / vPlus): three gender switchers, fourteen weapon type switchers and sixteen
model switchers. This page is what each does in OpenSRO, and where each fact comes from. Labels:
**READ** (the decompiled `sro_client.exe` / `SR_GameServer.exe`), **MEASURED** (the archive's
tables on the RE box), **OURS** (OpenSRO's design where the original has nothing), **INFERRED**,
**OPEN**.

Code: `server/internal/session/switcher.go`, `client/scripts/ui/hud/item_target_pick.gd` and
`HudPanels`' use-on mode (lane 4's).

## 1. The client: picking the target (READ)

| Step | Where | What |
|---|---|---|
| Right-click the tool | `IFSlotWithHelp::FUN_00676570` 0x6769a5..0x6769ff | a 3/3/13 item (`FUN_005dd680`: `(tid & 0x780) == 0x680`) whose CanUse byte (ref +0xac, itemdata column 24; `GlobalDataManager::FUN_00972910` 0x972b76) has both 0x81 bits and whose TypeID4 is 8, 0xc, 0xf or 0x10 is **not used**: the inventory keeps the tool's slot (+0x380, `FUN_006aef80`) and the cursor is forced to **0xa6** (`FUN_00777e70`), the bright gold arrow |
| Left-click a slot | `CIFSlotWithHelp::vslot_029` 0x681130..0x6811b8 | with the forced cursor 0xa6: a slot holding an item -- bag (window kind 0x46), worn (0x47) or avatar (0x4e) -- opens message box **0x1f** (`FUN_0077f0a0`), whose values are "1" the tool's slot, "2" the clicked slot and "3" its window kind, and the cursor is cleared; an empty slot does nothing and the pick stays |
| The box | `UI_SILKMALL::FUN_00644c90` case 0x1f (0x647d62..0x647d95) | title `UIIT_STT_CONFIRM_BOX` "Confirmation window", text `UIIT_MSG_QUESTION_SILKMALL_ITEM_USE` "Will you use the selected item?" |
| Its OK | `FUN_00797d90` case 0x1f -> `SendItem_HandleUseItem` 0x796660 case 8 | worn target: the client posts itself 0xB04C {2, **0x1882**}; bag target that is not armour (`FUN_0056fa30`: TypeID 3/1/{1,2,3,9,10,11}): **0x1884**; any other kind: nothing; else **0x704C** {u8 tool slot + 13, u16 type word, u8 target slot + 13} |
| Cancel | `FUN_0078b660` 0x1b -> `FUN_0079d620`; `CGInterface::vslot_017` 0x204 (0x77c733) | Escape clears a forced cursor (and does nothing else); the right button going down clears it |

The CanUse byte is 129 (0x81) on every 3/3/13/8 row of the archive (MEASURED).

**OpenSRO.** The pick is lane 4's use-on mode (`HudPanels._begin_use_on` / `_use_on_target` /
`use_on_check`, round 838), the one target pick of the client for 3/3/13/{8,12,15,16} and 3/3/1/6.
Lane 2 adds to it, for 3/3/13/8 (`ItemTargetPick`): a worn slot takes the target click and the
box's OK refuses it with 0x1882; retail's gender tool on a bag item that is not armour is refused
with 0x1884; the use goes with the target's wire slot (bag index + 13) in OpenSRO's use request's
Option byte (OpUseItem 0x008a), as the Nasrun extension's (round 789). The private server's tools
skip retail's client-side armour test (their descriptions name other targets); the server
decides. Lane 4's box is its own centred OK / Cancel panel; the title and text are READ.

## 2. The server: the gender switch tool (READ)

`CGItemExpendable::UseByKind` (gs:0x49c2b0), case 8 (`tid >> 11`):

1. the target byte must be a bag slot, `(b - 13) < 99`, else **0x1882**
   `UIIT_MSG_STRGERR_CANT_MUTATE_EQUIPED_ITEM`;
2. the item there must exist, be equipment (IGObj +0x84 `CGObj::IsEquip`, TypeID 3/1) and armour
   (+0x9c `CGObj::IsArmor` -> `FUN_00488eb0`: TypeID3 1, 2, 3, 9, 10, 11), else **0x1884**
   `UIIT_MSG_STRGERR_INVALID_TRANSGENDER_TARGET`;
3. the tool's Param1 (ref +0x2a0) must not be below the item's degree (`FUN_004775a0`: ItemClass,
   ref +0x1a8, `(c - 1) / 3 + 1` for equipment), else **0x1883**
   `UIIT_MSG_STRGERR_CANT_MUTATE_SINCE_EQUIP_CLASS_TOO_HIGH` (the mall's tool: Param1 12);
4. the item's **OrgObjCodeName** (ref +0x48, the third string `RefObjCommon_ExtractData` reads,
   cleared when "xxx") names what it becomes; empty: the use answers **2**, UseByKind's preset;
5. `CGObjPC::MutateItemAt` (0x4efb60, IGObj slot 141) looks the name up -- none: 0, the use stays
   2 -- and when the id differs sets the item's reference, runs `UPDATE _ITEMS SET REFITEMID = %d
   WHERE ID64 = %I64d` and sends the owner **0x3040 {u8 slot, u8 1, u32 RefItemID}**. The item
   object -- its plus, options, durability -- is unchanged. A name that is the item's own answers 1.

`Item_HandleUseItem` (0x510980) spends one tool only on 1 and answers 0xB04C after it. On the
armour of the archive the OrgObjCodeName is the opposite-gender twin (MEASURED: 5,912 of the
5,914 armour rows name an existing row, two name a missing one; e.g. `ITEM_CH_M_HEAVY_01_BA_A_DEF`
-> `ITEM_CH_W_HEAVY_01_BA_A_DEF`).

OpenSRO: refdata.Item.OrgCodeName (export column 96), `inventory.Mutator` (the row keeps its slot
and serial), the same codes, 0x3040 mask 1.

## 3. The private server's tools (OURS, to each description)

All take the same pick and box and refuse an equipped target with 0x1882 (their descriptions:
"Unequip the ... first"). A refusal keeps the tool. Counterparts are archive rows found by code
name and checked by TypeIDs and, where it matters, ReqGender and ItemClass.

### Gender: avatar, devil's spirit, flag

| Tool | Description's targets | TypeIDs taken |
|---|---|---|
| `ITEM_AVATAR_SWITCHER` | "avatars & their hats or accessories" | 3/1/13/1, /2, /3 |
| `ITEM_DEVIL_SWITCHER` | "Devil's Spirits or Angel's Spirits" (A, B, S) | 3/1/14/1 (the 26 Nasrun and Amalrun rows) |
| `ITEM_GDF_SWITCHER` | "Flags! (Gold Dragon Flag, Divine Flag, etc.)" | 3/1/13/4 |

The twin: a token swap of the code name -- `_M_` <-> `_W_` / `_F_`, a trailing `_M` <-> `_F` /
`_W` -- that exists with the same TypeIDs and the other ReqGender (1 a man's, 0 a woman's).
MEASURED over the archive: 506 of 519 hats, 440 of 454 dresses, 334 of 341 attachments, all 40
flags and all 26 spirits have exactly one; none has two; the 24 avatar rows whose OrgObjCodeName
names a twin name the same one. The rest (the male-only SHOGUN, the female-only NINJA, ...) are
refused: "that item has no version for the other gender". The instance is kept (an awakened
spirit keeps its expiry).

### The weapon type switchers ("Item Switcher (to Blade)" ...)

Restriction: "This scroll works ONLY on Egy A weapons!". The Egy A weapons are the degree-11
Egyptian set A rows: the archive gives `ITEM_<race>_<type>_11_SET_A_RARE` the description key
`SN_ITEM_EGYA_TT_DESC` (MEASURED: exactly those 16 rows, 14 weapons and 2 shields), and
`_11_SET_A` is the unsealed copy. OpenSRO takes a weapon (3/1/6) whose code is
`ITEM_(CH|EU)_<type>_11_SET_A[_RARE]` and makes it `ITEM_<tool's race>_<tool's type>_11_SET_A`
with the same seal, which must exist as 3/1/6/<the type> of the same ItemClass. Kept: the plus,
the blue options, the variance, the advanced elixir; the durability keeps its share of the new
maximum. The description names no race rule, so a China weapon may become a Europe one (OURS).
A weapon already of the type is refused. The two shield switchers are not sold and stay refused.

| Tool | TypeID4 under 3/1/6 |
|---|---|
| CH sword, blade, spear, glaive (TBLADE), bow | 2, 3, 4, 5, 6 |
| EU sword, two-handed sword, axe, dark staff, two-handed staff, crossbow, dagger, harp, staff | 7, 8, 9, 10, 11, 12, 13, 14, 15 |

### The model switchers (`ITEM_MODEL_01..16`)

"Model Switchers change the visual appearance of your desired item ... All model switchers are
VISUAL modifications ONLY! ... Model Switchers can ONLY be used on Degree 11 items!"

**The archive's design (MEASURED).** 1,248 rows `<code>_SWITCHnn` sit beside 64 degree-11 A-grade
bases: the plain `_11_A`, the sealed `_11_A_RARE` and the Egyptian `_11_SET_A_RARE` /
`_11_SET_B_RARE` of the 14 weapons and the 2 shields, nn 01..16 (and 17..23 for the sets). Row nn
draws `<type>_nn.bsr` (the degree's shape; 11 is the Egyptian set's), and its description reads
"Model Switched Item / Model: Degree N / Glow: Default". They are the private server's switch
targets. But they are not the same item: their prices are 15 x the base's (250,000 -> 3,697,666),
their CanDrop differs and the Egyptian shields' defences are doubled -- so becoming one would
change the item's stats and price, which the description forbids.

**OpenSRO (OURS): a per-instance model.** The item keeps its own row and every stat; its instance
carries `Model` -- the ref id of its `_SWITCHnn` row -- which is what is drawn:

- stored with the instance (`inventory_slots`, `account_storage_slots` and every other bag-store
  table, and `equipment_slots`: column `model_item_id`, 0 the item's own) and carried by every move
  (`inventory.Instance`);
- the owner's bag, warehouse and worn lists carry it in the item-info block's **models block**
  (u16 count, then u32 slot and u32 model per entry; written only when some entry has one, the
  message's last field);
- the owner's client draws its body, paper doll and portrait with the model's row
  (`World3D._display_equipped`) and the tooltip shows the model row's description; from round
  843 the item mall's preview and the skin-change window's preview do too (3a);
- other players' clients are told the model's row in place of the item's id in the spawn record
  (`lookOf`) and the 0x3038 broadcast (`displayRef`): they draw nothing else from it -- the
  model, the glow type (itemoption.txt lists the `_SWITCHnn` rows with types of their own, which
  follow the mesh) and the visual slot, which the row's TypeIDs keep. From round 843 they are
  also told the item's own id (3a), for the glow and seal a twin without rows of its own lacks.

Targets: a weapon or shield (the archive has twins for both; the description says "weapon"),
degree 11 (ItemClass 31..33), with a `<code>_SWITCHnn` row -- an unlocked `_ACTIVE` row uses its
locked row's (OURS: the two differ in requirement, not model). `ITEM_MODEL_11` is "Model Switcher
(Default [D11])": the "reset your weapon's model to its original one" of the description, Model
0. Degrees 12..16 are within the archive's twin range though its item rows stop at degree 11
(ItemClass 1..33). A target without the twin, a Default on an item with its own model, or the
model it already has are refused.

### 3a. The glow and seal of a switched item (round 843)

The user: "when using the model switcher, the seal and + glow/effects need to stay and they
currently don't".

**What the original draws (READ, `equip_glow_seal.md` §1).** The glow and the effects of a worn
weapon or shield are chosen by its RefID and its plus alone (`FUN_00a5f3e0`): the glow type from
`itemoption.txt`, the seal's effects from `itemrare.txt`, the +8 sparkle from
`itemoptionefp.txt`, each keyed by the item's code name. Nothing reads a Rarity, a seal or a
set. So an item drawn as another row glows, or does not, as that row does.

**The cause (MEASURED).** The user's own switched item on prod (read only): character 12's
`ITEM_EU_TSWORD_11_A_RARE_ACTIVE` (62652) +12 with model `ITEM_EU_TSWORD_11_A_RARE_SWITCH13`
(62220). The unlocked row has glow type 4, the three `eternity_11_nova_0N` seal effects and the
`system_enchant_b_01` sparkle; its twin has no row in any of the three tables. The archive's
twins are made from the **locked** Seal of Nova rows (`_11_A_RARE`), which have none either
(`equip_glow_seal.md` §0), and round 838 drew an unlocked item with its locked row's twins. The
census of the twins the mall's switchers reach (nn 01..16 but 11, the Default), against their
base:

| Base | Twins | The twin's tables |
|---|---|---|
| plain `_11_A` | 240 | a glow type and the sparkle, as the base (no seal on either) |
| locked `_11_A_RARE` | 240 | none, as the base |
| unlocked `_11_A_RARE_ACTIVE` (drawn with the locked twins) | 240 | **none; the base has glow, seal and sparkle** -- the bug |
| Egyptian `_11_SET_A_RARE`, `_11_SET_B_RARE` | 240 each | glow type, seal and sparkle of their own (the seal's files as the base's, the scale often the twin's own: 150 against 185 for `ITEM_CH_SWORD_11_SET_A_RARE_SWITCH05`) |

**What a glow type is (MEASURED, `itemtypenumber.txt`).** Types 1-4 have the same colours and
periods at every threshold, and the same textures but for type 1's +9 row (`option_texture20`
where the others use `option_texture14`). They differ in the option texture's scroll: types 1 and
2 scroll (+0.005, -0.005) up to +8 and (0, -0.005) from +9, types 3 and 4 (0, +0.005); and types 2
and 4 set the alpha-test flag. The archive sets it
per mesh: the twins of one model -- plain, locked and the two sets, which draw the same `.bsr`
(240 of 240) -- agree on it in 310 of 330, and a twin's type differs from its base's in 114 of
the 240 plain twins. The plain and the unlocked base rows share it on all 22 bases. The
twins' own description reads "Model Switched Item / Model: Degree N / **Glow: Default**".

**OpenSRO (OURS where the original has nothing).** `CharacterAppearance.glow_sources`:
- a drawn row the tables give any row keeps its own (the plain and the Egyptian twins, as the
  archive draws them: the glow stays, its scroll axis the model's; the set's seal stays at the
  scale the archive gives that model);
- a drawn row with none, worn by an item that has rows (the unlocked Seal of Nova item): its
  seal and sparkle are the item's own (`itemrare.txt`, `itemoptionefp.txt` at the item's scale;
  INFERRED that the base's scale suits the new model -- the archive has no Nova row for it,
  OPEN), and its glow type is the plain twin's of the same model
  (`..._A_RARE_SWITCHnn` -> `..._A_SWITCHnn`, the same `.bsr`), else the item's own;
- a locked item's twin stays plain, as the locked item is (`equip_glow_seal.md` §0).

**Who draws it.** Your body, the equipment window's doll and the portrait (round 838), and now
the item mall's preview and the skin-change preview: both built from `_player_equipped_last`,
the item's own ids, so they showed the item's own model (the mall's preview is a copy of the
Equipment window's dress, READ `0xa617d0` mode 0 in `item_mall.md` §4a, plus included, so it
shows what the window shows: the model, its glow and its effects). Other players: the record and
the 0x3038 name the model's row (round 838); OpenSRO's server adds, OURS:

- **0x3038 `Own`**: after the plus byte, a u32 -- the item's own RefItemID -- when the RefItemID
  is a model switcher's row (`EquipBroadcast.Own`, `switchedOwn`). Every other 0x3038 is retail's
  bytes; a retail client stops after the plus (`FUN_008a9260`).
- **After the spawn record** (0x3015 and the group spawns), one such 0x3038 per switched worn
  item (`look.switched`, `switchedWornFrames`, among the spawn's state frames), since the
  retail record has no room for it.

The client keeps them per player and slot (`World3D._other_fx`; from round 847 the player's
`CharacterLook.own`), clears a slot on a 0x3039 or a plain 0x3038, and redraws the body when one
changes; the crowd's far recipes and kinds carry it too (the item dict's `"fx"`). Tests:
`switcher843_test.go`, `item_switch_glow843_test.gd`.

### 3b. The select screen (round 847)

The user: "the character selection doesn't reflect model changers. Make sure it shows what it's
supposed to show from now on."

**What the original's select screen draws (READ, `character_look.md` section 1).** The 0xB007
record carries per worn item a u32 RefItemID and a u8 plus (at most 9, the job suit's slot 8
among them), and `FUN_0085a580` installs each with `InstallEquipVisual(vslot, id, plus, 0)`,
whose loaded resource gets the glow and the seal's effects from that id and plus
(`FUN_00a60a90` -> `FUN_00a5f3e0`), as in the world; avatars (3/1/13) are attached on top.
So the select screen shows whatever row the record names, glowing as that row glows. The record
has no room for an item's own id.

**The cause (MEASURED in code).** OpenSRO's list builder (`lobbyhandler.go` `record`) named each
worn item's own row (`w.ItemID`): a switched item was drawn as its original model, where the
world, the doll and the previews drew the model (rounds 838 and 843).

**The fix (OURS).**
- The record names the drawn row (`displayRef`), as the spawn record and 0x3038 do.
- The list carries the own ids in a **trailer after the last record**, written only when some
  item is switched: u16 count, then per entry u8 character index, u8 item index, u32 own
  RefItemID (`LobbyResult.appendOwnTrailer`, `LobbyNet._decode_own_trailer`; golden vectors on
  both sides). It is the 0x3038 `Own` of 3a for the list. A retail client reads the records and
  stops (READ, `FUN_0085f840`).
- The select screen builds the record's look (`CharacterLook.from_lobby`, `character_look.md`):
  the twin's mesh, the plain twin's glow type, the unlocked item's own seal and sparkle at its
  plus, as the world draws it.

## 4. Not done here

- The other private-server 3/3/13/8 rows (not sold): `ITEM_MODELSWITCHER_*`, `*_UNLOCK`,
  `ITEM_UPGRADESTONE_*`, the shield type switchers -- refused as before.
- The exchange and stall show an item's own description, not its model's.
- ~~The character select screen draws the item's own row, not its model~~ (round 843's OPEN):
  closed in round 847 (3b).
- The Nova seal's scale on another model (3a): the archive has no Nova row for the twins (OPEN).
