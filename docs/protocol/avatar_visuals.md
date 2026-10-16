# Avatars in the client: what is drawn, the equipment window's avatar view, the grant window

Round 789, lane AC. The wire is docs/protocol/avatars.md (lane AS) and the golden vectors
`client/scripts/net/testdata/avatar_golden.json`; this page is what the client does with it.
Everything is READ from `sro_client.exe` in `/root/opensro-pk3av789/AVATAR_RESEARCH.md` and
`AVATAR_ALCHEMY_RESEARCH.md` (the RE box, 2026-10-16) unless labelled **MEASURED**, **INFERRED**,
**OPEN** or **OURS**. Code: `CharacterVisualChange` (ui/character_visual_change.gd),
`CharacterAppearance` (ui/character_appearance.gd), `AvatarNet` (net/avatar_net.gd),
`AvatarEquipment` (ui/hud/avatar_equipment.gd), `ItemTooltipLines` (ui/hud/item_tooltip_lines.gd),
`GrantMagicAttributeWindow` (ui/hud/grant_magic_attribute_window.gd), `AvatarTables`
(items/avatar_tables.gd).

## 1. Which meshes a character draws (charactervisualchange)

### The table
`server_dep\silkroad\textdata\charactervisualchange.txt`, read from the player's Media.pk2:
`Service, ID, Name, ConditionID, AttachType, Pram1..4, StrPram1..4, Slot, OverlapSlot,
OverlapSlotGroup, Priority, MaterialID, AnimationName, BsrName(M), BsrName(F)` (only Service 1
rows; MEASURED 269 on the box archive). ConditionID 1 is an equipped item keyed by its TypeID
word, 2 an avatar keyed by TypeID word **and** Param7, 3 a skill or state, 4 a second mesh by item
code name, 5 fortress suits, 6 the default wear, 7 timed transforms (c:0x4e9e50).

### The key of an item (c:0x4ec260 -> c:0x4ec170)
- TypeID word: `CashItem | Bionic << 1 | TypeID1 << 2 | TypeID2 << 5 | TypeID3 << 7 | TypeID4 << 11`
  (s:0x48f610, c:0x6abcd0; `ItemTableReader.Item.type_word`).
- An avatar (non-bionic 3/1/13) takes the first ConditionID-2 row with `Pram1 == word` (the cash
  bit included) and `Pram2 == Param7` (itemdata column 130). That the client's ref +0x544 is Param7
  is INFERRED, but **MEASURED** by `client/tools/avatar_probe.gd` on the box archive: 1,347 of 1,355
  avatar ids find a row (13/1 520 of 520, 13/2 454 of 454, 13/3 333 of 341, 13/4 40 of 40); the 8
  misses are attachments with Param7 -1. **An avatar with no row is not drawn at all.**
- Anything else takes the first ConditionID-1 row with `Pram1 == word`. A devil's spirit (3/1/14)
  goes this way and no ConditionID-1 row has its word (MEASURED: 0 of 26), so it draws nothing.
- OURS: an equipped non-avatar item with no ConditionID-1 row (a cash or bionic word) is walked as a
  visual with Slot 0 and Priority 250: it collides with nothing and is drawn, as before round 789.
  Whether retail attaches it is OPEN.
- A wing dress: the ConditionID-4 row of its code name adds the first non-empty of BsrName(M) /
  BsrName(F) as a second mesh (c:0xa5f4f0), which comes and goes with the dress.

### The arbitration (c:0xa611e0, FUN_00a5da10, FUN_004e8750, FUN_004e8f90, FUN_00a5fe00)
Every attached visual is walked in ascending Priority, ties in attach order (worn slots 0..8 in
order, then the avatars), and drawn unless it collides with what is drawn already:

```
occ = 0; lastPrio = 0; groupOverlap = {}
for v in ascending Priority:
    S = occ | OR(groupOverlap[g] for g != v.group)
    conflict = (S & v.Slot) and (v.group == 0 or (S & ~v.OverlapSlot & v.Slot) or v.group not in groupOverlap)
    if conflict and lastPrio <= v.Priority: hidden
    else: drawn; occ |= v.Slot & ~v.OverlapSlot; lastPrio = v.Priority; groupOverlap.setdefault(v.group, v.OverlapSlot)
```

`CharacterVisualChange.arbitrate` is this walk; `CharacterAppearance.arbitrate_wears` runs it on
every build (`_resolve_wears`), so the far recipes, the template look-ahead and `build()` agree.
With the archive's rows (MEASURED values): a hat (Slot 0x0A01, Overlap 0x0200, group 1, prio 70)
hides the helm (0x0801); a dress 0x023E hides mail, shoulders, hands, pants and boots, not the helm;
the hat and a dress coexist; an attachment (0x0500, prio 90) is drawn and a flag (0x0500, prio 110)
is hidden while it is; a 0x063E dress (Slot 0x073E) hides the attachment; the weapon (0x0040) and
shield (0x0080) are never covered by an avatar row; a job suit (prio 10, Slot 0x073F) hides the
armour and avatars it covers.

**Correction to the research:** AVATAR_RESEARCH.md 6.2 says "0x023F/0x063F dresses also hide the
helm". The ConditionID-2 rows for Param7 0x023F and 0x063F have Slot 0x023E and 0x073E (MEASURED,
`awk` over /var/tmp/tables/charactervisualchange.utf8.txt on the box): no helm bit. The code
follows the table, so those dresses leave the helm drawn.

### Default wear (FUN_00a5e010)
Decided from every DRAWN visual's Slot: a dress covering 0x002 and 0x010 leaves no default clothes
under it (`DefaultWear.wear_for`'s `extra_mask`, the drawn avatars' Slot bits).

### The hair under a hat (INFERRED)
How retail removes the base hair is OPEN (nothing but the arbitration reads +0x174). The hat's Slot
holds the hair bit 0x0800 outside its OverlapSlot, so a drawn avatar whose Slot takes 0x0800 hides
the body's hair piece (attachable key 0) through a stand-in block
(`CharacterAppearance.hide_hair_by_mask`, QA `OPENSRO_QA_AVATAR_HAIR=0` turns it off). MEASURED
(`avatar_probe.gd --hats=40`): 36 of the first 40 men's hats that have a row already hide the hair
by their own `.bsr` attachable block; the rule changes the other 4.

### Not built
ConditionID 3/5/7 rows (skill and state looks, fortress suits, timed transforms: their triggers
are OPEN in the research), the animation group (6.5), the alternate set while a CObjTime transform
is on.

### One path for everyone (6.3)
The world's own player, other players (the spawn's avatar block, 0x3038/0x3039 by RefItemID), the
equipment window's paper doll and the select screen (the lobby record's avatars) all build through
`CharacterAppearance.build`. World3D keeps avatars in its slot -> item maps under OURS keys
`CharacterAppearance.AVATAR_KEY_BASE + n` (200..204): the storage slot for the player, the order in
the spawn block or the first free key for others; `build()` reads an avatar from its type, never
its key.

## 2. The equipment window's avatar view (CIFEquipment)

- **Display by type, storage by order** (c:0x6abcd0): GDR_AVATAR_SLOT_01..05 show the hat, dress,
  attachment, flag and devil's spirit (TypeID4 - 1 for 13/x, TypeID4 + 3 for 14/x) whatever
  storage slot 0..4 each sits in; the storage slot is what the wire carries.
- **A drop on the equipment window** (vslot_028 c:0x6ad180, the hovered slot ignored; the research
  names no mode test, so either view): a 3/1/13 whose display window is taken is refused locally
  with `UIIT_MSG_STRGERR_EQUIPITEM`; an attachment with no dress with `UIIT_STT_AVATAR_MAIL_ONLY_WEAR`;
  else 0x7034 type 0x24 to the first empty storage slot (5 when all are full, which the server
  refuses). A 3/1/14 always asks for storage 4.
- **Back to the bag**: an avatar picked up from its window and put down on the bag sends type 0x23
  with the cell clicked (the server picks the first free slot); over the bag window but off a cell,
  the first empty slot is named (OURS).
- **The reply**: NetClient applies 0xB034 to its avatar and bag instances as the client does
  (c:0x87ba20; the dress's sub-op takes the attachment off too) and HudPanels redraws; a refusal is
  routed by what was sent (OURS bookkeeping: a refusal carries no type) and shown with the
  storage-category names in `AvatarNet.MOVE_REFUSAL_KEYS` (0x1806, 0x1809 and 2 have no name READ:
  our own line).
- **The attachment window** greys under a dress whose ChildItemCount (col 159) is 0 (c:0x6ae6a3;
  how a disabled window is drawn is OURS).
- **GDR_AVATAR_SKILL_WND** shows in the avatar view only while a worn non-bionic 3/1/14 has time
  left (c:0x6abde0; the time is the record's period word, INFERRED for SOItem +0x60). Its four skill
  slots stay empty: which skills fill them needs the skill table's +0x61 and +0xfc bytes (OPEN).
- **0x3078 `{u8 3, u8 slot}`** (READ s:0x4bbd60; lane AS sends it when a worn devil's spirit
  expires): the spirit's period word becomes "activated, 0 s left", so the strip hides and the
  tooltip says `UIIT_STT_NASRUN_AWAKE_TIMEOVER`; the item stays in its window.
- **Right click** on an avatar window does nothing, as on a worn slot; on a bag avatar it does what
  the bag does for any item (use, which the server refuses for equipment; a devil's spirit's use is
  its activation). The client's own handler `IFSlotWithHelp::FUN_00676570` was not followed for
  avatars (OPEN 1 of the research).
- **The OURS avatar list** (0x0044 -> 0x0045 = 0x3013's avatar section) is asked for with every
  worn list (`NetClient.list_equipment`), its request naming the character as the bag list's does.

## 3. Tooltips

- **Avatar** (c:0x682410): the name (gold seal / cyan with options / white) and a blank; seal and
  set lines (none on avatars, Rarity 0 MEASURED); `UIIT_STT_ITEM_TYPE` beige; a blank; the
  description and a blank when it resolves; a dress's `UIIT_STT_SILKMALL_ATTACH` +
  `UIIT_STT_AVATAR_WEAR` / `_NOT_WEAR` by ChildItemCount, beige; `UIIT_STT_AVATAR_MAGICOPTION_MAXCOUNT`
  with column 158 and `UIIT_STT_UNIT`, beige; the stat block; the requirements; a blank and the blue
  lines in cyan; the prices. The rent/expiry and socket blocks after them are not built (OPEN).
- **Blue lines of a 3/1/13**: each option's generic line (round 732's formats, and 13/4's own
  `MATTR_STR_AVATAR`/`MATTR_INT_AVATAR` branch) cut before its "(+x%)" -- c:0x6720fe..0x6721ce erases
  from the character before the first '+' to the end, the space before it kept -- then the avatar
  table's line (c:0x669e20 / c:0x66a8c0): `"%s %d %s"` when the PARAM key holds STR or INT or is
  PARAM_HP / PARAM_MP, else `"%s %d%% %s"`, MDIA's unit `UIIT_STT_PROBABILITY`. That the cut needs
  the format's percent (the flag at [esp+0x17]) is INFERRED.
- **Devil's spirit** (c:0x67b460): name, type, description; the ability of (RefItemID, plus) from
  `refabilitybyitemoptleveldata` / `refmagicoptbyitemoptleveldata` (falling back to the highest
  lower plus, FUN_008bf680) in groups BASIC (white), ADD (green), MAGIC (cyan); its own blue options
  under `UIIT_STT_NASRUN_MAGIC_OPTION`; `UIIT_STT_NASRUN_AWAKE_TIME` then the days of Param1 (not
  active), `UIIT_STT_NASRUN_NOT_AWAKE` (Param1 -1), the days/hours/minutes left, or
  `UIIT_STT_NASRUN_AWAKE_TIMEOVER`. The Nasrun formats' argument order is INFERRED (research OPEN 2).

## 4. The grant window (CIFGrantMagicAttributeWnd)

- Opened by the blacksmith's talk line kind 0x2f: `0x7046 {npc, 0x20}`, and `0xB046 {1, 0x20}`
  shows `GDR_GRANT_MAGIC_ATTRIBUTE` (ginterface.txt, under `APPLY_AVATAR_SYSTEM`, which
  `config\define.txt` defines -- MEASURED) built from `resinfo\ifgrantmagicattributewnd.txt`'s
  Create and OptionList sections and the inventory beside it. Cancel hides it and ends the talk
  (0x704B). The layout is read from the player's Media.pk2 at runtime.
- A bag item put down on it: a non-bionic 3/1/13 that is not a 13/4 goes in slot 8, anything else
  gets `UIIT_STT_AVATAR_MAGICOPTION_ONLY_AVATAR`. ID 9 reads "<kind> - <ADD_COUNT>: <n><UNIT>"
  (c:0x8092f0; `UIIT_STT_SILKMALL_HAT` / `_DRESS` / `_ATTACH`, n = col 158 - the option count).
- The rows: the magicoptionassign names of (TypeID3, TypeID4) minus the options the item has (exact
  name), each through the avatar table's line with the magicoption row's column 9 at the item's
  degree (c:0x80a4f7); five shown, 23 px apart; the selected row's bar `interface\guild\
  gil_bar02_select.ddj`, the others `gil_bar02_deselect.ddj` (paths READ in the binary's strings).
- Confirm sends 0x34A9 (bag slot + 13, the MATTR code) unless the count has reached col 158
  (`UIIT_MSG_AVATAR_MAGICOPTION_ADD_ERORR`); 0x34AA replaces the bag item, drops the granted row and
  shows `UIIT_MSG_AVATAR_MAGICOPTION_ADD`; a refusal shows its category-0x20 name
  (`AvatarNet.GRANT_REFUSAL_KEYS`) -- in the system line (OURS: the error box is not built).
- OURS: the list scrolls with the wheel (the scroll manager's bar is not built); the window is
  placed as HudPanels places a panel; whether the class draws CIFMainFrame's caption and close
  button is not READ (the registry frame's chrome is drawn).

## 5. The alchemy window

An avatar is refused as the target with `UIIT_MSG_ENCHANT_LOAD_EQUIP_FIRST` (index 8, round 768
already); round 789 adds the devil's spirit whose Param2 (col 120, ref +0x2b8) is 0 with index
0xe, `UIIT_STT_NASRUN_EVENTNASRUN_NOT_UPGRADE` (c:0x578bb0..0x578c11). The avatar enchant does not
exist in the client (no 0x34A7 sender, no 0x34A8 handler).
