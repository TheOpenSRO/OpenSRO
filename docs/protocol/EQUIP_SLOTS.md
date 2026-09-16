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

Nine records, and **nine is the whole array**: `EQUIP_VISUAL_COUNT == 9`, from two differently
worded asserts in the same file (`CObjCharacter.cpp:1893` `"dwSlotPos < EQUIP_VISUAL_COUNT"` with
guard `8 < dwSlotPos`, and `:770` `"(nEquipSlot >=0 ) && ( nEquipSlot < EQUIP_VISUAL_COUNT)"`).
So the drawn slots are 0..8 — the six armour pieces, the weapon, the shield, and EXTRA.

**The accessories are not drawn, and the client says so directly.** Its appearance installer
(`0x00a61010`) branches on the slot before it touches a model:

```c
if (8 < slot) {                           // 9..12
    if ((slot < 0xd) && (item != 0))
        FUN_00a5ff00(slot, item);         // a separate path
    return 0;                             // no mesh, no visual record
}
// 0..8 fall through to the +0x38 array and the model attach calls
```

`slot < 0xd` is a third independent witness for the 13-slot bound, after the server's equip check
and its resolver.

The client also has its own item-to-visual-slot resolver, `GlobalDataManager::FUN_009db5e0`
(`0x009db5e0`), called from the character-appearance packet parser. It reproduces the server's
`GObjPC::FUN_00496c20` arm for arm — same armour permutation `1→0 2→2 3→1 4→4 5→3 6→5`, weapons
to 6, shields to 7 via `TypeID3 == 4` with `TypeID4` in {1,2}, `TypeID3 == 7` to 8, and the
accessory families 5/12 to 9/10/11 by `TypeID4` 1/2/3. Two binaries, compiled separately,
agreeing on all twelve slots.

**Slot 8 has two names in the client and they disagree.** The debug dump above prints `EXTRA`;
the window artwork is `equip_slot_specialdress.ddj`. The item table settles what is in it — every
`TypeID3 == 7` row is a trade outfit — so `equipment.Slot` calls it `SlotJobSuit`. Recording this
because a later reader finding `EXTRA` in the binary should not conclude the Go name is wrong.

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
