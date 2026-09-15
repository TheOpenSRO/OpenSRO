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
| Skill **damage** | **RECOVERED (2026-09-14)** | The skill's own `'att'` parameter. Skill parameters are `(code, values…)` runs in the Param block, the code being a C multi-char literal stored as a big-endian int; the server's parser `FUN_00587630` compares against those literals and gives each code's run length, so `'att'` (0x00617474) is a fixed six-word run. Values are (type, percent, min, max, percent): across `SKILL_CH_SWORD_SMASH_A` levels 1–5 the percent holds at 143 while min/max climb 15–18 → 29–35, and a plain swing (`SKILL_CH_SWORD_BASE_01`) is 60 % with no flat damage. So a cast deals a percentage of weapon damage plus a flat roll. `skillDamageBonus`; the old per-level stand-in survives only as the fallback for skills with no `'att'`. |
| Mastery level-up SP cost | **RECOVERED (2026-09-14)** | **leveldata column 2**, at the mastery's current level. Found by following the spend rather than the field: `charData+0x80` is only touched directly by a packet builder and the kill reward because the raise handler goes through the skill-point adder `FUN_004e4c60`, which is itself virtual (vtable slot 93 = offset 0x174, right after exp-gain at 92). Two of that slot's callers pass a **negative** delta; one is `FUN_0059c4e0`, the mastery level-up: it walks the levels being raised, accumulates the level table's `entry+0x10` for each, and refuses with error 0x3802 when the character's skill points fall short. A level entry holds the int64 EXP requirement at +8, so +0x10 is the field straight after — column 2: 1, 1, 2, 2, 4, 5, 6, 7, 9, 12 … 53 at level 20, 172 at level 32. `leveldata.Table.MasteryUpCost`; the old disclosed `currentLevel+1` remains only as the fallback when no level table is loaded. |
| Drop schema (`refdata.MonsterDrop`/`DropGroupEntry`) | **RECOVERED (schema)** | Real `_RefMonster_AssignedItemRndDrop`/`_RefDropItemGroup`; `refdata_schema.md`. |
| Starter-kit item IDs | **RECOVERED** | The item table's own `_A_DEF` code-name marks starters; real rows (3643–3645 / 3652–3654 / 3632). Two picks (garment family, sword) **disclosed** as this project's, because the original chooses by creation-class the server doesn't record. |
| Monster identity — CodeName, Level, Rarity, Name (`MOB_CH_*`) | **RECOVERED** | Real `characterdata` (`_RefObjChar`): CodeName is the row key the model resolves by; Level is col 57, Rarity col 15, and the English Name is `textdata_object`'s resolution of the row's `SN_` key. Re-verified 2026-09-13 for the whole 11-species Jangan ladder (levels 1–10 + Earth Ghost 27) — every CodeName, level, rarity 0 and name matched real data. |
| Combat damage model — **mitigation SHAPE recovered (2026-09-15)** | **PART RECOVERED** | The shape was wrong, not just the numbers. `Formula_MitigatePhysicalDamage` (`0040e450`) and its magical twin (`0040e830`) — structurally identical, gated on bits 4 and 8 of the flags at `+0x230` — compute **`damage = raw / (1 + reductionPercent/100) − flatAbsorb`**, floored at 0, with the reduction read as ParamKeeper param 7 (physical) or 8 (magical) and the constants 1.0 / 100.0 at `.rdata 0x00b45ac0` / `0x00b45af0`. **Which side owns the reduction is settled by the formula's own monotonicity**, not assumed: a larger param 7 yields *less* damage, so it cannot be the attacker's. `combat.MitigateDamage`. The monster's percentage is REAL — `characterdata` cols 73/74 are the physical and magical reduction and both equal the monster's level on every row of the **original client's** table (Mangyang 1, Gyo 5, Yeoha 10, Bandit Archer 12). Still disclosed: the flat `Defense` term, the floor of 1 (the game floors at 0, but a zero-damage hit there is a *miss* and srrevamp has no hit/evade roll), and the player's own reduction percentage, which comes from the gear aggregate and is not yet traced. |
| Weapon damage is **rolled in [min, max]** | **RECOVERED (2026-09-15)** | srrevamp always swung for `PhysAttackMax`. `Formula_RollWeaponDamage` (`0040f8d0`) and its twin for the other damage type (`0040f930`) are three lines each: `min = GetParam(191); max = GetParam(190)` (193/192 on the twin), `if max-min < 1 return 0`, `rand() % (max-min+1) + min` — inclusive at both ends. `Char_PublishCombatStats` publishes 190/191 and 192/193 as the two types' pairs, and this project already loads both ends from the client's own itemdata (cols 12-15). `combat.RollDamage`. |
| **`/(1 + p/100)` is the engine's universal opposed-stat idiom** | **RECOVERED (2026-09-15)** | Not a quirk of the damage formula — the same divisor appears at least three independent times: damage mitigation by params 7/8, a blow's **critical** value divided by the defender's `'evcr'` (param 57), and its **block** value divided by `'evbl'` (param 56), all inside `Combat_ResolveDamage` with the same 1.0/100.0 constants. Worth knowing before recovering any further opposed stat: expect a divisor, not a subtraction. |
| Unarmed damage = 5 | **OWN-DESIGN (disclosed)** | Labelled "Own [design]." |
| Player **MaxMP = Int × 10 × 1.02^(level−1)** | **RECOVERED IN FULL (2026-09-15)** | Supersedes the earlier "growth only" reading. `GObjPC_InitStats` does not compute stats arithmetically — it declares a dependency graph (class `GParamKeeper`, named in its own assert) of 30 edges, and mana is the chain `Int(2) → 53 → 55 → MaxMP(4)`, with `1000.0` (`.rdata 0x00b462ac`) in slot 3 of param 53 and `1.02^(level−1)×100` (`0x00b45ea0`) in slot 3 of param 55. The keeper evaluates a node as `slot0×(slot1+100)/100×slot2×slot3/100` (slot 3 defaulting to 100), so the chain collapses to `Int × (1000/100) × 1.02^(level−1)`. **The base was never a constant — it is the stat.** `character.MPBase` is deleted. |
| Player **MaxHP = Str × 10 × 1.02^(level−1)** | **RECOVERED IN FULL (2026-09-15)** | The same graph, chain `Str(1) → 52 → 54 → MaxHP(3)`. Two layers had to come off first: the parameter's identity travels in **DI**, which Ghidra never assigned to an argument (so all 297 call sites decompiled to `SetParam(slot, 0, value)` with the identity silently gone), and the callers materialise each id through **chains of LEAs** off a neighbouring constant rather than a `MOV`, so there was nothing to grep. `client/tools/ghidra/ResolveRegArg.java` resolves both and writes the ids back as comments, so the dump now carries them inline. The ids are pinned by use-site, not shape: 3/4 are MaxHP/MaxMP because `GObjMob_PublishStats` pushes `refobj+0x19c`/`+0x1a0` at them and `+0x19c` is the field `RefObjChar_ExtractData` asserts `m_dwMaxHP > 0` on; 0/1/2 are Level/Str/Int from `charData+0x65/+0x74/+0x76`, with 0 confirmed a second time by the monster path pushing its level virtual at the same id. **Starting Str/Int = 20 remain own design, disclosed** — nothing writes a constant to `charData+0x74`/`+0x76` anywhere in the binary, because character creation happened on the database side. |
| Monster **MaxHP** | **RECOVERED (2026-09-14)** | Real `characterdata` col 59. Recovered from the pserver's own `SR_GameServer.exe`: `RefObjChar::ExtractData` deserialises a row into `CRefObjChar`, whose layout runs `uint8 Lvl; uint8 CharGender; uint32 MaxHP; uint32 MaxMP;` at 0x198/0x199/0x19c/0x1a0, and 0x19c is the field the binary asserts `m_dwMaxHP > 0` on. Confirmed four ways against the data (col 57 = the already-verified Level, col 58 = CharGender 1/2, col 59 = MaxHP, col 60 = MaxMP = 0 for every monster). `monsterSpec.MaxHP`. |
| Monster def / atk / gold | **OWN-DESIGN (disclosed)** | `cmd/server` `monsterStatsForLevel`: a disclosed curve off the grounded level. No real table for these three has been identified. Rarity multiplies gold only — it no longer touches HP, which is now real. |
| Monster spawn positions (XYZ) | **OWN-DESIGN (disclosed)** | Clustered at two farmland anchors (region 96/168) measured flat/walkable/object-clear; the coordinates themselves are ours, disclosed in the `monsterSpecs` comment. |
| EXP reward per kill | **RECOVERED (2026-09-15)** | **`leveldata` column 5, taken at `min(killerLevel, victimLevel)`.** `Formula_MonsterExpReward` (004105d0) computes `scaleByWindow × levelRecord[+0x1c] × victim[0x1cd8] × scaleByDiff`, floored at 1, and its result goes to `GObjPC_GiveExp` (vtable slot 421, read out of the vtable at `0x00af6090`). What `+0x1c` *is* was settled by a second, independent use-site: `FUN_00631050` hands `entry[0x1c] × multiplier` straight to `GObjPC_GainExpAndLevel` as an exp amount, no formula in between. That it is **column 5** was settled by elimination rather than curve-matching — column 2 is at `+0x10` (confirmed value-for-value against the real file: 1,1,1,2,2,4,5,6,7,9,12,15), columns 3 and 4 are plain zero integers occupying `+0x14`/`+0x18`, so the next 4-byte field is column 5; every other packing puts a provably impossible value at `+0x1c` (skipping the zero columns lands on column 7, making a level-1 kill worth 15,000,000 exp). **Verified identical in the ORIGINAL client's `leveldata.txt` and the pserver's**, so it is not a private-server edit — only the job-cap columns 6-8 differ. `leveldata.Table.ExpUnit`/`KillExp`. **The minimum-level rule is the important half**: out-levelling a monster, or being power-levelled, pays at the weaker party's rate. The two level-gap scalers are NOT recovered and are treated as 1.0 — disclosed. |
| Loot table values | **OWN-DESIGN (disclosed)** | Placeholder item IDs 500–502; keyed by name (real tables key by `RefMonsterID`, mapping not yet confirmed). |
| Shop prices | **RECOVERED** | Real Price/SellPrice from the client's own itemdata (`_RefObjCommon` cols 26/31; Copper Sword 890/427). The stat formula is now only a fallback for an import that predates them. The DB's `_RefPricePolicyOfItem` is still just the cash-shop table; the vendor prices were in itemdata all along. |
| Quest catalog / gold rewards | **OWN-DESIGN (disclosed)** | "own design"; references the placeholder monster content. **Settled 2026-09-14 — quest objectives can never be grounded, because they are not data.** This project long believed `questcontentsdata.txt` carried an "opaque objective encoding"; it carries none. The client's copy (17 cols × 989 rows; the pserver server ships a trimmed 12 × 202) is quest codename, Korean name, category, **next quest in the chain**, a flag, then **cols 5–12 = a list of step-description string ids** (`SN_CON_<quest>_01`…`_08`) — the quest window's text, nothing more. `questdata.txt` is identity only. The server's RTTI carries `CRefQuest`/`CRefQuestReward`/`CRefQuestRewardItems` — **reward** tables — but no objective/mission refdata class, and `_CHARQUEST` persists only CharID/QuestID/Status/AchievementCount/StartTime. So "kill N of X" lives in server code (`CBasicQuest`, `SetupMissionNPC`), which no archive contains. **What IS real and should be used: quest identity, required level, names, step descriptions, the chain, and rewards** (`refquestrewarditems.txt`, 366 rows — col 1 quest codename, col 3 real ITEM codename, col 7 quantity). Same shape as monsters: real identity + real rewards, disclosed objectives. |
| EXP overflow carries to next level | **RECOVERED (2026-09-11)** | Grounded in `sro_client.exe` `FUN_008a97c0`: the level-up loop subtracts each level's requirement from the running EXP and increments the level, carrying the remainder. `leveldata.Advance` matches. |
| Max character level = 110 | **RECOVERED (2026-09-11)** | Same handler caps its loop `while (level != 'n')` (0x6E = 110), independent of the 139-row table. `leveldata.MaxCharacterLevel`. |
| Max-level EXP held at requirement−1 (not zeroed) | **RECOVERED (2026-09-11)** | Same handler, cap branch: `exp = requirement - 1`. `Advance` corrected from its earlier zeroing assumption. |
| Level-up refills HP; stat points granted at level-up | **BEHAVIOUR ASSUMPTION** | Server-authoritative (not in the client EXP handler). The curve it sits inside is **no longer own design** — the refill now goes to the recovered `Str × 10 × 1.02^(level−1)` maximum. The refill *event* itself is still an assumption. |
| Berserk gauge (fill/hit, orbs, duration, damage bonus) | **OWN-DESIGN (disclosed)** | `internal/berserk`: "The mechanic is the real one" (SRO's five-orb berserk); the numbers (Fill 8/hit, 5 orbs, 20 s, +50 %) are "this project's own disclosed design … server-side balance values that were never recovered." The client's own `GDR_PMI_CIRCLE0..4` (5 mini-info circles) drive the orbs — a structural mapping, not decompile-confirmed. |
| PvP (duel) damage | **OWN-DESIGN (disclosed)** | Reuses the same combat model, mitigated by the defender's real equipped armour; no separate formula. |
| Inventory size = 50 slots | **OWN-DESIGN (disclosed)** | Labelled "our [own design]"; not claimed as the real client's slot count. |

## Client — mechanics / behaviour

| Item | Status | Evidence / disclosure |
|---|---|---|
| `REAL_CHARACTER_NATIVE_HEIGHT` = 14.34 | **RECOVERED (measured)** | From real character mesh bounds; carries an honest open caveat that the real client may apply a further scale this project hasn't found. |
| Region axes (region y→X, x→Z) and span 1920 | **RECOVERED** | Confirmed twice (terrain-edge + minimap tiling); `AGENTS.md`, `WORLD_ISSUES.md`. |
| Named-zone region coords (Jangan 97/168, Dunhuang 98/157, …) | **RECOVERED** | `cmd/scanlandmarks` / `cmd/findregionassets` over all 4,050 real regions; densest real placement cluster. |
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

- **Level-up refills HP; derived stats (maxHP/maxMP from level+Str/Int, phys/mag atk·def).** The
  biggest remaining ground, and the same recovery the character window needs. Entry points found:
  the client's `CIFPlayerInfo` player-info window (RTTI `.?AVCIFPlayerInfo@@`) and the character
  struct at `DAT_00eef5ec` (level@0x868, EXP@0x870). The local player's maxHP is largely
  server-set in the client, so this may need cross-checking against the authoritative server logic
  — note the on-disk `SR_GameServer.exe` is a third-party emulator bundle (y0gi), *not*
  authoritative; the official client stays the ground truth.
- Attack-combo order (the four animation types are real; the order is ours).
- Monster always counterattacks; no dodge/crit/evade (disclosed own-design combat).
- The rest of the own-design economy/combat layer (damage, flat HP, monster stats, prices, quests,
  loot values, gold) — placeholder by intent, to be replaced from `refdata` + the recovered
  derived-stat formulas.
