# Real equip-slot names and order (from `sro_client.exe`)

This project's own equip/unequip system (`server/internal/equipment`) previously had just two
slots, `SlotWeapon` and a single catch-all `SlotArmor` covering a whole fixed 6-piece set at once
— an own design choice, not informed by any real data, since none had been found. It has since
been replaced by a real, decompiler-confirmed 8-slot layout.

## How this was found

Searching `sro_client.exe` for equip-related strings turned up a real, literal debug-print format
string block: `"HELM [ %d ] [ %d ]"`, `"MAIL [ %d ] [ %d ]"`, `"SHOULDERGUARD [ %d ] [ %d ]"`,
`"PANTS [ %d ] [ %d ]"`, `"BOOTS [ %d ] [ %d ]"`, `"WEAPON [ %d ] [ %d ]"`,
`"SHIELD [ %d ] [ %d ]"`, `"EXTRA [ %d ] [ %d ]"`, alongside real assert strings
`"dwSlotPos < EQUIP_VISUAL_COUNT"` and `"(nEquipSlot >=0 ) && ( nEquipSlot < EQUIP_VISUAL_COUNT)"`
confirming these are slots in one real bounded array, not incidental strings.

Decompiling the one real function that references all 8 strings (`FUN_00a5e360`, a real debug
dump of an "Avatar" equip-visual struct) confirmed both the **real order** and that each slot
reads from its own real, fixed struct offset:

| Real slot name  | Struct offset (`param_1 + `) |
|------------------|------|
| `HELM`           | `0x38` |
| `MAIL`           | `0x44` |
| `SHOULDERGUARD`  | `0x50` |
| *(gap: two unlabeled slots at `0x5c`/`0x64` — this debug function skips them, but the fixed
  12-byte stride between every other entry means real slots likely exist there too; not named by
  any string found, so not claimed here. Revisited once, specifically looking for a real
  glove/gauntlet/cloak name that might explain `aa` (forearms) or these two gaps — searched
  `sro_client.exe` for `GLOVE`, `GAUNTLET`, `GLOVES`, `CLOAK`, `CAPE`, `MANTLE`, `ARM `, `BRACER`;
  none exist, and no other candidate label strings sit adjacent to the known 8. Real, confirmed
  dead end, not further pursued.)* | |
| `PANTS`          | `0x68` |
| `BOOTS`          | `0x74` |
| `WEAPON`         | `0x80` |
| `SHIELD`         | `0x8c` |
| `EXTRA`          | `0x98` |

## Mapping to this project's existing real body-part rendering

Five of these eight real names map directly, by real-world meaning, to bone slot codes
`CharacterAssembler.EQUIPMENT_SLOT_BONES` already uses (found independently, via a real
triangle-centroid-X gap scan on `clothes_03_*.bms` — see `docs/PROGRESS.md`):

| Real slot (this doc)  | `CharacterAssembler` code | Real bone(s) |
|------------------------|---------------------------|--------------|
| `HELM`                 | `ha`                      | `Bip01 Head` |
| `MAIL`                 | `ba`                      | `Bip01 Spine1` |
| `SHOULDERGUARD`        | `sa`                      | `Bip01 R/L Clavicle` |
| `PANTS`                | `la`                      | `Bip01 Pelvis` |
| `BOOTS`                | `fa`                      | `Bip01 R/L Foot` |

`CharacterAssembler` also has a 6th real code, `aa` (forearms, `Bip01 R/L Forearm`), that has **no
confirmed real slot name** from this debug function — plausibly one of the two unlabeled gap slots
above, but not confirmed, so this project doesn't claim which. `WEAPON` already matches this
project's existing `SlotWeapon`.

`SHIELD` also now renders: real, faction-wide shield item meshes were found under the same real
`Prim\Mesh\Item\China\weapon\` folder as weapons (e.g. `shield_11.bms`, confirmed real via a
matching `material_name`-to-layer-name pair against `shield_11.bmt`, the same real technique used
for weapons), and attach to a second real, directly-confirmed bone: `Bip01 L Hand` — the off-hand
counterpart to `WEAPON`'s `Bip01 R Hand`, found the same way (pulling a real skeleton and locating
the exact string). `EXTRA` is still a real, tracked slot with no rendering wired up yet — no real
"extra" cosmetic-item convention has been investigated in this project.

## What changed

`equipment.Slot` now has one real constant per confirmed slot (`SlotWeapon`, `SlotHelm`,
`SlotMail`, `SlotShoulderGuard`, `SlotPants`, `SlotBoots`, `SlotShield`, `SlotExtra`) instead of a
single `SlotArmor`. `EntitySnapshot` broadcasts a real per-slot armor bitmask (which of
`HELM`/`MAIL`/`SHOULDERGUARD`/`PANTS`/`BOOTS` are actually equipped) plus separate `HasWeapon`/
`HasShield` bools, instead of one flattened `HasArmor` bool, and `World3D.gd` renders exactly those
real pieces per character rather than an all-or-nothing bundle. `aa` (forearm) pieces render
whenever `MAIL` (body) is equipped, since that's the one real slot this project's fixed
`clothes_03` set's `aa` piece was always bundled with before this change, and no more precise real
mapping is confirmed.

`EXTRA` is tracked (equip/unequip work, broadcast isn't extended to it since there's nothing to
render) but not otherwise wired into gameplay yet — real, honestly incomplete, not guessed at
further.

## `EXTRA` rendering: investigated, real dead end (no shipped mesh)

Looked for what `EXTRA` might really render before giving up on it. Found a real, genuine
cosmetic-item system separate from armor: `Media.pk2` ships `resinfo\avataritemdata.txt`, a real
tab-separated (UTF-16) item registry with exactly 4 real rows:

```
1  ITEM_MALL_AVATAR_M_ANGEL_WING_DRESS   avatar_wing  res\item\avatar\avatar_m_angel_wing.bsr   50
1  ITEM_MALL_AVATAR_W_ANGEL_WING_DRESS   avatar_wing  res\item\avatar\avatar_w_angel_wing.bsr   50
0  ITEM_MALL_AVATAR_M_DEVIL_WING_DRESS   avatar_wing  res\item\avatar\avatar_m_devil_wing.bsr   50
0  ITEM_MALL_AVATAR_W_DEVIL_WING_DRESS   avatar_wing  res\item\avatar\avatar_w_devil_wing.bsr   50
```

Real, dedicated UI exists for it too (`interface\equipment\equip_slot_avata_button.ddj`, distinct
from the plain `equip_slot_equipment_button.ddj`), plus real icons under `icon\item\avatar\` and
`icon64\item\avatar\` (wings, hats, festival costumes, etc. — more items than the 4-row registry
covers, so the full mall-avatar catalog is larger than what this client build's `resinfo` lists).
This is a real, cosmetic, non-armor overlay item category — plausibly what `EXTRA` is for.

**But the actual `.bsr` mesh files the registry points to (`res\item\avatar\avatar_*_wing.bsr`) do
not exist anywhere in this client build's `Media.pk2`** — checked directly, only the icon files
ship, not the meshes. Real system, real data file, real UI slot, but no asset to render. Confirmed
dead end for this client's data — not pursued further, since there is nothing real to build
against.
