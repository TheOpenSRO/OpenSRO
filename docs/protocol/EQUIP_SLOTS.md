# Equipment slots

The game's own slot set and order, from `sro_client.exe`, and how this project's
`equipment.Slot` / `EquipmentNet.SLOT_*` numbering follows it.

## The order

The client's equipment window (`FUN_006acb30`, which releases every slot's artwork one after
another) names seventeen slot images in this order:

```
interface\equipment\equip_slot_helm.ddj
interface\equipment\equip_slot_mail.ddj
interface\equipment\equip_slot_shoulderguard.ddj
interface\equipment\equip_slot_gauntlet.ddj
interface\equipment\equip_slot_pants.ddj
interface\equipment\equip_slot_boots.ddj
interface\equipment\equip_slot_weapon.ddj
interface\equipment\equip_slot_shield.ddj
interface\equipment\equip_slot_specialdress.ddj
interface\equipment\equip_slot_earring.ddj
interface\equipment\equip_slot_necklace.ddj
interface\equipment\equip_slot_l_ring.ddj
interface\equipment\equip_slot_r_ring.ddj
interface\equipment\equip_slot_cloth.ddj
interface\equipment\equip_slot_pandernt.ddj
interface\equipment\equip_slot_plag.ddj
interface\equipment\equip_slot_extraneous01.ddj
```

The avatar's equip-visual struct (`FUN_00a5e360`, a debug dump found earlier by its literal
`"HELM [ %d ] [ %d ]"` … `"EXTRA [ %d ] [ %d ]"` format strings and the assert
`"dwSlotPos < EQUIP_VISUAL_COUNT"`) keeps the same order twelve bytes apart: HELM at `0x38`,
MAIL `0x44`, SHOULDERGUARD `0x50`, one the dump skips at `0x5c`, PANTS `0x68`, BOOTS `0x74`,
WEAPON `0x80`, SHIELD `0x8c`, EXTRA `0x98`. The slot the dump skips is the gauntlet — the window's
artwork names it, and the item table's `AA` pieces (TypeID4 5) are what goes in it. An earlier
version of this document guessed at two gaps there; the stride allows only one.

## This project's numbering

`server/internal/equipment.Slot` and the client's `EquipmentNet.SLOT_*` use the game's order:

| Slot | Number | Item table piece (TypeID4) | Model suffix |
|---|---:|---|---|
| Helm | 0 | 1 | `_ha` |
| Mail | 1 | 3 | `_ba` |
| Shoulder guard | 2 | 2 | `_sa` |
| Gauntlet | 3 | 5 | `_aa` |
| Pants | 4 | 4 | `_la` |
| Boots | 5 | 6 | `_fa` |
| Weapon | 6 | family 6 | |
| Shield | 7 | family 4 | |
| Extra | 8 | — | tracked, nothing rendered |

`ArmorSlots` is the six worn slots; `WearableSlots` adds the two held ones. The accessories
(slots 9–16 in the client) are not modelled yet. The starting kit fills mail, pants, boots and
weapon — the table's own `_A_DEF` rows (ITEM_FORMAT.md).

The numbers are on the wire (`EntitySnapshot` carries slot + item id per worn slot) and in the
`equipment_slots` table, and the client's constants mirror them; `TestArmorSlotsRealOrder` pins
them.

## What decides the slot an item goes in

Not the slot the client asks for: the item's own `TypeID3`/`TypeID4` (ITEM_FORMAT.md), which
`equipment.SlotFor` maps as in the table above, and `equipment.Refusal` enforces. A suit asked
into the helm slot is refused with "that does not go in that slot".

## How each slot's item is drawn

By the item's own `.bsr`, not by a bone table here — see ITEM_FORMAT.md. The earlier
`CharacterAssembler.EQUIPMENT_SLOT_BONES` (slot code → guessed bone, with the shoulder piece
landing at the pelvis) is gone; the file names the bone.
