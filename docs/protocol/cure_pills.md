# The cure pills (round 786)

The universal pills and the purification pills, read in `SR_GameServer.exe`; the census MEASURED
on the box's own itemdata (the 63 `ItemData_*.txt` its `itemdata.txt` lists, exported by
`cmd/export-refdata`). Code: `server/internal/session/curepill.go`,
`server/internal/statuseffect/cure.go`.

## The dispatch

`CGItemExpendable::DoJob` (`0x49aca0`) case 2 (TypeID3 2): TypeID4 7 (`(tid & 0xf800) == 0x3800`)
goes to slot 327 (vtable `+0x51c`, the pets' path), every other TypeID4 to slot 308 (`+0x4d0`,
`0x49b710`), the recovery potions' slot. Item_HandleUseItem has asked the item's COOLTIME before
(the item cooldown map, `ItemCooldowns::IsReady` `0x64c040`).

Slot 308's TypeID3-2 branch (`0x49b765..0x49b897`):

1. **The kind lock.** `GObjPC::FUN_004eb410` (`0x49b779`): TypeID3 2 maps TypeID4 1 to bit
   `0x100` and every other kind to `0x40` (`0x4eb49b..0x4eb4ab`) and answers whether the bit is
   clear in the BYTE at `[pc+0x30]+8` (`0x4eb42b movzx`). A set bit is 0x185b and the pill is kept.
   Bit 0x100 is outside that byte, so **the purification pill's kind lock never refuses** (the
   engine's own quirk); its reuse is its COOLTIME.
2. **TypeID4 1 (purification):** `FUN_004a56c0(holder, 0, 0, curl, rcur)` with
   `curl = {Param1, Param3, Param2}` -- mask, chance, level cap -- and `rcur = {1}`
   (`0x49b7f4..0x49b85d`). Delay float32 20.1 (`.rdata 0xb461b4`).
3. **Any other TypeID4 (universal):** `FUN_0049ac50` copies Param1..6 (`+0x2a0`, `+0x2c0`,
   `+0x2e0`, `+0x300`, `+0x320`, `+0x340`) and `FUN_004a56c0(holder, that block, 0, 0, 0)`
   (`0x49b7bd..0x49b7d8`). Delay float32 1.1 (`0xb461b8`).
4. `FUN_004e0ab0` arms the lock (`0x49b884`) and the answer is 1 (`0x49b88c`): DoJob spends the
   pill whatever it cured.

## FUN_004a56c0(holder, elem6, curt, curl, rcur)

(`0x4a56c0..0x4a59cb`; round 785 read it for the skills, which pass `elem6 = 0`.)

- **Candidates:** each active slot whose bit (`MaskForSlot`, the table at `0xc63ec8`) is in
  `curl[0]` (tested first), else in `curt[0]`, else -- with `elem6` given -- any slot 0..5, the
  elemental six (`0x4a573e`, `0x4a5744 cmp bl,0x5`).
- `rcur`: the list shuffled (`0x4a6560`) and cut to `min(n, rcur[0])`.
- **curl:** chance `curl[1]`, divided by `(level - curl[2])` when the state's level (+0x18) is
  above `curl[2]`; a roll that comes up (`0x5a1a20`) ends it.
- **curt / elem6:** strength `curt[1]` (a WORD) or `elem6[slot]` (the jump table at `0x4a59d0`; a
  zero skips the slot); `0x410b40(slot, strength)` -- the slot's duration unit x the 16-bit
  strength -- is taken off the state's start; a zero move skips the slot; the state ends when
  `now - start > duration` (`0x4a590b cmp`, `0x4a590e jbe` keeps it). **Round 786 corrected round
  785's `>=`.**
- The mask is rebuilt and sent (`0x4a5c60`) when any start moved or any state ended.

The function walks only the 32 abnormal-state records (`holder+0xc`, stride 0x70): a buff record
(a skill's buff, a Warlock or Bard debuff kept as a buff) is not touched by any pill.

## The census (MEASURED, 18 rows of TypeID 3/3/2)

| rows | TypeID4 | Params | what slot 308 does | OpenSRO |
|---|---|---|---|---|
| ITEM_ETC_CURE_ALL_01..05 (55-59), _05_EVENT (57821) | 6 | 36 / 68 / 108 / 172 / 228 / 228, all six equal | universal: each elemental state wound back by Param x its unit (freeze 97 ms, frostbite 250, burn and zombie 750, shock 500, poison 1000); no level cap; lock 0x40, 1.1 s | used |
| ITEM_ETC_CURE_RANDOM_01..04 (10374-10377), _04_EVENT (57822) | 1 | mask 0x17fafc0, cap 3 / 6 / 9 / 12 / 12, chance 100; COOLTIME group 0xC8, 20000 ms | purification: one random held state of the mask ended -- sleep, root, slow, fear, myopia, bleeding, dark, disease, confusion, decay, weakness, powerless, dissociation, panic, combustion, incubation (bits 6-11, 13, 15-22, 24; not stun 14, nor the elemental six) -- at 100 %, or 100 / (level - cap) above the cap | used |
| ITEM_QNO_TQ_MAGICPOWDER_3_02 (10537) | 1 | the same mask, cap 9, chance 100, no COOLTIME | the purification branch | used |
| ITEM_COS_P_CURE_ALL_01..02 (9226-9227) | 7 | 36 / 68 | slot 327, the pet's states | refused, OPEN (no pet states) |
| ITEM_MALL_CURE_SUPERSET_1..4_BAG (29414-29417) | 8 | all -1 | DoJob sends it to slot 308's universal branch; whether Item_HandleUseItem opens a bag first was not read | refused, OPEN |

`TestRound786EveryCurePillRow` (`OPENSRO_ITEMS_CSV=<export>`) runs every row through the handler
against a character holding all six elemental states and five others: 6 universal, 6
purification, 6 refused, all as the table says.

## OpenSRO

- The universal pill's sixth Param (`+0x340`, itemdata column 128) is exported since this round
  (`refdata.Item.Param6`, CSV column 88, `items.param6`): **an older export or database cures no
  zombie** until it is re-exported and re-imported.
- The client shows the icons clearing from the OpObjectStatus the cure sends, and the count from
  the use's reply (`Remaining`, the bag relisted).
- OPEN: the chance-memory dice for the curl roll (`0x5a1a20` with key `0x1a000000`); OpenSRO rolls
  the plain dice -- moot for every real pill, whose chance is 100.
