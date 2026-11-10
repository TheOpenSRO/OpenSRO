# A skill's required gear after the cast: passives that stop counting, buffs that end (round 882)

What the original does with a learned passive and with a running buff when the item its skill asks
for is taken off, swapped away or broken. READ is `SR_GameServer.exe` (`s:`) as assembly unless a
line says otherwise; MEASURED, INFERRED, OURS and OPEN as everywhere. The cast-time side of the
same list is in `skill_use_gate.md`; the resists a passive files are in `status_resist.md`.

Implemented in `server/internal/session/gearreqs.go` (the list, the re-check), `passives.go` (the
passives' set), `buffreqs.go` (the buffs' walk, kind 14).

## 1. The list (READ)

A skill row's `reqi` runs fill up to five `[kind, value]` entries at `CRefSkill+0x3a0`; `reqn`
(`+0x3b4`) makes the list ALL-of. Three functions walk it with the same loop: the cast gate
(`Skill_CheckCastRequirement` `s:0x58d480`), the params' own gate at the head of
`ApplySkillParamsToChar` (`s:0x594ac0`, `s:0x594aed..0x594cd5`) and the re-check
(`GObjPC::FUN_0059f0e0` `s:0x59f0e0`). An entry by its kind (the jump table at `s:0x59f3e4`, the
byte map at `s:0x59f3f8`):

| kind | what must be worn | site |
|---|---|---|
| 6 | the weapon slot's item has TypeID4 = value | `s:0x59f1be` |
| 4 | the shield slot's item has TypeID4 = value | `s:0x59f1e0` |
| 1, 2, 3, 9, 10, 11 with value 0 | **all six** body parts (head, shoulder, chest, legs, hands, feet: the table at `s:0xc63f44`) are of that TypeID3 -- the first that is not clears the answer and leaves | `s:0x59f232..0x59f274` |
| the same with a value N | the part at index N has TypeID4 = N; the kind is not compared (no shipped row has one) | `s:0x59f209..0x59f230` |
| 14 with value 1 | the avatar storage's item at index 4, not a devil's spirit whose time is over (round 839) | `s:0x59f276..0x59f297` |

- **What a slot answers.** Each slot is read through a getter -- the weapon's `s:0x4ead40`, the
  shield slot's `s:0x4ead80`, a body part's `s:0x4eadc0` -- that returns TID 0 for an empty slot
  and for an item whose broken flag (`+0x190`, set at durability 0) is set. Nothing else is asked.
  So **a broken item answers no list**, and **an item that fails its own level or mastery
  requirement -- worn, and counting for no stat (round 877) -- still answers**.
- **Any-of and all-of.** Without `reqn` the first entry that holds is enough. With it every entry
  must hold. A list whose five entries are all filled and all hold leaves the loop with the answer
  cleared (`s:0x59f2a9..0x59f2d3`: the count is compared with the index only on the way out through
  an empty entry) -- the engine's own; no shipped row fills five.

## 2. When it is asked, and what it does (READ)

**At the engage.** `ApplySkillParamsToChar` walks the list of a record its owner cast on itself
(context `+0x20` = 1) on a player. A list that fails leaves the record with `+0x10 = 0` and
applies **nothing** (`s:0x594cc7`): no ParamKeeper entry, no `real` resist, no `setv` variable
(`FUN_005a02e0`, the function's last call, `s:0x59692a`). A passive's engage is

- a world entry (`CGObjPC` vslot 391 `s:0x4df9e0` -> `FUN_0059acd0` `s:0x59acd0`, which builds a
  record for every learned Basic_Activity 0 row and hands it to `SkillActionHandler`; the
  handler table's entry 4, `s:0x587260`, is `EngageSkill` `s:0x593540` and the book's insert),
- a revive (`GObjPC::Revive` `s:0x4df290`, the same call),
- the learn of the row (`Skill_HandleLearn` `s:0x59bfe0`).

**The re-check** `GObjPC::FUN_0059f0e0` runs

- after `CGItemEquip::DetachAbilityByItemOptLevel` (`s:0x50f1f0`, at `s:0x50f53f`) changed a worn
  item: an equipment move (a put-on, a take-off, a swap over a worn slot) or an avatar move;
- when `CGObjPC::ChangeItemDurability` (`s:0x4e7100`, at `s:0x4e71a2`) took a worn item (slot
  below 13) to 0 or back from 0.

It walks the book's running records, the self-cast ones whose skill has a list
(`s:0x59f12e..0x59f160`):

| record | list | what happens | site |
|---|---|---|---|
| passive (Basic_Activity 0), `+0x10 = 1` | fails | its `real` entries taken out (`FUN_0059df20`), its `setv` variables removed (`FUN_005a02a0` `s:0x5a02a0`), its ParamKeeper contributions removed (`s:0x4b3660`), `+0x10 = 0` | `s:0x59f324..0x59f37d` |
| passive, `+0x10 = 0` | holds | `ApplySkillParamsToChar` again, `+0x10 = 1` | `s:0x59f2f8..0x59f31f` |
| active buff | fails | ended (`FUN_0059eff0(0)`; its 0xB072 at the book's next update) -- **unless** its Basic_Code holds `SKILL_CH_FIRE_SHIELD_` | `s:0x59f383..0x59f3a8` |

`SkillBook::Update` (`s:0x59bb80`) passes a passive record over, so a passive stays in the book
while it does not count.

Not looked at, ever: a record another character cast (`+0x20` = 2), and a skill with **no list**.
A buff whose skill asks for a weapon only through the cast gate's other branch (the
`ReqCast_Weapon` columns) therefore outlives the swap. A level change and a mastery raise run
neither the gate nor the re-check.

## 3. Which skills (MEASURED: the skill table)

176 of the 783 player passive rows carry a list -- 18 skills:

| passive | list | writes |
|---|---|---|
| Cleric, two defence passives (`GLORYP_PHYSICAL` / `_MAGICAL`) | a whole light-armour set AND a cleric rod (`10:0; 6:15; reqn`) | `defp` |
| Cleric, Charity (`PRAISEP_ABILITY`) | the same | `real`, `reat`, `setv` |
| Cleric, Faith (`PRAISEP_HEAL`) | a whole robe set AND a cleric rod (`9:0; 6:15; reqn`) | `real`, `reat`, `setv` |
| Warrior, `SHIELDP_DEFENSE` / `_BLOCK` / `_CRITICALDOWN` | a one-handed sword (`6:7`) | `defp` / `br` / `dcri` |
| Warrior, `TWOHANDP_CRITICALUP` / `_RETURN` | a two-handed sword (`6:8`) | `cr` / `dmgr` |
| Warrior, `DUALP_ABNORMAL`, `FRENZYA_DEFENSE` | a dual axe (`6:9`) | `real`, `reat` / `defp` |
| Warlock, two `MINDP` passives | a warlock rod (`6:10`) | `defp`, `dru`, `hpi`, `odar`, `hwir`, `setv` |
| Rogue, `BOWP_ABSORB` | a crossbow (`6:12`) | `odar` |
| Chinese `SWORD_PASSIVE` | a shield (`4:1`) | `br`, `dru` |
| three Chinese balance rows | a sword or blade; a spear or glaive or a shield; a bow or a shield | `dru`, `er`, `hr`, `odar` |

The other 607 passive rows have no list and count whatever is worn (the Warrior's three weapon
attack passives among them).

Timed active rows with a list: the Warrior's guard and frenzy buffs (`6:7; 6:8; 6:9`, any of its
three weapons; the damage frenzy `6:8` alone), the Cleric's four blessings (`6:15`), the Wizard's
(`6:11`), the Warlock's (`6:10`), the Rogue's (`6:12; 6:13`, the bow and dagger extremes one
weapon each), the Bard's (`6:14`), the Chinese shield buffs (`4:1`), the Chinese bow and
damage-divide buffs, and the 23 spirit rows (`14:1`). Holy Word and Holy Spell have none.

## 4. MEASURED

A level-109 European, Warrior 110 and Cleric 101, in a +12 robe set, with rank 18 of the
one-handed-sword defence passive (`defp` 224), a rank of the Cleric's light-armour defence
passive (`defp` 168), the damage frenzy (list `6:8`, 900 s), the physical guard buff (list
`6:7; 6:8; 6:9`, `defp` 2118, 45 s) and Holy Word (no list):

| worn weapon | character window phy def | |
|---|---|---|
| none | 2590 | |
| a cleric rod (robe set on) | 2590 | the light-armour passive adds nothing: both of its entries are asked |
| a one-handed sword | **2814** | + 224, at the move |
| a two-handed sword (its own Str / Int options) | 2602 | the 224 gone at the swap; 12 from the sword's options |
| a one-handed sword, read at a login wearing it | 2814 | counted at the engage |

| buff | move | result |
|---|---|---|
| damage frenzy, cast with the two-handed sword | swap to the one-handed sword | ended: its 0xB072 **34 ms** after the move's request, ahead of the move's own answer |
| guard buff, cast with the one-handed sword (phy def 2814 + 2118) | swap to the two-handed sword | stays (2602 + 2118: the passive's 224 gone, the buff's 2118 kept) |
| the same | then swap to a cleric rod | ended: 0xB072 **96 ms** after the request, 57 ms after the move's answer; phy def 2590 |
| Holy Word, cast with the rod | swap to the two-handed sword, then to the one-handed | stays (no 0xB072 in 30 s; its icon kept) |

The two ends differ by the book's update tick: the re-check only marks the record.

## 5. What OpenSRO does

- `gearReqsHold` is section 1's walk over a `gearState` -- the worn, unbroken items' types
  (`wornKindsOf`: every worn item, whether or not round 877 lets it count) and kind 14's answer.
- **Passives.** OURS: OpenSRO keeps no passive records; a character's passives are a computed set
  (`passiveOf`). It is computed over what is worn -- a row whose list fails adds no stat, no
  variable and (at the state roll) no resist -- and forgotten, to be computed again, at each
  moment the engine re-checks (`gearChanged`). The first read after a world entry is the engage.
- **Buffs.** `gearChanged` ends every running buff of the character's own whose list fails
  (`buffReqFails`: not another's cast, not a passive, not a fire shield, not a skill without a
  list) and tells the zone (`OpBuffEnd`) before the move's answer.
- `gearChanged` runs after an equip, an unequip and a swap (`handleEquip` / `handleUnequip`, the
  job suit's two), when a worn item breaks (`wearOneSlot`) and when a broken worn item is mended
  (both repair paths); the avatar moves run the same walk (`recheckSpiritBuffsAfterMove`).

OURS / OPEN:

- The worn items unreadable, or an item with no type data (a row imported before the type
  columns): every equipment entry holds, as before this round (OURS, the cast gate's own
  caution).
- The engine marks the record and the 0xB072 leaves at the book's next update (34 and 96 ms
  MEASURED); OpenSRO sends it at once, before the move's answer.
- A buff restored at a world entry has no row filed for the re-check until it is cast again
  (`rowOf`), so a carried buff is not ended by a later swap (OPEN).
- An ammunition reload into the shield slot runs no re-check (not read in the engine either:
  `AutoReloadMagazine`'s path was not followed; no list asks for ammunition).
- Kind 14 in the params' gate reads another getter (`FUN_004eae20`) than the re-check's avatar
  slot; not followed -- no passive carries kind 14 and the spirits' skills are gated at the cast.
