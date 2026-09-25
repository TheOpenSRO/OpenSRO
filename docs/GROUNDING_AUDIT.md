# Grounding audit — is the inferred game functionality real or assumed?

**Date:** 2026-09-11. **Asked for:** a check that every piece of code imitating real game
behaviour (formulas, curves, constants, mechanics) traces back to the real client — Ghidra
decomp, reverse-engineering, or a real data file — and that nothing assumed is dressed up as
recovered.

**Scope.** Game *mechanics and data* — combat, EXP/levelling, stats, drops, skills, prices,
quests, NPC placement/behaviour, item data, character scale, the level-up effect. **Not** in
scope: the file-format readers (`bms`/`bsr`/`ddj`/`nvm`/`mapm`/…), which are grounded by
construction — they parse real bytes and are validated against real files in
`docs/protocol/*` — and the client's own engine/UX tuning (camera feel, network send rate,
interpolation), which is legitimately this project's own client, not a claim about a real value.

## How each item is classified

- **RECOVERED** — traced to the real client with a citation: a real data file, a `docs/protocol`
  spec, a `docs/WORLD_ISSUES.md` round, a `server/cmd` scan tool, or Ghidra. Grounded.
- **OWN-DESIGN (disclosed)** — this project's own mechanic/value, honestly labelled as *not* from
  the client. Allowed by the rules; listed here so there is a single place that says "these are
  ours, not the game's."
- **BEHAVIOUR ASSUMPTION** — a rule layered on top of recovered data that is reasonable but *not*
  itself confirmed against the real client. The closest thing to "assumed," and the actionable
  part of this audit.
- **FLAG** — a comment or value that reads as more grounded than its evidence supports. Corrected
  as part of this audit (see the last section).

## Open item added 2026-09-16 — CLOSED the same day

**A character's Str and Int rise by 1 each per level, automatically.** Implemented
in v0.1.239: `SetLeveling` now carries Str and Int, both stores persist them, and
the level-up applies `character.StatGrowthPerLevel` per level gained. A level-40
character has Str 59 rather than 20, and roughly three times the health it had.
The text below is the original entry, kept for the reasoning.

**A character's Str and Int rise by 1 each per level, automatically, and srrevamp
did not model it.** `GObjPC_SetLevel` calls `SpendStatPoints(levels, levels)`
immediately after granting the pool, which adds to charData `+0x74` and `+0x76`.
srrevamp keeps Str and Int at `StartingStr`/`StartingInt` for a character's whole
life and accumulates the three spendable points without spending them.

The consequence is not cosmetic: `MaxHPFor` is `Str × 10 × 1.02^(level−1)`, so a
level-40 character here has roughly a third of the health the real game gives one.
This is a schema change (Str/Int must travel through `SetLeveling`) and a large
balance change, which is why it is filed here rather than folded into the tick
that found it.

## The starting-stat absence, measured 2026-09-16

`StartingStr`/`StartingInt` (20 apiece) are OWN DESIGN, and the audit closed the
whole character-creation category on one binary's silence — `SR_GameServer.exe`
writes no constant to charData `+0x74`/`+0x76`, because creation happened on the
AgentServer. That reasoning is sound but it is a negative from a single artifact,
and since `StatGrowthPerLevel` shipped these two numbers multiply at every level.

Three artifacts were asked, and the absence holds in all three:

| asked | answer |
|---|---|
| characterdata's player rows | 78 rows match `CHAR_(CH\|EU)_(MAN\|WOMAN)`; **0 carry a non-zero MaxHP**. No bare `CHAR_CH_MAN` row exists — the player rows are class/appearance variants. |
| the client's creation screen | `UIO_NEWCHAR_*` strings are race, gender, class and explanation text. It previews an appearance, not a stat line. |
| `LevelData.txt` | nine columns, none a stat. |

So the value stays own-design with a stronger reason. Recorded because an absence
inferred from one artifact and an absence measured across three are different
claims, and this project has been bitten by the first kind.

## Headline

**No invented value dressed as real was found.** Across every mechanics package audited, each item
is either recovered with a real citation or honestly disclosed as own-design — including packages
that document the RE *dead-end* that forced an own-design fallback. **Two of those dead-ends have
since been reopened and are now real**, which is the pattern worth noting: a dead-end is a
statement about the tools available at the time, not about the data. Skill damage was recorded
here as unrecoverable ("all 118 `_RefSkill` columns catalogued, none encodes a damage value") —
true of the *columns*, but the damage was in the Param block all along, and decompiling the
server's parameter parser decoded it (2026-09-14). The other:
**shop prices are now REAL** — the client's own itemdata carries `_RefObjCommon` Price and SellPrice
columns (a Copper Sword buys 890, sells 427), which the DB export had dropped and the audit had
concluded absent; the own-design stat formula is now only a fallback. What genuinely exists is a
short list of **behaviour assumptions**
built on recovered data, mostly disclosed, plus **one client comment that overstated its grounding**
(the attack-combo order), now corrected.

## Server — mechanics

| Item | Status | Evidence / disclosure |
|---|---|---|
| EXP curve (exp-to-next per level) | **RECOVERED** | `leveldata.txt` col 1; level 9 = 17978 matches a real character window. Pinned in `leveldata`/`export-leveldata` tests. Imported at runtime (game data, not committed). |
| Stat points = 3 / level | **RECOVERED** | Real window showed Stat Point 24 at level 9; (9−1)×3 = 24. `docs/LEVELING.md`. |
| Item stats (`refdata.Item`) | **RECOVERED (schema) + BYO (values)** | Curated subset of real `_RefObjItem` (~105 cols), `docs/protocol/refdata_schema.md` + `ITEM_FORMAT.md`. Values imported from the operator's own export; none committed. |
| Skill table (`refdata.Skill`) | **RECOVERED (schema)** | Curated subset of real `_RefSkill` (118 cols confirmed). |
| Skill **damage** | **RECOVERED (2026-09-14)** | The skill's own `'att'` parameter. Skill parameters are `(code, values…)` runs in the Param block, the code being a C multi-char literal stored as a big-endian int; the server's parser `FUN_00587630` compares against those literals and gives each code's run length, so `'att'` (0x00617474) is a fixed six-word run. Values are (type, percent, min, max, percent): across `SKILL_CH_SWORD_SMASH_A` levels 1–5 the percent holds at 143 while min/max climb 15–18 → 29–35, and a plain swing (`SKILL_CH_SWORD_BASE_01`) is 60 % with no flat damage. So a cast deals a percentage of weapon damage plus a flat roll. `skillDamageBonus`; the old per-level stand-in survives only as the fallback for skills with no `'att'`. **NARROWED 2026-09-18:** the fallback no longer applies to the 1,797 real skills (5.6%) that carry no combat parameter at all. `Combat_ResolveDamage` (0x0058e5f0) returns before resolving anything for those, so they now deal nothing rather than `level * 4` — see `refdata.Skill.NoCombatParam` and `skillparam.CombatParameters`. **WIDENED the same day:** `local_d0 == 1` was read and zeroes BOTH halves of the blow, so the rule is simply *no `'att'` and no `'ck'` means zero damage* — 2,482 rows, containing the 1,797. The disclosed constant now applies to 1,526 real rows only: 1,265 whose Param block stops at a variable-length code and cannot be decided, and 440 carrying `'att'` with a percent of 0, whose engine behaviour has not been read. See `refdata.Skill.ZeroDamage`. **CLOSED the same day:** the 1,526 are all decided now. The 440 zero-percent rows are FLOOR blows -- the mitigation formulas multiply by the percent with no guard, and `Combat_ResolveDamage` floors a computed zero at 1 (`refdata.Skill.FloorBlow`, 446 rows with the two sibling cases). The 1,265 "undecidable" rows fell to a sound inference: a code word absent from the WHOLE row cannot be in the block, which proves 1,085 of them zero-damage, and the other 180 all carry `'att'`. The three classes partition all 33,632 rows and the disclosed constant reaches **none** of them on a fresh export -- it survives only for an export predating these columns and for the own-design `skill.Catalog`. |
| Mastery level-up SP cost | **RECOVERED (2026-09-14)** | **leveldata column 2**, at the mastery's current level. Found by following the spend rather than the field: `charData+0x80` is only touched directly by a packet builder and the kill reward because the raise handler goes through the skill-point adder `FUN_004e4c60`, which is itself virtual (vtable slot 93 = offset 0x174, right after exp-gain at 92). Two of that slot's callers pass a **negative** delta; one is `FUN_0059c4e0`, the mastery level-up: it walks the levels being raised, accumulates the level table's `entry+0x10` for each, and refuses with error 0x3802 when the character's skill points fall short. A level entry holds the int64 EXP requirement at +8, so +0x10 is the field straight after — column 2: 1, 1, 1, 2, 2, 4, 5, 6, 7, 9, 12 … 53 at level 20, 172 at level 32 (the leading run of three 1s re-read from the player's `leveldata.txt` in round 518; it had been written with two). `leveldata.Table.MasteryUpCost`; the old disclosed `currentLevel+1` remains only as the fallback when no level table is loaded. **Two levels cost 0 whatever the table says (round 484):** level 0 (the first point: `test cl,cl` at `0x59c628` sends it to the level setter, past the loop and the `0x3802` check) and anything above 120 (the loop's `cmp esi,0x78 ; jg` at `0x59c64e` breaks before summing). `session.masteryUpCost` applies both. |
| Drop schema (`refdata.MonsterDrop`/`DropGroupEntry`) | **RECOVERED (schema)** | Real `_RefMonster_AssignedItemRndDrop`/`_RefDropItemGroup`; `refdata_schema.md`. |
| Starter-kit item IDs | **RECOVERED** | The item table's own `_A_DEF` code-name marks starters; real rows (3643–3645 / 3652–3654 / 3632). Two picks (garment family, sword) **disclosed** as this project's, because the original chooses by creation-class the server doesn't record. |
| Monster identity — CodeName, Level, Rarity, Name (`MOB_CH_*`) | **RECOVERED** | Real `characterdata` (`_RefObjChar`): CodeName is the row key the model resolves by; Level is col 57, Rarity col 15, and the English Name is `textdata_object`'s resolution of the row's `SN_` key. Re-verified 2026-09-13 for the whole 11-species Jangan ladder (levels 1–10 + Earth Ghost 27) — every CodeName, level, rarity 0 and name matched real data. |
| Combat damage model — **mitigation SHAPE recovered (2026-09-15)** | **PART RECOVERED** | The shape was wrong, not just the numbers. `Formula_MitigatePhysicalDamage` (`0040e450`) and its magical twin (`0040e830`) — structurally identical, gated on bits 4 and 8 of the flags at `+0x230` — compute **`damage = raw / (1 + reductionPercent/100) − flatAbsorb`**, floored at 0, with the reduction read as ParamKeeper param 7 (physical) or 8 (magical) and the constants 1.0 / 100.0 at `.rdata 0x00b45ac0` / `0x00b45af0`. **Which side owns the reduction is settled by the formula's own monotonicity**, not assumed: a larger param 7 yields *less* damage, so it cannot be the attacker's. `combat.MitigateDamage`. The monster's percentage is REAL — `characterdata` cols 73/74 are the physical and magical reduction and both equal the monster's level on every row of the **original client's** table (Mangyang 1, Gyo 5, Yeoha 10, Bandit Archer 12). Still disclosed: the flat `Defense` term, the floor of 1 (the game floors at 0, but a zero-damage hit there is a *miss* and srrevamp has no hit/evade roll), and the player's own reduction percentage. **That last one is now SETTLED (2026-09-15): a player's percentage is ZERO, and recovered as zero rather than assumed.** Param 7 has exactly three writers and none can set it for a player. `Char_PublishCombatStats` (`00497830`) publishes it from a float in the `_RefObjItem` defence block — and a census of all **21,560 item rows** finds no percentage-reduction column populated anywhere. The skill-effect applier (`00594ac0`) reaches it only through the skill param code **`'ar'`** (`SkillGlobal::RefSkill_ParseParams`, `00587630`, writing `skill+0x268` as a 3-word run), and `'ar'` appears on **zero of the 29,342 real skill rows** — the single numeric match is a skill's own id column. `GObjMob_PublishStats` is mobs only. The two defensive skill codes that ARE live go elsewhere: `'defp'` (273 skills) writes params 5/6 at slot 0, the FLAT absorb, and `'defr'` (4 skills) writes them at slot 1, a percentage boost to that flat term. So the asymmetry this project already had — monsters carry a percentage, players do not — is the game's own, and `session.playerMitigationPercent` now states it as an explicit cited 0 routed through the same `combat.MitigateDamage`. |
| Weapon damage is **rolled in [min, max]** | **RECOVERED (2026-09-15)** | srrevamp always swung for `PhysAttackMax`. `Formula_RollWeaponDamage` (`0040f8d0`) and its twin for the other damage type (`0040f930`) are three lines each: `min = GetParam(191); max = GetParam(190)` (193/192 on the twin), `if max-min < 1 return 0`, `rand() % (max-min+1) + min` — inclusive at both ends. `Char_PublishCombatStats` publishes 190/191 and 192/193 as the two types' pairs, and this project already loads both ends from the client's own itemdata (cols 12-15). `combat.RollDamage`. |
| **`/(1 + p/100)` is the engine's universal opposed-stat idiom** | **RECOVERED (2026-09-15)** | Not a quirk of the damage formula — the same divisor appears at least three independent times: damage mitigation by params 7/8, a blow's **critical** value divided by the defender's `'evcr'` (param 57), and its **block** value divided by `'evbl'` (param 56), all inside `Combat_ResolveDamage` with the same 1.0/100.0 constants. Worth knowing before recovering any further opposed stat: expect a divisor, not a subtraction. |
| Unarmed damage = 5 | **OWN-DESIGN (disclosed; its reason CORRECTED in round 505)** | 5 is the invented ROLL of an empty hand, not the blow. **Round 505 corrected the reason this row gave**: it said an unarmed attack would need a base skill with no weapon type and that the skill table has none. The empty hand's base attack exists — `SKILL_PUNCH_01`, id 1, filed for TypeID4 1 by `SkillGlobal::PostLoadSkillTable` (0x5893e0), requiring weapon code 1 (the bare hand), `att` 5/150/0/0. It is not one of the twelve `_BASE_01` rows, which are all weapon-typed (CH sword/spear/bow; EU sword/tsword/axe/crossbow/dagger/staff/wand×2/harp). What is still not read is the roll that 150% scales: damage reaches the engine as params 190/191 from the equipment aggregate, and what an empty hand puts there is unknown. So 5 stands in for that roll, and since round 505 the plain swing applies the punch's 150% to it after mitigation (`session.plainSwingOf`). **Trap recorded**: characterdata cols 84–86 on a player row are base-attack SKILL IDS (CH reads 2/40/70 = the three CH base skills; EU reads 8419/8420/8421), and `[85]=40 [86]=70` reads like a tidy 40~70 damage range but is not one. |
| Player **MaxMP = Int × 10 × 1.02^(level−1)** | **RECOVERED IN FULL (2026-09-15)** | Supersedes the earlier "growth only" reading. `GObjPC_InitStats` does not compute stats arithmetically — it declares a dependency graph (class `GParamKeeper`, named in its own assert) of 30 edges, and mana is the chain `Int(2) → 53 → 55 → MaxMP(4)`, with `1000.0` (`.rdata 0x00b462ac`) in slot 3 of param 53 and `1.02^(level−1)×100` (`0x00b45ea0`) in slot 3 of param 55. The keeper evaluates a node as `slot0×(slot1+100)/100×slot2×slot3/100` (slot 3 defaulting to 100), so the chain collapses to `Int × (1000/100) × 1.02^(level−1)`. **The base was never a constant — it is the stat.** `character.MPBase` is deleted. |
| Player **MaxHP = Str × 10 × 1.02^(level−1)** | **RECOVERED IN FULL (2026-09-15)** | The same graph, chain `Str(1) → 52 → 54 → MaxHP(3)`. Two layers had to come off first: the parameter's identity travels in **DI**, which Ghidra never assigned to an argument (so all 297 call sites decompiled to `SetParam(slot, 0, value)` with the identity silently gone), and the callers materialise each id through **chains of LEAs** off a neighbouring constant rather than a `MOV`, so there was nothing to grep. `client/tools/ghidra/ResolveRegArg.java` resolves both and writes the ids back as comments, so the dump now carries them inline. The ids are pinned by use-site, not shape: 3/4 are MaxHP/MaxMP because `GObjMob_PublishStats` pushes `refobj+0x19c`/`+0x1a0` at them and `+0x19c` is the field `RefObjChar_ExtractData` asserts `m_dwMaxHP > 0` on; 0/1/2 are Level/Str/Int from `charData+0x65/+0x74/+0x76`, with 0 confirmed a second time by the monster path pushing its level virtual at the same id. **Starting Str/Int = 20 remain own design, disclosed** — nothing writes a constant to `charData+0x74`/`+0x76` anywhere in the binary, because character creation happened on the database side. |
| Potion restore amount: **HP = Param1 × 1.02^(level−1) × (1 + Str/416)**, MP the Int twin | **RECOVERED and WIRED (round 496)** | `GObjPC::FUN_0049aa70`, read from `srv.asm` because the dump's C drops every x87 instruction: `fdiv QWORD` by the 416.0 at `.rdata 0xb45e98`, 1.02 (`0xb45ea0`, `character.StatGrowth`) raised to `GetLevel − 1` by inlined square-and-multiply, `+1` (`fld1` / the 1.0 at `0xb45ac0`), `fimul` the Param, truncated by `_ftol2_sse` (`0x9fbb40`, `cvttsd2si`). The percentage pair (Param2/Param4 of GetMaxHP/GetMaxMP, the fraction rounded to a float first) is read only when Param1 and Param3 are both zero. `session.potionRestore`; a level-1, 20-Str character gets 125 from HP_POTION_01's 120. **Landed through the queue since round 509**: an absolute amount arrives in five steps of amount/5 -- the first at once, then one per `CGObjPC::PeriodicUpdate` pass (`FUN_0049a0c0` / `FUN_0049a510`, `session.PotionQueue` / `RunPotionQueue`); a percentage amount lands whole at once; the potion is spent even when nothing lands (full HP). **Disclosed, not modelled**: a zombie is hurt by it, and panic/combustion cut it (params 143/144). The per-kind reuse delay (`FUN_004eb410` / `FUN_004e0ab0`) is wired since round 508 -- see the next row. |
| Potion reuse delay: **1.1 s** for an absolute potion (China), **4.1 s** for a percentage one, per recovery kind | **RECOVERED and WIRED (round 508)** | `CGItemExpendable` slot 308 (`0x0049b710`) asks `FUN_004eb410` first: TypeID4 1/2/3 -> bit 1/2/4 (jump table `0x4eb574`), refused with `0x185b` while the bit is set in the byte at `[pc+0x30]+8`, and `DoJob` keeps the refused item. `FUN_004e0ab0` sets the bit after the heal and queues an `AJStateChanger` type-6 record with a float32 `fld DWORD` from `.rdata`: 1.1 (`0xb461b8`, `cd cc 8c 3f`), 4.1 (`0xb461b0`, `33 33 83 40`), 15.1 for a non-China Country (`0xb461ac`, `9a 99 71 41`; unselected, every character is China). The float is SECONDS: `FUN_004065d0` divides the GetTickCount delta by the double 1000.0 at `0xb45c68` before `AJStateChanger::vslot_002` subtracts it, and its type-6 case clears exactly that bit (`0x4060da`-`0x4060e6`). `session.potionReuseBit` / `potionReuseDelay`. **Disclosed, not modelled**: the job manager ticks every 0.3 s (`0xb45b8c`), so retail frees the bit on a tick, and `FUN_004e67b0` clears every bit from `CGObjPC` slots 306/307. |
| Monster **MaxHP** | **RECOVERED (2026-09-14)** | Real `characterdata` col 59. Recovered from the pserver's own `SR_GameServer.exe`: `RefObjChar::ExtractData` deserialises a row into `CRefObjChar`, whose layout runs `uint8 Lvl; uint8 CharGender; uint32 MaxHP; uint32 MaxMP;` at 0x198/0x199/0x19c/0x1a0, and 0x19c is the field the binary asserts `m_dwMaxHP > 0` on. Confirmed four ways against the data (col 57 = the already-verified Level, col 58 = CharGender 1/2, col 59 = MaxHP, col 60 = MaxMP = 0 for every monster). `monsterSpec.MaxHP`. |
| Monster **defence** | **RECOVERED (2026-09-15)** | Both terms. The flat absorption is `characterdata` col 71 (Mangyang 7, Weasel 12, Yeoha 22, Earth Ghost 103) and the percentage reduction is col 73, which equals the monster's level. Settled by disassembling `Formula_MitigatePhysicalDamage` — the decompiled C was unreadable there, x87 juggling having collapsed the expression into a `CONCAT44` — where `PUSH 0x5` feeds an `FSUB` (the flat term) and `PUSH 0x7` feeds `FADD 1.0` then `FDIVR` (the percentage). `GObjMob_PublishStats` publishes cols 71/73 into exactly those params. Values taken from the **original client's** characterdata. `monsterSpec.Defense` + `combat.Monster.DefensePercent`. |
| Monster **attack** | **RECOVERED (2026-09-15)** | A monster attacks with a **skill**, not a weapon, which is why no column and no `GObjMob_PublishStats` push ever held a damage range. `characterdata` col 83 is the species' primary attack skill id, and the ids name the species: `160 = MSKILL_CH_MANGNYANG_ATTACK01`, `165 = MSKILL_CH_GYO_ATTACK02`, `176 = MSKILL_CH_YEOHA_ATTACK01`. That skill's `'att'` param (already decoded by this project for player skills) carries the range, and with no weapon to scale, the grounded formula collapses to `rand(min, max)`: Mangyang 17-19, Weasel 35-40, Yeoha 67-79, Earth Ghost 219-261. From the **original client's** skilldata. `monsterSpec.AttackMin/Max`. |\n| Monster gold | **PART RECOVERED (2026-09-15)** | Range from the **original client's** `levelgold.txt` (level → min → max; L1 = 28-59, L10 = 60-125, L27 = 119-250), rolled per kill. The binary's gold table is the level-table manager's `+0x268` array, identified by use-site: `FUN_009348f0` spawns `ITEM_ETC_GOLD_03` with an amount rolled out of it by `FUN_00724330`, which reads `{chance, min, max}`. **The join is inferred**: nothing proves `levelgold.txt` fills `+0x268`, because the server references no refdata filename at all (it loads from its database). Data real, linkage inferred — said plainly in `combat.RollGold`. Replaces the invented `10 + level*5`. |\n| Monster gold (old) | **superseded** | `cmd/server` `monsterStatsForLevel`: a disclosed curve off the grounded level. No real table for these three has been identified. Rarity multiplies gold only — it no longer touches HP, which is now real. |
| Monster spawn positions (XYZ) | **PART RECOVERED (2026-09-15)** | **Mangyang's are REAL** — its four `npcpos` rows in region 96/168, which are that region's entire npcpos content and all id 1933 (`MOB_CH_MANGNYANG`, the species and its level/HP reached independently). All four were measured walkable before wiring, and the region→world transform they go through is itself measured at eleven columns (`server/internal/worldmap`). The other ten species keep own-design anchors, which are **region 97/168 local (960,1800) and (1300,1300)** — this row said 96/168 until 2026-09-15; the coordinates were right and the region label was wrong, and no local position in 96/168 maps to either. |
| EXP reward per kill | **RECOVERED (2026-09-15)** | **`leveldata` column 5, taken at `min(killerLevel, victimLevel)`.** `Formula_MonsterExpReward` (004105d0) computes `scaleByWindow × levelRecord[+0x1c] × receiver[0x1cd8] × scaleByDiff`, floored at 1, and its result goes to `GObjPC_GiveExp` (vtable slot 421, read out of the vtable at `0x00af6090`). What `+0x1c` *is* was settled by a second, independent use-site: `FUN_00631050` hands `entry[0x1c] × multiplier` straight to `GObjPC_GainExpAndLevel` as an exp amount, no formula in between. That it is **column 5** was settled by elimination rather than curve-matching — column 2 is at `+0x10` (confirmed value-for-value against the real file: 1,1,1,2,2,4,5,6,7,9,12,15), columns 3 and 4 are plain zero integers occupying `+0x14`/`+0x18`, so the next 4-byte field is column 5; every other packing puts a provably impossible value at `+0x1c` (skipping the zero columns lands on column 7, making a level-1 kill worth 15,000,000 exp). **Verified identical in the ORIGINAL client's `leveldata.txt` and the pserver's**, so it is not a private-server edit — only the job-cap columns 6-8 differ. `leveldata.Table.ExpUnit`/`KillExp`. **The minimum-level rule is the important half**: out-levelling a monster, or being power-levelled, pays at the weaker party's rate. **STALE WHEN WRITTEN, CORRECTED 2026-09-20:** both level-gap scalers are RECOVERED and both are applied. `Formula_ExpScaleByLevelWindow` (0x0040fed0) and its classifier `FUN_0040fe60` turn out not to be a mode selector but three comparisons on the gap (`< -3` → 2, `< 11` → 0, else 1), and mode 0 jumps past every arithmetic path, leaving 1.0 — so inside a -3..+10 band the scale really is exactly 1.0, which is most kills. The outer arms are `1 - 0.02*(gap-10)` and `1 - 0.15*(gap-3)` with a flat 0.9 arm, clamped to [0.1, 1.0]. See `leveldata.ExpWindowScale` / `ExpDiffScale`, both called by `KillExp`. **The diff scaler's party gap bonus ships too (round 480)**: `Formula_ExpScaleByLevelDiff` (0x0040ffe0) adds 0.15/0.30/0.45 for a target 5/7/9 or more levels up, but only for a receiver in an exp-sharing party (`pc[0x72e]` non-null and party flag bit 0, the exp-sharing flag per `CParty::CheckCanJoin`) — every srrevamp party is one, so a partied kill earns it and a solo one does not. A party of ONE does not either (round 485): the engine tests the pointer, but only ever creates a party with two members on an accepted invite, so srrevamp's own create-alone path does not earn it; what the engine does when a party drops to one is unread. Its Europe arm (0.30/0.60/0.90, on the ref object's Country byte) is recovered but never selected, because every srrevamp character is China. **CORRECTED round 485:** the `+0x1cd8` factor is the RECEIVER's, not the victim's (`fld [edi+0x1cd8]` at 0x410660, then `mov esi,edi` hands the same object to the diff scaler as its receiver), and it is not an unmodelled premium/event rate: it is the mastery-lag scale `GObjPC_RecalcLevelDiffExpScale` alone writes, applied by `session.applyMasteryExpScale` (`leveldata.MasteryExpScale`). So that factor is modelled too. |
| Loot table values | **REAL PATH WIRED 2026-09-20; own-design FALLBACK** | This row was stale twice over. The item ids are not 500–502 (they are the real potion ids in `combat/loot.go`), and the `RefMonsterID` mapping was never the obstacle — `characterdata` col 1 is the id and col 2 the code name, settled 2026-09-15. **A kill now rolls the real `_RefMonster_AssignedItemRndDrop`/`_RefDropItemGroup` tables** through `session.dropsForKill`, using the engine's own arithmetic (`refdata.MonsterDrop.RollAssignedDrop` / `refdata.SelectFromGroup`, recovered from `CRefDropData__AddAssignedItemDrop`). The loaders, the store and that arithmetic had all existed since 2026-09-15 and were unreachable because `combat.Monster` carried no numeric id — `cmd/server`'s `monsterSpec.RefObjID` has had it since 2026-09-19 and simply never passed it down. **The per-monster assignment remains own design whenever an operator has not imported those tables**, which is the only remaining gap and is data, not code: the drop tables are server-side DB tables and are in no client archive. A monster WITH real rows that rolls nothing drops nothing — it does not fall through to the own-design table, which would pay out both. |
| Shop prices | **RECOVERED** | Real Price/SellPrice from the client's own itemdata (`_RefObjCommon` cols 26/31; Copper Sword 890/427). The stat formula is now only a fallback for an import that predates them. The DB's `_RefPricePolicyOfItem` is still just the cash-shop table; the vendor prices were in itemdata all along. |
| Quest catalog / gold rewards | **OWN-DESIGN (disclosed)** | "own design"; references the placeholder monster content. **Settled 2026-09-14 — quest objectives can never be grounded, because they are not data.** This project long believed `questcontentsdata.txt` carried an "opaque objective encoding"; it carries none. The client's copy (17 cols × 989 rows; the pserver server ships a trimmed 12 × 202) is quest codename, Korean name, category, **next quest in the chain**, a flag, then **cols 5–12 = a list of step-description string ids** (`SN_CON_<quest>_01`…`_08`) — the quest window's text, nothing more. `questdata.txt` is identity only. The server's RTTI carries `CRefQuest`/`CRefQuestReward`/`CRefQuestRewardItems` — **reward** tables — but no objective/mission refdata class, and `_CHARQUEST` persists only CharID/QuestID/Status/AchievementCount/StartTime. So "kill N of X" lives in server code (`CBasicQuest`, `SetupMissionNPC`), which no archive contains. **What IS real and should be used: quest identity, required level, names, step descriptions, the chain, and rewards** (`refquestrewarditems.txt`, 366 rows — col 1 quest codename, col 3 real ITEM codename, col 7 quantity). Same shape as monsters: real identity + real rewards, disclosed objectives. |
| EXP overflow carries to next level | **RECOVERED (2026-09-11)** | Grounded in `sro_client.exe` `FUN_008a97c0`: the level-up loop subtracts each level's requirement from the running EXP and increments the level, carrying the remainder. `leveldata.Advance` matches. |
| Max character level = 110 | **RECOVERED (2026-09-11)** | Same handler caps its loop `while (level != 'n')` (0x6E = 110), independent of the 139-row table. `leveldata.MaxCharacterLevel`. |
| Max-level EXP held at requirement−1 (not zeroed) | **RECOVERED (2026-09-11)** | Same handler, cap branch: `exp = requirement - 1`. `Advance` corrected from its earlier zeroing assumption. |
| Level-up refills HP; stat points granted at level-up | **RECOVERED** (2026-09-16) | Both halves settled in `GObjPC_SetLevel` (`0x004e4d90`). The refill is real: on a level increase it calls `heal(this, GetMaxHP−GetCurHP, GetMaxMP−GetCurMP, 0x80)` — the delta *is* the missing amount, so it tops both pools up. The grant is real too: `pool += levels*5`, then `SpendStatPoints(levels, levels)` auto-spends two, leaving the three srrevamp already used. See `leveldata.StatPointsPerLevel`. |
| **Critical hits** | **RECOVERED (2026-09-15)** | The dice, the multiplier and the monster's chance. `FUN_00599cc0` (reached via `FUN_005a1a20` from `Combat_ResolveDamage`) is the game's chance roll: chance 0 never succeeds, chance ≥ 100 always succeeds **without rolling**, otherwise success is `chance >= rand() % 101` — inclusive at both ends, modulus `0x65`. A critical then doubles: `Formula_MitigatePhysicalDamage` builds a multiplier (1.0 normally, `GetParam(189)+2.0` for a berserk attacker) and does `if (flags & 2) multiplier += multiplier` before multiplying the already-mitigated damage, and bit 1 is set by `Combat_ResolveDamage` on a successful critical roll. The monster's chance is **characterdata col 78**, settled by disassembling `GObjMob_PublishStats`: it publishes the ref-object's fields into params in a consecutive 4-byte run (+0x230→5, +0x234→6, +0x238→7, +0x23c→8, +0x240→9, +0x244→10, +0x248→11, +0x24c→12), and two of those offsets were already proven (+0x230 = col 71, +0x238 = col 73), anchoring the run onto cols 71–78. The data agrees four ways: cols 73 and 74 equal the level exactly, 75 and 77 are identical (`25 + 2*level`), 76 is 0 for every Jangan monster (blocking is a shield mechanic) and 78 reads **2 on 7,493 of 7,495** monster rows. **Not modelled, disclosed:** the real roll also keeps a per-actor accumulator (raised by `chance` on a miss, dropped by 100 on a hit) that it compares instead of the raw chance — bad-luck protection. srrevamp rolls memorylessly, so its criticals are streakier, never more or less frequent. **CORRECTED TWICE 2026-09-15:** the player DOES crit, and now does. The first correction said the earlier sentence was "true about one route and wrong as a conclusion" — it was wrong about the route as well. `Char_PublishCombatStats` **does** publish param 12, from the stat source's `+0x1dc`; the pass that said otherwise had cut its disassembly at 220 instructions and that write sits at `0x00497ef0`, three hundred past the end. So the player's critical arrives by the same route as every other combat stat. It is not the only route, though: `Stat_ApplyTaggedModifier` also maps the tag `'cri'` to param 12, and that is the item-modifier path, which is where a **weapon's Critical column (itemdata 116)** goes. (This sentence previously asserted both that the function does publish param 12 and that it "indeed does not"; the publish is real — `0x00497ef0`, `MOV EDI,0xc`, from the stat source's `+0x1dc` — and the two routes simply coexist.) That column was already verified against a real +5 tooltip (a Copper Sword reads 3, the tooltip showed 3) and already loaded as `refdata.Item.CriticalMin` with nowhere to spend it. Unopposed against monsters, and that is not a simplification: the real chance divides by `(1 + target 'evcr'/100)`, and `GObjMob_PublishStats` publishes params 0, 3–12, 23, 24, 27–33 and 140 — param 57 is not among them. |
| **Blocking** | **RECOVERED and SHIPPED (2026-09-15)** | A blocked hit deals **nothing**, and the control flow proves it: on a successful roll `Combat_ResolveDamage` falls through to `JZ 0x005905fb`, past **all four** `Formula_Mitigate*` call pairs (`0x58f15d`, `0x58f2fb`, `0x58f7ea`, `0x58f9b2`), so no damage is ever computed and the record's zero-initialised `+0x28`/`+0x24`/`+0x20` stand; a *failed* block jumps to `0x58f739`, before the third pair, and resolves normally. The chance is the defender's `'bri'` over `(1 + attacker 'evbl'/100)`, and the roll is the critical's, distinguished only by a key byte in ECX's high bits — `OR ECX,0x42000000` (**'B'**) against `0x43000000` (**'C'**), which is also the key the bad-luck accumulator is filed under, so the two have independent streak protection (srrevamp models neither). The player's chance is a **shield's block ratio, itemdata cols 74–75** — 10~20, on exactly the 500 shield rows — now carried as an appended optional export column. Unopposed against monsters, measured: `GObjMob_PublishStats` publishes params 0, 3–12, 23, 24, 27–33 and 140, and param 56 is not among them. |
| **Death penalty** | **RECOVERED (2026-09-15)** | Dying costs experience, and the whole block is gated on `10 < Char_GetLevel(victim)` — **levels 1–10 die free**. `GObjPC_OnDeath` (`004e6980`, which the binary places at `D:\WORK2005\Source\SilkroadOnline\Server\SR_GameServer\GObjPC.cpp` line 6168, from the CLAMP assert inside this very block) multiplies the level's EXP unit — `levelTable[lvl]+0x1c`, *the same field a kill is paid from* — by one of four constants: **100** killed by a monster, **300** by a monster while carrying PK penalty points, **20** by a player, **100** by a player while flagged. The flagged branches also cost **60** / **20** skill points, capped at what the character holds (`charData+0x80` = `RemainSkillPoint`); an ordinary death costs no SP. The loss is clamped (the assert spells its minimum as `1.0`), reduced by a stat this code does not model, and applied through `GainExpAndLevel` (slot `0x170` = 92) with a **negative** 64-bit amount — a death never touches `CurLevel`. That `+0x1c` is the EXP unit is not assumed: `Formula_MonsterExpReward`'s disassembly reads the identical field *and* shows the minimum-level rule (`CMP EBX,EAX / JLE / MOV EBX,EAX`) this project had recovered separately. The branch condition also resolves half of the old `pc[0x72d]` open item: it is a byte at victim+0x1CB4 compared against **5**, gating the harsh branches together with `charData+0xb4` = `PKPenaltyPoint` from the recovered `_CHAR` schema. What the state enum *means* is still unrecovered. Checked against the ORIGINAL client's `leveldata.txt` (identical to the pserver's at every level sampled): the cost is steeply regressive — **74% of a level at 11, 17% at 20, 1.9% at 50, ~0% at 110**. |
| Berserk **damage multiplier** | **RECOVERED (2026-09-15)** | **×2 exactly.** Berserk is "Hwan" internally, which is why grepping for "berserk" never found it. The chain, all named now: `CGObjChar::SetBerserk` (vtable slot 198, `0x004a9fc0`) writes the flag at `(*(this+0x30))+3`; `CGObjChar::IsBerserk` (slot 64, `0x004aa5b0`) reads that same byte, which is what ties the pair together; `Combat_ResolveDamage` (`0x0058e5f0`) sets bit 2 of the damage flags when the **attacker** is berserk; and both `Formula_MitigatePhysicalDamage` (`0x0040e450`) and `Formula_MitigateMagicalDamage` (`0x0040e830`) then use `GetParam(189) + 2.0` where they otherwise use `1.0`, and multiply the damage by it. The 2.0 is the double at `.rdata 0x00b45f30`; its neighbours `0x00b45af0 = 100.0` and `0x00b45ac0 = 1.0` are the already-confirmed constants of the `/(1 + p/100)` idiom, so the width is settled rather than assumed — and at float width the multiplier would be 0.0, i.e. a berserk attacker would deal no damage. Param 189 is a separate berserk-damage **stat** that adds on top (`SetBerserk`'s 5th argument grants it a base 0.3, float at `0x00b45b8c`), but every call site bar one passes 0, so 2.0 is the plain case and 2.3 the special one; the stat is not modelled and is left out rather than folded in at a guessed rate. **The ORDER was wrong too**: the multiplier applies *after* mitigation, not to the raw roll. |
| Berserk gauge (fill/hit, orbs, duration) | **OWN-DESIGN (disclosed)** | `internal/berserk`: "The mechanic is the real one" (SRO's five-orb berserk); Fill 8/hit, 5 orbs and 20 s remain this project's own design. The duration in particular is genuinely unrecovered: `SetBerserk` takes a state-change slot and a float duration, but **every** call site passes `0xff`/`0` for them, so the real server holds that timer somewhere else. The client's own `GDR_PMI_CIRCLE0..4` (5 mini-info circles) drive the orbs — a structural mapping, not decompile-confirmed. **CHECKED 2026-09-18: the berserk config is not in client data.** The engine has a `_RefHWANLevel` table (`VCRefHWANLevel`) and its client file `hwanleveldata.txt` IS in `Media.pk2`, but it holds only Hwan level **names** — 257 rows of `id, UIO_SECOND_HWAN_*_NAME_LEVEL_n` string ids, no numbers — so the duration, gauge fill and per-level values are confirmed server-side DB rows, not client-groundable. The disclosed 20 s / 8-per-hit are correctly disclosed: no client source exists to ground them. And `hwit` (skill param → ParamKeeper 195, `PARAM_HWAN_TIME_INCREASE`, a *duration bonus* not the base) has no findable reader, so even its meaning stays an inference. |
| PvP (duel) damage | **RECOVERED, via the shared pipeline (2026-09-15)** | This row said *"reuses the same combat model, no separate formula"* and had stopped being true. The duel path was a bare `base - armor` while the PvE path collected six recoveries in a row — the `/(1 + pct/100) − flat` mitigation shape, berserk, the level term, criticals and blocking — and nothing connected the two. Both now go through **`combat.ResolveBlow`**, one function for every blow in the game, so they cannot drift again: a block skips the whole pipeline, then mitigation, then the critical doubling, then the level term, in the order `Formula_MitigatePhysicalDamage` runs them. In a duel both sides are players, so a weapon's Critical column (itemdata 116) and a shield's block ratio (74–75) both apply, and both levels are real. Berserk stays outside `ResolveBlow` — it is per-character state the combat package does not hold. |
| Inventory size = 50 slots | **OWN-DESIGN (disclosed, with a PROVEN REASON 2026-09-15)** | The starting size is a `_CHAR.InventorySize` row (schema offset +0x0ac — inventory is per-character and expandable), not a constant in the exe, so it is the same DB-side wall as starting Str/Int. What the binary *does* give: `CGObjPC::ExpandInventory` caps the main inventory at **77** slots normally and **99** under a predicate, hard-capped below 100; and `CGObjPC::FindEmptySlotNum` calls `CGStorage::FindTotalEmptySlot(0xd)`, so the general inventory begins at index **13**, after 13 equipment slots. 50 sits inside the real range. |

## Client — mechanics / behaviour

| Item | Status | Evidence / disclosure |
|---|---|---|
| `REAL_CHARACTER_NATIVE_HEIGHT` = 14.34 | **RECOVERED (measured)** | From real character mesh bounds; carries an honest open caveat that the real client may apply a further scale this project hasn't found. |
| Region axes (region y→X, x→Z) and span 1920 | **RECOVERED** | Confirmed twice (terrain-edge + minimap tiling); `AGENTS.md`, `WORLD_ISSUES.md`. |
| Named-zone region coords (Jangan 97/168, Donwhang 102/153, Constantinople 105/79, Hotan 92/135) | **RECOVERED** | Round 569: the region where the town's own `NPC_<code>_*` npcpos rows (joined to characterdata on the first column) and its `GATE_<code>` teleportdata row agree, the same on the server (`worldmap.ZoneCentre`) and the client (`World3D` `*_ZONE_REGION`). Until then a densest-architecture pick (`cmd/scanlandmarks` / `cmd/findregionassets`), which chose Donwhang's ferry region 98/157 and Constantinople's 104/80; the server's hotan/samarkand/constantinople had no recorded source. `docs/RE_COMPLETION.md`, round 569. |
| Samarkand's region, 106/107 | **UNRESOLVED (disclosed)** | Its `NPC_CA_*` rows split 5/4/4/3 over 107/108, 106/108, 107/107, 106/107 (the town sits on their corner) and `GATE_CA` is in 106/108, so the tables name no one region; both sides keep the client's earlier density pick, one of the four (textzonename: "Samarkand"). Round 569. |
| NPC placements (`npcpos.txt`) | **RECOVERED** | Real file, 12,367 rows, columns confirmed npc-id/region/X/Y/Z (histogram: every row exactly 5 cols). |
| Level-up effect meshes + textures + message | **RECOVERED** | `levelup01–04.bms` + paired textures from `system_levelup.efp`'s RenderMesh stream; `UIIT_MSG_STRGERR_LEVEL`. `WORLD_ISSUES.md` round 163. |
| Level-up effect *animation timing* | **OWN-DESIGN (disclosed)** | The .efp graph curves are not reliably recovered; grow/fade is a disclosed designed approximation. |
| `ZONE_SPAWN_LOCAL` Jangan (1002,1020) | **OWN-DESIGN (disclosed)** | Landing spot chosen near the *real* town-square/dragon (1002,917); disclosed as a UX choice, not the real spawn coordinate. |
| `MOVE_SPEED` base 6.0, gravity 20.0, camera/zoom/send-rate | **OWN-DESIGN (engine tuning)** | Client feel scaled by `PLAYER_SCALE_RATIO`; not a claim about a real game value. |
| Collision layer bitmasks | **ENGINE ORGANISATION** | Godot layer assignment, not a game fact. |
| Fog density / sun-scatter / aerial-perspective | **OWN-DESIGN (disclosed)** | "disclosed choice, not real data," bounded by the real terrain shader's phase term. |
| Gait threshold (0.1 × height) | **OWN-DESIGN (heuristic)** | Animation blend heuristic, disclosed. |
| `ATTACK_SEQUENCE` = types 2,5,16,17 | **RECOVERED (types) + FLAG (order)** | The four animation *types* are real (`.bsr` groups). The claim that "the game chains them in **that order**" was stated as fact without a citation — see below. |
| NPC facing | **ABSENT — open RE task** | `npcpos.txt` carries no heading (confirmed: 5 columns). Real heading source not yet found; NPCs currently use default facing. The user has asked this be found in Ghidra — tracked separately, not shipped as a guess. |

## Flags corrected in this audit

1. **`ATTACK_SEQUENCE` chain order** (`client/scripts/World3D.gd`). The comment asserted "the game
   chains them in that order." The four types are recovered; the *order* they cycle in on
   successive normal attacks is a behaviour claim with no citation. Comment softened to say the
   order is this project's own sequencing of real animation types, pending an RE confirmation —
   not presented as observed real behaviour.

2. **`leveldata.Advance` EXP carry** (`server/internal/leveldata/leveldata.go`). The doc disclosed
   the max-level cap but presented "overflow carries to the next level" as fact. Note added that
   the carry is the assumed model, not RE-confirmed.

## Grounded since the first pass (2026-09-11)

- **EXP overflow carry + max level + max-level bar** — recovered from `sro_client.exe`
  `FUN_008a97c0`; `leveldata.Advance`/`MaxCharacterLevel` corrected. See the leveling rows above.

## Regrounding pass — 2026-09-13 (combat loop v0.1.142–144)

A re-verification of everything the combat-loop work touched, against real client data on the RE
box. **No invented value dressed as real was found in the new work either.** What changed:

- **Monster ladder — every claim re-checked and holds.** All 11 species in `cmd/server`'s
  `monsterSpecs` were re-read from the real `characterdata_*.txt`: every CodeName exists, every
  Level matches col 57 exactly (Mangyang 1 · Small-eyed Ghost 2 · Big-eyed Ghost 3 · Old Weasel 4
  · Weasel 5 · Water Ghost slave 6 · Water Ghost 7 · Tomb Stone Ghost 8 · Stone Ghost 9 · Yeoha 10
  · Earth Ghost 27), every Rarity is 0 (col 15), and every English Name matches `textdata_object`'s
  real English column — including the non-obvious ones (`_CLON` of BIGEYEGHOST really is
  "Small-eyed Ghost"). The `main.go` "GROUNDED" comment was accurate; the memory had merely
  under-recorded it (3 of 11 verified → now all 11).
- **EXP curve — re-confirmed.** The loaded CSV matches real `leveldata.txt` for every level
  (level 9 = 17978); the runtime path is correct.
- **Shop prices — re-confirmed.** Copper Sword (`ITEM_CH_SWORD_01_A`, id 71) still reads
  col 26 = 890 / col 31 = 427 in the client's own itemdata.
- **Armor/shield defence columns — re-confirmed by type relationship** (the storage-session
  grounding, which post-dated the first audit). Across real itemdata, cloth (`CLOTHES`), light
  (`LIGHT`) and heavy (`HEAVY`) chests at one tier order exactly as the game's armor types should:
  heavy has the highest col 65/66 (phys def) and durability (col 63), cloth the highest col 76/77
  (mag def), light between — confirming col 65/66 = physical def and col 76/77 = magical def, each
  min<max. Col 74/75 (block) is 0 on all body armor and 10–20 only on shields (`SHIELD`), confirming
  it as the shield block ratio. So `item_table_reader`'s defence column map is grounded, not just
  schema-aligned.
- **Disclosures verified honest.** `character.go` (per-level MaxHP), `berserk.go` (gauge numbers)
  and the `monsterStatsForLevel` curve each label themselves own-design with the reason (all
  server-side balance, never recovered). No new FLAG.
- **Stale rows corrected (this doc):** the pre-combat-loop rows called MaxHP "flat 100" and said
  monsters had "no real map/monster data" — both now false and rewritten above.
- **Candidate raised, then DISPROVEN — monster MaxHP is col 59, not col 79.** This pass first
  flagged col 79 as the better MaxHP candidate: across the ladder it is a strikingly clean
  ≈23.5-per-level line (L1–10: 24, 47, 71, 94, 118, 141, 165, 188, 212, 235), where col 59 looked
  "inconsistent" (54, 55, 85, 83, …). It was **not** grounded or shipped on that basis, which was
  the right call — **it was wrong**. Col 79 is simply 23.5×level, the same value `leveldata`
  col 5 carries. The real MaxHP is **col 59**, recovered from the binary (see the row above), and
  its non-monotonicity is authored design, not noise: a `_CLON` is a weaker slave version, so the
  level-4 Old Weasel (83) genuinely sits under the level-3 Big-eyed Ghost (85). The lesson is the
  project's own: a clean-looking curve is not evidence of what a column *means*.

- **What col 79 actually is — measured, but its *meaning* is still UNCONFIRMED.** Across all 6,117
  `MOB_*` rows, col 79 equals `leveldata` col 5 for the monster's own level in **5,829 (95.3 %)**
  of them; the 288 that differ are exactly the special cases (`MOB_EU_KERBEROS`, level 110 rarity 3
  → 40000 against the 12550 standard; the `ROCKY_CLON2` quest mobs → 37060 against 6949). So col 79
  is "the standard value for this level, overridden upward for uniques/quest mobs", and `leveldata`
  col 5 is that per-level standard (23.5×level early, ~114×level by 110 — an accelerating curve).
  That shape fits **ExpToGive**, and the kill pacing works against the real EXP curve (≈20 level-1
  Mangyang at 24 each ≈ the 470 needed for level 2). It is **not shipped**, because none of that
  says *which* quantity it is.

  **The column→offset map is now settled** (`client/tools/ghidra/FindOffsetRefs.java`, written for
  this). `RefObjChar::ExtractData` stores one column per write, so listing its stores in address
  order and anchoring on two independently-known fields fixes the whole run: `0x19c` is col 59 (the
  `m_dwMaxHP > 0` assertion) and `0x25c` is col 82 (the code defaults it to `0xbb8` = 3000, which is
  col 82's value in the data). Counting between them gives col 67→0x224, 68→0x228, 69→0x22a,
  70→0x22c, 71→0x230, 72→0x234, … 78→0x24c, **79→0x250**, 80→0x254, 81→0x258, 82→0x25c. So an
  earlier note here saying col 79 was `0x24c` was **off by one** — exactly the risk that kept it
  unshipped. Supporting the exp reading: the stat-publication function `FUN_004c3730` reads the ref
  object's 0x230–0x24c (cols 71–78, the combat stats) and **skips 0x250**, so col 79 is not a combat
  stat.

  **Resolved 2026-09-14 — col 79 is NOT ExpToGive, and the "supporting evidence" above is
  withdrawn.** Intersecting the readers of `0x250` with the readers of the *proven* MaxHP field
  `0x19c` (`FindOffsetRefs`) leaves exactly two functions: `RefObjChar::ExtractData`, which writes
  it, and `FUN_00495d60` — and that one reads `0x24c`/`0x250` as **floats in pairs**, alongside
  `0x20c`–`0x218` and `0x1b0`–`0x1b8`, so it is a float stat block on a different struct whose
  offsets merely collide. **Nothing in the server reads `CRefObjChar+0x250` as an integer at all.**
  A field the server never reads cannot be the exp it grants, so col 79 is dead data in the server
  (a derived copy of `leveldata` col 5, which is what the 95.3 % match really shows). Monster exp
  stays the disclosed `ExpFor`, and the real source is still unfound: the exp-gain entry point
  `FUN_004e5250` has no direct callers, only a vtable slot at `0x00af5b6c`, so tracing it needs
  virtual-dispatch analysis.

  **Dig update (2026-09-14):** scoped the decompile path; it is a genuine epic, not a quick win.
  The client's refdata load is `FUN_00844cd0` (master dispatcher: builds each `%stextdata\…`
  filename and calls a *generic* tokenizer `FUN_00952890(this, …)` per file, characterdata among
  them). So the per-column `_RefObjChar` map lives in a per-type manager's virtual parse method
  reached through dispatch the decompiler won't cleanly resolve — and the client is the binary that
  prior work found does **not** store monster HP (it comes from the server), so this path may
  confirm "no HP field" rather than a column. The authoritative source is the emulator server
  (`SR_GameServer.exe`, a decompilable PE32 that *does* use HP for combat; its `SR_GameRefData/`
  ships the same positional `CharacterData_*.txt`, so its loader parses by index too) — but that is
  a fresh large import + the same dispatch chase, and grounds column *identity* off a non-retail
  emulator (values still carry the pserver caveat). The server crash `.dmp`s on the box are
  minidumps (0–55 KB), not full-memory dumps, so there are no loaded `_RefObjChar` structs to mine.

  **Dig done (2026-09-14, same day):** the server-binary route was taken and it worked.
  `SR_GameServer.exe` imports into Ghidra at `/home/ghidra/re_server` (`SR_GameServer_re`) and,
  unlike the stripped client, carries RTTI class names, embedded `D:\WORK2005\…` source paths and
  assertion strings — which is what made it tractable. `RefObjChar::ExtractData` was found by
  xref'ing its own error string, and the `m_dwMaxHP > 0` assertion inside it named the field's
  offset. **Monster MaxHP is grounded (col 59); MaxMP is col 60.** Worth noting the y0gi
  `SR_GameRefData/CharacterData_*.txt` and the pserver client's characterdata agree value-for-value
  on these rows, so the emulator is not modded here and the column indices transfer directly.

## What is genuinely still assumed (summary for the next pass)

None of these is a value dressed as real; each is a behaviour rule on top of recovered data, or a
disclosed placeholder, to confirm against the client when the relevant system is next opened:

- ~~**Level-up refills HP; derived stats (maxHP/maxMP from level+Str/Int).** The biggest
  remaining ground.~~ **RECOVERED — this entry is stale (corrected 2026-09-17).** The whole
  formula is in `docs/RE_COMPLETION.md`'s grounded table: `MaxHP = Str x 10 x 1.02^(lvl-1)`
  and `MaxMP = Int x 10 x 1.02^(lvl-1)`, read off the `GObjPC_InitStats` stat graph with
  `.rdata 0x00b462ac` = 1000 and `0x00b45ea0` = 1.02.

  **AND THE CAVEAT ATTACHED TO IT WAS WRONG, which mattered more.** It read: *"the on-disk
  `SR_GameServer.exe` is a third-party emulator bundle (y0gi), not authoritative"*. That
  sentence told every later reader to discount the single artifact most of this project's
  recovered values come from. Measured:

  | evidence | result |
  |---|---|
  | strings naming Joymax's build tree `D:\WORK2005\Source\SilkroadOnline\Server\` | **55** |
  | distinct Joymax **source filenames** in them | **52** — `Formulae.cpp`, `GObjPC.cpp`, `GObjChar.cpp`, `AIHive.cpp`, `AsyncQuery_*.cpp`, … |
  | PE TimeDateStamp | 2011-08-08 |
  | linker version | **8.0** (Visual Studio 2005 — consistent with a `WORK2005` tree) |
  | RTTI classes in Joymax's own naming | 1,882 |
  | `## Illegal ##` base-class stubs naming `IGObj` methods | 208 |

  Those filenames come from `__FILE__` in the assert macro **at compile time**. A
  reimplementation written by a third party cannot contain 52 of Joymax's own source
  filenames, nor their internal class names. **The binary is Joymax's own compiled build.**

  What stays true is the *other* half, and it is worth keeping separate: a redistributed
  server **bundle** is third-party, and the DATA shipped alongside it (rates, tables, DB
  contents) may well be modded — this project already records that for the VSRO package.
  A Joymax binary does not make the bundled data authoritative.

  **Not verified**: whether this particular build was patched after compilation. Nothing seen
  suggests it, but no integrity check was run, so "Joymax's build" is a claim about its
  provenance and not about its byte-for-byte purity.
- Attack-combo order (the four animation types are real; the order is ours). **Still true.**
- ~~Monster always counterattacks; no dodge/crit/evade (disclosed own-design combat).~~
  **STALE, corrected 2026-09-20 (round 314).** Three of the four clauses have since been
  grounded and shipped:
  - **Criticals are real and rolled.** `PlayerCritical`/`MonsterCritical` ride the combat
    result packet, and the roll is not even memoryless — `internal/combat/chancememory.go`
    implements the engine's per-actor accumulator from `FUN_00599cc0`, reached from
    `Combat_ResolveDamage` via `GObjPC::RollChance`.
  - **Blocking is real.** `PlayerBlocked` is on the wire; a blocked hit deals nothing, read in
    `docs/RE_COMPLETION.md`, "Blocking: a blocked hit deals nothing (2026-09-15)".
  - **The monster does NOT always counterattack.** It strikes no more often than its attack
    skill's ReuseDelay — `combat.Hub.CounterattackReady`, round 254, with Mangyang 3000 ms,
    Gyo 2000, Yeoha 2500. **And behind `-monster-battle` (round 546, off by default;
    `session.SetMonsterBattle`) it does not counterattack at all: it chases its attacker to its
    attack band at its run speed and swings on its own attack timer** -- immediate on entering
    BATTLE, then every ReuseDelay through the action machine (round 545's timer read) -- with
    each blow pushed to the zone as `OpMonsterAttacked`, and gives up by distance
    (`ai.TargetWithinChaseRange` / `ai.GiveUpCode`, whose `_RefTactics` columns are disclosed
    stand-ins). With the flag off the synchronous counter is what it was.
  - What survives: **parry and evade are still not rolled.** Parry is recovered as ParamKeeper
    param 9 but nothing wires it, and the evade tags in `combat/paramtags.go` are vocabulary
    only.

    **Round 370 rewrote this bullet to say the engine "has no separate parry roll" because param
    9 is "the denominator of the hit chance". THAT EDIT IS RETRACTED (round 373).** The formula
    it found is real but is the **damage centre**, not a hit chance -- see
    `docs/protocol/damage_pipeline.md`'s retraction section and the 2026-09-15 entry "What
    'attack rate' actually does", which states that attack rate is not a hit/miss roll at all.
    What is true, and was true before round 370: there is no separate parry ROLL, because parry
    rate is an **input to where in the damage range a blow lands**. srrevamp does not model
    either stat, so the centre is unported -- though round 371 did remove the blocker the
    2026-09-15 entry recorded, by recovering a bare character's `hra = era = 10 + Level`.
- ~~The rest of the own-design economy/combat layer (damage, flat HP, monster stats, prices,
  quests, loot values, gold) — placeholder by intent.~~ **STALE, corrected 2026-09-20.** Most
  of that list is grounded now, and the headline table above already says so:
  - **Monster stats**: MaxHP is `characterdata` col 59 and the attack range is col 83's skill
    `'att'` — both cited in `internal/combat/combat.go` itself.
  - **Prices**: `itemdata` cols 26/31, with `SellPrice < Price` checked on every real row.
  - **Flat HP**: superseded by the recovered `MaxHP = Str x 10 x 1.02^(lvl-1)`.
  - **Loot values**: not a placeholder but a **proven absence** — loot is DB-only, censused at
    17 server-side tables, with a test that fails if that count drifts
    (`persistence.ServerOnlyLootTables`). That is a disclosed value WITH a proven reason,
    which is the bar this project sets, not an open assumption.
  - Still genuinely ours: **quest objectives** (proven not to be data, above) and the
    placeholder loot item ids 500-502.

**This section has now rotted twice**, which is why each bullet above carries its citation
inline: the 2026-09-17 correction found it telling readers the server binary was not
authoritative, and this pass found it describing a combat system three features behind the
code. `internal/systems` guards `docs/SYSTEMS.md` against exactly this and nothing guarded
this page; `TestGroundingAuditMatchesTheShippedCombat` now does, for the three mechanics
above.

## A mechanical citation check (2026-09-20, round 287)

The audit above classifies *mechanics*. This one asks something narrower and
entirely mechanical: **the strings this project quotes as the engine's own
words — are they actually in the binary?**

The question is not idle. Round 286 found that a text sweep over the decompiled
dumps matches **this project's own annotations**, because the dumps carry both
the code and everything we have written onto it. A citation harvested that way
would look exactly like a citation harvested from the program.

**The check.** Every double-quoted span of 8 characters or more in
`recovered_names.tsv`'s evidence column — 856 occurrences, **286 unique
(binary, string) pairs** — tested against the bytes of `SR_GameServer.exe` and
`sro_client.exe` directly, ASCII and UTF-16, verbatim first and then by the
longest literal fragment between format specifiers.

**The result.**

| | |
|---|---|
| found verbatim in the binary | 279 |
| found once a documentation ellipsis or escaped quote was removed | 5 |
| not a claimed literal at all (prose caught by the extractor) | 1 |
| **a real defect** | **1** |

**Nothing fabricated.** The one defect is a paraphrase presented as a quotation:
seven rows for `PayQuestRewardCatchMob` quoted "the engine's own"

	fail pay quest. because don`t have Catch Mob : ID[n] -> TARGET

where the binary says

	fail pay quest. because don`t have Catch Mob : %d[%d] - >%s

The format specifiers had been rewritten into readable placeholders. The
meaning survived; the claim "the engine's own" did not, because those are not
the engine's characters. Corrected in all seven rows.

**What this does not cover.** Evidence that is a *description* rather than a
quotation, which is most of the file, and numeric citations (offsets, slots,
constants). It covers exactly the claim "the binary says this, in these
characters", which is the one a reader is most likely to take on trust.

## The numeric half of the same check (2026-09-20, round 288)

The string check above ends by saying it does not cover numeric citations. The
addresses are the corpus's backbone -- every row of `recovered_names.tsv` is a
claim that *this function, at this address, in this binary* is the thing named
-- and `recovered_names_test.go` says in its own header that it cannot reach
them.

It can now, on the box:
`client/tools/re/verify_recovered_addresses.py`. Every row is classified:

| verdict | meaning | count |
|---|---|---:|
| `start` | the address is a function START in the claimed binary | **2,415** |
| `interior` | inside a known function but not at its head -- a name on a jump target | **0** |
| `wrong-binary` | not a function in the claimed binary, but is one in the other | **0** |
| `outside` | no function there in either dump | **1** |

The one `outside` is `0x587260` (`SkillAction_Stance`), which is **the dump gap
`AGENTS.md` already records** -- real code Ghidra never defined. The audit
rediscovered it without being told, which is the best evidence available that
the probe works.

`interior` and `wrong-binary` are always defects and the tool exits non-zero on
them. `outside` is not: it reports and passes, because a new one means *read
that address* before calling it wrong. The two `client`/`server` mislabels the
Go test's header remembers are exactly the `wrong-binary` case, and there are
none left.

## A broken weapon now refuses the cast (2026-09-21)

**RECOVERED, and half of it was already shipped.** A skill's cast requirement
wants the required item *present and serviceable*:
`Skill_CheckCastRequirement` (`0x0058d480`) returns **`0x300f`** when vtable slot
372, 399 or 400 answers 0, and the client's own name for `0x300f` is
**`UIIT_SKILL_USE_FAIL_BROKEN_WEAPON`** — so those three slots are serviceability
predicates (`docs/protocol/igobj_vtable.md`).

srrevamp already honoured the *other* consequence of breakage: a broken item
contributes no stats, which the combat sums implement by skipping it, matching
the engine dropping its ParamKeeper entry (`durability.md`). But the **cast went
through anyway**, so a broken weapon cost you its damage and nothing else. It now
refuses.

**CORRECTED round 486: one flag, not three predicates, and the `reqi` branch is
modelled.** The paragraph that stood here said the engine had three predicates
collapsed into one test, and that the `reqi` branch's serviceability was not
modelled. Both were readings of the error code, not of the bodies. Read:

- CGObjPC's slots 372 (`0x004ec5a0`), 399 (`0x004ec5d0`) and 400 (`0x004ec600`)
  fetch the weapon (storage 6), the shield (7) and an armour part (through
  `DAT_00c63f44`) and answer `item == 0 || item+0x190 == 0` (`4ec5bb` / `4ec5eb`
  / `4ec631` `cmp [eax+0x190],ecx ; sete cl`). `+0x190` is the flag
  `GItemEquip::SetBrokenFlag` (`0x00495980`) stores, and its callers pass
  `durability < 1`. So durability at zero is the whole test.
- In the `reqi` branch the engine reads each slot's type through a getter —
  `Equip_GetShieldTID` (`0x004ead80`, called at `58d4c9`), `Equip_GetWeaponTID`
  (`0x004ead40`, `58d4d4`), `Equip_GetArmourPartTID` (`0x004eadc0`, `58d57e` /
  `58d5c8`) — and each writes TID 0 when `+0x190` is set (`4ead63` / `4eada3` /
  `4eadf5` `cmp [..+0x190],0 ; jne`). A broken item is an **empty slot** to the
  list walk: it matches no entry with a TypeID4, and the refusal is **`0x300d`**
  (`58d695`, `UIIT_SKILL_USE_FAIL_WRONGWEAPON`), not `0x300f`.
  `session.equippedTypes` now leaves broken items out, which is that.
  `0x300f` for a shipped skill comes only from the weapon-byte branch
  (`58d719`–`58d72a`), which `weaponIsBroken` already models.
- Not every serviceability call in the `reqi` walk can produce `0x300f` at all
  (round 490): the `+0x640` call for an armour entry WITH a Value (`58d599`)
  jumps to the loop tail on 0 (`58d5a6 je 0x58d638`) and sets no code. Only
  `+0x5d0` at `58d527` (`je 58d607` at `58d533`), `+0x63c` at `58d556` (`je
  58d607` at `58d562`) and the Value-0 scan's `+0x640` at `58d5de` (`je 58d605`
  at `58d5eb`, falling into `58d607`) reach the `0x300f` store.

Still not modelled, disclosed in `combat.CastRequirement.Satisfied`: a
weapon/shield entry with Value 0 matches an *empty* slot in the engine (none
shipped -- the one claim here that IS checked against records, by
`CastRequirement`'s 1,552-record measurement); the rest are not checked against
records: an armour entry with Value 0 scans parts in
order and stops at the first part not of the Kind; an armour entry with a Value
compares TypeID4 only; an ALL-of list with all five entries matching returns
`0x300d`. And the weapon-byte branch's order: a broken weapon of the wrong kind
is `0x300f` in the engine and "wrong weapon" here — both refuse.

A lookup failure permits the cast, the same choice every other gate in that
function makes for the same reason — reference data is the operator's, and a
fresh deployment must not be locked out of its skills.
