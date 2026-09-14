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
that document the RE *dead-end* that forced an own-design fallback (skills: all 118 `_RefSkill`
columns catalogued, none encodes a damage value). One earlier such dead-end was later reopened:
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
| Skill table (`refdata.Skill`) | **RECOVERED (schema)** | Curated subset of real `_RefSkill` (118 cols confirmed). Explicitly notes **no** real damage/effect column was found. |
| Drop schema (`refdata.MonsterDrop`/`DropGroupEntry`) | **RECOVERED (schema)** | Real `_RefMonster_AssignedItemRndDrop`/`_RefDropItemGroup`; `refdata_schema.md`. |
| Starter-kit item IDs | **RECOVERED** | The item table's own `_A_DEF` code-name marks starters; real rows (3643–3645 / 3652–3654 / 3632). Two picks (garment family, sword) **disclosed** as this project's, because the original chooses by creation-class the server doesn't record. |
| Monster identity — CodeName, Level, Rarity, Name (`MOB_CH_*`) | **RECOVERED** | Real `characterdata` (`_RefObjChar`): CodeName is the row key the model resolves by; Level is col 57, Rarity col 15, and the English Name is `textdata_object`'s resolution of the row's `SN_` key. Re-verified 2026-09-13 for the whole 11-species Jangan ladder (levels 1–10 + Earth Ghost 27) — every CodeName, level, rarity 0 and name matched real data. |
| Combat damage model (`base + bonus − defense`, floor 1) | **OWN-DESIGN (disclosed)** | `combat.go`: "Entirely own design." No crit/dodge/evade (disclosed open item). |
| Unarmed damage = 5 | **OWN-DESIGN (disclosed)** | Labelled "Own [design]." |
| Player MaxHP = 100 + 40·(level−1); no MP pool | **OWN-DESIGN (disclosed)** | `character.go`: "Own design -- no real max-HP table was recovered (it is server-side, like monster HP)." `MaxHPForLevel`. **Narrowed 2026-09-14:** the player formula is now known to be *computed*, not table-driven, and three candidate sources are definitively ruled out — characterdata's own player rows (`CHAR_CH_*`) carry MaxHP=0/MaxMP=0; neither `LevelData.txt` nor `RefLevel.txt` has an HP/MP column; and the server's `_Char` table persists `CurLevel`, `Strength`, `Intellect`, `RemainStatPoint` but **no** MaxHP/MaxMP. So max HP/MP are derived from level + Str + Int in `CGObjPC` code. That function was not located this pass (the 5 assert-bearing `GObjPC.cpp` functions are not it), so nothing is shipped for MP — the pool stays absent rather than guessed. |
| Monster **MaxHP** | **RECOVERED (2026-09-14)** | Real `characterdata` col 59. Recovered from the pserver's own `SR_GameServer.exe`: `RefObjChar::ExtractData` deserialises a row into `CRefObjChar`, whose layout runs `uint8 Lvl; uint8 CharGender; uint32 MaxHP; uint32 MaxMP;` at 0x198/0x199/0x19c/0x1a0, and 0x19c is the field the binary asserts `m_dwMaxHP > 0` on. Confirmed four ways against the data (col 57 = the already-verified Level, col 58 = CharGender 1/2, col 59 = MaxHP, col 60 = MaxMP = 0 for every monster). `monsterSpec.MaxHP`. |
| Monster def / atk / gold | **OWN-DESIGN (disclosed)** | `cmd/server` `monsterStatsForLevel`: a disclosed curve off the grounded level. No real table for these three has been identified. Rarity multiplies gold only — it no longer touches HP, which is now real. |
| Monster spawn positions (XYZ) | **OWN-DESIGN (disclosed)** | Clustered at two farmland anchors (region 96/168) measured flat/walkable/object-clear; the coordinates themselves are ours, disclosed in the `monsterSpecs` comment. |
| EXP reward per kill (`ExpFor` = maxHP) | **OWN-DESIGN (disclosed)** | Placeholder; real per-species `ExpToGive` not loaded yet. |
| Loot table values | **OWN-DESIGN (disclosed)** | Placeholder item IDs 500–502; keyed by name (real tables key by `RefMonsterID`, mapping not yet confirmed). |
| Shop prices | **RECOVERED** | Real Price/SellPrice from the client's own itemdata (`_RefObjCommon` cols 26/31; Copper Sword 890/427). The stat formula is now only a fallback for an import that predates them. The DB's `_RefPricePolicyOfItem` is still just the cash-shop table; the vendor prices were in itemdata all along. |
| Quest catalog / gold rewards | **OWN-DESIGN (disclosed)** | "own design"; references the placeholder monster content. |
| EXP overflow carries to next level | **RECOVERED (2026-09-11)** | Grounded in `sro_client.exe` `FUN_008a97c0`: the level-up loop subtracts each level's requirement from the running EXP and increments the level, carrying the remainder. `leveldata.Advance` matches. |
| Max character level = 110 | **RECOVERED (2026-09-11)** | Same handler caps its loop `while (level != 'n')` (0x6E = 110), independent of the 139-row table. `leveldata.MaxCharacterLevel`. |
| Max-level EXP held at requirement−1 (not zeroed) | **RECOVERED (2026-09-11)** | Same handler, cap branch: `exp = requirement - 1`. `Advance` corrected from its earlier zeroing assumption. |
| Level-up refills HP; stat points granted at level-up | **BEHAVIOUR ASSUMPTION** | Server-authoritative (not in the client EXP handler), and sits inside the own-design `MaxHPForLevel` curve. Grounding it needs the real max-HP/derived-stat formula — the same recovery the character window needs. Tracked as the next target. |
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
  stat. Still not positive identification — no use-site on a `CRefObjChar` has been found that names
  it — so monster exp stays the disclosed `ExpFor`.

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
