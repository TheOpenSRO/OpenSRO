# RE completion ledger

**What "100%" means here.** Both binaries are already decompiled in full —
`SR_GameServer.exe` (30,385 functions) and `sro_client.exe` (39,851), 0 failures,
0 skipped, on the RE box at `/var/tmp/decomp_server` and `/var/tmp/decomp_client`
(see `client/tools/ghidra/README.md`). Dumping is done. **This ledger tracks the
part that is not: every game value this project runs on being either recovered
from real data/binary, or honestly disclosed as own design with the reason.**

A line is **GROUNDED** when a real citation exists (data file + column, or a
binary function + offset). It is **DISCLOSED** when it is ours and labelled as
such. It is **OPEN** when nobody has tried hard enough to say which.

Score = GROUNDED / (GROUNDED + OPEN). Disclosed-by-necessity does not count
against completion *if* the reason is proven (the data genuinely does not exist),
which is itself a recovery — quest objectives are the model for that.

## Grounded

| Value | Where it came from |
|---|---|
| EXP curve | `leveldata.txt` col 1 |
| EXP overflow carry, level cap 110, max-level bar | client `FUN_008a97c0` |
| Mastery level-up SP cost | `leveldata` col 2 (server `FUN_0059c4e0` sums `entry+0x10`) |
| Skill damage | skill `'att'` param: percent of weapon damage + flat min–max |
| Skill cooldown / MP cost / learn gating | `_RefSkill` ReuseDelay, Consume_MP, ReqLearn_SP, mastery reqs |
| Monster identity (CodeName, Level, Rarity, Name) | `characterdata` cols 2/57/15/5 + `textdata_object` |
| Monster MaxHP | `characterdata` col 59 (`RefObjChar::ExtractData` → `m_dwMaxHP` at +0x19c) |
| Shop prices | `itemdata` cols 26/31 |
| Item max stack | `itemdata` col 57 |
| Armour/shield defence | `itemdata` cols 63/65-66/74-75/76-77 |
| Potion restore amounts | `itemdata` Param block cols 118/120/122/124 (self-labelling) |
| **Player MaxHP / MaxMP (whole formula)** | `Str×10×1.02^(lvl−1)` / `Int×10×1.02^(lvl−1)` — `GObjPC_InitStats` graph, `.rdata 0x00b462ac`=1000, `0x00b45ea0`=1.02 |
| ParamKeeper ids 0/1/2/3/4 = Level/Str/Int/MaxHP/MaxMP | `GObjPC_InitStats` pushes `charData+0x65/+0x74/+0x76`; `GObjMob_PublishStats` pushes `refobj+0x19c`/`+0x1a0`; and `Stat_ApplyTaggedModifier` maps `'int'`→2, `'hp'`→3, `'mp'`→4 independently |
| **Monster EXP per kill** | `leveldata` col 5 at `min(killerLvl, victimLvl)` — `Formula_MonsterExpReward` (004105d0) reads levelRecord `+0x1c`, result to `GObjPC_GiveExp` (vtable 0x694); `FUN_00631050` grants `entry[0x1c]*n` directly. Column settled by elimination; identical in the ORIGINAL client |
| **Monster `characterdata` cols 75–78** | `'era'`→9, `'bri'`→10, `'hra'`→11, `'cri'`→12 from `Stat_ApplyTaggedModifier`; real data: col 76 = **0** for every monster, cols 75 = 77 = **2·level+25**, col 78 = **2** |
| Stat points per level (3) | real character window |
| Quest identity, chain, descriptions, rewards | `questdata`, `questcontentsdata` cols 3/5-12, `refquestrewarditems` |
| Quest objectives are NOT data | proven absent: no objective refdata class; `_CHARQUEST` is status+count |

## Open — the actual work queue

Ordered by value. Each line names the next concrete probe, so a cold start can
pick one up without re-deriving anything.

1. **Monster combat profile — CLOSED (2026-09-15).** Every term is real now.

   | what | source | values |
   |---|---|---|
   | MaxHP | `characterdata` col 59 | Mangyang 54 … Yeoha 249 |
   | flat absorption | col 71 → param 5 | 7, 12, 22, 103 |
   | reduction % | col 73 → param 7 | = the monster's level |
   | **attack damage** | **col 83 → that skill's `'att'` param** | 17-19 … 67-79 |
   | exp per kill | `leveldata` col 5 at `min(lvl)` | 24 … 12550 |

   **Monster attack was hiding in plain sight because it is not a stat.** No
   column holds it and `GObjMob_PublishStats` never publishes a damage range —
   only `Char_PublishCombatStats` sets params 190/191, and that is the character
   path. A monster attacks with a **skill**: characterdata col 83 is its primary
   attack skill id, and the ids are named after the species itself —
   `160 = MSKILL_CH_MANGNYANG_ATTACK01`, `165 = MSKILL_CH_GYO_ATTACK02`,
   `176 = MSKILL_CH_YEOHA_ATTACK01`. That skill's `'att'` param carries the
   damage, and this project decoded `'att'` months ago for player skills. With
   no weapon to scale, the grounded skill formula collapses to `rand(min, max)`.

   The ranges rise cleanly with level across the whole Jangan ladder (17-19,
   21-23, 25-29, 30-34, 35-40, 41-47, 47-54, 60-70, 67-79), which is
   corroboration rather than the finding — the finding is the skill-id column.

   *Gold — data real, linkage inferred (2026-09-15).* `levelgold.txt` ships with
   the **original client**, shaped level → min → max (L1 = 28-59, L10 = 60-125,
   L27 = 119-250). The server's level-table manager holds a per-level gold table
   at `+0x268`, and what makes it *the gold table* rather than a lookalike is a
   use-site: `FUN_009348f0` spawns `ITEM_ETC_GOLD_03` (itemdata id 3) with an
   amount rolled straight out of it by `FUN_00724330`, which reads entries as
   `{chance, min, max}`. Three `Formulae` functions read the same table after
   `Char_GetLevel`.

   **What is not proven is that `levelgold.txt` fills `+0x268`.** The server
   references no refdata filename anywhere — it loads from its database — so no
   parser ties the file to the table. Two real things that fit perfectly, with
   the join inferred. Shipped anyway, labelled in `combat.RollGold`, because it
   is strictly better than the `10 + level*5` invention it replaces; a reader who
   disagrees can find the exact gap named in the doc comment.

2. **Death penalty — recovered, deliberately NOT shipped.** `GObjPC_OnDeath`
   (`004e6980`) pays the killer and then penalises the dead: exp loss computed as
   `levelEntry+0x1c` (the same per-level exp unit that pays for a kill) times
   **20, 100 or 300** depending on branch, applied through
   `GObjPC_GainExpAndLevel` with a **negative** amount; skill-point loss through
   `GObjPC_AddSkillPoints`, also negative and capped at what the character has;
   then a `rand` roll that can drop an inventory item via
   `CGStorage__RandomSelectNonEmptySlotForDeathPenalty`. All gated on the dead
   character's level being above 10.

   **Half the blocker is gone (2026-09-15).** `charData+0xb4` is
   **`PKPenaltyPoint`**, from `CharData_BindDBColumns`. Re-reading the penalty
   with that in hand, it is a *criminal* rule: the killer's exp **doubles** when
   the victim carries PK penalty, and the victim's own loss is **3× plus 60 skill
   points** in that case against the smaller factor otherwise.

   **CLOSED 2026-09-16. The state enum is the death CAUSE.** `param_2[0x72d]`
   (victim `+0x1CB4`) has exactly one writer, `GObjPC::ResolveDeathCauseAndDispatch`
   (`004e6ec0`), which computes it and switches on it in the same 81 bytes:
   1 -> the job-suit path, **3/4/5 -> `GObjPC_OnDeath`**, 6 -> a zone path, and
   2 is not in the switch at all, so such a death costs nothing.

   What separates 3 from 5 is a use-site, not a curve. `ResolveDeathCause`
   (`004e6590`) ends `return (-(uint)(IsKilledByPlayer != 1) & 0xfffffffe) + 5`
   — 5 when it returns 1, else 3 — and `IsKilledByPlayer` (`004eb390`) gates on
   **vtable slot 7 for both parties**, which the engine's own
   `"## Illegal ##  IGObj::IsPC Entered! TypeID: %u"` stub names `IsPC`
   (`IsNPC` at slot 8, `IsMonster` at slot 10 for corroboration). So **5 is a
   player kill and 3 is not**, which agrees with the multipliers already read out
   of the branches — a monster kill costing more than a player kill is what the
   table says. That agreement is the check, not the finding.

   Shipped as `leveldata.DeathCause` with `DeathPenaltyFactorFor`, so the engine's
   own `byte != 5` test is encoded rather than `== 3` (cause 4 takes the
   not-a-player branch with it). srrevamp still only ever reaches
   `DeathCauseMonster`; the rest are implemented, tested and disclosed
   unreachable. Three names applied: `ResolveDeathCauseAndDispatch`,
   `ResolveDeathCause`, `IsKilledByPlayer`.

   This also corrected a name. `004e6980` was called `GObjPC_GrantKillReward`
   after an earlier pass read only its first half; it is the death handler, and
   `ApplyKnownNames.java` gained a `force` mode so the table can fix its own
   mistakes rather than only add to them.

3. **Combat damage model — the mitigation formula is RECOVERED; the model is
   not yet shipped.** srrevamp still runs `base + bonus - defence, floor 1`, own
   design. The real one is now partly in hand.

   **The unlock was the read side.** Two ticks were lost hunting inlined keeper
   reads (`obj[0x7c+N]`) that collide with every other struct at byte 0x204.
   That was the wrong shape entirely: stats are read through a **virtual at
   vtable offset 0x104 that takes the param id as a literal argument** —
   `(**(code **)(*obj + 0x104))(0xbf)`. So every param read in the binary is
   greppable, with its id visible. 141 read sites. This is the single most
   useful handle found for the stat system and it should be the first thing
   reached for next time.

   **COVERAGE CLAIM CORRECTED 2026-09-16 — it sees about half.** There is a
   second read path, `EvaluateParam` (`0x004b3740`) with the id in **EAX**, and
   **29 param ids are read only through it** — including 195 (the berserk
   duration bonus) and 256/257/258 (the death-penalty reduction, which this
   project had to disassemble by hand for exactly this reason). Counted: the
   vtable path has 186 sites over 53 ids, `EvaluateParam` 65 sites over 40. One
   further id is *computed* (`lea eax,[esi+0x41]` with `esi = -5` → param 60,
   the berserk base duration), so no id-literal grep on either path finds it.
   Full note: `docs/protocol/param_registry.md`.

   **What it produced:**

   - `Formula_RollWeaponDamage` (`0040f8d0`) — the damage roll:
     `rand() % (max-min+1) + min`, with **min = param 191, max = param 190**,
     returning 0 when `max <= min`. `Char_PublishCombatStats` sets 190/191 and
     192/193 as the two types' min/max pairs.
   - `Formula_MitigatePhysicalDamage` (`0040e450`) and
     `Formula_MitigateMagicalDamage` (`0040e830`) — twins, gated on bits 4 and 8
     of the flags at `+0x230`, structurally identical:

     ```
     damage = X / (1 + reduction% / 100) - flatAbsorb        (floored at 0)
     ```

     with **param 7** the reduction percentage on one side and **param 8** on the
     other (`0x00b45ac0` = 1.0, `0x00b45af0` = 100.0). So mitigation is
     *percentage-based with a flat term*, not the flat subtraction srrevamp
     currently uses.

   That also half-answers open item 1: params 5/7 are one damage type and 6/8
   the other, and **param 7/8 is a percentage reduction**. Joined to the column
   map, a monster's cols 73/74 → params 7/8 hold *exactly its level*, so a
   level-10 monster mitigates 10%. Physical-vs-magical rests on the player stat
   graph feeding param 5 from Strength and param 6 from Intellect.

   **CLOSED 2026-09-16, and this entry was stale in two ways.** The model IS
   shipped — `combat.MitigateDamage` has carried
   `raw / (1 + pct/100) - flat` since v0.1.1xx, with the `push 0x5` disassembly
   as its citation — and the "which object" question had already been settled
   once, by the formula's own monotonicity (a larger param 7 yields less damage,
   so it is the defender's).

   The register walk settles it a **second, independent way**: the formula takes
   the defender in **EDX** and the attacker as its **first stack argument**, and
   it asks the EDX object `IsMonster` (slot 10) then `GetMonsterClass` (slot 75)
   before reading a param off the *other* object. A bonus conditioned on what
   the target is belongs to the attacker, so EDX is the target. Two routes, one
   answer — so params 5/6 are defence, as shipped.

   **What is new is the whole pipeline, split by side** — the param registry had
   bounds for these eight ids and no roles. Full table in
   `docs/protocol/param_registry.md`; the shape is

   | # | side | param (phys / mag) | role |
   |---|---|---|---|
   | 1 | defender | 5 / 6 | flat absorption, subtracted |
   | 2 | defender | 7 / 8 | percentage reduction, the divisor |
   | 3 | attacker | 128 **or** 129 | chosen by `test [ecx],0x2` |
   | 4 | attacker | 259 | **only when the defender is a monster of class 3** |
   | 5 | attacker | 189 | gated on flag bit `0x4` |
   | 6 | attacker | 178 / 179 | |
   | 7 | defender | 180 / 181 | |

   The registry's own bounds corroborate rather than being assumed from: param 5
   is capped at 9,999,999 (a flat quantity), param 7 at 10,000 (a percentage
   with headroom), and every other id here at exactly 100.

   Step 4 is an **anti-monster-class damage bonus** that srrevamp cannot reach —
   nothing here publishes param 259 — as are steps 3, 5 and 6. Recorded in
   `combat.go` so they read as unreachable rather than as a gap in the formula.

4. **Berserk numbers** (fill 8/hit, 20 s, +50 %) — ours. The mechanic and the
   five orbs are real.
   **The recorded next probe was WRONG and is withdrawn (2026-09-15).** It said
   to chase the `'zb'` tag; the client's own text says `PARAM_ZB` = **"Zombie"**,
   a status effect, nothing to do with berserk. Berserk is **"Hwan"** internally
   (`PARAM_HWAN_TIME_INCREASE` = *"Berserker time %d sec. increased"*,
   `UIIT_CTL_TC_ACQUISITION_WHAN` = *"Chance of Obtaining Berserk Gage"*).
   `hwanleveldata.txt` was checked and is **not** it either — 255 rows of
   *titles* ("Ambassador", "Champion", "Conqueror"), not gauge values. The
   numbers look genuinely server-side; *next probe:* the `HWAN`/`WHAN` naming in
   the server binary, not the client's data.
5. **Monster spawn positions — the "proven absence" was WRONG (2026-09-15).**
   This line used to read *"ours by necessity (`npcpos.txt` has no monsters).
   Likely genuinely absent; prove it and it stops counting as open."* Trying to
   prove it disproved it.

   **`npcpos.txt` is overwhelmingly monster spawns.** Of its 12,367 rows:
   **12,110 `MOB_`**, 248 `NPC_`, 8 `STRUCTURE_`, 1 unresolved. The old claim
   almost certainly came from grepping the file for `"MOB_"` — which returns
   zero, because npcpos stores **numeric object ids**, not codenames. Resolving
   those ids against `characterdata` is what settles it, and `2124` →
   `MOB_KT_DESERTTRUNKZ_CLON` was the first thing that looked wrong.

   Row shape: `objectId, regionId, localX, localY, localZ`. Every one of the
   eleven species in this project's Jangan roster has real spawn points:

   ```
   MANGNYANG 1933  55 spawns      WATERGHOST_CLON 1938  20
   BIGEYEGHOST_CLON 1934  37      WATERGHOST      1939  31
   BIGEYEGHOST 1935  37           TOMBSTONE_CLON  1950  35
   GYO_CLON  1936  41             STONEGHOST      1941  36
   GYO       1937  30             YEOHA           1943  26
                                  WC_EARTHGHOST   1963  65
   ```

   Region ids 23716–25511 decode to y 92–99 / x 166–171 — the Jangan area, as
   expected. The ids also cross-check: 1933 is the `RefMonsterID` this project
   already recorded for Mangyang.

   **The region→server conversion is now derived and sanity-checked
   (2026-09-15).** npcpos rows are `(objectId, regionId, localX, localY,
   localZ)`. The region id packs the project's own `x/y` as `(x << 8) | y` —
   Jangan `97/168` is **25000**, and the ladder's regions cluster 23716–25511
   around it, which is the first confirmation. The client's transform
   (`World3D.gd`) is `worldX = y·1920 + localX`, `worldZ = x·1920 + localZ`, and
   the server's `(0,0,0)` is `ZONE_SPAWN_LOCAL["97/168"]` = local (1002, 1020)
   in that region. So:

   ```
   rx = regionId >> 8 ;  ry = regionId & 0xff
   serverX = (ry·1920 + localX) − 323562
   serverZ = (rx·1920 + localZ) − 187260
   ```

   **It sanity-checks strongly: distance from the town square rises with monster
   level.** Nearest spawn per species, in the server's own frame:

   ```
   Mangyang        lvl 1   2,342     Water Ghost      lvl 7   4,011
   Small-eyed      lvl 2   4,129     Tomb Stone Ghost lvl 8   7,103
   Big-eyed        lvl 3   3,876     Stone Ghost      lvl 9   6,873
   Old Weasel      lvl 4   3,559     Yeoha            lvl 10  6,501
   Weasel          lvl 5   4,088     Earth Ghost      lvl 27 23,246
   Water Ghost sl. lvl 6   4,290
   ```

   The level-1 monster is a short run from spawn and the level-27 one is 23k
   away in another town — exactly the shape a real ladder should have, from a
   transform that knew nothing about levels.

   **MEASURED, CORRECTED and WIRED (2026-09-15).** The derivation above has the
   **wrong sign on Z**, and the sanity check could not have found it. Measured
   on the render box at eleven columns, reading the client's own region group
   nodes (`World3D.gd`'s `_qa_columns_report`), in a world centred on Jangan's
   real region 97/168:

   ```
   worldX = (ry − 168)·1920 + (localX − 960)
   worldZ = (97 − rx)·1920 + (960 − localZ)
   ```

   Two corrections, both of which change where a monster lands:

   - **World Z is mirrored**, consistently: local z runs opposite to world Z
     *inside* a region and the region-to-region step runs opposite too, so the
     two agree and regions still tile seamlessly. The derived formula predicted
     `(130, −1560)` for the first real Mangyang row; the measurement is
     `(130, 2280)`. Shipping the prediction would have put that monster 3,840
     units away, on the far side of the town. World X has **no** such mirror —
     which is why both axes were probed in both directions (`97/169`→`(+1920,0)`,
     `97/167`→`(−1920,0)`, `98/168`→`(0,−1920)`, `96/168`→`(0,+1920)`) rather
     than one being assumed from the other.
   - **The origin is the centre region's geometric centre, not the spawn
     point.** The old constants 323562 and 187260 were built from
     `ZONE_SPAWN_LOCAL` (1002, 1020); the true origin is local (960, 960), and
     the client *moves* the player from there to the landing spot afterwards.
     That is the 42-unit X offset between the two.

   **Why the sanity check passed anyway, and this is the lesson:** the old Z is
   exactly `−(true Z) + 900`. A sign flip applied to *both* the monster and the
   reference point preserves every distance between them — it is an isometry —
   so a table of distances is mathematically **incapable** of detecting it. The
   curve looked right because it was right; it just was not evidence for the
   thing it was being read as evidence for. This is the concrete case for
   *never promote a value on a suggestive curve alone — a use-site settles it.*

   Wired for Mangyang, the one species measured so far. `npcpos` has exactly
   four rows in region 96/168 — the farmland immediately south of town — and
   all four are id 1933, which `characterdata` gives as `MOB_CH_MANGNYANG` at
   level 1 with 54 HP: the same species and the same two numbers the roster
   already carried, reached independently. All four were measured walkable
   first: one surface each, landing height equal to terrain within 0.05, no
   blocking edge within 40 units, nearest placed-object navmesh cell ≥174 units.
   The transform lives in `server/internal/worldmap` with all eleven columns as
   its tests, and the roster stores the `npcpos` rows verbatim so the grounded
   fact is what is in the source and the world coordinate is derived.

   Their authored heights disagree with the measured terrain by 11–41 units and
   are deliberately dropped: the client resolves standing height from the
   region's walkable graph and ignores the authored y.

   *Next step:* the other ten species. Their real regions are known
   (Mangyang 95–96/166–170, Water Ghosts 100/166–169, Stone Ghosts
   100–101/171–173, Yeoha 95–98/163–164, Earth Ghost 101–102/154–155), but each
   needs its own walkability pass before wiring, and most sit 2+ regions out —
   beyond the radius-2 grid the town loads, so they also need the player to
   actually travel there.

   Found while deriving it: `World3D.gd`'s comment above `ZONE_SPAWN_LOCAL` said
   the town square is local **(1002, 917)** while the constant has always been
   **(1002, 1020)**. Anything derived from the comment would have been 103 units
   out. Corrected.

6. **Quest objectives — absence RE-TESTED and CONFIRMED, now with the shape
   (2026-09-15).** Re-examined against the same evidence that overturned
   `npcpos`: the 85-table SQL refdata catalogue and `_CHARQUEST`'s
   `QuestData1`/`QuestData2`. The conclusion holds — objectives are code — and
   the re-test recovered *how*:

   **Each custom quest gets a compiled three-handler lifecycle.** The triple
   `QuestHandler_SetupQuest` / `QuestHandler_OnUpdate` / `QuestHandler_OnDead`
   (`008699a0` / `00869740` / `00869640`) all resolve **the same name id
   (0x15a)** through a virtual and log `"HandlerSetupQuest_%s(%d)"`,
   `"HandlerOnUpdate_%s()"`, `"HandlerOnDead_%s()"` — so the `%s` is the quest's
   name fetched *for the log line*, and the handler bodies are compiled C++ for
   that one quest. They call the generic helpers `CBasicQuest__SetupMissionNPC`
   and `CBasicQuest__PayQuest`.

   `_REFQUEST` exists as a DB table (`DB_Load_RefQuest`, `008341b0`) but is the
   server's copy of quest **identity and metadata** — the counterpart to
   `questdata.txt`, not a table of objectives.

   So the entry sharpens from "objectives live in server code somewhere" to
   **"each quest is a compiled SetupQuest/OnUpdate/OnDead triple over
   `CBasicQuest`"**. Any objectives srrevamp ships are own design, and now it is
   clear they always would have been — there is no table to import, in a file or
   a database.

   **The RTTI pass put a number and a name on it (2026-09-15).** Those compiled
   quests are classes, and the binary names every one: **153 `CQNO_*` objective
   classes** (201 quest classes in total), each with its own vftable — which is
   what the triple-handler lifecycle looks like from the type system's side.
   The names are the quests' own ids (`CQNO_CH_HWAN_1_1` … `CQNO_WC_SOLDIER_SO_1`),
   so a quest can now be matched to its compiled code by name rather than by
   hunting its log string. That is the *confirmation* of "objectives are code",
   not a contradiction of it: 153 hand-written classes is exactly what having no
   objective table looks like.

7. **Loot tables — absence RE-TESTED and CONFIRMED, and now actionable
   (2026-09-15).** After `npcpos` showed that a recorded absence can simply be
   wrong, this one was re-examined against evidence the original conclusion did
   not have: the **88-type refdata catalogue** and the **56 DB table schemas**.
   Neither contains anything drop-related — the only `reward` types are quest,
   event and shop. The absence holds.

   But the re-test turned a dead end into something an operator can act on. The
   drop tables are **SQL refdata**, and the binary names all four:

   ```
   _REFDROPITEMGROUP                          loader DB_Load_RefDropItemGroup
   _REFDROPITEMASSIGN                         loader DB_Load_RefDropItemAssign
   _REFMONSTER_ASSIGNEDITEMDROP               loader DB_Load_RefMonster_AssignedItemDrop
   _REFCUSTOMIZINGRESERVEDITEMDROPFORMONSTER  loader FUN_0082c100
   ```

   The structure is recovered too. `RefItemDrop.cpp` is a 28-function module, and
   `CRefDropData__AddAssignedItemDrop` walks the assignments as a **48-byte
   (0x30) stride array**, comparing a roll against a **float at record+8** — the
   drop probability. The error string names the key relation outright:
   *"Can't find ItemGroupID(%d) within _RefMonster_AssignedItemRndDrop Table"* —
   a monster maps to an item **group** id, and the group maps to items.

   So the entry is no longer "no drop table exists anywhere". It is: **drops are
   database refdata; here are the four table names, the relation between them,
   and the record shape.** An operator with a real server database can import
   them, and this project knows what to ask for.

8. **Inventory size (50)** — ours, and now known **not** to be a constant in the
   real game: `InventorySize` is a persisted per-character `_CHAR` column
   (charData `+0xac`), so inventory is expandable per character. The starting
   size is set on the database side, the same wall as starting Str/Int, so it
   stays disclosed — but as "a per-character value we fix at 50", not "a number
   nobody has found". **Unarmed damage (5)** — still ours.

## The client's refdata catalogue: 88 type ids

`Client_LoadAllRefData` pushes a **type id** alongside each `%stextdata\<file>`
name, and `Client_LoadRefDataFile` switches on that id. Pairing the two recovers
the complete enum — every reference-data file the client loads, with its id:

```
    1 skilldata_virtual                     2 itemdata                          
    3 worldmap_mapinfo                      4 worldmap_localinfo                
    5 characterdata                         6 gameguidedata                     
    7 usableresobjiddata                    8 leveldata                         
    9 actionwnddata                        12 erasableskill                     
   13 erasablemastery                      18 teleportdata                      
   19 teleportlink                         20 teleportbuilding                  
   21 npcchat                              23 skillgroup                        
   24 magicoption                          25 questdata                         
   26 questcontentsdata                    28 dg                                
   29 npcpos                               30 gachaitemset                      
   31 gachanpcmap                          32 levelgold                         
   33 fmncategorytreedata                  34 fmntidgroupmapdata                
   35 refshop                              36 refshoptabgroup                   
   37 refshoptab                           38 refmappingshopwithtab             
   39 refpackageitem                       40 refshopgoods                      
   41 refscrapofpackageitem                42 refpricepolicyofitem              
   43 refaccesspermissionofshop            44 reftreatitemofshop                
   45 refrewardpolicytobuyscrapitem        46 refrewardpolicytosellpackageitem  
   47 refrewardpolicytosellscrapitem       48 refconditiontosellpackageitem     
   49 refconditiontobuyscrapitem           50 refconditiontosellscrapitem       
   51 shopitemstockquantity                52 refshopgroup                      
   53 refmappingshopgroup                  54 siegefortress                     
   55 eventzonedata                        56 gameworlddata                     
   57 atstructeffect                       58 siegefortressitemforge            
   59 siegefortressbattlerank              60 siegestructupgradedata            
   61 force_addobject                      66 magicoptionassign                 
   67 refgachatreeforclientuidata          68 hwanleveldata                     
   69 eventdata                            71 worldmap_instanceinfo             
   72 event_npc_look                       74 refabilitybyitemoptleveldata      
   75 refskillbyitemoptleveldata           76 refmagicoptbyitemoptleveldata     
   77 itemeffect                           78 refoptionalteleport               
   79 eventguidedata                       80 item_grouping                     
   81 refsetitemgroup                      82 specialnpcdata                    
   83 maxtradescaledata                    85 mallitemmenulistdata              
   86 refshopitemstockperiod               87 gameworldconfigdata               
   89 worldmapguidedata                    90 eventword                         
   91 refmagicoptgroup                     93 worldmapguidedata_region          
   94 refquestrewarditems                  95 refqusetreward                    
   97 collectionbook_theme                 98 collectionbook_item               
   99 refrentitem                         100 refeventrewarditems               
  101 refeventreward                      102 siegefortressreward               
  103 refsiegeblessbuff                   104 refsiegedungeon                   
  106 groupworld_config_forclient       
```

This is the map for any future column work: it says which switch case parses
which file, so a column question starts at a known case instead of a 155KB
function. 421 functions appear in **exactly one** case, making them that file's
parsing code; 71 were still unattributed and are now in `RefData_<file>`
namespaces (the other 350 had already been swept into modules by the chain, and
an existing namespace is never overwritten).

Incidentally it re-confirms **type 32 = `levelgold`** — the client really does
load that file, which supports (without proving) the gold linkage recorded
above. And the client's own parser for it reads exactly **three** sequential
tokens — a byte then two dwords — which grounds `levelgold`'s
`(level, min, max)` shape in code rather than in eyeballed values.

### 39 refdata files now have a readable column map

A function that appears in **exactly one** switch case *and* reads many
sequential tokens is that file's record parser — and therefore its exact
column→offset map, straight from code. 59 such parsers exist; **39 are matched
to a named refdata type** and now carry `RefParse_<type>` names. Among them the
whole shop chain this project already depends on — `refshop`, `refshopgoods`,
`refshopgroup`, `refpricepolicyofitem`, `reftreatitemofshop`,
`refscrapofpackageitem`, `refpackageitem` — plus `teleportdata`/`teleportlink`,
`magicoption`, `worldmap_mapinfo`/`localinfo`, `gameworlddata`, `siegefortress`,
`leveldata` and `levelgold`.

**So a column question about any of those is now a two-minute read instead of a
dig.** That is the practical payoff of the catalogue.

**`characterdata` is NOT among them, and that is now confirmed rather than
suspected.** Case 5 calls fourteen functions and *none* of them reads a token
directly — the per-column parse really does hide behind virtual dispatch, as
this project found the hard way when it first tried the client. The
characterdata column map stays what it is: derived from the server's
`RefObjChar_ExtractData` store order, anchored on two independently-known
fields.

### Column order is NOT offset order — a correction to how this was reasoned

Reading the client's **leveldata** parser (case 8) settles something that had
been assumed rather than checked. It stores the nine columns like this:

```
col 0 → +0x08    col 3 → +0x1c    col 6 → +0x24
col 1 → +0x10    col 4 → +0x20    col 7 → +0x28
col 2 → +0x18    col 5 → +0x30    col 8 → +0x2c
```

**Column 5 is stored out of sequence.** So "the next column is at the next
offset" is false for these records, and that assumption appears verbatim in the
grounding of the monster exp unit: *"cols 3/4 are zero ints at +0x14/+0x18, so
col 5 is at +0x1c"*.

**The shipped value (v0.1.155) survives, but on different evidence than stated:**

- The alternative readings are impossible by value. If the server mirrored the
  client's layout, `+0x1c` would be **column 6 = 15,000,000**, and
  `FUN_00631050` hands `entry[0x1c] × multiplier` *straight* to
  `GObjPC_GainExpAndLevel` — a level-1 kill worth fifteen million experience.
  Column 7 is 15,000,000 too. Only column 5 (23.5·level) is a possible per-kill
  reward.
- The offsets the server actually reads are `+0x0c`, `+0x10`, `+0x1c` — under
  packing exactly columns 1, 2 and 5: the exp requirement, the mastery cost and
  the exp unit. Precisely the three fields the game needs, and nothing spare.

So the grounding rests on **elimination plus coherence**, not on packing. Any
future column↔offset inference in this codebase must not assume packing — the
client proves it does not hold.

`ApplyNamespaceTable.java` exists for this shape of result: attribution derived
by reasoning over the decompiled C, which a Ghidra script cannot redo, arriving
as a `address<TAB>namespace` table.

## The message dispatcher, and 29 packet handlers

`FUN_00414260` reads a **uint16 opcode** out of the message buffer at `+0x1050`
and branches into a handler per opcode — a compiler-built binary-search tree,
which is why it never looked like a table. 33 distinct opcodes have handlers
across the dispatcher family, in the expected shapes: **0x3xxx requests, 0xBxxx
responses**, plus some 0x7xxx and one 0x5xxx.

The 29 handler functions are named `MsgHandler_<opcode>` — **by their opcode,
because that is what is proven**. The number is a fact the dispatcher states;
what the handler *does* is not claimed, and a handler serving several opcodes
carries the first two in its name.

**8 of those 29 were WRONG — a 28% error rate — and only a validation pass found
them.** `ValidateNames.java` now checks every bulk pass against a signal the
name did not come from, and is meant to run after each one:

| prefix | independent check | result |
|---|---|---|
| `DB_Bind_*` | calls the column-bind helper | **55/55 clean** |
| `RefParse_*` | reads ≥3 sequential tokens | **39/39 clean** |
| `MsgHandler_*` | few callers (a handler has ~2) | **8 of 29 failed** |

All eight turned out to be infrastructure the opcode-tree extractor had paired
with a nearby comparison: **seven singleton accessors** (`if (g == 0) Assert();
return g;`) and the **message buffer readers** `MsgBuf_ReadUInt8` /
`MsgBuf_ReadUInt16`. They are now named for what they are; one that could not be
identified had its name **withdrawn** rather than replaced with a guess. The
singleton shape turned out to be a small lever of its own — 34 of them in the
server, all now named.

**The original slip, and why it went unnoticed:**
`FUN_00964b60` was named `MsgHandler_7d1b`; it is the **assert helper** —
`IsDebuggerPresent` and break — with **10,357 call sites**, the most-called
function in either binary. The extractor paired an opcode comparison with the
next call, and in one branch that call was this. Renamed
`Assert_BreakIfDebugger`.

Two cheap checks would have caught it immediately, and are worth applying to any
future bulk naming:

- **Call count.** A packet handler has ~2 call sites. Every other name in the
  set does; this one had five thousand times more.
- **Address band.** Every real handler sits near the `0x41xxxx` dispatcher;
  `0x96xxxx` is infrastructure. An outlier band is a red flag on its own.

The other 28 pass both checks.

This is the **inter-server / gateway** protocol layer, not the main client one
(only 7 of the 33 are 0x7xxx).

**The client-facing protocol does not dispatch this way, and that is the
finding (2026-09-15).** Four routes were tried and none produced an
opcode→handler map:

- *More opcode switches.* Ranking functions by 0x70xx-0x75xx constants is a
  **false signal**: the stat tag literals collide with the opcode range —
  `'ps'` is 0x7073, `'zb'` is 0x7a62 — so the top hits are
  `Stat_ApplyTaggedModifier` and its family, not dispatchers.
- *`On*` handler names.* Only **10** exist in the whole server, all already
  recovered by the assert lever (`COpenMarketMgr__On*Req` is the nice family).
- *A masked opcode index.* **Zero** call sites of the form
  `(**(code **)(table + idx * 4))()` anywhere in the binary.
- *The one known handler's caller.* `FUN_0050d0c0` calls a
  `GObjPC_MsgHandler_SpecialCommand` function but contains no opcode comparison
  at all.

What it does instead: `FUN_004054d0` reads the opcode and then **walks a
registration table of subscribers** (`(id + 0x200) * 0x10 + base`), routing each
message to whoever registered. So there is no static opcode→handler table to
recover — the mapping is built at runtime, and recovering it would mean finding
every registration call site rather than reading one tree.

*Levers checked and found exhausted this pass, so nobody re-walks them:*
high-fan-in helpers (the top ten are all infrastructure — assert, `std::string`
assign, buffer write, allocator, list clear), and `__FILE__` attribution
(**zero** headroom: 153 server functions cite a path, all already namespaced,
and only one function anywhere cites two files).

## The server's OTHER refdata catalogue: 85 SQL tables

The client reads 88 textdata files. The **server reads 85 `_REF*` tables out of
its database** — it references no refdata filename anywhere, which is why every
hunt for a server-side parser has come up empty. The two catalogues are the same
reference data in two forms, and the table names are all in the binary:

`_REFOBJCHAR` `_REFOBJITEM` `_REFOBJCOMMON` `_REFOBJSTRUCT` `_REFLEVEL`
`_REFSKILL` `_REFSKILLMASTERY` `_REFQUEST` `_REFCHARDEFAULT_QUEST`
**`_REFCHARGEN`** `_REFHWANLEVEL` `_REFDROPGOLD` `_REFDROPITEMGROUP`
`_REFDROPITEMASSIGN` `_REFMONSTER_ASSIGNEDITEMDROP` `_REFMONSTER_ASSIGNEDITEMRNDDROP`
`_REFDROPOPTLVLSEL` `_REFDROPCLASSSEL_*` (10) `_REFMAGICOPT*` (4) `_REFSHOP*` (8)
`_REFSIEGE*` (11) `_REFTELEPORT` `_REFTELELINK` `_REFREGION` `_REFGAME_WORLD`
`_REFGAMEWORLDNPC` `_REFINSTANCE_WORLD_START_POS` `_REFCLIMATE` `_REFALCHEMYMERIT`
… and the rest.

**This names where three open items actually live**, which is more useful than
another round of guessing they are absent:

- **`_REFCHARGEN`** — character generation. Starting Str/Int is disclosed
  own-design precisely because nothing writes those constants in the exe; this
  is the table that would hold them.
- **`_REFHWANLEVEL`** — the berserk levels. `hwanleveldata.txt` turned out to be
  a *title* table, and the gauge numbers had no string handle; this is where
  they live. **Partly closed 2026-09-15** — see below. `hwanleveldata.txt` is
  re-confirmed as titles only: 255 rows of three columns, level plus two
  `UIO_SECOND_HWAN_CH_NAME_LEVEL_n` keys, no effect columns. The per-level
  effect list is a vector inside `CRefHWANLevel` of `{uint32 tag; uint8 value}`
  pairs, built from the tags `'DABR'` and `'SPDU'`, and its magnitudes really
  are DB rows this project does not have. **But the damage multiplier itself is
  not in that table** and is now recovered — it is a constant in the formula.
- **`_REFQUEST`** — quest refdata. Worth re-testing the standing "objectives are
  not data" conclusion against it, the way `npcpos` was re-tested.

**It also weakened a shipped value, and that is recorded in the code.** The
catalogue contains `_REFLEVEL` and `_REFDROPGOLD` but **no `_REFLEVELGOLD`** —
so the server's gold table is named after *drops*, and `levelgold.txt` may be
the client's copy of something else entirely. `combat.RollGold`'s doc comment now
says so. The value stays, because the honest comparison is against the invented
`10 + level*5` it replaced, and an operator supplying `_REFDROPGOLD` supersedes
it outright.

## The real game's persisted data model

One helper binds every database column to its struct offset, and **60 functions
call it** — one per table. `NameDBBinders.java` names them all `DB_Bind_<TABLE>`
and writes each table's columns into its plate comment, so the schema lives in
the program. **55 named in a single pass**, which is the largest naming return
from one lever since the attribution chain.

It is self-validating, which is rare here: the `_CHAR` binder reproduces four
offsets this project had already derived by entirely unrelated routes —
`Strength` 0x74, `Intellect` 0x76, `CurLevel` 0x65, `RemainSkillPoint` 0x80, all
exact. A map that gets four known answers right is worth trusting for the rest.

The tables, by size: `_CHAR` (39), `_ITEMS` (19), `_OpenMarket` (16),
`_GUILDMEMBER` (15), `_TIMEDJOB`/`_TIMEDJOBFORPET` (14), `_TRAININGCAMPMEMBER`,
`_GUILDWAR`, `_LOGEVENTITEM` (11), `_ITEMQUOTATION`, `_GUILD`,
`_CharInstanceWorldData`, `_SiegeFortress`, `_RentItemInfo` (10), `_CHARCOS`,
`_CHARQUEST`, `_BindingOptionWithItem` (9), … plus `_USER`, `_INVENTORY`,
`_INVENTORYFORAVATAR`, `_INVENTORYFORLINKEDSTORAGE`, `_CHEST`, `_INVCOS`,
`_CHARSKILL`, `_CHARSKILLMASTERY`, `_Friend`, `_Memo`, and the siege/log family.

The ones srrevamp already implements something for:

```
_ITEMS      RefItemID, OptLevel, Variance, CreaterName,
            MagParamNum, MagParam x12, Serial64
_CHARQUEST  CharID, QuestID, Status, AchievementCount,
            StartTime, EndTime, QuestData1, QuestData2
_CHARSKILL          CharID, SkillID, Enable
_CHARSKILLMASTERY   CharID, MasteryID, Level
_Friend     CharID, FriendCharID, FriendCharName, RefObjID
_Memo       FromCharName, Message, Status, RefObjID
_CHARCOS    OwnerCharID, RefCharID, KeeperNPC, State, CharName,
            ExpOffset, PetOption, RentEndTime
_USER       UserJID, CharID
```

Two of those refine recorded conclusions rather than merely adding facts:

- **`_ITEMS` persists `Variance`** alongside `OptLevel` — so the real game rolls
  a per-instance stat variance, which is why two identical weapons differ. This
  project ships fixed itemdata values; that is a disclosed simplification nobody
  had named before.
- **`_CHARQUEST` has `QuestData1`/`QuestData2`**, not just status and a count.
  The standing conclusion ("objectives are not data; `_CHARQUEST` persists only
  status+count") is *narrowed*: objectives still live in server code, but
  per-quest progress state is richer than a counter, and those two slots are
  where it goes.

## The character struct, in the game's own column names

`CharData_BindDBColumns` (`0083e6b0`) binds every persisted `_CHAR` column to its
offset in charData — `FUN_00401fc0(name, nameLen)` then `local_150 = offset` —
for **38 columns**. It is the single best artifact in the binary for that struct,
and it **validates against four offsets this project had derived independently**:
`Strength` 0x74, `Intellect` 0x76, `CurLevel` 0x65, `RemainSkillPoint` 0x80, all
exact.

```
+0x020 CharID          +0x086 RemainHwanCount   +0x0b4 PKPenaltyPoint
+0x024 Deleted         +0x088 GatheredExpPoint  +0x0b8 GuildID
+0x028 RefObjID        +0x094 LatestRegion      +0x0bc LastLogout
+0x02c CharName16      +0x0a4 AppointedTeleport +0x0cc TelRegion
+0x048 NickName16      +0x0a8 AutoInvestExp     +0x0d0 TelPosX/Y/Z
+0x064 Scale           +0x0ac InventorySize     +0x0dc DiedRegion
+0x065 CurLevel        +0x0b0 DailyPK           +0x0e0 DiedPosX/Y/Z
+0x066 MaxLevel        +0x0b2 TotalPK           +0x0ec WorldID
+0x068 ExpOffset       +0x074 Strength          +0x0ee TelWorldID
+0x070 SExpOffset      +0x076 Intellect         +0x0f0 DiedWorldID
+0x078 RemainGold      +0x080 RemainSkillPoint  +0x0f2 HwanLevel
                       +0x084 RemainStatPoint
```

**What it settled immediately:**

- **`+0xb4` is `PKPenaltyPoint`** — one of the two unknown branch conditions in
  the death penalty (see below). Half that blocker is gone.
- **`InventorySize` is a per-character column**, so the real game's inventory is
  expandable per character rather than the fixed 50 this project ships. That
  changes the *nature* of that open item: it is not "a constant nobody has
  found", it is "a per-character value whose starting size is set on the database
  side", which is the same wall as starting Str/Int.
- **`HwanLevel` and `RemainHwanCount` are both persisted**, so berserk has a
  level *and* a count. **The berserk DAMAGE is recovered (2026-09-15); the
  gauge/duration numbers stay disclosed.**

  Berserk is "Hwan", which is why grepping for "berserk" found nothing for three
  sessions. With the RTTI class names in place the chain reads straight through,
  and every link is a named function:

  ```
  CGObjChar::SetBerserk   slot 198  0x004a9fc0   writes the flag at (*(this+0x30))+3
  CGObjChar::IsBerserk    slot  64  0x004aa5b0   reads that same byte
  Combat_ResolveDamage              0x0058e5f0   sets damage-flag bit 2 when the
                                                 ATTACKER IsBerserk()
  Formula_MitigatePhysicalDamage    0x0040e450   multiplier = GetParam(189) + 2.0
  Formula_MitigateMagicalDamage     0x0040e830   (in place of the usual 1.0)
  ```

  The setter and the predicate touching the **same byte** is what ties the pair
  together; neither alone would have been better than a suggestive name.
  `UpdateHwanLevel` sits next door at slot 197, writing the level to
  `CGObjChar+0x1c58` and persisting it to `_CHAR.HwanLevel` (`charData+0xf2`,
  dirty bit `0x2000`) — which also confirms the `_CHAR` schema offset. The level
  cap is the row count of the `_REFHWANLEVEL` vector.

  **×2 exactly.** The 2.0 is the double at `.rdata 0x00b45f30`, and its
  neighbours `0x00b45af0 = 100.0` / `0x00b45ac0 = 1.0` are the two already-
  confirmed constants of the `/(1 + p/100)` idiom, so the width is settled
  rather than assumed. All three read `0.0` at float width because a double's
  low word is zero — and the float reading is incoherent anyway, since it would
  make a berserk attacker deal no damage at all.

  Param 189 is a separate berserk-damage **stat** adding on top (`SetBerserk`'s
  fifth argument grants it a base of 0.3, float at `0x00b45b8c`, and clears it
  otherwise), but every call site in the binary bar one passes 0 there. 2.0 is
  the plain case, 2.3 the special one; the stat is not modelled rather than
  folded in at a guessed rate.

  The **duration** is now known to be genuinely unrecoverable from this
  function: `SetBerserk`'s signature carries a state-change slot and a float
  duration, and every call site passes `0xff`/`0` for them, so the real server
  keeps that timer elsewhere. Body mode 1 is Hwan (the `BODYMODE_HWAN` string);
  modes 0, 2 and 4 also appear at those call sites.
- `DiedRegion`/`DiedPos` are persisted: the game remembers where you died.

## The stat vocabulary, in the game's own words

The server tags stats with C multi-char literals (`Stat_ApplyTaggedModifier`,
52 of them); the client names the same stats with `PARAM_*` localisation keys
whose English text ships in `textuisystem.txt`. The two were recovered
independently, from different binaries and different evidence, and the
abbreviations line up exactly — eight of them, which is past coincidence:

| tag | `PARAM_` key | the game's own English |
|---|---|---|
| `'hr'`/`'hra'` | `PARAM_HR` | **Attack rate** |
| `'er'`/`'era'` | `PARAM_ER` | **Parry rate** |
| `'cri'` | `PARAM_CRITICAL` | Critical |
| `'bri'` | `PARAM_BLOCKING` | Blocking rate |
| `'str'` | `PARAM_STR` | Str |
| `'int'` | `PARAM_INT` | Int |
| `'luck'` | `PARAM_LUCK` | Lucky |
| `'ps'` | `PARAM_PS` | Poisoning |
| `'fz'` | `PARAM_FZ` | Freezing |
| `'zb'` | `PARAM_ZB` | **Zombie** |

Also named, with no tag counterpart found yet: `PARAM_PA` "Phy. atk. pwr.",
`PARAM_PD` "Phy. def. pwr.", `PARAM_MA` "Mag. atk. pwr.", `PARAM_MD`
"Mag. def. pwr.", `PARAM_ABSORB` "Absorption".

## `ItemClass` is itemdata column 61, and a shipped claim that was false (2026-09-15)

**First, a correction.** The previous entry says `TwoHanded` was exported. It was
not — the edit that was meant to map column 93 matched nothing (wrong
indentation; a silent no-op is what a non-matching string replace does), so
`fTwoHanded = 93` sat defined and unused and the equipment rule depending on it
was inert in every real deployment. The build was happy: Go objects to an unused
local, not an unused const. The round-trip test only checked the record's
*width*, and the new-column test only checked defence and block. Fixed, and
pinned by a test **verified to fail without the fix**.

**`ItemClass` is column 61** — the last placeholder in the item exporter that
anything reads. It flows through the shop listing to the client, where it had
been a constant 0.

Derived from the ORDER of the server's own deserialiser rather than from the
shape of the data. `RefObjItem::ExtractData` reads fields consecutively off the
row — `+0x198` (4 bytes), `+0x19c` (1), `+0x1a0` (4), `+0x1a4` (4), `+0x1a8` (1)
— and `+0x19c` is confirmed as `ReqGender` by
`CGPCInventoryOP::CheckEquipsetIntegrity`, which compares it against
`GetGender()`. The exporter already pinned 57/58/59/60 as MaxStack / ReqGender /
ReqStr / ReqInt, exactly those four in exactly that order, so the next field is
column 61 — a one-byte read, matching `m_btItemClass`.

Checked against the binary's own assertion rather than a curve: `ExtractData`
asserts *"ItemClass must be not zero"* / `m_btItemClass > 0`, and column 61 is
non-zero on **all 21,552** equipment rows.

**The exporter sweep is finished.** Every remaining `"0"` placeholder in either
exporter — `FlyingSpeed`, `Interruptable`, `Overlap`, `AutoAttackType`,
`Basic_Name`, `Basic_ChainCode`, `Basic_RecycleCost` — has **zero readers** in
the server, so a wrong value there reaches nothing. They stay, now for a
measured reason.

## `TwoHanded` is itemdata column 93 (2026-09-15)

The field existed in `refdata.Item`, was exported as a literal `"0"`, and
nothing read it — harmless until shields started blocking, at which point a
two-handed weapon plus a shield became free damage avoidance.

Column 93 is a clean 0/1, **constant within every weapon kind** (`TypeID4`),
never mixed, and 0 on all 511 shield rows. Diffing a one-hander against a
two-hander finds it; that alone is a suggestive column, so it was settled
against a source that knows nothing about this table — the **client's own
weapon-to-animation-group switch**, recovered from a different binary by a
different route, which names five kinds outright:

| TypeID4 | the client's own name | col 93 |
|---|---|---|
| 7 | `onehand_sword` | 0 |
| 10, 15 | `onehand_staff` | 0 |
| 8 | `twohand_sword` | 1 |
| 11 | `twohand_staff` | 1 |

Five for five. The remaining kinds fall out consistently: spear, glaive, bow,
axe, crossbow and harp read 1; blade and dagger read 0.

Shipped with `equipment.TwoHandedConflict`. Slot 7 being the shield is
confirmed independently by `CGPCInventoryOP::CheckEquipsetIntegrity`, which
tests `local_c != 7` for exactly that slot — the same index this project's
equipment package already used.

## Loot is DB-only, censused (2026-09-15)

The audit carried monster drops as "keyed by name (real tables key by
`RefMonsterID`, mapping not yet confirmed)". The mapping cannot be confirmed
because **the tables are not shipped anywhere this project can reach**, and that
is now a census rather than a failed search.

The pserver's `SR_GameRefData` directory holds **238 refdata tables** — every
one this project has ever used and many it has not: `LevelData`, `SkillData`,
`CharacterData`, `npcpos`, `shopdata`, `QuestData`, `levelgold`,
`hwanleveldata`, `MagicOption`, `teleportdata`, `siegefortress*`,
`refquestrewarditems`, `collectionbook_*`, `gacha*`. **None of them is a drop
table.** A `find` for `*drop*` across the entire server package returns only
drop *models and icons* (`.bsr`, `.bmt`), and the ORIGINAL client's `Media.pk2`
contains exactly one match for "drop" — `etc_waterdrop_yellow.ddj`.

So `_RefDropItemGroup`, `_RefMonster_AssignedItemRndDrop`, `CRefDropItemAssign`
and the ten `CRefDropClassSel_*` classes exist in the binary's RTTI and as DB
tables, and nowhere else. srrevamp's placeholder loot is own design for a
reason that is now stated rather than assumed, and an operator with the database
supersedes it.

## Blocking: a blocked hit deals nothing (2026-09-15)

Recovered in `Combat_ResolveDamage`. The chance is the engine's standard opposed
idiom:

```
block = GetParam(10)                       the defender's 'bri'
      + a bonus when (refobj+0x230) != 0   (FUN_00410c20)
      / (1 + GetParam(56)/100)             opposed by the attacker's 'evbl'
```

stored in the damage record at `+0xe`, where the critical chance sits at `+0xc`.

**The roll is the same one the critical uses, and the disassembly shows how the
engine keeps them apart** — they differ only in a key byte placed in the high
bits of ECX:

```
0058f0c8  MOVZX EAX,byte ptr [EBX + 0xe]   ; the BLOCK chance
0058f0d2  OR ECX,0x42000000                ; 'B'
0058f0de  CALL FUN_005a1a20

0058ed8c  MOVZX EAX,byte ptr [ESP + 0x2f]  ; the CRITICAL chance
0058ed97  OR ECX,0x43000000                ; 'C'
0058eda3  CALL FUN_005a1a20
```

That key is what `FUN_00599cc0` stores its bad-luck accumulator under, so blocks
and criticals have **independent streak protection** per actor. It also settles,
rather than assumes, that the block roll really takes the block chance — the
`MOVZX EAX,[EBX+0xe]` is the field the `'bri'`/`'evbl'` computation wrote.

**A blocked hit deals nothing**, and the control flow proves it rather than a
comment claiming it. On success the roll falls through to `JZ 0x005905fb`, and
that target is **past all four** `Formula_Mitigate*` call pairs — at `0x58f15d`,
`0x58f2fb`, `0x58f7ea` and `0x58f9b2`. No damage is ever computed, so the
record's `+0x28` (physical), `+0x24` (magical) and `+0x20` (total) keep the zero
they were initialised with. A *failed* block instead jumps to `0x58f739`, which
is before the third pair, and resolves normally. (One secondary path, guarded by
an ability pointer at defender+0xD2C, explicitly zeroes those fields and re-runs
the formulas; that is a special case this project does not model.)

**SHIPPED 2026-09-15 (v0.1.168).** The blocker was the input, not the mechanic:
a player's block chance is a shield's own block ratio — itemdata cols 74–75,
10~20, on exactly the 500 shield rows — and the curated item export carried no
such column. Added as an appended optional column, the pattern every earlier
addition used, so an export made at any older width still loads and blocks
nothing.

**And it uncovered a live bug next to it.** `cmd/export-refdata` was emitting a
literal `"0"` for *both armour defences*, under a note reading "armour, not
verified" — a note that stopped being true when `ITEM_FORMAT.md` grounded those
columns three ways and was never revisited. Every deployment importing through
that tool gave armour **no defence at all**, while `defenderArmor` read the
zeroes. Physical (65/66) and magical (76/77) are now exported from their
verified columns.

The monster side of blocking still never fires: every species on the Jangan
ladder reads 0 for col 76, though 938 other monsters carry 20.

## Criticals, and the dice behind them (2026-09-15)

The standing "crit/block/hit rolls — values recovered, dice not" item closes on
the dice side. `FUN_00599cc0`, reached through `FUN_005a1a20` from
`Combat_ResolveDamage`, is the game's chance roll for criticals **and** blocks:

```
chance == 0     -> fail, no roll taken
chance >= 100   -> succeed, no roll taken
otherwise       -> succeed when chance >= rand() % 101
```

Inclusive at both ends — the modulus is `0x65`, not 100.

**A critical doubles.** `Formula_MitigatePhysicalDamage` builds a multiplier
(1.0 normally, `GetParam(189)+2.0` for a berserk attacker) and does
`if (flags & 2) multiplier += multiplier` before multiplying the already-
mitigated damage. Bit 1 is set on a successful critical roll, so an ordinary
critical turns 1.0 into 2.0 — and a berserk critical is 4.6×, since it doubles
whatever the multiplier already is.

**The monster's chance is characterdata col 78**, settled by disassembling
`GObjMob_PublishStats`, which publishes the ref-object's fields into params in a
consecutive 4-byte run:

| offset | param | column | |
|---|---|---|---|
| +0x230 | 5 | 71 | flat phys absorb — **already proven** |
| +0x234 | 6 | 72 | flat mag absorb |
| +0x238 | 7 | 73 | phys reduction % — **already proven** |
| +0x23c | 8 | 74 | mag reduction % |
| +0x240 | 9 | 75 | `'era'` parry |
| +0x244 | 10 | 76 | `'bri'` block |
| +0x248 | 11 | 77 | `'hra'` attack rate |
| +0x24c | 12 | **78** | **`'cri'` critical** |

Two known offsets anchor the run onto columns 71–78, and the data then agrees
four ways: cols 73 and 74 equal the level exactly on every row; 75 and 77 are
identical (`25 + 2*level`); 76 is 0 for every Jangan monster, which is right
because blocking is a shield mechanic (938 monsters elsewhere do carry 20); and
78 reads **2 on 7,493 of 7,495** rows. The two that differ are what prove it is
a column rather than a shared default.

**Not modelled, disclosed:** the real roll keeps a per-actor accumulator, raised
by `chance` on a miss and dropped by 100 on a hit, and compares *that* on later
rolls — bad-luck protection. srrevamp rolls memorylessly, so its criticals are
streakier, never more or less frequent. **The player never crits:** param 12 is
not among the fifteen `Char_PublishCombatStats` publishes; it comes from the
item stat-tag path this project does not model — the same wall as the player's
mitigation percentage.

**Blocking is recovered but not shipped**, for the same reason: col 76 is the
chance and the roll is the same function, but every monster on the Jangan ladder
reads 0, so there is nothing to see until the roster reaches the 938 species
that carry 20.

## Unarmed damage: the game does not define one (2026-09-15)

`unarmedDamage = 5` was the last value in the grounding audit carrying no reason
at all — just "Own [design]." It has one now, and it is an absence established
by enumeration.

Damage reaches the engine as params 190/191, published from the equipment
aggregate; the numbers themselves live in a skill's `'att'` parameter, which is
how a monster's attack was recovered. So an unarmed player would need a base
attack skill with **no weapon type** — and the skill table has none. Every
`_BASE_01` attack skill in the game is weapon-typed, all twelve of them:

```
CH   SWORD(2)        SPEAR(40)        BOW(70)
EU   SWORD(8419)     TSWORD(8420)     AXE(8421)      CROSSBOW(9354)
     DAGGER(9355)    STAFF(9944)      WAND_WARLOCK(10625)
     HARP(11162)     WAND_CLERIC(11526)
```

The state exists *visually* — the client's recovered animation-group table has
index 0 `default` for an empty hand — but nothing in the data gives it a damage
value. So 5 is a number this project must invent to have a fight at all, not one
it failed to find.

**A trap caught on the way, worth recording because it nearly shipped.**
Player rows in `characterdata` read `[83]=1 [84]=2 [85]=40 [86]=70`, and
`[85]/[86]` looks exactly like a tidy 40~70 unarmed damage range — a monster row
has 0 in both. It is not a range. Those columns are **base-attack skill ids**:
2 / 40 / 70 resolve to precisely the three Chinese base skills, and a European
row reads 8419 / 8420 / 8421 (sword / tsword / axe), consecutive ids in the
thousands that no one would mistake for damage. The census across both races is
what refuted it; the single-race reading was entirely plausible.

**Also closed this tick, as exhausted rather than open:** the `__FILE__`
source-path lever. 164 distinct source paths in the client and 50 in the server,
and `NamespaceFromSourceFile` reports **444 of 446** client functions and
**166 of 166** server functions already namespaced. There is nothing left in it;
a future tick should not re-run it hoping for yield.

## GParamKeeper's combination rules, and what `ctx` was for (2026-09-15)

The previous entry left one question in the way of using reinforce: does a
derived bind **overwrite** its target's slot or **accumulate** into it? Param 13's
slot 0 is written twice — directly from the aggregate's `+0x1b8` (the weapon's
own range) and by propagation from 17 (Str-derived, scaled by reinforce) — and
which survives decides whether a player's damage is the weapon alone or the
weapon plus a Str term.

**It accumulates, and the answer is slot-dependent.** `ParamKeeper_StoreSlot`
(`004b3000`) shows a slot is not a float: it is a container, allocated on first
use, and `FUN_004b2d60(container, ctx, value)` stores into it **keyed by `ctx`**.
That is what the long-unexplained third argument to
`ParamKeeper_SetParam(slot, ctx, value)` has been all along — the identity of the
contributor, so two sources writing the same slot each keep their own entry.

`FUN_004b2e60` then reduces a slot's container to one float, and how it combines
them depends on which slot it is:

```
acc = (slot == 3) ? 100.0 : 0
for each entry:
    slot 3  ->  acc = entry * acc / 100     percentages compound
    slot 2  ->  acc = (entry/100 + 1) * acc multipliers compound
    slot 0  ->  acc = entry + acc           SUM
    slot 1  ->  acc = entry + acc           SUM
```

So the four slots are **base (summed)**, **additive % (summed)**, **multiplier
(compounding)** and **percent scale (compounding from 100)**, and
`ParamKeeper_EvaluateParam` combines them exactly as recorded:
`slot0 * (slot1+100)/100 * slot2 * slot3/100`, with a clamp that asserts in
`GParamKeeper.cpp:301`.

> **SUPERSEDED — read the amendment below together with the registry recovery
> that followed it the same day (`docs/protocol/param_registry.md`). The
> mechanism described here is correct; the closing claim that the defaults are
> "not in the binary" is WRONG. They are a static table at VA `0x00c64110`, and
> reading it restored every inference this amendment had retracted.**
>
> **AMENDED 2026-09-15 — the formula above is right but incomplete, and the
> missing piece changes how an unwritten param must be reasoned about.**
> `ParamKeeper_EvaluateParam` has two fallbacks to a per-param **default** held
> at `+0x28`:
>
> ```c
> if (!anySlotHasEntries) { value = *(float *)(param + 0x28); return; }
> if (*(int *)(param + 8) == 0)  local[0] = *(float *)(param + 0x28);  // slot 0 empty -> base = default
> ```
>
> and slot 2 *replaces* rather than multiplies when the base product is zero.
> So **an unwritten param does not evaluate to zero — it evaluates to its
> default.** The read path makes this unavoidable: `FUN_004b3740` calls
> `ParamKeeper_EnsureParam` *first*, which lazily creates the param via
> `FUN_004b2f40(min, max, default, ?)` from a descriptor record fetched out of a
> map keyed by param id (sentinel `0xcd3110`, root `0xcd3114`), asserting if the
> id is absent. The four values arrive as `fild [ecx+4/8/0xc/0x10]` — integers
> from a record built at **runtime**, not immediates in the code.
>
> **Consequence**: "nothing writes param N, therefore N is zero" is not valid on
> its own — the default has to be read before the conclusion follows. It now
> has been, for all 120 params, and the conclusion does follow for every id this
> project relies on. `combat.MitigateDamage`'s params 9/11 argument never
> depended on it either way, being a READ-side census (a param nothing reads
> cannot matter whatever its default).

**The consequence for damage**: param 13's slot 0 holds the weapon's own range
*and* the Str-derived contribution from 17, and they **add**. A player's physical
damage in the real game is the weapon's range plus a term of roughly
`Str x reinforce%`, and srrevamp's damage ignores Str entirely.

**Still not shipped, and the remaining gap is now exact.** The magnitude needs
one more fact: whether an item's reinforce *replaces* the innate base in param 34
or adds to it. Both are plausible and the container's `ctx` keying decides it —
same key replaces, different keys sum. `GObjPC_InitStats` writes ctx 0 while
`Char_PublishCombatStats` passes the stat-source pointer as ctx, which would make
them different keys and therefore additive — giving a Copper Sword user 61.2%
reinforce rather than 30.6%. That reads wrong, which is exactly why it is written
down as a question rather than shipped as a formula.

## The player stat graph, read off GObjPC_InitStats (2026-09-15)

`GObjPC_InitStats` (`004e3200`) declares the whole graph in one function, and
`ResolveRegArg`'s annotations make the edges readable directly:
`/* BindDerived source->target: EBX 0x3a (58), EDI 0x32 (50) */`.

**The three roots are confirmed against the `_CHAR` schema**, which is the check
on everything built from them:

```
param 0 = Level      SetParam(0, charData+0x65)   _CHAR.CurLevel
param 1 = Str        SetParam(1, charData+0x74)   _CHAR.Strength
param 2 = Int        SetParam(2, charData+0x76)   _CHAR.Intellect
```

**The Str/Int split is the graph's shape**, not an inference about it:

```
1 (Str) -> 17, 18 -> 13, 14   physical damage min/max
1 (Str) -> 21     -> 5        physical flat absorb
2 (Int) -> 19, 20 -> 15, 16   magical damage min/max
2 (Int) -> 22     -> 6        magical flat absorb
```

**This places the six fields the publication map had left unnamed:**

| field | param | where it goes |
|---|---|---|
| +0x1b0 | 58 | → 50 → 21 → **5**, physical flat absorb |
| +0x1b4 | 59 | → 51 → 22 → **6**, magical flat absorb |
| +0x1c8 | 34 | → 17 → **13**, physical damage min |
| +0x1cc | 36 | → 18 → **14**, physical damage max |
| +0x1d0 | 35 | → 19 → **15**, magical damage min |
| +0x1d4 | 37 | → 20 → **16**, magical damage max |

**Which REFUTES the previous entry's guess.** 58 and 59 were recorded as the
obvious candidates for the item table's phys/mag *reinforce*, on the strength of
sitting between the defence and damage blocks. They feed **flat absorb**, a
defence stat; reinforce is a weapon stat. The candidates are wrong, and the
graph says so without needing a second opinion.

**Two base values fall out, both real constants:** a character's innate attack
rate (param 11) and parry (param 9) are each **10.0** (`.rdata 0x00b45b44`),
each with a level-derived binding (`0 → 11`, `0 → 9`). srrevamp models neither
stat, so there is nothing to wire.

### Params 34–37 are the REINFORCE quad (settled 2026-09-15)

The previous pass recorded this as a lead and declined to promote it on one
numeric coincidence. It is settled now, five ways, and the objection that held it
back dissolved once the right question was asked.

| param | base | is |
|---|---|---|
| 34 | 30.6 | physical reinforce **min** |
| 36 | 34.2 | physical reinforce **max** |
| 35 | 49.0 | magical reinforce **min** |
| 37 | 54.8 | magical reinforce **max** |

1. **The slot says "percentage".** Every edge in the graph binds at slot 0
   (base) *except six*, and four of them are these: `34 → 17`, `36 → 18`,
   `35 → 19`, `37 → 20`, all at **slot 3**, which
   `ParamKeeper_EvaluateParam` divides by 100. The engine treats them as
   percentages, which is what a reinforce *is*.
2. **The targets split physical and magical** exactly as the client's two
   labels do: 34/36 scale the physical damage chain (17,18 → 13,14) and 35/37
   the magical (19,20 → 15,16).
3. **They are min/max pairs**, matching the client's `"%s ~ %s"` rendering.
4. **The values are real item values.** `306 / 342` is precisely
   `ITEM_CH_SWORD_01_A`'s physical reinforce and `490 / 548` precisely
   `ITEM_CH_BLADE_01_A`'s magical.
5. **Both are the FLOOR of their column.** No weapon in the table has physical
   reinforce below 306 or magical below 490 — which is exactly what an innate
   baseline should be, and is what dissolves the earlier objection. The bases
   are not "one weapon's stats"; they are the minimum of each column
   independently, which is why the physical matched a sword and the magical a
   blade.

This answers the question two entries back: *the only combat stat the client
reads that the server never exports is reinforce — where does it land?* It lands
on the Str/Int-derived damage, as a percentage.

**Not exported and not wired, deliberately.** Using it means knowing whether a
derived bind OVERWRITES its target's slot or accumulates into it: param 13's
slot 0 is written both directly (from the aggregate's `+0x1b8`, the weapon's own
range) and by propagation from 17. Which of those survives decides whether a
player's damage is the weapon's range alone or the weapon's range plus a
Str-derived term — a formula change, not a constant. `Param_PropagateToDependents`
is the function that settles it, and until it is read, exporting the columns
would only add a field nothing consumes, which is the exact pattern the last
four entries have been correcting.

Also in the tail: a six-iteration loop binding `(phys, mag)` pairs from a static
table at `.rdata 0x00c640d0` — 0.032/0.052, 0.027/0.043, 0.042/0.067,
0.034/0.055, 0.025/0.039, 0.030/0.049, each ×100 — into params 50/51, the same
defence chain. Six is the armour-slot count *and* the European mastery count,
and the loop's param id is computed rather than literal, so which of those it is
stays open.

## Where a player's combat stats come from (2026-09-15)

`Char_PublishCombatStats` (`00497830`) publishes fifteen ParamKeeper params from
fifteen consecutive float fields. Every call decompiles identically —
`ParamKeeper_SetParam(0, piVar1, param_1)` — because both the id and the value
are register-passed, so this is read off the disassembly:

| field | param(s) | what |
|---|---|---|
| +0x198 | 5 | physical flat absorb |
| +0x19c | 9 | `'era'` **parry rate** |
| +0x1a0 | **7** | **physical reduction %** |
| +0x1a4 | 10 | `'bri'` **blocking rate** |
| +0x1a8 | 6 | magical flat absorb |
| +0x1ac | 8 | magical reduction % |
| +0x1b8 | 13 **and** 191 | physical damage **min** |
| +0x1bc | 14 **and** 190 | physical damage **max** |
| +0x1c0 | 15 **and** 193 | magical damage min |
| +0x1c4 | 16 **and** 192 | magical damage max |
| +0x1b0 | 58 | not identified |
| +0x1b4 | 23, 59 | not identified |
| +0x1c8 | 34 | not identified |
| +0x1cc | 36 | not identified |
| +0x1d0 | 35 | not identified |
| +0x1d4 | 37 | not identified |
| +0x1d8 | 11 | `'hra'` **attack rate** |
| **+0x1dc** | **12** | `'cri'` **critical** |

**Extended and CORRECTED 2026-09-15 (same day).** The table above is eighteen
fields, not the eleven this entry first recorded. The earlier pass cut its
disassembly at 220 instructions, and six of the writes are past that — the last
of them, `+0x1dc → param 12`, at `0x00497ef0`, three hundred instructions
beyond where the reading stopped.

That one matters, because this entry went on to say param 12 was **not**
published here, and a later tick used that to argue the player's critical
arrives by the item-modifier path (`Stat_ApplyTaggedModifier`'s `'cri'` tag)
instead. It does not: it arrives by the same route as every other combat stat,
published from `+0x1dc` immediately after `'hra'` attack rate at `+0x1d8` —
exactly where a reader would expect the pair. The shipped value (the weapon's
own Critical column, itemdata 116) was right throughout; only the citation
improves. *A disassembly window is a measurement boundary, and an absence found
inside one is not an absence.*

**Two standing questions close.** First, params 13/14 and 190/191 are *the same
two floats* — so `Formula_RollWeaponDamage`'s uniform roll (190/191) and the
centre-biased roll in `FUN_0040dce0` (13/14) read an identical range. The two
rolls differ in distribution, not in input, which is what the previous tick
could not tell.

Second, the defence block runs PD, ER, PAR, BR, MD, MAR at consecutive floats —
**exactly the `_RefObjItem` column order `refdata_schema.md` records** — and two
of those land on params the client itself names: ER on 9 (`PARAM_ER` = "Parry
rate") and BR on 10 (`PARAM_BLOCKING`). Those two anchors bracket PAR, placing
it on param 7, the physical reduction percentage, and MAR on param 8. That
decodes two of the three columns the schema explicitly records as *not decoded*.
It is an ordering argument with named anchors on both sides, **not** a use-site
on PAR itself, and is recorded at that strength.

### SETTLED: a player's percentage mitigation is ZERO, and that is recovered

The previous pass left this open because a census of item columns is only
*suggestive*. It is closed now by enumerating the writers instead: param 7 has
exactly **three**, and none of them can make it non-zero for a player.

| writer | reaches a player? |
|---|---|
| `GObjMob_PublishStats` (`004c3730`) | no — mobs only (characterdata col 73 = the monster's level) |
| `Char_PublishCombatStats` (`00497830`) | from the `_RefObjItem` defence block — and **no percentage-reduction column is populated on any of the 21,560 item rows** |
| the skill-effect applier (`00594ac0`) | only through the skill param code **`'ar'`** — which appears on **zero of 29,342 skill rows** |

`'ar'` is `SkillGlobal::RefSkill_ParseParams` (`00587630`) writing `skill+0x268`
as a 3-word run, which the applier publishes into params **7 and 8 at slot 0**.
The single numeric hit for it in the skill table is a skill's **own id column**,
not a param code. The mechanism exists; nothing shipped uses it.

**The two defensive skill codes that ARE live go somewhere else entirely**, and
that is what makes the negative result convincing rather than merely absent:

| code | writes | published as | real skills |
|---|---|---|---|
| `'defp'` | `skill+0x25c`, 4-word run | params 5/6 at **slot 0** — the FLAT absorb | **273** |
| `'defr'` | `skill+0x260`, 2 words | params 5/6 at **slot 1** — a % boost to that flat term | 4 |
| `'ar'` | `skill+0x268`, 3-word run | params 7/8 at slot 0 — the reduction % | **0** |

So defensive buffs in this game raise your **flat absorb**, never your
percentage. The asymmetry srrevamp already had — monsters carry a percentage,
players do not — is the game's own. `session.playerMitigationPercent` now states
it as an explicit cited `0` routed through the same `combat.MitigateDamage` the
monster side uses, so the zero carries its evidence instead of being a bare
subtraction that happens to compute the same number.

**A methodological note worth keeping.** The first census of these codes said
`'defr'`, `'defp'` and `'heal'` appeared on **zero** rows — because the
multi-char constants had been worked out by hand and were wrong (`'defr'` is
1684366962, not 1684366450). Recomputed properly, `'defp'` is on 273 skills.
A second slip in the same pass: the code list was harvested with
`grep '== 0x'`, which misses every branch the compiler emits as `!=` — and
`'ar'`, the one code this whole question turned on, is exactly such a branch.
Both mistakes produce *false negatives*, which are the dangerous kind here: an
absent value looks like a settled question.

**Now genuinely open:** the class of `Char_PublishCombatStats`'s first argument
(it answers a virtual at slot 33, `+0x84`, and is *not* `CRefObjChar` — that has
`uint8 Lvl` at 0x198, read here as a float). Not needed for the above, but it is
the handle on where gear aggregates.

## The death penalty, and half of `pc[0x72d]` (2026-09-15)

srrevamp had no death penalty at all. The real one is recovered and shipped
(v0.1.164). `GObjPC_OnDeath` (`004e6980`) gates everything on
**`10 < Char_GetLevel(victim)`** — levels 1–10 die free — then multiplies the
level's EXP unit by one of four constants:

| killed by | ordinary | PK-flagged |
|---|---|---|
| a monster | `unit * 100`, no SP loss | `unit * 300`, **60** SP |
| a player | `unit * 20`, no SP loss | `unit * 100`, **20** SP |

The loss is clamped (the block's own CLAMP assert gives the minimum as `1.0`
and names the source file — `D:\WORK2005\Source\SilkroadOnline\Server\
SR_GameServer\GObjPC.cpp` line 6168), reduced by an unresolved stat, and
applied through `GainExpAndLevel` (vtable slot `0x170` = 92, the same function
that grants experience) with a **negative** 64-bit amount. Nothing in the block
touches `CurLevel`: a death never costs a level. The SP loss is capped at
`charData+0x80` = `RemainSkillPoint`.

**The EXP unit is the same field a kill is paid from**, and that is measured,
not assumed: `Formula_MonsterExpReward`'s disassembly reads the identical
`levelTable[lvl]+0x1c` and, in the same few instructions, shows the
minimum-level rule (`CMP EBX,EAX / JLE / MOV EBX,EAX` over two `Char_GetLevel`
calls) that `leveldata.KillExp` already implements. One function confirmed both
the field and a rule this project had recovered by another route.

**Half of the `pc[0x72d]` open item falls out.** That byte (victim `+0x1CB4`)
is compared against **5**, and gates the harsh branches together with
`charData+0xb4` = `PKPenaltyPoint` from the recovered `_CHAR` schema. What the
state enum *means* is still unrecovered, so the branches are labelled by the
condition that can be named rather than by a guess at the enum.

Checked against the **ORIGINAL client's** `leveldata.txt`, identical to the
pserver's at every level sampled (only level 110's exp-to-next differs, a
pserver cap edit), the cost is steeply regressive: **74.2% of a level at 11,
16.7% at 20, 6.1% at 30, 1.9% at 50, ~0% at 110.** Brutal the moment the
level-10 grace period ends, shrugged off at cap.

Only the monster branch is reachable — srrevamp has no PK system — so the other
three are implemented, tested and disclosed as unreachable. The reduction stat
is left out rather than guessed, which makes srrevamp's penalty a strict upper
bound on the real one.

*Also re-confirmed on the way:* `hwanleveldata.txt` aside, the **inventory**
item is DB-side like starting Str/Int. `CGObjPC::ExpandInventory` caps the main
inventory at **77** slots normally and **99** under a predicate (hard-capped
below 100), and `CGObjPC::FindEmptySlotNum` calls
`CGStorage::FindTotalEmptySlot(0xd)` — so the general inventory begins at index
**13**, after 13 equipment slots. The starting size is a `_CHAR.InventorySize`
row, not a constant in the exe, so `inventory.SlotsPerCharacter = 50` stays
own design.

## The base class names the slot (2026-09-15)

The berserk lever, generalised into a pass. `IGObj::UpdateHwanLevel`'s base
implementation is a stub that does nothing but log its own name —
`"## Illegal ##  IGObj::UpdateHwanLevel TypeID: %u"` — and RTTI says that stub
is slot 197. Those two facts do not name one function: they name **slot 197 in
every class that inherits it**.

248 such `(class, slot, method)` triples are sitting in the server's strings, in
the game's own spelling. **Validated against three facts the pass did not
produce**: `IGObj slot 65 GetParam` (this project derived vtable offset
`0x104` = GetParam by hand, and 0x104/4 = 65), `IGObj slot 197 UpdateHwanLevel`
(last tick's berserk work), and `IGObj slot 74 GetMaxLevel` landing immediately
after the hand-derived slot 73 `Char_GetLevel` — the adjacency a declaration
pair would have.

Two guards earned their place:

- **The string's class is the authority.** The seed is `(class named in the
  string, slot)`, propagating only to vtables whose class is that class or has
  it in its base chain. Slot numbers mean nothing across unrelated hierarchies.
- **`Class::member` is not a method.** The client's
  `"CObjChild::m_pGfxDevice is null"` would have seeded slot 15 of the root of
  the whole UI hierarchy; that one string accounted for **477 of the client's
  484** candidates before the filter. Only 7 client names survive it, and that
  is the correct number.

**481 functions named** (474 server, 7 client). Coverage after re-running the
chain: **server 64.1%** (was 56.3%), **client 46.0%** (44.5%) — combined
identified **38,555 → 41,844**. The gain is mostly downstream: 474 real names
seeded +2,417 new attributions, which is the compounding effect again.

A counting trap worth recording: nameable functions must be counted as
**distinct entries**, not `(seed, class)` pairs. An inherited implementation is
one function reached through every derived class's table, so the pair count read
6,325 against an apply that named 474 — a thirteenfold overstatement in a
report that would have been quoted as a result.

**What the 248 names open up.** They are the game's own vocabulary for things
this project has open items on: `CountEmptyInventory`, `ExpandInventory`,
`FindEmptySlotNum`, `GetLatestAvailableSlot` (inventory size);
`RandomSelectNonEmptySlotForDeathPenalty`, `CanRevive`, `GetLifeState`,
`SetLifeState` (the death penalty); `OffsetGold`, `OffsetExpPoint`,
`OffsetSkillPoint` (the economy); plus `GetCurHP`/`GetCurMP`, `GetBodyMode`/
`SetBodyMode`, `IsWeapon`/`IsShield`/`IsArmor` and the rest of the type
predicates.

## What "attack rate" actually does, and the damage dice (2026-09-15)

The standing item was "crit/block/hit rolls — values recovered, dice not". The
dice are recovered, and **attack rate turns out not to be a hit/miss roll at
all**.

`Formula_MitigatePhysicalDamage` opens by calling `FUN_0040dce0`, which is where
a blow's size is decided:

```
lo, hi  = GetParam(13), GetParam(14)     each scaled by (1 + bonus%/100)
centre% = clamp( ((hra/era) * 0.5 + levelTerm) * 100 , 10 , 90 )
p       = min(u1, u2, u3)                ui = rand()/32767 * 100
damage% = centre% ± p                    fair coin, then clamped to [0, 100]
damage  = lo + damage%/100 * (hi - lo)
```

`hra` is param 11 (**attack rate**, on the attacker) and `era` param 9 (**parry
rate**, on the defender) — the two the client's own `textuisystem.txt` named.
So attack-rate-versus-parry sets **where in the damage range the blow lands**,
never below 10% nor above 90% of it. The excursion `p` is the **minimum of
three uniform samples**, heavily biased toward zero, so blows cluster near the
centre: the distribution is not uniform.

`_DAT_00b45af8 = 32767.0` is `RAND_MAX`, and that is the check on the whole
reading — `rand()/32767 * 100` is only a uniform percentage if every other
constant in the expression was read at the right width. Clamps are floats 10.0
/ 90.0; the `hra/era` scale is the double 0.5; the level factor is the double
0.03 at `0x00b45dc8`.

**Crit and block** use the engine's opposed-stat idiom, computed in
`Combat_ResolveDamage` and stored into a struct at `+0xc` / `+0xe`:

```
effective crit  = attacker 'cri' (12) / (1 + defender 'evcr' (57)/100)
effective block = attacker block     / (1 + defender 'evbl' (56)/100)
```

**Nothing was rewired from the distribution, deliberately.** It is a *second*
roll, on params 13/14, distinct from `Formula_RollWeaponDamage` (uniform,
`rand() % (max-min+1) + min`, params 190/191) which `combat.RollDamage` already
implements correctly and which `Combat_ResolveDamage` also calls. srrevamp has
no attack-rate or parry-rate stat, so porting the centre would mean inventing
its only input.

**One piece was wireable and is now shipped (v0.1.163).** The same formula ends
with `if defLvl < atkLvl { damage = (levelTerm + 1.0) * damage }` where
`levelTerm = clamp((level(ECX) - level(EDI)) * 0.03, 0, 0.3)` — so out-levelling
the target is worth **+3% a level, capped at +30%**. Which object is the
attacker was settled on the disassembly (`SUB ESI,EAX` after two
`Char_GetLevel` calls) *plus* an independent fact: the other object supplies
defence params 5 and 7, which this project already established are the
*target's* (cols 71/73 via `GObjMob_PublishStats`). Applied last — after
mitigation and after the berserk multiplier — and in both directions, since a
monster is the attacker in its own counterattack. Guarded on both levels being
non-zero, because a zero means "not set", not "level zero".

**The tag → ParamKeeper-id map, harvested wholesale (2026-09-15).** The tags
above are names; this is where each one *writes*. Extracted by grepping the 21
tag dispatchers for `in_EAX == 0x…` beside `ResolveRegArg.java`'s own
`/* ParamKeeper param id: EDI … */` annotations, so both halves come out of the
dump rather than being paired by eye:

| tag | params | tag | params |
|---|---|---|---|
| `'int'` | 2 | `'rals'` | 27,28,29,30,31,32 |
| `'hp'`/`'hpa'` | 3 | `'hpna'` | 52 |
| `'mp'`/`'mpa'` | 4 | `'mpna'` | 53 |
| `'era'` | 9 | `'evbl'` | 56 |
| `'bri'` | 10 | `'evcr'` | 57 |
| `'hra'` | 11 | `'drua'` | 128,129,130 |
| `'cri'` | 12 | `'dara'` | 174,175,176,177 |
| `'hprg'` | 25 | `'DABR'` | 174,175,176,177 *(negated)* |
| `'mprg'` | 26 | `'SPDU'` | 23,24 |
| `'hpmp'` | 25,26 | | |

Two corrections to what was recorded: `'rals'` writes **six** params (27–32),
not 27 alone, and `'hpmp'` is a single tag touching both regen params. `'DABR'`
and `'SPDU'` are the two tags a `CRefHWANLevel` row's effect list is built from
— each entry is a `{uint32 tag; uint8 value}` pair, and `'DABR'` applies its
value *negated* to the same four params `'dara'` writes.

**Three of this project's readings were wrong and are corrected by this.**
`'era'` was read as "evasion" and is *parry*; `'hra'` was read as "hit rate" and
is *attack rate*; and `'zb'` was recorded as the next probe for the berserk
numbers when it is a zombie status effect. The lesson is narrow: an abbreviation
that looks obvious in English is still a guess until the game's own text says
it, and the client ships that text.

## Naming coverage, and the denominator

Measured by `SymbolReport.java` (three states: **NAMED** — a real name, from
FID, an assert spelling out `Class::Method`, or applied by hand with evidence;
**ATTRIBUTED** — still `FUN_xxxxxxxx`, but in a namespace derived from a fact the
binary states about itself; **UNKNOWN**) and by `CodeCensus.java`, which
separates game logic from library code.

| | game-logic fns | % of binary | named | attributed | identified | of game logic |
|---|---|---|---|---|---|---|
| `SR_GameServer.exe` | 29,554 | 95.6% | 730 | 3,168 | **3,898** | **13.2%** |
| `sro_client.exe` | 36,457 | 91.5% | 681 | 9,485 | **10,166** | **27.9%** |
| **combined** | **66,011** | **93.3%** | 1,411 | 12,653 | **14,064** | **21.3%** |

**The "most of it is CRT and STL" assumption was wrong, and it was measured
rather than argued.** An earlier note in this file said the real denominator
must be far smaller than the 70,773 total because a stripped MSVC binary is
mostly library code. It is not. Across both binaries only **1,368 + 3,394**
functions are clearly not game logic — 368 thunks, 3,461 tiny (<16 bytes), 933
named as CRT/STL by Ghidra's own signature database. Everything else is the
game. So "a full decomp with named functions" is a **~66,000-function problem**,
not the ~6,000-function one that assumption implied.

Two honest caveats on that number, in both directions:

- **Upper bound.** Unnamed STL template instantiations cannot be told from game
  code by any signal here, so some of the 66,011 is library. The `tiny` bucket
  (3,461) is probably mostly STL accessors, and there will be more above 16
  bytes that FID never named.
- **Virtual functions are IN the count, deliberately.** 18,522 game functions
  have no direct caller. An earlier version of the census excluded those as
  dead, which was wrong: a virtual is reached only through a vtable slot and
  Ghidra does not resolve those, so that bucket holds some of the most important
  code in the binary — `GObjPC_GainExpAndLevel`, the exp-gain entry point, is in
  it. It does also hold genuinely dead code, and nothing here separates the two.

**The big attribution passes were validated too, and they hold.**
`ValidateAttribution.java` checks interpolated modules against the **call
graph** — an independent signal, since interpolation used address adjacency
alone:

| | server | client |
|---|---|---|
| interpolated functions | 671 | 2,493 |
| call graph **agrees** | **79.6%** | **72.9%** |
| isolated (no signal either way) | 17.6% | 15.4% |
| one dissenting neighbour (weak) | 2.1% | 8.4% |
| several dissenting, none agreeing | **0.7%** (5) | **3.3%** (82) |

So roughly three quarters are positively corroborated by evidence the heuristic
never saw, and genuine suspects are under 1% on the server and about 3% on the
client. That is a very different picture from the opcode-tree pass, which was
**28% wrong** — and the difference is instructive: the attribution passes encode
a structural fact about the compiler (a translation unit is contiguous; a callee
shares its caller's module), while the opcode pass encoded a *textual* pattern
that infrastructure calls happened to match.

**This validates `maxGap = 3` specifically.** Raising it — 8 would take 3,027
functions instead of 1,286 — invalidates the measurement, so re-run this after
any change to the gap.

Levers used so far, by what they returned: call-graph attribution
(`PropagateModules.java`, +3,131), authored UI string ids
(`LabelFromUIStrings.java`, +140 namespaced and 597 commented), `__FILE__`
asserts (`NamespaceFromSourceFile.java`, 760 seeds), vtable slots
(`VtableAttribute.java`, +68 namespaced and **5,225 annotated**), Ghidra FID
(~930, mostly library), and hand-proven names with citations (~30). The server
is the weaker side at 4.4% and it is where the gameplay lives.

**Levers now exhausted, measured rather than assumed:**

- **Log/assert strings naming `Class::Method`** — 517 server functions reference
  exactly one such string and **13** are still unnamed; the client, 18 and 2. The
  earlier assert-string pass took essentially all of it.
- **Log strings naming a bare `Method()`** — counted 77 unnamed, **worth about
  6**. Reading them rather than trusting the count showed why: the overwhelming
  majority are `"CLAMP() ==> min(%.3f) exceeded max(%.3f) value), File: %s,
  Line: %d"`, a shared assertion macro that says nothing about the function
  containing it — naming those `CLAMP` would be actively wrong. The genuinely
  self-naming remainder is applied (`InitializeGame`,
  `CLobby_RemoveStalePlayers`, `AQ_COSManipulator_DoWork`,
  `RemoveParamKeeperItemEntry`, `AutoReloadMagazine`, `DelItem_EXT`,
  `PC_ReleaseCOS`). Several more were rejected as ambiguous, because the message
  names a function the code *called* rather than itself
  (`"... call DelItem_EXT() returned fail"`); the rule that survives is **take
  the first identifier in the string, and only when nothing precedes it**.
  Lever closed.
- **RTTI class recovery** — ~~impossible, not merely hard. 1,871 type descriptors
  survive and **zero** are referenced, so the COL/vftable chain was stripped.~~
  **WRONG, reopened and harvested 2026-09-15.** Nothing was stripped. The probe
  was fired 8 bytes off. An MSVC `TypeDescriptor` is
  `{ void *pVFTable; void *spare; char name[]; }`, so the `.?AVCGObjPC@@`
  string sits at **+8 inside** the descriptor and the COMPLETE OBJECT LOCATOR
  points at the descriptor's **start**. Asking for references to the *string's*
  address returns zero however intact the chain is. Walking
  `vftable[-1] → COL → TypeDescriptor` instead:

  | | descriptors | pointed at | COLs | vftables | **classes** | slots |
  |---|---|---|---|---|---|---|
  | client | 1,223 | 1,223 | 1,751 | 1,680 | **1,211** | 34,840 |
  | server | 2,003 | 2,003 | 2,029 | 1,972 | **1,939** | 40,513 |

  Two things had to be fixed before the numbers meant anything, and both were
  *artefacts of Ghidra's coverage rather than facts about the binary*:

  - **Enumerate descriptors from raw bytes, not defined data.** Ghidra had
    typed only 1,088 of the client's 1,223 as strings. Every missed descriptor
    costs its class, its vftable and every slot in it — and one of the
    casualties was the `CGObjPC` table this project has been hand-naming from
    for sessions.
  - **Walk slots while the word points into executable memory**, not while
    Ghidra happens to have defined a function there. Using `getFunctionAt` as
    the loop condition stopped at the first undefined entry and cut the average
    table to 1.4 slots. Two vftables are always separated by their COL pointer,
    which is `.rdata` and not executable, so the walk still terminates by
    itself in the right place.

  **Validated against four facts it did not produce.** Probing the one server
  vftable whose slots this project derived by hand, `0x00af59fc`:
  slot 73 → `Char_GetLevel`, 92 → `GObjPC_GainExpAndLevel`,
  93 → `GObjPC_AddSkillPoints`, 421 → `GObjPC_GiveExp` — all four exact, and
  the table ends at **427 slots**, just past 421. The walk neither over-runs
  nor mis-numbers. And the table's class comes back as **`CGObjPC`**: the
  naming convention this project adopted by hand is the binary's own.

  **Applied conservatively.** A base class's implementation appears in *every*
  derived class's table, so "first table wins" would file a base method under
  an arbitrary subclass. A function is only *named* where exactly one class
  claims it (5,313 client / 5,953 server targets) and only over a blank `FUN_`;
  everything else gets a comment listing every class and slot that reaches it,
  which is pure fact. Result: **5,362 functions named** (1,992 + 3,370) and
  6,113 commented.

  **Coverage after re-running the compounding chain: client 35.0%, server
  39.2%** — combined identified **14,064 → 26,072**.

- **RTTI, second half: the inheritance graph and 6,799 new functions
  (2026-09-15).** Both items the first pass left on the table are done.

  The COL's *other* pointer is the hierarchy: `COL+0x10` →
  `ClassHierarchyDescriptor`, whose `+0x08` is the base count and `+0x0C` the
  base-class array; each `BaseClassDescriptor` points at a `TypeDescriptor`
  from offset **0**, which is why those pointer sites had been rejected as
  "bad COL signature". They were never noise — they were the other half of the
  answer.

  | | COLs | hierarchies read | classes with a chain | edges | roots | deepest |
  |---|---|---|---|---|---|---|
  | client | 1,751 | 1,680 | 1,211 | 7,266 | 276 | 10 |
  | server | 2,029 | 1,970 | 1,939 | 2,595 | 552 | 8 |

  ```
  CGObjMob  : CGObjNPC : CGObjChar : CGObjMobile : CGObj : IGObj : CBase
  CGObjCOS  : CGObjNPC : CGObjChar : CGObjMobile : CGObj : IGObj : CBase
  CICPlayer : CICUser : CICharactor : CIGIDObject : CIObject : CIEntity : CObjChild : CObj : …
  CIF<any>  : CIFMainFrame : CIFFrame : CIFTileWnd : CIFWnd : CGWnd : CGWndBase : CObjChild : CObj
  ```

  **It confirms two hard-won findings structurally.** `CGObjMob` **is a**
  `CGObjNPC` — which is exactly why `npcpos` carries monsters, the correction
  that overturned a recorded absence and had until now rested on resolving one
  id by hand. And PC and mob share `CGObjChar`, which is why the GParamKeeper
  sits at `charObj+0x1EC` for both; that was an observation, and is now a
  consequence of the type system.

  **6,799 functions created at vftable slot targets** (3,191 server, 3,608
  client). A slot target *is* a function entry — the binary says so by putting
  it in a vftable — and Ghidra had simply never reached them, because it finds
  functions by following calls and a virtual has no direct caller. That is the
  same blind spot `VtableAttribute` was written for, and this is the stronger
  fix: a *defined* function gets decompiled into the dumps every later grep
  reads. Done only where safe — 227 targets already inside another function
  were left alone rather than splitting a correct body, and 8 that would not
  disassemble were skipped rather than forced.

  **Coverage after re-running the chain over them: server 56.3%, client
  44.5%** — combined identified **26,072 → 38,555**. Across the two ticks that
  opened this lever: **14,064 → 38,555**.

- **The 128 `CRef*` refdata classes** (server), recovered from the same
  descriptor scan and readable straight out of the binary with `strings`. This
  is the join from the 85 SQL `_REF*` tables to the C++ that parses them, and
  it names several open ledger items outright: `CRefHWANLevel` (berserk),
  `CRefCharGen`/`CRefCharGenData` (starting Str/Int), `CRefDropGold`,
  `CRefDropItemGroup`, `CRefDropItemAssign`, `CRefDropOptLevelSel` and ten
  `CRefDropClassSel_*` (the loot tables, previously "right but
  under-specified").

- **The 291 `CIF*` UI window classes** (client) — the complete catalogue of
  every window the game has, each now tied to its own vftable and therefore to
  its code. This is the UI lane's index: `CIFAlchemyBox`, `CIFAutoPotion`,
  `CIFApprenticeShipHonorRanking` and 288 more. It supersedes
  `LabelFromUIStrings`' guess-by-authored-id for anything it covers, because a
  class name is the binary naming the window itself rather than an inference
  from the text it happens to display. Counts: 879 plain classes on the client,
  809 on the server (the rest of each total is templates).

**The population nothing reaches:** 18,522 game-logic functions have no direct
caller. They are virtuals, and every call-graph lever steps past them.
`VtableAttribute.java` is the answer to that and annotates 5,225 of them with
their table and slot — the fact this project has re-derived by hand four times
(slots 92 exp-gain, 93 SP-adder, 73 GetLevel, 421 GiveExp).

**The levers compound, and that is the main finding of 2026-09-15.** Run once
each they returned little; run as an ordered chain they returned a lot, because
each one's output is the next one's seed. On the server: interpolating 218 gaps
let `PropagateModules` find **175 more** by call-graph unanimity, and the richer
namespace set then let the vtables vote for **149** where they had managed 13
before. Combined identified went 5,055 → **7,822** (7.6% → 11.8%) in a single
chained pass. The order is in `client/tools/ghidra/README.md`; `VtableAttribute`
belongs last and wants re-running after every other lever.

**A second chained pass confirmed it compounds rather than saturating**:
7,822 → **10,710** (11.8% → 16.2%), with the vtable vote rising again from 149
to 228 on the server and 55 to 786 on the client.

**A third pass, after adding 84 hand names (55 DB binders + 29 packet
handlers), returned 10,710 → 14,064 (16.2% → 21.3%)** — and the server's
interpolation nearly doubled, 158 → 295, precisely because those 84 names were
scattered through previously unattributed stretches. That is the mechanism in
one line: **a handful of well-placed names is worth thousands of attributions**,
because each one anchors an interpolation that anchors a propagation that
anchors a vtable vote. The rule is to re-run the whole chain whenever names are
added, not once.

## How to work this file## How to work this file

Pick the top open item, run its next probe against the dumps (grep, don't
re-decompile — see `feedback_re_decomp_first`), and then do one of three things:
move the line to Grounded with its citation, prove the data does not exist and
say so, or record what the probe ruled out and leave the line with a sharper
next probe. **Never** move a line to Grounded on a suggestive curve alone — that
mistake was made twice on characterdata col 79. A use-site is what settles
meaning.

## The trap this file exists to catch

Item 2 (player MaxHP/MaxMP) sat open for three sessions behind a *wrong shape*.
The note here said "find the `FUN_004b3510(0, …)` push that targets them" — and
no such push exists. The base was never pushed at all; it arrives over an edge
of a dependency graph, from Str. Worse, the parameter's identity was invisible
in every one of the 297 decompiled call sites, because it travels in DI, which
Ghidra had not assigned to an argument, and because the callers materialise the
id through chains of LEAs rather than a MOV of a constant — so grep found
nothing and the C read as `SetParam(0, 0, value)` everywhere, complete and
useless.

The lesson is narrow and worth keeping: **when the decompiled C reads cleanly
but says nothing, suspect the calling convention before suspecting the code.**
The fix (`client/tools/ghidra/ResolveRegArg.java`) resolves register arguments
by abstract interpretation and writes them back as comments, so the next dump
carries them. That tool generalises — any callee whose real arguments live in
registers can be recovered the same way.

## Strength reaches damage: the reinforce chain, settled (2026-09-15)

The previous entry left the reinforce quad recovered but deliberately unwired,
behind one question: *does a derived bind overwrite its target's slot or
accumulate into it?* Both halves of that are now read out of the binary, and
they have **opposite answers for different params** — which is why a single
answer never fit.

### A slot is keyed, and `SetParam` and the graph share one keyspace

`ParamKeeper_SetParam(slot, ctx, value)` forwards straight to
`ParamKeeper_StoreSlot(slot, ctx, value)`, and so does the graph:
`Param_PropagateToDependents` calls `StoreSlot(*(iVar2+0x10), unaff_EBX, value)`
where `unaff_EBX` is **the source param's own object pointer**. One keyspace,
two kinds of writer. `FUN_004b2e60` then reduces a slot, and for slots 0 and 1
the reduce is `acc = entry + acc` — a SUM over entries with distinct keys.

So "replace or accumulate" is decided per call site, by whether two writers
happen to use the same `ctx`. Reading the ctx off every call site in
`Char_PublishCombatStats` gives a clean partition, not noise:

| params | slot | ctx |
|---|---|---|
| 5,6,7,8,9,0xa,0xb,0xc,0xd,0xe,0xf,0x10, 0xbe–0xc1 | 0 | **EBP** |
| 0x21–0x25, 0x3a, 0x3b, 0x8d | 0 | **0** |
| 0x17, 0x18 (four pairs) | **2** | 0 |

**And EBP is the equipped item, not the character.** The function takes the
object in `arg0` (`MOV EBP,[ESP+0x10]`) and the character in `arg1`
(`MOV ESI,[ESP+0x1c]; ADD ESI,0x1ec` — the keeper offset). `CGItemEquip::vslot_000`
zeroes exactly `+0x19c/+0x1c8/+0x1cc/+0x1d0/+0x1d4`, the fields this function
reads. That **closes the standing question about the class of arg0** (asked
because it answers a virtual at slot 33, `+0x84`, and is not `CRefObjChar`), and
it explains the ctx choice: an equipment contribution is keyed by the item, so
two equipped items each keep their own entry in slot 0 and re-equipping replaces
only that item's.

### The two answers

- **Param 34 REPLACES.** `GObjPC_InitStats` writes the innate default with
  `SetParam(0, 0, …)` and `Char_PublishCombatStats` republishes the weapon's own
  with `SetParam(0, 0, …)`. Same key, so the weapon's reinforce overwrites 30.6
  rather than adding to it. This is what the last entry declined to assume, on
  the grounds that summing would give a Copper Sword user 61.2% — that objection
  was right, and the binary agrees with it.
- **Param 13 ACCUMULATES.** Its slot 0 gets the weapon's flat minimum under
  `ctx = the item` and the Str-derived term under `ctx = param 17's object`.
  Different keys, so both live and the reduce sums them.

### The use-site, and a false negative it corrected

An intermediate reading of this said the opposite and would have shipped
nothing: `Formula_RollWeaponDamage` reads params **190/191**, not 13/14, and
nothing binds into 190–193 (checked two ways — no `BindDerived` mentions them on
either side, and their only writers are in `Char_PublishCombatStats`). On that
evidence the Str term never reaches damage.

The evidence was real; the conclusion was wrong, because a second reader exists.
`FUN_0040db50` — the helper `FUN_0040dce0` calls once per bound — reads

	iVar4 = (unaff_EDI != 0) + 0xd;                 // 13 or 14
	fVar5 = (**(code **)(*in_EAX + 0x104))(iVar4);  // GetParam(13/14)

**a computed id**, so a census of literal `GetParam(0x…)` arguments finds no
reader for params 13–16 and finding none proves nothing. Worse, the census was
wrong twice over: Ghidra prints small integers in **decimal**, so the regex
`\(0x[0-9a-f]+\)` silently dropped every id below 11 as well. *That is the third
time a too-narrow probe has produced a confident false absence in this project*
(after the 220-instruction disassembly window and the `== 0x` grep that missed
every `!=` branch). The rule already in this file — check the probe before
believing a negative — earned its place again.

So both rolls are real and they differ in **input as well as distribution**:
190/191 carry the weapon's flat range alone and are rolled uniformly; 13/14
carry that range plus the Str term plus every buff and skill modifier, and are
rolled centre-biased. **This corrects the earlier entry above**, which recorded
that the two "read an identical range" — true of the floats at publish time,
false at evaluation time, which is the only time that matters.

### The columns, pinned by four floors

`FUN_00495d60` computes an item's actual stat from a `(lo, hi, inc)` triple as
`lo + t*(hi-lo) + inc*plus`, asserting `lo < hi`. srrevamp models neither
per-instance variance nor plus level, so it takes `lo` — and `lo` is the end the
engine's own innate defaults correspond to:

| param | `.rdata` default | itemdata column | column floor (1,568 weapon rows) |
|---|---|---|---|
| 34 | 30.6 (`0x00b462a8`) | **105** | 306 |
| 36 | 34.2 (`0x00b462a0`) | **107** | 342 |
| 35 | 49.0 (`0x00b462a4`) | **109** | 490 |
| 37 | 54.8 (`0x00b4629c`) | **111** | 548 |

Four constants against four independent column minima. The `(n, n+2)` spacing
matches the already-verified attack pair (`fPhysAttackMin = 95`, max at 97), and
99/104 are the per-plus `inc` values. Read out of the PE's own `.rdata`, not
inferred: `0x00b45af0` really is `100.0`, and the slot-3 accumulator base
(`0x00b45e10`) really is `100.0`, so param 17 evaluates to `Str*reinforce/100`.

The six-row table at `0x00c640d0` reads back byte-for-byte as this file already
recorded it (3.2/5.2, 2.7/4.3, 4.2/6.7, 3.4/5.5, 2.5/3.9, 3.0/4.9), which is an
independent check on that entry rather than a new finding.

### Shipped

`combat.ReinforceDamage` and the reinforce quad through export → CSV → SQL →
`attackerDamage`, so a player's blow is `weapon range + Str*reinforce%` at both
ends. A Copper Sword (306/342) at 20 Str adds 6 and 7. Exports predating the
columns leave them zero and behave exactly as before — pinned by its own test.

### Open

- **The distribution is still uniform.** `FUN_0040dce0` rolls 13/14 with a
  three-sample minimum centre-biased about a midpoint; srrevamp rolls uniformly.
  That is a known, deliberate difference, not an unrecovered one.
- **Which roll the live melee path takes.** Both `Formula_RollWeaponDamage`
  (190/191, via `FUN_0040f990`'s attack-type switch) and `FUN_0040dce0` (13/14)
  exist; this entry establishes that 13/14 are read for damage bounds, not that
  190/191 are dead. Tracing `FUN_0040f990`'s callers is the next probe.
- Unarmed keeps the innate 30.6/34.2 in the real engine; srrevamp takes 0 there,
  since `unarmedDamage` is own design anyway.
- Still open from before: itemdata columns 114 and 117; `pc[0x72d]`'s state enum;
  blocking's monster side.

## The physical damage pipeline, register by register (2026-09-15)

The previous entry's open item was *which roll the live melee path takes*. Both:
`Combat_ResolveDamage` (`0058e5f0`) calls `Formula_MitigatePhysicalDamage` four
times **and** `FUN_0040f990` twice. They are different stages, not rivals — and
the one that produces the blow is the first.

**A better tool, recorded because it changes what is cheap.** `objdump -d
--start-address=… -M intel /var/tmp/SR_GameServer.exe` disassembles the PE
directly. It needs no Ghidra, takes no `flock`, and answers in under a second,
where a `Disasm.java` run costs ~25s and contends with the cron. Every register
fact below came from it. Use it whenever the decompiled C is ambiguous — and
here it was worse than ambiguous, reading `fStack_8` before assignment and
applying `>> 0x20` to a float.

### Who is who

	esi = eax          the attack context   (+0x230 descriptor, +0x524 bonus)
	bl  = cl           the flag byte
	ebp = [esp+0x1c]   the ATTACKER
	edi = edx          the DEFENDER

The attacker/defender assignment is proven, not assumed: `FUN_0040dce0` is
entered with `ecx = ebp`, moves it to `esi`, and calls `FUN_0040db50` with
`eax = esi`; `FUN_0040db50` then does `GetParam((edi != 0) + 0xd)` on **eax**.
So the object whose damage params 13/14 are rolled is `ebp`. The mitigation
block reads params 5 and 7 off `edi`, the other one. **That settles whose params
5 and 7 are — the defender's** — which this project had recorded as "the same
object" without saying which.

### The order

	raw   = centre-biased roll of ATTACKER params 13/14        FUN_0040dce0
	        + descriptor[+8] / [+0xc] folded into the bound     40db86 / 40db8b
	raw  += context[+0x524] bonus                   if flags & 0x08
	mit   = raw / (1 + defender_p7/100) - defender_p5          40e52a-40e542
	        ... skipped entirely                    if flags & 0x20
	mit   = max(mit, 0)                                        40e54a
	mit  *= descriptor[+4] / 100                               40e56e-40e588
	mit  *= 1 + GetParam(0x80 | 0x81)/100                 by flags bit0/bit1
	mit  += GetParam(0x103)/100 * mit      if defender vf[0x12c] == 3
	mit  *= GetParam(0xbd) + 2.0                    if flags & 0x04
	mit  *= 2                                       if flags & 0x02
	mit  *= 1 + LevelAdvantage()                    if atkLevel > defLevel

The struct at `+0x230` is the **attack descriptor**, and its three numeric
fields are exactly the three this project already reads out of skilldata's
`'att'` parameter: the percentage at `+4`, a flat minimum at `+8` and a flat
maximum at `+0xc`. **The two halves land on opposite sides of mitigation** —
the flat pair is added to the rolled bound inside `FUN_0040db50`, the percentage
multiplies only after the division, the subtraction and the clamp.

### What moved

- **Shipped:** `combat.ApplySkillPercent`, and `skillDamageBonus` now returns
  `(flat, percent)` so `performAttack` can put them on the right sides. srrevamp
  had folded the percentage into the raw roll, which scales the defence away:
  a 200% skill against 10 flat armour paid 180 instead of 160. Pinned end to end
  through the network harness by a test verified to report 50 under the old
  order. This is the same mistake, and the same fix, as the berserk multiplier's
  ordering two entries ago — worth noting that it recurred in a second place
  after being fixed in the first.
- **Fixed in passing:** the old `skillDamageBonus(ref, weaponDamage)` rolled the
  weapon a *second* time to compute its percentage, then handed the result to
  `performAttack`, which rolled the weapon again for `base`. Two independent
  rolls were being mixed into one blow. The percentage now scales the actual
  blow, so there is one roll.
- **Citation upgraded, no code change:** `playerMitigationPercent = 0` and
  `LevelAdvantage` 0.03/0.30 both re-derived independently here — the level
  constants read out of `.rdata` as `fmul QWORD 0x00b45dc8` = 0.03 and
  `fld DWORD 0x00b45b8c` = 0.30, with the operand sizes confirming which is
  which. Both already carried the right values and the right citations.
- **v0.1.174 validated:** the params the live path rolls for its damage bounds
  are 13/14, the ones carrying the Str-derived reinforce term.

### Open

- `GetParam(0x80)` / `GetParam(0x81)` off the attacker, selected by descriptor
  bits 0 and 1 — a percentage bonus against some target class.
- `GetParam(0x103)` off the attacker, live only when the defender's `vf[0x12c]`
  returns 3.
- Descriptor flag `0x20` skips mitigation outright; which attacks set it.
- `FUN_0040f990`'s switch (2..N) scales `Formula_RollWeaponDamage`'s uniform
  190/191 roll by `.rdata` constants. Since 190/191 carry no Str term and no
  buffs, this is a *second*, simpler damage path; what selects it is unknown.
- Still open from before: itemdata columns 114 and 117; `pc[0x72d]`'s state
  enum; blocking's monster side.

## The kill-EXP formula, and a correction (2026-09-15)

### First, two open items closed cheaply

**Which damage path is the ordinary attack.** `Combat_ResolveDamage` wraps its
damage step in `switch (*(byte *)(iStack_e0 + 5))` — a damage-KIND selector:

| case | path | params |
|---|---|---|
| **0** | `Formula_MitigatePhysicalDamage` + the magical twin | **13/14** |
| 1 | `Formula_RollLevelDamage` | level-based |
| 2 | `GObjPC::FUN_00615a20` | — |
| 3 | `FUN_0040f990` → `Formula_RollWeaponDamage` | 190/191 |

Case 0 is the ordinary attack, so the Str-carrying params 13/14 are the live
path and `FUN_0040f990`'s simpler 190/191 roll is a special damage kind. That
confirms v0.1.174 and v0.1.175 sit on the right branch.

**The berserk constant.** `_DAT_00b45f30` reads 2.0 as a double and 0.0 as a
float, so the operand size decides a shipped value. It is
`40e672  FADD QWORD PTR ds:0xb45f30` — a double. Berserk is `GetParam(189) +
2.0`, and srrevamp's flat ×2 is that at the default rate. No change; the
citation is now operand-checked.

### The exp reward, register by register

`Formula_MonsterExpReward` (`004105d0`), disassembled:

	ebx = MIN(level(esi), level(edi))            the anti-powerlevelling rule
	A   = (float)(uint32) RefLevel_GetEntry(ebx)[+0x1c]
	B   = Formula_ExpScaleByLevelWindow(edi)
	C   = FLD DWORD PTR [edi + 0x1cd8]
	D   = Formula_ExpScaleByLevelDiff(esi, edi)
	exp = B * A * C * D, floored at 1

**Correction: `+0x1cd8` is the KILLER's field, not the victim's.** This file
recorded it as `victim[0x1cd8]`. `GObjPC_OnDeath` (`004e6980`) is `__thiscall`
with the dead party as its stack argument, and its prologue is unambiguous:

	4e69bf  MOV EBP,[ESP + 0x11f4]     <- the stack arg, the DEAD
	4e69d2  MOV EDI,ECX                <- `this`, the KILLER
	4e69c6  MOV EAX,[EBP + 0x34]       <- the dead's charData (+0xb4 below)
	4e6a07  MOV EAX,EBP ; CALL 0x4105d0

so inside the formula `esi` is the dead and `edi` the killer, and `C` is read
off the killer. It is a float, and on `CGObjMob` the same offset is a packed
byte (`CGObjMob::GetMonsterClass` is `MOV AL,BYTE PTR [ECX+0x1cd8] ; AND AL,0xF`)
— different classes, which is what made the original reading look plausible.
A per-character exp rate, presumably premium or event; not modelled.

**There is no per-species exp column anywhere in this formula.** The monster
contributes only its LEVEL, through the minimum and through the gap scaler.
That retires the standing note in `combat.ExpFor` that "the real value is in the
client's mob data (RefObjChar's ExpToGive)" — no such field is read.

### Formula_ExpScaleByLevelDiff: RECOVERED and shipped

	40108f  LEA EAX,[EDI + 0x3] ; CMP EAX,EBX ; JG     <- victim+3 > killer?
	4100a0  FLD1 ; RET                                 <- else exactly 1.0
	4100a8  SUB EDI,EBX ; ADD EDI,0x3                  <- victim - killer + 3
	4100ad  CMP EDI,0xD ; MOV [ESP+0xC],0xD            <- capped at 13 steps
	4100c2  FMUL qword [0x00b45dc8]                    <- * 0.03
	4100c8  FADD [ESP + 0x8]                           <- + bonus + 1.0
	4100f1  FLD  dword [0x00b45dc0]                    <- clamped to 4.0

`EDI` is the victim's level and `EBX` the killer's, from the caller's
`MOV EAX,ESI ; MOV ESI,EDI` at `0x410666` plus the prologue above. Operand sizes
give the constants: `FMUL qword` makes `0x00b45dc8` a double, **0.03** — the
same constant the level-advantage damage term uses — and `FLD dword` makes
`0x00b45dc0` a float, **4.0**.

So: out-level the target by three or more and the bonus is exactly 1.0;
otherwise `1 + 0.03 * min(victim - killer + 3, 13)`, spanning 1.03 to 1.39.

**Not modelled, deliberately.** The same function can add a further
0.15/0.3/0.45 (or 0.3/0.6/0.9 under a flag at the killer's ref object `+0x88`)
for gaps above 4, 6 and 8 — but only behind a state gate, `killer[0x72e]`
non-null with bit 0 of its `+0x10` set, which is not identified. A bonus whose
precondition is unknown would be applied always, which is worse than omitting
it. The cap is therefore unreachable in srrevamp.

`Formula_ExpScaleByLevelWindow` (`0040fed0`) stays at 1.0: it branches on a mode
from `FUN_0040fe60` and asserts on two of its three paths, and neither the mode
nor what selects it is identified.

**What moved:** `leveldata.ExpDiffScale`, applied inside `KillExp`. The base and
the minimum-level rule were already real and already wired into the kill path;
this replaces the last "treated as 1.0" simplification in the kill reward with
the recovered curve. A level-1 character killing a level-20 monster now earns
33 rather than 24 — still paid at the level-1 unit, but with the gap bonus. The
reverse direction is unchanged at 24, so the economy only opens upward.

### Noted in passing

`pc[0x72d]` — an open item — appears here as `CMP BYTE PTR [EBP+0x1cb4],0x5`
(`0x72d * 4 = 0x1cb4`). `!= 5` is what gates both the doubled exp reward and
the death-penalty branch, so whatever state 5 is, it suppresses both. Still not
identified, but the use-site is now a pair rather than a single.

## The death handler, read to the bottom (2026-09-15)

`GObjPC_OnDeath` (`004e6980`) had three things recorded against it as not
understood. All three are now read.

### pc[0x72d] is a DEATH-KIND code

An open item since the death penalty was first recovered. It is written one
instruction before it is dispatched on, by `GObjPC::FUN_004e6ec0` (`004e6ec0`):

	uVar1 = FUN_004e6590();            <- classify the death
	pc[0x1cb4] = uVar1;                <- 0x72d * 4
	switch (uVar1) {
	  case 1:            FUN_004e6820(); return;
	  case 3: case 4: case 5: GObjPC_OnDeath(); return;
	  case 6:            FUN_004e6d60(); return;
	}

So it is not a general state enum: it is the KIND of the death that just
happened, and only kinds 3, 4 and 5 reach the penalty handler at all. The
classifier `FUN_004e6590` ends with

	iVar2 = FUN_004eb390(in_EAX);
	return (-(uint)(iVar2 != 1) & 0xfffffffe) + 5;     <- ==1 -> 5, else -> 3

and `FUN_004eb390` returns 1 only when the killer passes the `vf[0x1c]`
predicate, BOTH parties have a non-null `[0x72f]`, and a further comparison
matches. Two parties sharing a membership object, in a death that suppresses the
PK treatment — the shape of a duel or a match — but `[0x72f]` is not identified,
so the kind is described, not named.

### The 20/100/300 branch conditions

Previously "NOT understood". The selector is `killer->vf[0x1c]()`:

	vf[0x1c]() == 0  ->  100 / 300,  SP loss 60
	vf[0x1c]() != 0  ->   20 / 100,  SP loss 20

and that same predicate gates the exp grant at the top of the function — the
killer is paid only when it is non-zero. A predicate that decides whether the
killer receives experience identifies a PC, so `!= 0` is **killed by a player**
and `== 0` **killed by a monster**. That confirms, rather than changes,
srrevamp's existing `DeathPenaltyKilledByMonster` 100 / `Flagged` 300 and
`KilledByPlayer` 20 / `Flagged` 100 — names that were a reasonable hypothesis
and are now the recovered mapping.

The second condition, the one the names call "Flagged", is
`deathKind != 5 && victim.PKPenaltyPoint >= 1` — and the SP loss is non-zero
only on that branch, which is why srrevamp's two skill-point constants exist
only in flagged form. The identical condition doubles the KILLER's experience,
so a flagged victim is worth twice as much and loses three times as much.

### The reduction stat: param 257, and a proven zero

Recorded as "read through a register-passed ParamKeeper id this code has not
resolved, so it is left out rather than guessed at". The id is in EAX:

	4e6b78  LEA  EDI,[EBP + 0x1ec]      <- the VICTIM's own GParamKeeper
	4e6b7e  MOV  EAX,0x101              <- param 257
	4e6b83  CALL 0x4b3740               <- EvaluateParam
	4e6b88  FDIV qword [0x00b45af0]     <- / 100
	4e6b8e  FIMUL dword [ESP + 0x14]    <- * the loss
	4e6b9b  SUB  ESI,EAX                <- loss -= that

so it is a PERCENTAGE of the loss rather than a flat term. **Exactly one
function in the binary writes param 257**, and it names itself:
`CTJ_PremiumKeeper::vslot_012` (`006524b0`), which sets 256, 257 and 258
together out of one premium-benefit record (`+0x300`, `+0x2c0`, `+0x320`). The
death-penalty reduction is a PREMIUM ACCOUNT benefit; an ordinary character has
no writer for the param and evaluates it at zero.

**What moved:** `leveldata.DeathPenaltyReductionPercent` and
`ApplyDeathPenaltyReduction`, wired into `DeathPenaltyExp`. The value is zero, so
no death costs a different amount — but it is now a *cited* zero with the
engine's shape around it, the same status as `playerMitigationPercent`, instead
of an unmodelled gap. The test pins the percentage shape so a premium system
later lands in the right arithmetic.

### Three stale claims corrected

- `combat.ExpFor` told the reader the real value was "RefObjChar's ExpToGive".
  There is no such field in the formula — the previous entry established that a
  monster contributes only its level — so the note sent future work looking for
  a column that is never read. Same claim removed from `Monster.ExpReward`.
- `Monster.SPReward` carried the same claim, but there the honest statement is
  different and now says so: the exp formula has been read end to end and pays
  no skill points at all, so whatever grants them is a path not yet found.
- `duel.go` justified charging no death penalty with "same as PvE", which
  stopped being true when PvE began applying the real 100x. The divergence is
  now stated as own design, together with what is and is not established: a PC
  killer does take the 20x branch, but whether a duel death reaches
  `GObjPC_OnDeath` at all depends on its death kind, and kinds 1, 2 and 6 go
  elsewhere. Charging 20x without reading that would be a guess dressed as
  recovery, so the behaviour is unchanged.

### Open

- `[0x72f]` and `[0x72e]` — adjacent pointer fields on a PC, gating death kind 5
  and the exp-reward tier bonus respectively. Naming either would name both a
  death kind and a shipped-adjacent bonus.
- `vf[0x3b4]` on the killer overrides the loss outright in the monster branch.
- Death kinds 1, 2 and 6, and their handlers `FUN_004e6820` / `FUN_004e6d60`.
- Params 256 and 258, the other two premium benefits.
- Still open from before: `GetParam(0x80/0x81)` and `GetParam(0x103)` in the
  damage pipeline; the mitigation-skipping descriptor flag `0x20`;
  `Formula_ExpScaleByLevelWindow`'s mode; itemdata columns 114 and 117.

## [0x72e] and [0x72f] are PARTY and GUILD — and the exp formula closes (2026-09-15)

The previous entry named these two adjacent PC pointer fields as the best next
lever, on the grounds that either one would settle both a death kind and a
shipped-adjacent bonus. Both are named now, and from the binary's own asserts
rather than by inference:

	CGObjPC::GetPartyInfo  (IGObj vtable slot 76)  reads pc+0x1cb8  -> [0x72e] = PARTY
	CGObjPC::GetGuildName  (IGObj vtable slot 94)  reads pc+0x1cbc  -> [0x72f] = GUILD

Each override is a two-line function whose only field access is the one in
question, and each was already named by the base class's `__FILE__` assert. That
retires two open items at once:

- **The exp-reward tier bonus is a PARTY bonus.** Its gate is `killer[0x72e]`
  non-null with bit 0 of the party's `+0x10` set. Still not shipped — what bit 0
  selects is unread, and srrevamp's parties are own design with no such flag —
  but the reason is now "a party-conditional bonus whose party flag is unread"
  rather than "an unidentified state".
- **Death kind 5 needs BOTH parties in guilds.** `FUN_004eb390` requires the
  killer to pass the PC predicate, the victim's `+0x1cbc` to be non-null, and
  the killer's `[0x72f]` likewise, before a further guild-to-guild comparison.
  A player kill where both sides are guilded, which suppresses the PK penalty
  and the doubled reward, is a guild-war or siege death. Described, not yet
  named: the comparison itself (`FUN_005e4390`, a two-hop accessor into the
  guild object) has not been followed to a war table.

### Formula_ExpScaleByLevelWindow: RECOVERED, and the exp formula is now whole

The last "treated as 1.0" term. Its mode comes from `FUN_0040fe60`, which turns
out not to be a mode at all but three comparisons on the level gap:

	gap = victimLevel - killerLevel
	gap <  -3 -> 2      gap < 11 -> 0      otherwise -> 1

and **mode 0 jumps straight past every arithmetic path** (`40ff03 SUB EAX,0 ;
JE 0x40ff8c`), leaving the 1.0 the result was initialised to. So inside a
-3..+10 band the scale is exactly 1.0 — which is most kills, and means the old
placeholder was accidentally right for the common case and wrong only at the
extremes.

The two outer arms:

	mode 1, 40ff5d:  SUB EDX,EBX ; SUB EDX,0xA
	                 FMUL qword [0x00b45ec8]      <- * 0.02
	                 FLD1 ; FSUBRP                <- 1.0 - that
	mode 2, 40ff1f:  SUB ECX,EBX ; CMP ECX,-7 ; JG
	         40ff55:   FLD dword [0x00b45ddc]     <- 0.9 flat
	         40ff38:   SUB EBX,EDX ; SUB EBX,3
	                   FMUL qword [0x00b45ed0]    <- * 0.15
	                   FLD1 ; FSUBRP
	clamp,  40ff94:  FCOM qword [0x00b45ec0]      <- below 0.1 -> 0.1
	        40ffb6:  FLD1 ; FCOM                  <- at or above 1.0 -> 1.0

`EBX` is the killer's level and `EDX` the victim's, from
`Formula_MonsterExpReward`'s `MOV ECX,EDI` (EDI being the killer) with ESI still
holding the victim.

**Operand size mattered more than usual here.** Both `0x00b45ec8` and
`0x00b45ed0` read as `2` when taken as a float and as `0.02` and `0.15` as
doubles — and the instruction is `FMUL qword` in both cases, so they are the
doubles. Taking the float would have made every extreme-gap kill pay a negative
scale clamped to the floor.

So the scaler is, clamped to [0.1, 1.0]:

| gap (victim − killer) | scale |
|---|---|
| ≥ 11 | 1 − (gap − 10) × 0.02 |
| −3 … 10 | **1.0** |
| −4 … −6 | 0.9 |
| ≤ −7 | 1 − (−gap − 3) × 0.15 |

**What moved:** `leveldata.ExpWindowScale`, applied in `KillExp` alongside
`ExpDiffScale`. With both scalers in, a kill's experience is the game's own
formula at the base rate — only the killer's premium/event multiplier
(`killer+0x1cd8`) is left out, and a character without one evaluates it at its
default.

The visible change is at the extremes, and it is the real anti-powerlevelling
rule: a level-20 killing a level-1 drops from 24 to **2** (the minimum-level
rule still pays the level-1 unit, but the window floor takes 90% of it), and a
level-10 killing a level-3 from 71 to 28. Kills inside the band are unchanged —
a level-3 on a level-10 stays 92.

### Open

- Bit 0 of a party's `+0x10`, which arms the exp tier bonus.
- `FUN_005e4390` and the guild-to-guild comparison behind death kind 5.
- `vf[0x3b4]` on the killer, which overrides the death loss outright.
- Death kinds 1, 2 and 6 and their handlers.
- Premium params 256 and 258, and `killer+0x1cd8`, the exp rate.
- Still open from before: `GetParam(0x80/0x81)` and `GetParam(0x103)` in the
  damage pipeline; the mitigation-skipping descriptor flag `0x20`; itemdata
  columns 114 and 117.

## The stat-tag vocabulary, extracted mechanically (2026-09-15)

`Stat_ApplyTaggedModifier` (`00498690`) is the id→name table this binary has as
code rather than data, and it had been read by hand, fourteen tags at a time.
Extracting it mechanically instead — walk the function body, remember the most
recent `in_EAX == 0x…` equality (never a range test, which is the binary-search
trap this file already records), and attribute the `ParamKeeper param id`
comments that follow it — gives nineteen:

| tag | constant | params |
|---|---|---|
| `int` | 0x00696e74 | 2 |
| `hp` / `hpa` | 0x00006870 / 0x00687061 | 3 |
| `mp` / `mpa` | 0x00006d70 / 0x006d7061 | 4 |
| `era` | 0x00657261 | 9 |
| `bri` | 0x00627269 | 10 |
| `hra` | 0x00687261 | 11 |
| `cri` | 0x00637269 | 12 |
| `hprg` | 0x68707267 | 25 |
| `mprg` | 0x6d707267 | 26 |
| `hpmp` | 0x68706d70 | 25, 26 |
| `rals` | 0x72616c73 | 27–32 |
| `hpna` | 0x68706e61 | 52 |
| `mpna` | 0x6d706e61 | 53 |
| `evbl` | 0x6576626c | 56 |
| `evcr` | 0x65766372 | 57 |
| **`drua`** | 0x64727561 | **128, 129, 130** |
| **`dara`** | 0x64617261 | **174, 175, 176, 177** |

**Seventeen of the nineteen reproduce the map this project had already read by
hand, value for value.** That is what licenses the other two: the extraction is
not a new method whose output has to be taken on trust, it is a method checked
against seventeen known answers before being asked a new question.

`drua` matters because params 128 and 129 are read in the damage pipeline —
`Formula_MitigatePhysicalDamage` multiplies the mitigated blow by
`1 + GetParam(0x80 | 0x81)/100`, choosing between them on bits 0 and 1 of the
attack descriptor. So it is a conditional damage bonus, and the tag that grants
it is now named even though what the two bits select is not.

**Encoding, since this has been got wrong before.** The tables store the tag as
a multi-char literal, so the bytes come out reversed from a little-endian read:
`0x00617474` unpacks to `tta` and is `att`. A census of the real skilldata Params
block confirms it independently — the codes that fall out are `tta`, `pfed`,
`laeh`, `arud`, `msnc`, which reversed are `att`, `defp`, `heal`, `dura`, `cnsm`.
Hand-computing these constants has cost this project a wrong result twice; both
times the fix was to let the machine do the arithmetic, and that is what this
entry does.

### A negative that does not hold, recorded so it is not re-derived

`drua` and `dara` appear on **zero** rows of skilldata's Params block and zero
rows of itemdata. That is NOT evidence they are dead, and the control run in the
same probe proves why: **`cri` also appears zero times**, and `cri` is a real,
shipped stat — a weapon's Critical reaches param 12 from itemdata **column 116**,
a dedicated column, not from a Params tag. A tag's absence from the Params block
therefore says nothing about whether the stat is live.

The probe was too narrow, and only the control caught it. This is the fourth
false negative in this project from a probe that could not have found what it was
looking for; the rule it keeps re-teaching is to run a known-positive through
every new probe before believing its zeros.

### Naming coverage, measured

Off the dump indexes directly, needing no Ghidra run: server **64.6%** (22,033 of
34,113), client **46.1%** (20,038 of 43,460). The client's unnamed set is mostly
small — 17,245 of its 23,422 are under 128 bytes — leaving roughly 6,200
substantial functions genuinely unnamed.

Both binaries already carry the source-file attribution pass (12,954 module
comments in the client dump, 14,328 in the server), so that lever is spent. An
earlier count here suggesting otherwise was an artifact of comparing *files*
containing the comment across dumps with 22 and 2,133 shards respectively.

**No srrevamp value changed this tick.** The vocabulary is knowledge, and the
one code-adjacent edit is a correction: `docs/GROUNDING_AUDIT.md` asserted in a
single sentence both that `Char_PublishCombatStats` publishes param 12 and that
it "indeed does not". It does — `0x00497ef0`, `MOV EDI,0xc`, from the stat
source's `+0x1dc` — and the tag route simply coexists with it.

## Skill points are a CURRENCY, not a per-kill grant (2026-09-15)

`combat.SPFor` -- a tenth of a monster's max HP -- was the last wholly invented
value in a monster's profile. Every other field is real: level (col 57), rarity
(15), max HP (59), flat absorb (71), reduction (73), the attack range (col 83's
skill `'att'`), gold (levelgold.txt), critical (78), block (76), spawns
(npcpos), and since two entries ago the experience. Skill points were the
holdout, and the previous entry had recorded that "the exp formula has been read
end to end and pays no skill points, so whatever grants them is a separate path
this project has not found."

It is not a separate path. It is the same call, one argument over.

### The mechanism

`GObjPC_GainExpAndLevel` (`004e5250`) takes SIX arguments, and the skill
experience is the **fourth and fifth** -- a 64-bit pair distinct from the
experience in the second and third. Every ordinary exp grant passes zero there
(`GObjPC_GiveExp` calls it `(src, expLo, expHi, 0, 0, 0)`), which is why reading
the exp path end to end found no skill points. The block that consumes it:

	acc = charData[0x70] + amount          <- _CHAR.SExpOffset, the carried total
	if acc >= 400 {
	    sp  = __alldiv(acc, 400)           <- whole points
	    acc = acc - sp*400                 <- the remainder STAYS on the character
	    this->AddSkillPoints(sp, 0)        <- vtable slot 93
	}
	charData[0x70] = acc                   <- persisted, dirty bit 4 set

`charData + 0x70` is `SExpOffset` in the recovered `_CHAR` schema, and the name
says it: skill experience, offset-encoded like `ExpOffset` beside it.

**So skill points are bought, at 400 skill-experience each, out of a running
total the character carries between kills.** Granting whole points per kill --
what srrevamp did -- cannot reproduce that at any rate, because it rounds every
kill to a whole point.

The same block confirms last entry's guild naming from a completely different
function: it only touches its guild-contribution accumulator (`pc[0x861]`,
flushed to the guild at 10) when `pc[0x72f]` is non-null, and `[0x72f]` was
named GUILD from `CGObjPC::GetGuildName`.

### What is NOT recovered, and is disclosed instead

How much skill experience a KILL is worth. The amount reaches the function as
`levelTable[lvl]+0x1c * M` (`FUN_00631050`), the same per-level unit that pays a
kill's exp and a death's penalty -- but `M` comes from a struct that has not been
identified, and the one caller that spells the expression out is a quest reward
rather than a kill. srrevamp takes **M = 1**: a kill is worth its own experience
in skill experience. That is a disclosed choice and the single knob to turn if
`M` is ever read.

It also corrects a claim in `ExpUnit`'s own comment, which said `FUN_00631050`
hands that product to `GainExpAndLevel` "as an exp amount". It goes in as the
skill experience. The same per-level unit feeding a kill's exp, a death's
penalty and a skill-point award is what makes it the table's unit of account
rather than one system's constant.

### What moved, and the balance consequence stated plainly

`leveldata.SkillExpPerPoint = 400`, `skill.Store.AddSkillExp` (both stores, with
a `skill_exp` column added beside `points` so existing characters keep what they
earned), and the kill path now credits skill experience instead of points. The
whole-point path survives only as the fallback for a deployment with no level
table, where there is no experience to convert.

**SP income drops sharply, and that is the point rather than a side effect.** A
level-1 character killing a Mangyang earned 5 points a kill (a tenth of its 54
max HP); it now earns 26 skill experience, so a point arrives about every 15
kills, and the first mastery level costs 1. At level 20 a same-level kill is
worth ~512, so roughly a point a kill against a mastery cost of 53. That curve
-- tight early, roughly one point per kill by mid level -- is the shape the
400:1 conversion produces on its own, from numbers that were already grounded.

### Also corrected

Two field comments in `combat.Monster` that had gone stale: `Defense` was
labelled "still the disclosed curve" when it has been characterdata col 71 since
2026-09-15 (`cmd/server`'s own `monsterSpec` says so), and `Level` still claimed
MaxHP and the attack range were disclosed defaults when both are real.

## No kill feeds the skill-point currency (2026-09-15)

The previous entry shipped the 400:1 skill-experience conversion and disclosed
one unknown: how much skill experience a KILL is worth, taken as `M = 1`. The
justification was thin — "the one caller that spells it out is a quest reward
rather than a kill" — and it sat under a large balance change, so it was worth
settling. It is settled, in the negative, and the probe is closed rather than
merely unlucky.

**Every route into the currency, enumerated:**

1. **The carried total has one writer.** `_CHAR.SExpOffset` (`charData+0x70`) is
   written in exactly one place: the 400:1 conversion inside
   `GObjPC_GainExpAndLevel`. The only other function that touches the field,
   `GObjPC::FUN_0049efc0`, reads it (with `+0x74`, Strength) into a packet.
   Checked two ways — the `[0xd] + 0x70` form and a broad `+ 0x70) =` scan whose
   other hits are offset collisions on unrelated structs.
2. **Only four of forty-two `GainExpAndLevel` call sites pass skill
   experience.** It is the FOURTH argument, a 64-bit pair distinct from the
   experience in the second and third, and every ordinary exp grant passes zero
   there — `GObjPC_GiveExp` calls it `(src, expLo, expHi, 0, 0, 0)`. The four
   that do not are a quest reward (`FUN_00631050`), its party distribution
   (`FUN_00631630`), and two others off the same path. The first census of this
   missed the argument lists because the decompiler wraps them across lines; the
   second joins the call before matching, and finds the same four.
3. **Every positive `AddSkillPoints` caller is the conversion or a refund.**

So **no kill path in this binary feeds the skill-point currency**, and there is
no `M` to read for a kill. That does not change what srrevamp ships; it replaces
a thin reason for the disclosure with an exhaustive one, which is the difference
between "not found yet" and "searched and absent".

### Recovered in passing: the skill-reset refund is 80%

`FUN_00410ea0` walks a chain (`+0x59c` is the next link), sums the skill points
invested at each node (`+0xc0`), optionally stopping at a level threshold
(`+0x64`), and then:

	iVar1 = iVar1 + (iVar1 * -0x14) / 100      <- minus 20%, i.e. 80% back

Its caller `FUN_0059f8b0` hands the result to `AddSkillPoints(n, 1)`, and the
client ships the window it belongs to — `IFSkillWithdrawal.cpp` and
`IFSkillRemovalBox.cpp` are both in the client's own source-path strings. So
un-learning a skill chain refunds **80%** of the points spent on it.

**Not shipped, deliberately:** srrevamp has no skill withdrawal, so exporting an
80% constant would add a value nothing consumes — the pattern this file has
corrected repeatedly. It is recorded here for whoever builds that window.

### Open

- Whether a mob's death runs through a handler this project has not found. All
  three death handlers reached from `FUN_004e6ec0`'s dispatch (`FUN_004e6820`
  kind 1, `GObjPC_OnDeath` kinds 3–5, `FUN_004e6d60` kind 6) are PC-death
  variants in `GObjPC.cpp`, all gated on the victim's level exceeding 10 and all
  applying an exp penalty. If a mob-side death handler exists, it is the one
  place a kill-side skill-exp source could still hide.
- `M` itself, for the quest path: `*(int *)(iVar2 + 0x10)` from an unidentified
  struct.
- Still open from before: bit 0 of a party's `+0x10`; `FUN_005e4390`'s guild
  comparison; `vf[0x3b4]`; premium params 256/258 and `killer+0x1cd8`;
  `GetParam(0x80/0x81)` and `GetParam(0x103)`; descriptor flag `0x20`; itemdata
  columns 114 and 117.

## Death dispatch is vtable slot 311 — and a foundational claim weakens (2026-09-15)

The previous entry's recorded next thread was "whether a mob's death runs
through a handler this project has not found". It does, it is found, and what it
does not do is the finding.

### The dispatch, by vtable slot

Death entry is **slot 311** (`offset 0x4dc`), and reading that slot straight out
of each class's vtable in the PE names all three implementations without opening
Ghidra:

| class | vtable | slot 311 |
|---|---|---|
| `CGObjPC` | 0x00af59fc | `0x004e67e0` → `FUN_004e6ec0`, the kind classifier |
| `CGObjMob` / `CGObjNPC` | 0x00aee43c, 0x00aef674 | **`0x004c42f0`** |
| `CGObjCOS` (pets) | 0x00af0c1c, 0x00af127c | `0x004d2cd0` |

`0x004c42f0`'s RTTI confirms it: *CGObjMob slot 311, CGObjNPC slot 311,
CGObjSiegeObject slot 311…*. **It grants no experience.** It runs a PK decay
(`FUN_004eb6b0`, gated on the killer's `PKPenaltyPoint > 0`, scaling by a
level-gap classifier) and dispatches slot 398, which for `CGObjMob` is a death
broadcast building opcode `0x7808`.

### Every exp grant in the binary, enumerated

All 42 `GObjPC_GainExpAndLevel` (slot `0x170`) call sites, with argument lists
joined across the decompiler's line wrapping first. The ones granting positive
experience are:

- **Quest completions** — eight `CQNO_*::vslot_103`.
- **`GObjPC_GiveExp`** — and its only three callers are `GObjPC_OnDeath`,
  `FUN_004e6d60` and `FUN_004e1f60`, all reached from the PC death-kind
  dispatch.
- **`FUN_004fcda0`** — `GiveExp`'s own party share.
- **`FUN_0049ff20`** — a premium/item grant; it reads `+0x2c0` off the same
  record `CTJ_PremiumKeeper::vslot_012` uses for param 257.
- **`trs_*`** — GM and training-camp paths, one of which hands out a flat
  2,000,000.

### The consequence: the name overstated the case

`Formula_MonsterExpReward` is **this project's** name. Its only two callers are
reached when a **PLAYER** dies — `GObjPC_OnDeath`'s victim is always a PC, which
is settled rather than assumed: the function reads `param_2[0x72d]`, the
death-kind byte, and that byte is written only by `FUN_004e6ec0`, which is
reached only from `CGObjPC::vslot_311`.

So every use-site of the formula in this binary is a PvP kill. Nothing *in* the
formula is PvP-specific — it takes the two levels and the level table and
nothing else — so applying it to a monster kill remains the best grounded model
available, and `KillExp` is unchanged. But this file called it "PROVEN by its
use-site", and that was true of the function's **identity** (its result goes to
`GObjPC_GiveExp`) and not of its **application**. The comment in
`leveldata.ExpUnit` now carries the caveat.

**What is NOT concluded:** that monsters grant no experience. That would
contradict the game, and the honest reading is that a PvE reward path exists
which this enumeration has not reached — most likely deeper in `FUN_004c42f0`'s
slot-398 chain, which was read two levels down, or in the AI/tactics module. The
enumeration above is of `GainExpAndLevel` call sites; a path that reaches the
character's exp another way would not appear in it. Recording the boundary of
the probe rather than treating its edge as the world's.

### Also named

`FUN_004e1f60` — a per-death-kind social handler. For kind 1 it pays the killer
`levelTable[min(levels)]+0x1c * 3` and branches on `param_1[0x72e]`, the party
pointer, routing through `FUN_005bd7f0` when the killer is partied and
`FUN_004e2830` when solo. A third, independent use of the party field named two
entries ago.

`FUN_00410ea0`'s neighbourhood is confirmed as the skill-reset path rather than
a reward: `FUN_0059f8b0` hands its 80% refund to `AddSkillPoints`.

**No srrevamp value changed.**

## The PvE exp question, closed (2026-09-15)

The previous entry stopped at a boundary rather than a conclusion: the exp
enumeration covered `GainExpAndLevel` call sites, so a PvE path reaching a
character's experience *another way* would not have appeared in it. That hole is
now closed from the other end.

**Both experience fields have exactly one writer.**

| field | what | writers |
|---|---|---|
| `charData+0x68` | `ExpOffset` | **`GObjPC_GainExpAndLevel`**, and nothing else |
| `charData+0x70` | `SExpOffset` | the same function, and nothing else |

The only other function touching either is a reader in both cases:
`GObjPC::FUN_0049efc0` puts `SExpOffset` into a packet, and
`GObjPC::FUN_004909f0` formats `ExpOffset` into `" ^^%d^^"` for what is plainly
a GM stat dump. So **every** grant of experience or skill experience in the
binary must pass through `GainExpAndLevel`, whose 42 call sites the previous
entry enumerated in full.

Combined with this tick's vtable reads, the mob side is covered three ways:
`CGObjMob`'s death handler (slot 311, `0x004c42f0`), its slot-398 override
(`0x004c1c80`, a death broadcast) and its slot-322 override (`0x004c1c30`, which
only sets `[0x738] = 20000` behind the `vf[0x3b4]`/`vf[0x3bc]` predicates) grant
no experience between them.

**So this binary contains no PvE experience reward.** Not "none found" — none
reachable, because the field it would have to write has a single writer and that
writer's every caller is accounted for.

### Why that strengthens srrevamp rather than undermining it

The previous entry left `KillExp` resting on an extrapolation and flagged it as
one. The extrapolation is now the *only* option rather than a choice: there is no
PvE formula in the binary that srrevamp declined to use. It models a monster kill
with the single reward formula the artifact contains, whose inputs -- the two
levels and the level table -- carry nothing PvP-specific. `leveldata.ExpUnit`'s
caveat now says so.

The likeliest explanation for the absence is the artifact itself: this is a
private-server build (y0gi "Easy" VSRO), and a PvE reward that was configured
out, moved to a module outside this executable, or driven from data would leave
exactly this signature. That is a hypothesis about *why*, not a hedge on the
*what* -- the enumeration stands on its own.

### Named this tick

- **Slot 322** is a per-class "killed by" hook: `CGObjPC::vslot_322`
  (`0x004e27c0`) routes to `FUN_004e1f60`, the per-death-kind social handler;
  `CGObjMob::vslot_322` (`0x004c1c30`) is the only other override, everything
  else sharing a stub at `0x00934da0`.
- `GObjPC::FUN_004909f0` is a GM stat dump, and it carries a **second tag
  dispatcher** -- `0x687261` `hra`, `0x68707267` `hprg`, `0x6870` `hp`,
  `0x6872` `hr` are all visible in it. A cheap place to extend the param-code
  vocabulary next, since the extraction method is already written and validated.

**No srrevamp value changed.**

## The skill parameter vocabulary, all 102 codes (2026-09-15)

The previous entry's recorded next lever was a second tag dispatcher, to be
extracted with the method already validated on `Stat_ApplyTaggedModifier`. A
census first — every function in the server binary holding three or more
multi-char-literal equality tests — found eleven, and the largest is not the one
that was flagged:

| function | tags |
|---|---|
| `SkillGlobal::RefSkill_ParseParams` | **105** |
| `CGameServer::FUN_0072fd40` | 51 |
| `Stat_ApplyTaggedModifier` | 46 |
| `GObjPC::FUN_004909f0` | 33 |
| `FUN_00491bd0` | 29 |

`RefSkill_ParseParams` is the skill `Params` decoder, and this project had read
exactly four of its codes. All 102 that resolve are now in
**`docs/protocol/skill_params.md`**, each with the skill-struct field it fills
and how far the cursor moves.

**Validated before it was asked anything new**, the same discipline that licensed
the `Stat_ApplyTaggedModifier` extraction: `att` → field `0x230`, 6 words;
`defp` → `0x25c`, 4; `defr` → `0x260`, 3. Three of three against independently
recovered answers. The run length **includes the code word**, which is what makes
`att`'s six-word run carry the five values already in use —
`(type, percent, min, max, percent)`.

### A fabricated structural claim, caught before publishing

The first extraction reported fifteen codes as "run 1, 0 values". That is
self-contradictory: the parser points a field at values a one-word run cannot
contain. They take a different branch shape —

	cursor = cursor + 1;      // skip only the code word
	skill[field] = cursor;    // values follow, count NOT encoded

— so the "1" was the cursor advance past the code, not a run length. The three
controls all use the other shape, so they passed while fifteen rows were wrong;
a control set only proves the shape it exercises. They are now listed separately
with no length claimed.

### Deliberately not shipped

`hwit` (field `0x588`) is read by the skill-effect applier `FUN_00594ac0` and
written to ParamKeeper param **195**, which given the client's own
`PARAM_HWAN_TIME_INCREASE` is most likely the berserk-duration bonus —
`berserk.Duration` being srrevamp's one explicitly unrecovered value. It is not
the base duration, though: it is a modifier srrevamp has no consumer for, and
the identification's last step is an inference from a name rather than a
use-site. Recorded, not wired.

**No srrevamp value changed.** The artifact is a decoder: srrevamp reads one of
these 102 codes today, and the next skill system that needs a second one no
longer has to re-derive the format.

## The Param decoder, tested against 36,389 real rows (2026-09-15)

The previous entry recovered the skill Param schema but never ran it against
data. Doing so tests the format and the shipped parser at once.

**The block starts at column 69**, measured: the `att` code appears there in
30,677 rows and never earlier. Walking from 69 with the recovered run lengths,
**19,839 of 36,389 rows consume their Param block exactly to the end** — and
that is a real test of the schema, because one wrong run length derails the rest
of a row. 19,839 clean traversals are 19,839 independent confirmations of every
length they touched. The rest stop at a variable-length code, as expected; the
commonest is `efr`, on 9,534 skills.

The true code frequencies, counted only at verified code positions, are now in
`docs/protocol/skill_params.md`. `att` leads on 31,266 skills and `mc` (field
`0x288`, run 3) is second on 28,142 — structural rather than incidental, and
still unidentified.

### The shipped parser: a defect looked for, and disproved

`cmd/export-refdata`'s `attackParam` scans the WHOLE ROW for the literal
`6386804` rather than walking the block. That is a textbook way to read another
parameter's VALUE as a code, and this file already records the stat-tag literals
colliding with the opcode range once before. Tested three ways:

- the lowest column the literal ever occupies is 69, so **0 of 31,605** rows
  carry it before the block;
- **no row carries it twice**, so "first match" cannot pick the wrong one;
- on the 19,839 cleanly-walked rows the walk's `att` position and the scan's
  first match **agree 19,839 times and differ 0 times**.

So the scan is correct, and it is also the more version-robust of the two — a
client whose skilldata shifted the block would break a hard-coded column 69 and
would not break this. The comment now carries the measurement instead of an
assumption.

### Two more of my own probes were wrong, and only impossible output caught them

Worth recording because it is a pattern rather than an incident.

1. To find the block's start I scored candidate columns by "clean walks". The
   scorer treated a walk that stopped immediately on an empty cell as clean, so
   it reported column **68** with 2,475/4,000 — almost all of them empty-at-68.
   The census built on it returned **zero rows**, which is what exposed it.
2. The real start is 69, one column over, found by simply asking where the
   literal occurs.

The general shape: a metric that cannot distinguish success from
immediate-failure will report failure as success. Both this and the previous
entry's "run 1, 0 values" were caught by an output that was obviously impossible
— an empty census, a run that cannot hold the values it points at — rather than
by the controls, which passed in both cases.

**No srrevamp value changed.** A shipped one is now measured rather than assumed.

## `mc` is a skill's HIT COUNT — and a shipped defect it uncovered (2026-09-15)

The previous entry left `mc` as the most-used unknown in the skill format: field
`0x288`, a three-word run, on 28,142 of 36,389 skills. It is the number of times
one cast strikes.

**Settled by a use-site, not by the name.** `Combat_ResolveDamage` (`0058e5f0`):

	*(record + 5) = 1;                        // default
	piVar12 = *(int **)(skill + 0x288);       // the 'mc' values
	if (piVar12 && *piVar12 == 2)
	    *(record + 5) = (char)piVar12[1];     // mc overrides it
	if (*(record + 5) == '\0') Assert();      // 0 is a bug state
	...
	*(record + 6) = 0;                        // the iteration counter
	do { ... *(record + 6) += 1; ... }
	while (i < *(byte *)(record + 5));        // line 1162

A loop bound, a counter, and an assert against zero. The loop body spans lines
317–1162 and **contains the damage-kind switch and the mitigation calls**, so
each iteration is an independent blow — its own damage roll, its own critical
and block rolls. That is why it is a count and not a multiplier: multiplying one
blow would give a different distribution.

The real table: 24,368 skills strike once, 3,855 twice, 265 three times, 59 four
and 6 five. 35 carry `(2, 0)`, which would trip the engine's own assert.

**A wrong turn worth recording.** The byte `mc` writes is at `+5` of its record,
and the damage-kind switch reads `+5` of *another* record. I briefly had `mc`
selecting the damage kind — wrong, and it would have contradicted the earlier
finding that case 0 is the ordinary attack. `FUN_005a9f20`, which allocates the
switch's record, explicitly sets its `+5 = 0`, so the two are different objects
and **case 0 really is the default damage kind**. A claim I had started to doubt
came back stronger. Three distinct records in this one function carry a
meaningful `+5`; conflating them is the trap.

### The defect: SQL deployments were silently dropping skill damage

Wiring the hit count through exposed something worse. The exporter emitted a
skill's real `AttackPercent`/`DamageMin`/`DamageMax` and the CSV loader parsed
them — but the **skills table had no columns for them**, `ImportSkills` never
wrote them and `GetSkill` never read them back.

So on any SQL deployment — the production path, `-in-memory` being the option —
every skill silently lost its recovered damage and fell back to the disclosed
per-level stand-in. Nothing errored; the numbers were quietly wrong. This is the
same shape as the `TwoHanded` column that shipped as a false claim, and the same
lesson: a value is not shipped until something reads it back out of the store it
will actually live in.

### What moved

- `refdata.Skill.HitCount` and `HitsFor()`, exported from the `'mc'` parameter.
- `attack_percent`, `damage_min`, `damage_max`, `hit_count` added to the skills
  schema, the upsert and both selects.
- `performAttack` takes a hit count and resolves that many independent blows.
- A round-trip test that fails against the old schema, and boundary tests for
  `HitsFor`.

A two-hit skill now does roughly twice the damage it did, which is the
correction rather than a buff: it was doing one hit's worth all along.

## Auditing for the silent-drop defect, systematically (2026-09-15)

The previous entry found a skill's real damage being dropped by the SQL store —
exported, parsed out of the CSV, then discarded because the table had no column
for it. Nothing errored. It was found **by accident**, while editing nearby
code, which is the worst way to find a whole class of defect.

So this tick audited the class instead of the instance: a reflective
field-by-field round trip that fills every field of `refdata.Item` and
`refdata.Skill` with a distinct non-zero value, imports it, reads it back, and
names every field that changed.

**It found four more, and they were worse.** `RestoreHP`, `RestoreHPPct`,
`RestoreMP` and `RestoreMPPct` — the potion restore amounts, real since the item
table's self-labelling Param block was decoded — had no columns either. And
unlike the skill damage, which degraded quietly to a disclosed stand-in, this
one breaks a feature outright: `session/useitem.go` guards with

	if it.RestoreHP <= 0 && it.RestoreMP <= 0 && it.RestoreHPPct <= 0 && it.RestoreMPPct <= 0 {
	    return fail("that cannot be used")
	}

so on any SQL deployment — the production path, `-in-memory` being the option —
**every potion answered "that cannot be used"**. A player-visible break that no
test covered, because every test that exercised potions used the in-memory
store, which keeps the struct whole by construction.

### What the audit is, and why distinct values matter

Filling every field with `1` would pass while two adjacent columns were swapped.
The audit gives each field a distinct value, and floats a fractional one so a
column typed `INTEGER` where `DOUBLE PRECISION` was meant truncates and fails
rather than passing by luck.

A second guard covers the step before the database: `Item` has 40 fields and
exactly 40 CSV columns, `Skill` 28 and 28, and the parsers index positionally,
so a field added without a column is dropped between the exporter and the
importer just as silently. The counts are now asserted equal.

### What moved

- `restore_hp`, `restore_hp_pct`, `restore_mp`, `restore_mp_pct` added to the
  items schema, the upsert and both selects. Potions work again on SQL.
- `roundtrip_test.go`: the field-by-field audit for both types, plus the CSV
  column-count guard. Both fail against the old schema.

### The lesson, stated so it is not re-learned

A value is not shipped when it is recovered, nor when it is exported. It is
shipped when something reads it back out of the store it will actually live in.
Three values had passed the first two gates and failed the third; two of them
for long enough to reach a tagged release.

## itemdata 114 and 117 are the variance ceilings — a withdrawal reversed (2026-09-15)

First, the audit from the previous entry was finished: `MonsterDrop` and
`DropGroupEntry` round-trip cleanly, and the character store's SELECT covers all
twelve `Character` fields. `Item` and `Skill` were the only leaks, and both are
fixed. The class is closed.

Then the open item this file has carried longest: columns 114 and 117, which
`export-refdata` emitted as literal `"0"` under a note saying they were
"something else, not yet identified".

**They are attack rate's and critical's per-instance variance ceilings**, and the
argument that withdrew them was wrong in its premise rather than its care.

That argument ran: a real max would display as a range the way physical attack
does (`"27 ~ 28"`), but the verified Copper Sword tooltip shows "Attack rate 24"
and "Critical 3" — single values. True, and it does not follow. Physical attack
displays as a range because its min and max are **two different stats**, at cols
95 and 97, each with its own `(lo, hi)` pair beside it. Attack rate is **one
stat**, and the column beside it is that stat's variance — so an instance has a
single value and shows a single number. The tooltip never discriminated between
the two readings.

**The engine settles it.** `FUN_00495d60` computes every item stat as
`lo + t*(hi-lo) + inc*plus` from a `(lo, hi, inc)` triple at consecutive
ref-object dwords. Two of those triples are

	(0x288, 0x28c, 0x290) -> item +0x1d8
	(0x294, 0x298, 0x29c) -> item +0x1dc

and `Char_PublishCombatStats` publishes item `+0x1d8` as ParamKeeper param 11
(`'hra'`, attack rate) and `+0x1dc` as param 12 (`'cri'`, critical). So each of
them *is* a lo/hi pair, and the tooltip value is the lo — which is what the
project already reads from cols 113 and 116.

**The data confirms the engine's own precondition.** `FUN_00495d60` asserts that
`lo > hi` cannot happen. Across all 1,568 rows carrying the block:

| pair | inversions | equal |
|---|---|---|
| col 113 vs 114 | **0** | 0 |
| col 116 vs 117 | **0** | 448 |

Zero inversions in either. Equality is permitted by the assert, which fires only
on `lo > hi`. Two unrelated stats sitting side by side would invert somewhere in
1,568 rows.

### What moved

`HitRateMax` and `CriticalMax` are exported again, from cols 114 and 117, and
`fMax` rises to 117 to match the highest column now read. The test that pinned
the zeros now pins the real values and asserts the floor never exceeds the
ceiling. `refdata.Item`'s "which end does srrevamp use" note carried the same
false claim — that the Max field "is not the same stat" — and is corrected.

Nothing changes how a blow is rolled: `attackerCritical` still takes
`CriticalMin`, and that is now visibly a **choice of end** rather than a
consequence of the other end being a different stat.

## Joining the two skill vocabularies: code → the stat it modifies (2026-09-15)

`docs/protocol/skill_params.md` had 102 codes and where each files its values,
but nothing about meaning — and the spec said so explicitly, warning that the
names are suggestive and a name is not a use-site. This closes half of that gap
mechanically rather than one code at a time.

`FUN_00594ac0`, the skill-effect applier, reads the same skill-struct fields the
parser fills and publishes ParamKeeper params from them. Extracting
field → `param@slot` and joining on the field gives **code → the stat it
modifies**, for 22 of the 102.

**Validated before the join was read**, against three pairs recovered
independently and long before:

| control | expected | extracted |
|---|---|---|
| `defp` | params 5/6 at slot 0, the flat absorb | `5@0, 6@0` |
| `defr` | params 5/6 at slot 1, a percentage on it | `5@1, 6@1` |
| `hwit` | param 195 | `195@0` |

Three of three, and the `defp`/`defr` slot difference is exactly the distinction
this file recorded when `playerMitigationPercent` was settled as a real zero —
one writes the flat term, the other a percentage boost to it.

The four that matter most, because they touch params already modelled:

- **`apau`** adds a flat amount to params 13–16, **`apru`** a percentage to the
  same four. Those are the physical and magical damage min/max — the params a
  weapon's range and the Strength-derived reinforce term already land in. A buff
  of either kind stacks into the same slot-0 sum or slot-1 percentage the damage
  pipeline reads, so the buff design is already determined by shipped work.
- **`stri`** publishes param 1, Strength itself.
- **`irgc`** publishes 25/26 at slot 1 — `'hprg'`/`'mprg'`, health and mana
  regeneration.

Only 22 codes publish a param. The other 80 act elsewhere — teleports, summons,
cures, state flags — and each needs its own field followed into whatever
consumes it. The join is not a shortcut around that; it is the subset where the
shortcut exists.

**Nothing wired, deliberately.** srrevamp has no buff system, and a value with
no consumer is the pattern this file keeps correcting. The table is recorded so
that a buff system, when it exists, starts from the game's own vocabulary.

**No srrevamp value changed.**

### A process note, because it is the second occurrence

The commit that added the spec section went out without this entry: the heredoc
writing it ran from `server/`, where `docs/RE_COMPLETION.md` does not exist, so
the redirect failed while the `git commit` in the same command list succeeded.
That is exactly the failure from two entries ago, repeated. `&&` between a
redirect and a commit does not couple them — the redirect's failure is reported
by the shell and the commit runs anyway. Write the ledger from the repo root, or
check `git show --stat` before pushing.

## Attack rate and parry are DEAD params (2026-09-15)

`combat.MitigateDamage` floors a blow at 1 rather than the game's 0, and the
note explaining why said: a zero-damage hit is a miss in the real game, and
srrevamp "has no hit/evade roll yet (the `'hra'`/`'era'` params exist and are
unimplemented)". That reads as a gap waiting to be filled, and it is the kind of
claim this file exists to check.

**There is no roll to implement.** Params 9 (`'era'`, parry rate) and 11
(`'hra'`, attack rate) are published from four different places —
`Char_PublishCombatStats` from the equipped item's aggregate,
`GObjMob_PublishStats` from characterdata, `GObjPC_InitStats` with a base of
10.0 (`.rdata 0x00b45b44`), and the skill codes `er`/`terd`/`thrd` — and then
read by **nothing**.

### How the negative was made safe

A literal-argument census is exactly the probe that has produced four false
negatives in this project, so it was not trusted on its own. Every `GetParam`
call site in the binary was enumerated, literal and computed:

- **Literal ids present:** 1–8, 10, 12, 23, 24, 27–32, 56, 57, 140–150, 169,
  172, 173, 178–181, 184, 187–193, 259. Neither 9 nor 11.
- **Computed ids**, each resolved rather than waved at: `FUN_0040db50` reads
  `(edi != 0) + 0xd` → 13/14; `FUN_0040dc10` reads `(edi != 0) + 0xf` → 15/16;
  `Formula_MitigatePhysicalDamage` and its twin read 0x80/0x81; `FUN_0040ebe0`
  and `FUN_0040eef0` read 0x80/0x81 and 0x82/0x83. None is 9 or 11.
- The remaining ~100 non-literal hits are a three-argument call on a
  **different class's** vtable slot `0x104`, in quest code — not GetParam.

That 13/14 are also absent from the literal list is what makes the census
trustworthy here: the probe demonstrably misses computed reads, which is why
every computed read was resolved before the absence was believed.

### What the engine rolls instead

`Combat_ResolveDamage` reads exactly four combat params through GetParam: 12
(`'cri'`) and 10 (`'bri'`) off the attacker and defender, opposed by 57
(`'evcr'`) and 56 (`'evbl'`). Blocking and critical — and nothing else. **A
swing is resolved as blocked or not, never as a miss.**

Both are already modelled here, and both are correctly unopposed against
monsters: `GObjMob_PublishStats` publishes params 0, 3–12, 23, 24, 27–33 and
140, so neither 56 nor 57 exists on a monster. That was already recorded for
`'evcr'` when criticals were shipped; it holds for `'evbl'` for the same reason.

### What moved

Nothing numeric. The floor stays 1 and stays own design — but its justification
changes from "a mechanic we have not built yet" to "a mechanic the game does not
have", which is the difference between a gap and a decision. `MitigateDamage`'s
comment carries the enumeration.

This also closes the last open question about the `'hra'`/`'era'` pair, which
this file has carried since the tag vocabulary was first read: they are real
columns, really published, and vestigial in this build.

## The damage pipeline is complete for an unbuffed character (2026-09-15)

The previous entry's enumeration of every `GetParam` call produced a by-product
worth acting on: the exact set of params the engine reads. Intersecting that
with what srrevamp models leaves the terms the damage pipeline applies and this
project omits — params **128–131, 178, 180, 187, 188, 189 and 259**, each a
multiplier or addend on every blow. If any is non-zero by default, srrevamp's
damage is wrong.

**None of them is written by any baseline publisher.** The three functions that
establish a character's stats write only these ids:

| function | params written |
|---|---|
| `Char_PublishCombatStats` | 0x5–0x10, 0x17/0x18, 0x21–0x25, 0x3a, 0x8d, 0xbe–0xc1 |
| `GObjMob_PublishStats` | 0x0, 0x3–0xc, 0x17/0x18, 0x1b–0x21, 0x8c |
| `GObjPC_InitStats` | 0x0–0x2, 0x9, 0xb, 0x17/0x18, 0x21–0x25, 0x34–0x3c, 0x8c/0x8d, 0xc2–0xc8 |

Not one of 0x80–0x83, 0xb2, 0xb4, 0xbb, 0xbc or 0x103 appears. Their writers are
`Stat_ApplyTaggedModifier` (the item/skill tag path), `FUN_00594ac0` (the
skill-effect applier) and `FUN_005830b0` — all modifier paths. 180 and 259 have
**no writer at all**.

So for a character with no buffs and no tagged item modifiers — which is every
character srrevamp has — all of those terms evaluate to zero, and **the damage
pipeline here is complete rather than approximate**. That is a closure, not a
new value: nothing changes, and now it is known that nothing should.

### An error caught mid-tick, and the trap that caused it

Param 189 (the berserk bonus) is the exception, and I nearly filed it wrongly.
The census showed its only writer is `CGObjCOS_Summoned::SetBodyMode`, which
reads as "a summon's function, so a player's 189 is always zero, so berserk is
exactly x2". That is wrong.

`0x004a9fc0` is **vtable slot 198 across seventeen classes**, `CGObjChar` among
them, and the binary's own base-class assert names it **`IGObj::SetBodyMode`**.
The dump indexes a shared implementation under a single derived class — whichever
the RTTI walk reached — and reading that label as the owner is a mistake that
will recur, because most of this binary's shared virtuals are indexed the same
way. **The RTTI line, not the function name, says which classes reach it.**

A player therefore can carry param 189, and the existing account was already
right: `SetBodyMode`'s fifth argument grants a base of 0.3, every call site bar
one passes 0, so 2.0 is the plain multiplier and 2.3 the special case.

### Also corrected

`berserk.go` called `0x004a9fc0` "CGObjChar::SetBerserk". That name was this
project's invention; the binary calls it `SetBodyMode`, and berserk is one body
mode rather than the whole function. Renamed in the citation, with the reason.

**No srrevamp value changed.**

## A naming defect measured, not just noticed (2026-09-15)

The previous entry caught one mislabel by accident: `0x004a9fc0` is indexed as
`CGObjCOS_Summoned::SetBodyMode`, but it is vtable slot 198 shared by seventeen
classes including `CGObjChar`, so reading the label as the owner made a player's
param 189 look unreachable. The question that leaves is how many more there are.

**48 in the server, 69 in the client.** Measured by
`client/tools/ghidra/mislabelled_owners.py`, which needs no Ghidra — the dump's
own headers carry both `RTTI: reached as A slot N, B slot N, …` and
`RTTI hierarchy: Derived : … : Base`, so a name that credits a class deriving
from another class in the same list is provably crediting a descendant of the
real owner.

The two populations differ in how much they matter:

- The server's **48 of 331** include real names —
  `CGObjCOS_Summoned::EnterWorld`, `::ConsumeHpMp`, `::GetCharName`,
  `::GetGender` are all shared `CGObjChar` implementations. Those are exactly
  the functions a dig into player logic would want, and its author would grep
  past them.
- The client's **69 of 93** are a worse *rate* but a milder defect: nearly all
  are a run of unnamed `CCompChar::FUN_*` methods that belong to
  `CCompoundObj`. A wrong namespace on an unnamed function costs attribution,
  not identity.

### Why this is not a rename

The most ancestral class in the RTTI list is a **lower bound** on the owner, not
the answer. `SetBodyMode` reaches `CGObjChar` in its list, while its own assert
names `IGObj` as the declaring class — so renaming to `CGObjChar::` would swap
one inaccuracy for a smaller one. The detector says "this name is wrong"; only
an assert string says what the name should be. Renaming 48 functions on that
basis, in a write pass that would take the project lock and could not be
validated in the same tick, is not worth it.

What ships is the measurement and the rule, so the next naming pass can apply it
and any reader can re-run it.

### The parsing traps, recorded because they cost the first two attempts

The first run reported **906**. Two flaws, both of which inflate:

1. The class is the component **before the method**. `std::bad_alloc::vslot_000`
   is class `bad_alloc`; taking the first `::` component makes it `std`, which
   then "derives" from everything.
2. A function whose RTTI lists **one** class cannot have this defect, and those
   rows are pure noise.

48 against 906 is a nineteen-fold difference between a measurement and an
artifact, and the only thing that exposed it was the output being obviously
wrong — `std::bad_alloc` is not a mislabelled game function. That is the same
shape as the last three probe failures in this file: the control passes, the
scale is absurd, and the absurdity is what catches it.

**No srrevamp value changed.**

## The drop path: wrong blocker, real gap (2026-09-15)

`combat.LootTables` is own design, and its note said why: the real drop tables
key by a numeric RefMonsterID "this project doesn't have a confirmed name->ID
mapping to". Chasing that mapping is what this tick set out to do, and it took
one lookup — **characterdata col 1 is the RefObjChar id and col 2 the code
name**, exactly the id/code-name pair this project already reads out of
itemdata. `MOB_CH_MANGNYANG` is **1933**.

So the stated blocker was never the blocker.

**The real one:** the drop tables are server-side DATABASE tables and are not in
the client archives at all. Media.pk2's `server_dep\silkroad\textdata` listing
carries characterdata, leveldata, levelgold, hwanleveldata, the
refabilitybyitemopt family and the rest — and no drop or rnd-drop table of any
kind. `_RefMonster_AssignedItemRndDrop` and `_RefDropItemGroup` live in the
server package's SQL, which this project does not have. Own design stays, for a
reason that is now the true one.

### The real gap, found while checking: the importer had no way in

`refdata` has had `LoadMonsterDropsCSV`, `LoadDropGroupEntriesCSV`,
`ImportMonsterDrops` and `ImportDropGroupEntries` since the schemas were
curated. **`cmd/import-refdata` exposed none of them.** An operator holding the
real tables — the exact situation the "bring your own data" model exists for —
had no way to load them.

Every piece had its own test and passed. The chain had a missing link in the one
place nothing tested, which is the same shape as the SQL columns that silently
dropped a skill's damage and every potion's restore amount. **A capability is not
shipped until something exercises it end to end.**

**What moved:** `-drops-csv` and `-drop-groups-csv` on `import-refdata`, and a
test that walks CSV text -> loader -> store -> read-back for both tables, keyed
on 1933 so the mapping above is exercised rather than just asserted.

### A dead end, recorded so it is not re-walked

`hwanleveldata.txt` looked like the place to ground `berserk.Duration`, which is
srrevamp's one openly unrecovered value, and to settle param 189 (the berserk
damage bonus — the only term the game applies to a blow that this project omits
and cannot prove is zero). It is neither. 257 rows of four columns, and the
columns are display keys: `UIO_SECOND_HWAN_CH_NAME_LEVEL_1` and so on. It names
hwan levels for the UI and carries no duration, no bonus, no number at all.

## A survey of what the client actually ships (2026-09-15)

The previous entry established that the drop tables are not in the client at
all. That raised the obvious question: what IS there, and how much of it is this
project leaving on the floor?

**The client's `server_dep\silkroad\textdata` holds 136 distinct tables. The
code opens 22 of them.**

	characterdata  itemdata  skilldata  leveldata  levelgold  npcpos  npcchat
	refshopgoods  refshopgroup  refshoptab  refmappingshopgroup
	refmappingshopwithtab  refscrapofpackageitem  regioninfo  skilleffect
	skillgroup  skillmasterydata  textdata_object  textquest_speechname
	textuisystem  worldmap_mapinfo  worldmapguidedata

The 114 untouched ones are the grounding roadmap. The substantial ones, by what
they would ground: `questdata` and `questcontentsdata` (quest.Catalog is own
design), `magicoption` and `magicoptionassign` (item blues, unmodelled),
`teleportdata`/`teleportlink`/`teleportbuilding`, `refsetitemgroup`,
`learnableskill`/`learnablemastery`, `erasableskill`/`erasablemastery` (the
skill-reset path whose 80% refund was recovered two entries ago),
`refpricepolicyofitem`, and the siege family.

**How the count was got right.** The first pass grepped each table's basename
across `.go`, `.gd` and `.md` and reported 96 of 136 "used" — nonsense, because
`refdata_schema.md` *lists* table names and because "aaa" matches almost any
file. Matching `[a-z_0-9&]+\.txt` literals in code only gives 22, which is
checkable by eye against what the readers actually open.

### The mastery table confirms a measured column map

`skillmasterydata.txt` is unusual: it **ships a header row naming every
column**. That is worth knowing because this project already derived its layout
by measurement on 2026-09-11, and the header agrees on all six constants —
`Mastery ID`→0, `MasteryNameCode`→2, `Tab Name Code`→5, `Type (TabID)`→6,
`Weapon Type 1`→8, `Mastery Icon`→11. An independent confirmation of shipped
work, at no cost.

Its 13 real masteries, for the record — the id, the UI name code, the tab, and
the weapon `TypeID4`s each trains:

| id | name code | tab | weapons |
|---|---|---|---|
| 257 | `UIIT_STT_MASTERY_VI` | Weapon | 2, 3 (sword, blade) |
| 258 | `UIIT_STT_MASTERY_HEUK` | Weapon | 4, 5 (spear, glaive) |
| 259 | `UIIT_STT_MASTERY_PA` | Weapon | 6 (bow) |
| 273–276 | `HAN`, `PUNG`, `HWA`, `GI` | Force | — |
| 513, 515 | `WARRIOR`, `ROG` | EU physical | 7/8/9, 11/12 |
| 514, 516 | `WIZARD`, `WARLOCK` | EU magical | 11, 10 |
| 517, 518 | `BARD`, `CLERIC` | EU assist | 14, 10 |

### Corrected

`client/scripts/npc/mastery_reader.gd` said the project has neither a mastery's
trained level nor a skill point total, "so the skill window shows the masteries
at level 0 and says so". Both are tracked now — `skill.Store.MasteryLevels` and
`SkillPoints`, carried by `OpSkillState`, raised through `OpRaiseMastery` — and
`hud_panels.gd` already renders the real SP and the mastery total against the
3-per-level cap. The comment described a window that no longer exists.

**No srrevamp value changed.**

## What the quest epic actually faces (2026-09-15)

`quest.Catalog` is own design and is the largest invented surface left with real
data present in the client, so the roadmap from the previous entry points here
first. This is reconnaissance, not a value: what follows is the shape of the
problem, measured.

### The tables

- **`questdata.txt` — 696 quests.** The registry: a numeric id, a code name
  (`QNO_CH_SMITH_1`), and the `SN_*` string codes for the quest's name, its
  reward text and its conditions. **No objectives, no rewards.**
- **`questcontentsdata.txt` — 989 rows × 17.** Descriptions and `SN_CON_` string
  codes. Also no objectives; most columns are the literal `xxx` placeholder.
- **`refqusetreward.txt` — 709 rows × 26** (the game's own filename carries the
  typo). Keyed by the same quest code name, with numeric columns at 10 and 11
  carrying values like 205/270, 475/375, 1000/2752.
- **`refquestrewarditems.txt` — 366 rows.** Quest code name → item code name and
  a quantity, several rows per quest where a choice is offered.

So **quest rewards are fully available as client data**; quest objectives are
not in any client table.

**Deliberately not named:** which of columns 10 and 11 is experience and which is
gold. The magnitudes are suggestive and that is exactly the evidence this file
does not accept — characterdata col 79 was wrong twice on a suggestive curve.
A use-site settles it, and none has been read.

### "Quests are compiled code" is false, and worth measuring before believing

The server carries 177 bespoke quest classes — `CQNO_*`, `CQSP_*`,
`CQTUTORIAL*`, `CQEVENT_*` — which invites the conclusion that quest logic is
hand-written C++ and therefore ungroundable. Matching them against the registry
(after stripping the leading `C`, which the class names carry and the table's
code names do not) gives:

| | count |
|---|---|
| quests in `questdata.txt` | 696 |
| bespoke quest classes | 177 |
| registry names WITH a class | **154** |
| registry names WITHOUT one | **542** |

**78% of quests have no bespoke class**, so they run on the generic engine this
file already has anchors for — `CRefQuest`, `CBasicQuest`, and the `sQuestContents`
objective struct. The blocker is locating that engine's objective source, not
transcribing 700 C++ classes.

### Where this leaves srrevamp

Its quests are own design with invented names, so nothing keys to the real
tables today. Adopting the real code names is the step that unlocks rewards
wholesale — 709 reward rows and 366 reward-item rows arrive keyed by a name the
registry already supplies. That is an epic, not a tick, and it now starts from
measurements rather than from the assumption that quests are code.

**No srrevamp value changed.**

## Quest rewards: structure found, the column question still refused (2026-09-15)

The previous entry left one bounded question: which of `refqusetreward`'s columns
10 and 11 is experience and which is gold. It is still unanswered, and this
records the path so the next attempt does not restart from the table.

**What was established:**

- `CRefQuestReward : CDBRecStream : CDBRecord : CBase`. It is a DB-record class,
  and `FUN_0083a640` registers `_RefQuestReward` as its SQL table name.
- **The `_CHAR` lever does not apply here.** `CharData_BindDBColumns` named 38
  character columns because it binds each one by name (`FUN_00401fc0(name,len)`
  then an offset). `FUN_0083a640` calls that once — for the table name — and
  binds no columns at all. The text row reaches the struct positionally through
  `CDBRecStream`, so the name→offset trick that worked for `_CHAR` has nothing
  to read.
- **`FUN_009287c0` is the reward payer.** It looks the record up by quest id
  (`FUN_0051cd30`), asserts `"Can not find QuestRewardData : QuestID [%d]"` when
  it is missing, and copies the record's `+8`, `+0xc`, `+0x10`, `+0x14`, `+0x18`
  dwords and `+4`, `+5`, `+0x38`, `+0x39` bytes into a queued reward object. The
  field from record `+0x14` is later accumulated across entries.
- The reward is **queued rather than paid inline**, so the experience and gold
  calls are in a different function, and following them is where the next
  attempt should start.

**What was not established, and is therefore not written down:** the identity of
columns 10 and 11. The magnitudes (205/270, 475/375, 1000/2752) read like exp
and gold, and two independent structures now sit either side of the gap — the
CSV columns on one side, the struct offsets on the other — without a mapping
between them. Guessing the join is exactly the move that made characterdata col
79 wrong twice.

A thin tick, honestly. The structure is worth having; the answer is not in it
yet.

**No srrevamp value changed.**

## Correcting my own exp enumeration (2026-09-15)

The previous entry said the reward is queued and the exp call is elsewhere, and
pointed at eight `CQNO_*::vslot_103` functions that an earlier entry had listed
among the binary's positive experience grants. Following them shows that list
was wrong.

**All eight are `IQuest` virtuals, not experience grants.** Each is
`__thiscall Foo::vslot_103(Foo *param_1, …)` calling
`(**(code **)(*param_1 + 0x170))(…)` — a call on `this`, and `this` is a quest:
`CQNO_RM_OLDWOMAN_6 : CBasicQuest : CQuestBase : IQuest`. Slot `0x170` is
`GObjPC_GainExpAndLevel` on a **character**; on a quest it is something else
entirely. The earlier census matched the offset across the dump without checking
what the receiver was.

**The load-bearing conclusion survives, because it never rested on that census.**
"No PvE experience reward exists in this binary" was established from
`charData+0x68` having exactly one writer — `GObjPC_GainExpAndLevel` — with the
only other function touching the field being a GM stat dump that formats it into
a string. That probe is independent of the call-site list and is unaffected. What
was wrong is the supporting enumeration's quest entries, not the finding.

**A sharper open question falls out of it.** Quests demonstrably pay experience —
`refqusetreward` carries 709 rows of reward values. If quest classes do not call
`GainExpAndLevel`, and `GObjPC_GiveExp`'s only three callers are the PC-death
handlers, then quest rewards reach the character through the queued-reward object
`FUN_009287c0` builds, and a central payer drains that queue. Finding that payer
answers both this and the column question the previous two entries left open.

### The rule, now written down where it will be read

Three separate wrong results in this project have the same cause: a vtable-slot
census that did not resolve the receiver's class.

| slot | on a character | elsewhere |
|---|---|---|
| `0x104` | `GetParam` | a three-argument virtual on quest classes |
| `0x318` | `SetBodyMode`, shared by 17 classes | indexed under one derived class |
| `0x170` | `GObjPC_GainExpAndLevel` | an `IQuest` virtual |

`client/tools/ghidra/README.md` now carries the check, strongest evidence first:
the receiver expression (a `__thiscall` on `param_1` is `this`), then the dump's
own `RTTI hierarchy:` line, and only last the enclosing namespace — which is
weak, because a `GObjPC` function may call a slot on a char it was handed, and a
shared virtual is indexed under just one of its classes.

**No srrevamp value changed.**

## Respawn is 40%, not full (2026-09-15)

Three ticks had gone into the quest-reward column question without converging,
on a table srrevamp does not read. Dropped it and audited the thing the tick
brief actually asks for instead: every value srrevamp uses, grounded or disclosed
with a proven reason. 263 constants, mostly opcodes and schema strings; the
gameplay numbers are a much shorter list, and `mana`'s comment pointed at a real
gap — "the real game has an `'mprg'` parameter … but its value has not been
recovered".

**Half of that is now settled, negatively.** Params 25/26 (`'hprg'`/`'mprg'`) are
written by no baseline publisher — not `GObjPC_InitStats`, not
`Char_PublishCombatStats`, not `GObjMob_PublishStats` — so they are zero without
a buff, exactly like the damage-pipeline terms. Baseline regeneration is not
param-driven, and looking for an `'mprg'` default is looking for something that
does not exist.

Following the HP/MP pair to its other readers found something better.

### The recovery

`CGObjPC::vslot_212` — the PC create/load path, identifiable by its own error
string `"CheckEquipsetIntegrity() failed while Creating PC (CharID : %d)"` —
calls `GObjPC::FUN_004e1120`, which restores a character whose **stored** pool is
zero, which is the state a death leaves it in:

	if (charData->vf[0x38]() == 0) {       // stored HP is zero
	    hp = GetParam(3) * _DAT_00b460f0;   // MaxHP * 0.4
	    charData->vf[0x40](hp);
	}
	if (charData->vf[0x3c]() == 0) {       // and the same for MP
	    mp = GetParam(4) * _DAT_00b460f0;
	    charData->vf[0x44](mp);
	}

**`FMUL QWORD PTR ds:0xb460f0`** at `0x004e1141` and `0x004e1190` — a QWORD, so
the double **0.4**. At float width that address reads `-1.08e-19`, which would
bring every character back on a negative sliver of health; only the double is
coherent. Operand size has now decided four constants in this project.

**It does not apply to a level-up.** Nothing in the level path zeroes the stored
pool, so the branch never fires there and a level-up heals to full. That is why
the two are separate calls rather than one shared helper.

### What moved

`character.RespawnFraction = 0.4`, `Store.RespawnHP` on both stores, and
`character.RespawnMP`. The death path in `session/combat.go` uses them; the
level-up path still calls `ResetHP` for the full heal. Dying now costs 60% of
the pool on the way back, where it used to cost nothing.

Tests pin the fraction, pin that a level-up still heals fully, and pin that the
SQL and in-memory stores agree — the same recovered rule, so a deployment
swapping one for the other must not change what a death costs.

## The mastery caps, and a number that was never this binary's (2026-09-15)

Continuing the constant audit that found the 40% respawn. `MasteryTotalCapPerLevel`
stood out because its citation was an account of retail rather than the binary,
and mastery raising is a shipped feature. `Mastery_LevelUp` (`0059c4e0`) carries
three rules, and only one of them was already in this project.

**Per-mastery, the character's own level — now grounded.** The function compares
`Char_GetLevel()` against the mastery's current level plus the levels requested
and answers error `0x3804` when the character is lower. srrevamp already
enforced this; it was asserted, and now it is cited.

**Per-mastery, a hard 120.** The cost loop refuses to go past it:

	do {
	    if (0x78 < uVar4) break;          // 0x78 = 120
	    entry = RefLevel_GetEntry();
	    cost += entry[0x10];              // leveldata column 2, already grounded
	    uVar4++;
	} while (uVar4 < current + requested);

srrevamp had no such ceiling. leveldata runs to **140**, so a character can
outgrow 120 and the cap binds rather than being theoretical. Shipped as
`MasteryLevelCap`, applied as the lower of it and the character's level.

**The total cap is a FLAT 330, not a per-level rule.** On the branch where the
ref object's `+0x88` is zero, it refuses when `current + requested >= 0x14b`,
with no reference to the character's level at all.

### Why that did not change anything

srrevamp caps the total at 3 x the character's level. The binary caps it at 330
flat. Those are different shapes, and it is worth being explicit about why the
sourced rule survives the encounter:

- **A tempting reconciliation was checked and failed.** 330 = 3 x 110, which
  would make the flat cap "3 per level evaluated at the level cap" and confirm
  srrevamp's rule outright. But leveldata runs to 140, not 110, and no level cap
  this project can find is 110. The neat story does not hold, so it is not told.
- This is a **modded private-server binary**; the per-level rule comes from an
  account of **retail**. Adopting a flat 330 on that basis would trade a sourced
  rule for a modded constant.

**A number was also dropped.** The comment said "the pserver's 440 is a mod".
Whatever 440 was, it is not what this binary enforces — 330 is — and a wrong
number in a citation is worse than no number, so it is gone.

### What moved

`session.MasteryLevelCap = 120`, wired into the raise handler and tested at the
boundary (level 120 binds at 120, level 121 and level 140 both bind at 120).
`MasteryTotalCapPerLevel` is unchanged, with the shape difference recorded
against it rather than silently reconciled.

## Five orbs are five real charges (2026-09-15)

Third pass of the constant audit. The berserk gauge was the largest remaining
cluster of own-design numbers with a live consumer — the HUD orbs and the R key —
and one of the four turns out to be the game's.

**`Orbs = 5` is recovered.** `_CHAR.RemainHwanCount` is a persisted count at
`charData+0x86`, from the schema `CharData_BindDBColumns` spells out, and
`CUsedItemLimit::FUN_004a05b0` refuses an item when it has reached five:

	return (-(uint)(*(char *)(charData + 0x86) != '\x05') & 0xffffe7c3) + 0x183e;

A branchless ternary, and worth evaluating rather than eyeballing: not-5 gives
**1** (allowed), 5 gives **0x183e** (refused). A use-limit that refuses at
exactly five is a cap of five, so the five pips the client draws are five real
charges rather than a display choice.

**The shape around it is still ours, and the engine's is different.** The game
persists a COUNT that an item can raise and a berserk presumably spends; this
project fills a 0..100 gauge from combat. Those are different mechanics that
agree on the number five. Nothing found so far says how the real count is
earned, so `FillPerHit` stays own design rather than being dressed up as a fill
rate for a gauge the game does not have — and the test deliberately pins only
`Orbs`, because asserting an invented number makes it harder to replace later.

### Two audited and closed as unrecoverable

- **`inventory.SlotsPerCharacter`.** `_CHAR.InventorySize` is real and
  per-character, but nothing in the binary writes `charData+0xac` — the eight
  apparent hits are offset collisions on unrelated structs. Character creation
  is DB-side here, the same finding this project already reached for starting
  Str/Int, so a new character's default slot count is a database default and not
  in this executable.
- **`mana`'s regeneration rate**, half-settled. Its comment hoped for an
  `'mprg'` default; params 25 and 26 are written by no baseline publisher
  (`InitStats`, `Char_PublishCombatStats`, `GObjMob_PublishStats` write none of
  them), so they are zero without a buff and baseline regeneration is not
  param-driven at all. What ticks it is still unfound; the number stays own
  design, but the search for an `'mprg'` default can stop.

**What moved:** `berserk.Orbs`'s citation, from a display assumption to the cap
the engine enforces, with the shape difference recorded beside it.

## Two constants closed as unrecoverable, and one coincidence declined (2026-09-15)

Fourth pass of the constant audit. Both candidates this time end as disclosures
rather than groundings — which is the honest result, and in one case only
because a very plausible number was turned down.

### `party.MaxSize`: the 8 is in the wrong module

Party membership is a **linked list with no fixed bound** —
`CGObjPC::FUN_005bdd70` walks it to fill the party-info packet — so the cap is
enforced at join time and is not visible in the structure.

The party module's neighbourhood does contain two loops bounded at **8**, over
an array at `[x+4] + 0x1c + i*4`: one a membership test, one a broadcast. Eight
is exactly the party size Silkroad is usually said to have, and taking it would
have been easy.

It is declined. Both loops sit in `CMainProcess` functions that call
**`CGuild__BroadcastToLocalMember`**, in a shard ending at `0x5b9370` — *before*
the `CParty` code, which starts at `0x5bb300`. A Silkroad guild alliance holds
eight guilds, and an eight-slot array in guild-broadcast code is far more likely
that than a party roster. **A loop bound that lands on the expected number in
the wrong module is a coincidence, not a citation** — this is the same shape as
characterdata col 79, which was wrong twice for looking right.

### `character.MaxPerAccount`: not in this binary, and neither is its category

`SR_GameServer.exe` has no character-creation path at all — no limit string, no
count check. It cannot have one: creation happens on the AgentServer and in the
database.

That closes a **category** rather than a value, and the category is already
half-documented in this file:

| value | why it is not here |
|---|---|
| starting Str/Int | nothing writes `charData+0x74`/`+0x76` anywhere |
| default `InventorySize` | nothing writes `charData+0xac` (the hits are offset collisions) |
| `MaxPerAccount` | no creation path, no limit string |

Anything decided when a character is first made is outside this executable. Worth
stating once so the next audit does not spend a tick rediscovering it per value.

**What moved:** nothing numeric. Both constants keep their values and gain the
reason they cannot be grounded, which is what the brief asks for when a value
cannot be cited.

## The HP/MP write pipeline, and why potions need no modifier (2026-09-15)

Chasing `mana`'s still-ungrounded regeneration rate from the other end: instead
of looking for a tick, enumerate everything in the binary that can change a
character's pool. `charData`'s setters are virtuals at `vf[0x40]` (HP) and
`vf[0x44]` (MP), and they have **two callers each**, which makes the whole
pipeline small enough to map:

	GObjChar::FUN_004a66f0 / FUN_004a6790   the setters themselves
	GObjPC::FUN_004a87d0                   the generic adjust -- reads current
	                                       via vf[0x108]/[0x10c] and max via
	                                       vf[0x110]/[0x114], then writes
	GObjPC::FUN_004a86a0                   the RECOVERY path, scaling first
	CGObjChar::vslot_317 / vslot_318       effect application
	GObjPC::FUN_004e1120                   the load/respawn restore (the 40%)

**Passive regeneration is not on this list**, so it is still unlocated — but the
recovery path yielded something better than the number I went looking for.

### Potions: an unmodified heal, confirmed

`FUN_004a86a0` does not hand a recovery straight to the pool. It scales the HP
amount by ParamKeeper param **143** and the MP amount by **144** — `MOV EAX,0x8f`
and `MOV EAX,0x90` into `EvaluateParam`, both against the character's own keeper
at `+0x1ec` — before passing them on.

**Both params are structurally zero.** Neither has a `SetParam` site anywhere in
the binary, and neither is the target of a derived bind. So a
recovery-effectiveness stat exists in the engine and nothing in this build ever
grants one, which means the raw restore amount is what lands — exactly what
`session/useitem.go` already does.

That is a confirmation of a shipped value rather than a change, and it is the
third time this session that enumerating a param's writers has turned "srrevamp
omits a term" into "the term is provably zero" (after the damage-pipeline
multipliers and the death-penalty reduction).

**The probe was controlled.** A "no writers" result from the same search that
produced four false negatives earlier in this project is worth nothing on its
own, so it was run against param `0x22` — the weapon reinforce, known to be
written — and found it in two shards. The absence for 143/144 is a result, not a
broken search.

**What moved:** nothing numeric. `useitem.go`'s heal gains the citation that it
is unmodified because the modifier is always zero, not because the modifier was
overlooked.

## Passive regeneration does not exist, and "unwritten means zero" was wrong (2026-09-15)

> **OVERTURNED 2026-09-16 — passive regeneration DOES exist.** Section 1 below is
> wrong, and its own method is why: it enumerated every WRITER of the HP/MP pool,
> correctly and exhaustively, and then concluded "not one is driven by a clock"
> without checking what drives the writers. `GObjPC_RecoverHpMp` (`004a86a0`, the
> row it labels "potions and heal skills") is called by `CGObjPC::vslot_362`
> (`0x004e2990`), which is **registered as a timer**. See the entry at the end of
> this file. What survives unchanged is section 2, and the enumeration itself —
> every writer really is on that list.

Two results, the second of which matters more than the one I set out to get.

**1. There is no passive HP/MP regeneration in the server binary.** Closed as a
negative, and this time by an enumeration rather than a search that gave up.

A character's pool is written through exactly two clamped setters, and they name
their own source file: `GObjChar_SetCurHP` (`0x004a66f0`) and
`GObjChar_SetCurMP` (`0x004a6790`) assert with
`d:\work2005\source\silkroadonline\server\sr_gameserver\GObjChar.h` line `0x16c`
and the format `"CLAMP() ==> min(%.3f) exceeded max(%.3f) value)"`. Disassembling
the whole PE (`objdump -d -M intel`, 2.5M lines in 2s) and counting gives **4**
calls to the HP setter, **2** to the MP setter, **4** to the generic
`GObjPC_AdjustHpMp` they funnel through, and — the part that makes it an
enumeration rather than a sample — **zero address-taken references** to any of
the three, so none is ever reached through a vtable or a function pointer. Every
writer is on the list, and every one has now been read:

| Writer | What it is |
|---|---|
| `GObjPC_AdjustHpMp` `004a87d0` | the generic adjust: HP in EAX, MP in arg 2, notify mask OR'd into `pc+0xa0e` |
| `GObjPC_RecoverHpMp` `004a86a0` | potions and heal skills (params 143/144) |
| `CGObjCOS_Summoned::ConsumeHpMp` | summon upkeep |
| `CGObjChar::vslot_317` / `vslot_318` | effect application — 318 passes HP=0, so it is MP-only |
| `CGObjPC_PublishHpMp` `004e6330` | clamp, then send the update packet (bit 0 HP, bit 1 MP, bit 2 defers) |
| `GObjPC_OnEffectExpired` `005829d0` | re-clamp when an expiring buff takes MaxHP/MaxMP away |
| `FUN_00634020` | siege-structure removal |
| `GObjPC_RestorePoolOnLoad` `004e1120` | login/respawn seed at `GetParam(3)*0.4` — writes charData directly, because at load there is no current value to clamp against |

Not one is driven by a clock. Healing in this game is an **event** — a potion, a
skill, a respawn — never a tick. `'hprg'`/`'mprg'` (params 25/26) are real but
are not a resting rate: all seven writes of them come from skill effects and
every one targets slot 1 (additive percent) or slot 3, never slot 0. They modify
a regeneration the server itself never performs.

`mana.RegenPercentPerTick`/`RegenInterval` therefore stay own design, and the
comment now says so with the enumeration rather than with a hope that `'mprg'`
was still out there to be read.

**2. The correction, which came out of checking the probe.** I nearly shipped
the argument "slot 0 is never written for 25/26, and the formula multiplies by
slot 0, so the result is zero." Reading `ParamKeeper_EvaluateParam` instead of
assuming it killed that: when slot 0 holds no entries the base falls back to a
per-param **default** at `+0x28`, and when no slot has entries the result *is*
the default. The read path forces it — `FUN_004b3740` calls
`ParamKeeper_EnsureParam` first, which creates the param from a descriptor
record `(min, max, default)` fetched from a map keyed by param id and asserts if
the id is missing; the values arrive as `fild [ecx+4/8/0xc/0x10]`, integers from
a record built at runtime.

So **"nothing writes param N, therefore N is zero" is not a valid recovery**, and
this codebase used it three times. Fixed:

- `leveldata.DeathPenaltyReductionPercent` — still 0, but now disclosed as
  srrevamp's own choice for a server with no premium accounts, not as a value
  read out of the binary. What the binary proves is that param 257 is
  premium-only (`CTJ_PremiumKeeper::vslot_012` is its sole writer).
- `berserk`'s damage-completeness note — params 128-131, 178, 180, 187, 188, 259
  are proven **unmodified** for an unbuffed character, not proven zero.
- `combat.MitigateDamage`'s params 9/11 argument is **unaffected**: it is a
  read-side census, and a param nothing reads cannot matter whatever its default.

The defaults themselves are runtime data and are not recoverable from
`SR_GameServer.exe` — a new entry on the unrecoverable list, alongside drop
tables and character-creation defaults.

**Naming.** Seven functions and six vtable slots gained real names in
`ApplyKnownNames.java`, so they survive the next dump rebuild:
`GObjChar_SetCurHP`, `GObjChar_SetCurMP`, `GObjPC_AdjustHpMp`,
`GObjPC_RecoverHpMp`, `CGObjPC_PublishHpMp`, `GObjPC_OnEffectExpired`,
`GObjPC_RestorePoolOnLoad`; and by use, `vf[0x104]` = `GetParam`,
`vf[0x108]` = GetCurHP, `vf[0x10c]` = GetCurMP, `vf[0x110]` = GetMaxHP,
`vf[0x114]` = GetMaxMP, charData `vf[0x40]`/`vf[0x44]` = the HP/MP stores.

**A probe note worth keeping.** The param-id annotation pass covers **writes
only** — 278 annotated `SetParam` sites, **zero** reads. Any census of "who uses
param N" built on those comments is a write census wearing a use census's
clothes, which is how the slot-0 argument looked convincing. The read side goes
through `vf[0x104]`, and a literal-argument grep there finds real sites but must
not be trusted as complete either: of 113 apparent "computed id" sites, most are
three-argument calls to a *different* method at the same offset on another
receiver class. Slot meaning depends on the receiver — again.

**What moved:** nothing numeric. Two overreaching claims became accurate ones, a
long-open question closed as a proven negative, and thirteen names landed.

## The ParamKeeper registry, recovered whole — and yesterday's correction corrected (2026-09-15)

Last tick I retracted the inference "nothing writes param N, therefore N is
zero", on the grounds that an unwritten param falls back to a descriptor default
and that those defaults were runtime data, not in the binary. The mechanism was
right. **The claim that the defaults are unrecoverable was wrong, and this tick
found them.**

**The find.** There is exactly **one** `CParam` allocation site in the whole
binary, inside `ParamKeeper_EnsureParam`, and it runs only when the param id is
present in a global map. So if that map were empty the entire stat system would
be dead — which is what my own probe appeared to show, because grepping for the
map's address literals found a constructor, a clear and three lookups but no
insert. The insert exists; it reaches the map through registers and touches only
the size word, so an address-literal grep could not see it. `0xcd3118` found it
in one line: `add DWORD PTR ds:0xcd3118,0x1`.

From there it unwound: the insert's sole caller is `map::operator[]`, whose sole
caller is `CMainProcess::ParamRegistry_Register` (`0x004b3960`) — a plain loop
over a **static table at VA `0x00c64110`**, 20-byte records terminated by id
`0xFFFF`:

```c
struct ParamDesc { uint16 id; uint16 pad; int32 min, max, default, flag; };
```

**120 params, ids 0-259 with gaps.** Read out of the PE and written up in full at
`docs/protocol/param_registry.md`.

**Two checks that the layout is right**, neither of them tuned for: param 0 comes
out `min=1, max=140` — the level cap, matching `leveldata`'s own 140 — and the
magnitudes sort by kind on their own, HP/MP capping at ~INT_MAX, the percentage
stats (`bri`, `cri`, `hprg`, `mprg`, `evbl`, `evcr`) at 100, the rate stats
(`era`, `hra`) at 65535.

**What it settles.** Only **7 of 120** params have a non-zero default, every one
of them `100`: ids 34, 35, 36, 37, 50, 51, 140. Everything else defaults to **0**
— including every id this project reasons about. So the retracted inferences are
restored, this time on data:

- `leveldata.DeathPenaltyReductionPercent` — param 257 defaults to 0, so a
  non-premium character takes the full penalty. **Recovered, not chosen.**
- `berserk`'s damage-completeness note — 128-131, 178, 180, 187, 188 and 259 all
  default to 0, so an unbuffed character's damage pipeline really is complete.
- `mana` — `'hprg'`/`'mprg'` default to 0, so the engine's resting regeneration
  rate is zero. That agrees with yesterday's independent result that no pool
  writer is timer-driven: both halves say the same thing.

**A validation lever, which is the durable part.** The registry is the
authoritative list of param ids that can exist — an id absent from it asserts in
`EnsureParam`, creates nothing, and then faults in `Param_GetValue`, which has no
null check. Ids **61-127, 142, 151-168, 201, 203-255** are unregistered, so any
future "recovered" param id landing there is wrong by construction. Every param
id this project has previously recovered — 2, 3, 4, 9-17, 25-32, 52, 53, 56, 57,
128-131, 140, 141, 143, 144, 174-177, 178-189, 190-193, 256-259 — validates
against the registered set.

**Three probe failures in one tick**, all the same shape and all caught before
they became claims: a caller list that missed three callers, an "empty map" that
was an incomplete grep, and yesterday's "unrecoverable" that was an unfinished
search. The rule earned its place again — when a negative comes back, check the
probe, and prefer a probe that would fail loudly over one that returns nothing.

**Naming.** `ParamRegistry_Register`, `Param_Init`, `ParamKeeper_EnsureParam`,
`ParamKeeper_ReadParam` and `Param_GetValue` added to `ApplyKnownNames.java`.

**What moved:** nothing numeric — `DeathPenaltyReductionPercent` was already 0.
What changed is its standing: three constants went from *disclosed own design*
back to *recovered with a citation*, which is the direction this project is
supposed to move in.

## The stat-tag vocabulary, extracted in full (2026-09-15)

With the param registry recovered last tick (120 ids, each with min/max/default)
the obvious next lever was the other half of the vocabulary: which *tag* writes
which id. `Stat_ApplyTaggedModifier` (`0x00498690`) is the id→name table the
binary lacks as data — each branch pushes into a specific param and slot — and
this project had ~19 entries off it, read by hand.

Extracted systematically instead: **53 tags, 31 resolved, 7 proven dead**, in
`docs/protocol/param_tags.md`.

**Why two passes were needed.** The annotation pass that seeds
`/* ParamKeeper param id: EDI .. */` comments only resolves ids at a direct
`SetParam` call. **34 of the 53 tags** reach their param through a shared tail
(`LAB_00498adf`) with the id left in `EDI` — invisible to it, and rendered as a
bare `goto` in the decompiled C. Disassembly dataflow over each branch, tracking
`mov edi, imm`, resolves 12 more.

**The control ran first**, against the 19 known tags: 17 reproduced exactly. Both
discrepancies were informative rather than fatal, which is the point of running
a control at all:

- **`drua` came back as 128, 129, 130, 131** against a recorded 128, 129, 130.
  The use-site settles it — after three `SetParam`s the branch does
  `mov edi,0x83; jmp 0x498adf`, and the tail performs a fourth write. **The
  recorded entry was incomplete**, hidden behind exactly the `goto` this pass
  exists to see through. `berserk`'s note already said "128-131", so nothing
  shipped was wrong; the memory was.
- **`hp` came back empty** — it returns immediately after its single write and
  the walker lost it. Already known and confirmed in the decompiled C.

**What it newly settles:**

- **Param 1 is Strength.** Four tags write it (`str`, `stra`, `strj`, `strv`) and
  the dispatcher's own fall-through tail is `mov edi,0x1`. Independent
  corroboration of the stat graph, where health runs `Str(1) -> 52 -> 54 -> MaxHP(3)`.
- **Params 27-32 are the six status-effect resistances**: `fz` 27, *(28)*, `es`
  29, `bu` 30, `ps` 31, `zb` 32, with `rals` writing all six at once. Id 28 is
  only ever written as half of a pair (`mov edi,0x1b` beside
  `mov [esp+0x24],0x1c`), so its own tag was not isolated. The client names three
  of them: `PARAM_FZ` "Freezing", `PARAM_PS` "Poisoning", `PARAM_ZB` "Zombie".
- **`umdu` writes 259** — one of the damage-pipeline params established as
  unwritten for an ordinary character. Consistent rather than contradictory:
  `umdu` is a buff tag, so only a buffed character carries it.
- **Seven tags are DEAD** — recognised by the dispatcher, returning without
  touching a param: `er`, `atha`, `rep`, `astr`, `dura`, `luck`, `soli`. Since
  the dispatcher *is* the modifier path, a tag it ignores has no effect on
  stats. Note `luck` is dead even though the client ships `PARAM_LUCK` = "Lucky"
  and displays it — but the separate tag `luca` is live, so this is a statement
  about the tag, not about the stat.

**Cross-validation, which is the part worth keeping.** Every one of the 31
resolved ids is present in the param registry recovered last tick. Those two
artifacts came from completely different evidence — a static data table read out
of the PE at `0x00c64110`, versus dataflow through a dispatcher's branches — so
their agreement is a real check rather than a restatement.

Also named `AvatarBless_TagList` (`0x00508170`), which builds the 12 tags an
avatar item's blessing can carry and pairs with the `AVT <tag> +%d%%` strings.

**15 tags remain unresolved**: `ape`, `duru`, `hr`, `inta`, `intj`, `luca`,
`mdia`, `nrep`, `rcsi`, `rdii`, `rein`, `reis`, `rfei`, `rsli`, `rsti`. They
reach a param through read-modify-write paths this pass does not follow. Do not
guess them from the abbreviation — the client's `PARAM_*` keys have already
corrected this project twice.

**What moved:** nothing numeric; srrevamp models neither luck nor status
resistances, and `berserk`'s 128-131 was already right. The vocabulary went from
19 hand-read entries to 31 resolved plus 7 proven-dead, with a registry
cross-check behind it.

## The stat-write surface is 28 functions, and last tick's "dead tags" was too strong (2026-09-15)

Started by joining the skill param codes to the tag vocabulary recovered last
tick, on the theory that the two are partly the same language. They barely
overlap — but the first overlap found was `dura`, which last tick's table listed
as a **dead tag** and which `skill_params.md` shows on **1,979 skills**. A tag
carried by two thousand skills is not dead, so the claim needed checking rather
than extending.

**What the check established.** Enumerating every `ParamKeeper_SetParam` caller
gives **28 functions**, and exactly **one** of them is dispatched on a tag:
`Stat_ApplyTaggedModifier`. The other 27 are structural — `GObjPC_InitStats`,
`Char_PublishCombatStats`, `GObjMob_PublishStats`, `GObjPC_SetLevel`,
`GObjPC_SpendStatPoints`, `CTJ_PremiumKeeper::vslot_008`/`012`,
`CTJ_CharParamKeeper`, the mob, siege and mercenary paths, and the effect
apply/expire pair. **So a tag that the dispatcher ignores does not become a param
anywhere.** That half of last tick's claim survives, and is now enumerated rather
than asserted.

**What was wrong.** The published wording was that the dispatcher "**is** the
modifier path, so a tag it ignores has no effect on a character's stats", and it
called the seven tags DEAD. All seven are in fact recognised in five other
files — the description builders (`CGameServer::FUN_0072e2d0` and neighbours,
working in `LPCSTR`/`PCNZCH`, which produce the `AVT <tag> +%d%%` strings), the
enchant system (`CEnchant_EnchantAttrStone`), and `CGItemEquip`. **None of those
files contains a single `SetParam` call**, which is why they sit comfortably
beside the enumeration — but it means the tags are live code, not dead strings.

Corrected in `docs/protocol/param_tags.md` to the narrow claim the evidence
supports: **these seven are not character-stat modifiers.** What they are
instead is left unrecovered. `dura` reads like a duration and `rep` like a
repeat, but nothing in this pass settles either, and guessing a tag from its
abbreviation has already cost this project two wrong answers (`era` is parry,
not evasion; `hra` is attack rate, not hit rate).

**Recovered on the way**, from reading the unnamed half of those 28 writers:

- **`COS_ApplyHalfCombatScale`** (`0x004d60a0`) — sets slot 3, the percent scale
  that compounds from 100, to **50.0** across the entire combat block at once
  (params 5, 6, 9, 11, 13, 14, 15, 16) and flushes the keeper. The constant is
  `fld DWORD ds:0xb4603c` — a float32, checked for operand size — so it halves
  damage bounds, defence, parry rate and attack rate. Reached only from
  `CGObjCOS_GoldPet::vslot_215` and `vslot_211` (one call, one tail-`jmp`, no
  address-taken references), so it is **the gold pet's combat penalty**, not a
  general scale. srrevamp has no pet system, so this is recorded rather than
  wired.
- **`Effect_NegateDaraFamily`** (`0x004aaf80`) — dispatches on the four-character
  code `0x44414252` (`DABR` big-endian) and negates the value into params
  174-177 at slot 2, the same family the `dara` tag writes; `FUN_004ab060`
  removes the four again. The mechanics are recovered; what the code denotes is
  not, and is not guessed.

**What moved:** nothing numeric — srrevamp models neither pets nor the `dara`
family. One published claim narrowed from "these tags are dead" to "these tags
are not stat modifiers", with a 28-function enumeration behind the half that
held. The skill-code/stat-tag join that prompted all this turned out to be
nearly empty, which is itself worth recording so it is not retried.

## Naming coverage measured, and the item type-id widths recovered (2026-09-15)

**Coverage, computed from the dump index rather than by running Ghidra** (instant,
and it does not contend with the 15-minute cron): of the server's **34,113**
functions, **7,386 are named (21.7%)** and 26,727 are still `FUN_`. Of the
unnamed, 54% at least carry a class attribution (`Class::FUN_...`); 12,244 are
bare with no class at all, and those are mostly CRT and template code.

Biggest unnamed clusters by bytes: `CGameServer` (3,674 fns), `GObjPC` (2,906),
`CMainProcess` (1,376), `CGameWorldLayer` (545), `MapLoader` (260), `CNetEngine`
(273), `ReferenceData` (114).

**`ReferenceData` was the right target**, being small, bounded, and the layer
srrevamp actually ships against. Harvesting **assert strings across the whole
namespace in one pass** found 32 unnamed functions carrying string anchors, and
the anchors are the game's own error text, variable names and `ReferenceData.cpp`
line numbers — so the names can say what the code demonstrably does instead of
guessing an original identifier. Nine named this tick, covering the magic-option
validators, the item package checks, the shop price/sellable path and the
teleport loader.

### The type-id widths, and a value grounded

`ReferenceData::RefItem_ReadTypeIDs` (`0x006a8090`) deserialises an item's five
type bytes and bounds-checks each against a named constant, asserting with the
game's own file and line:

| assert | fires when | constant | width |
|---|---|---|---|
| `btCash < MAX_CASHITEM_TID_COUNT` | `1 < btCash` | **2** | 1 bit |
| `btType1 < MAX_TID1_COUNT` | `7 < btType1` | **8** | 3 bits |
| `btType2 < MAX_TID2_COUNT` | `3 < btType2` | **4** | 2 bits |
| `btType3 < MAX_TID3_COUNT` | `0xf < btType3` | **16** | 4 bits |
| `btType4 < MAX_TID4_COUNT` | `0x1f < btType4` | **32** | 5 bits |

`ReferenceData.cpp:2466-2470`. Each assert fires on `limit-1 < value`, so the
constant is one past the largest legal value.

**Wired into `internal/equipment`** as `MaxCashItemTID`, `MaxTID1..MaxTID4`, with
`TestTypeIDsAreWithinRecoveredBounds` holding every declared family and piece
constant inside them. Every value this project already used validates — the
largest family is `FamilyEuropeHeavy` 11 against a 16 ceiling, the largest piece
`PieceBoots` 6 against 32 — so nothing changed numerically. What the bounds add
is a guard: TypeID3 being four bits wide means a family id of 30 is a typo rather
than an undiscovered armour set, and such a constant would otherwise silently
match no item at all. The test also checks each bound is a power of two, since
each is one past a fixed-width field's maximum.

The engine's own check is an assert, not a rejection, so these are not used to
gate anything at runtime; that is recorded in the constant's comment so a later
reader does not turn them into validation the game never performed.

**What moved:** nothing numeric. Five recovered constants gained citations,
srrevamp's existing type-id constants gained a bounds test, nine `ReferenceData`
functions gained evidence-backed names, and naming coverage is now a measured
21.7% rather than an impression.

## The kill-reward path: damage share, and a 3%-per-member party exp bonus (2026-09-15)

Followed the source-path lever from last tick. Binary-wide it is nearly spent —
only 156 functions carry a `WORK2005` path and 68 of those are still `FUN_` — but
two of the files it names sit on srrevamp's critical path: **`Formulae.cpp`** (3
functions, 2 unnamed) and **`RefItemDrop.cpp`**. Took `Formulae` first.

Both unnamed functions are kill-reward formulas, and following their callers
opened the whole path:

	COS_DistributeKillReward (004d68c0)
	  pass 1: accumulate each contributor's damage into entry+0x18
	  pass 2: for each PC contributor -> vtable slot 420, with
	          (accumulated damage, party multiplier)
	GObjPC_ReceiveKillReward (004ea6a0, slot 420)
	  -> Formula_ExpRewardForContributor (00410110)
	  -> Formula_ExpShareByDamage        (004106b0)
	  -> GObjPC_DistributePartyExp       (004fcb00)

**The share is by accumulated damage, and the use-site settled it.** The obvious
misreading was that the share is the *last blow* — which would cut a solo
killer's exp by whatever fraction the final hit was, a tenfold difference. It is
not: `add DWORD PTR [eax+0x18],edx` in the first pass is an accumulator, and the
second pass passes `entry[6]` (that same field) per contributor. So
`share = clamp(accumulatedDamage / victimMaxHP, 1e-6, 1.0)`, and a solo killer's
share is exactly 1.0. The lower bound is an epsilon (`fld DWORD ds:0xb45c84` =
1e-06f), not a minimum-contribution rule. `vf[0x110]` being MaxHP came free from
the pool work two ticks ago.

### VALUE SHIPPED: the party exp bonus

`COS_DistributeKillReward` builds the multiplier immediately before each award:

	4d6bb9  FLD1                          <- starts at 1.0
	4d6bcd  CMP  DWORD [EDI+0x1cb8],0     <- pc[0x72e], the party field
	4d6bd4  JE   ...                      <- no party: stays 1.0
	4d6bd9  CALL 0x4ea230                 <- member count
	4d6bde  SUB  EAX,1                    <- members - 1
	4d6be9  FMUL QWORD ds:0xb45dc8        <- * 0.03
	4d6bef  FADD QWORD ds:0xb45ac0        <- + 1.0

**Party exp bonus = 1.0 + (members - 1) x 0.03** — 3% per extra member.

Both constants are `QWORD`, so **doubles**: 0.03 and 1.0. Read as float32 the
first is -3.7e19. The operand-size rule earned its keep again, and Ghidra had in
fact rendered both as `(float)` in the decompiled C, which would have produced
garbage.

Wired through as `leveldata.PartyExpBonusPerMember` / `PartyExpBonus(members)`,
applied in `session.applyPartyExpBonus` on the kill-reward path, with `parties`
threaded into `CombatHandler`, `UseSkillHandler` and `performAttack`. Two tests:
`leveldata.TestPartyExpBonus` pins the multiplier (and that it is monotonic and
never a penalty), `session.TestApplyPartyExpBonus` covers the wiring and the
three "no bonus" shapes — no hub, no party, party of one — which are all the
engine's own `FLD1` default.

**SCOPE, stated because the engine does more than srrevamp now does.** The real
server scales each contributor by its damage share *and* distributes to party
members through `GObjPC_DistributePartyExp`. srrevamp awards the whole unit to
the killer. For the killer that is exactly right — a solo contributor's share
clamps to 1.0, so the bonus alone reproduces the engine's number for that
character. What srrevamp still does not do is give the other members anything;
that is a separate missing feature, recorded in the constant's comment rather
than papered over.

**Also opened:** `killer+0x1cdc` is the multiplier `Formula_ExpShareByDamage`
applies (`unaff_EBX[0x737]` is the same field), which sits beside the long-open
`killer+0x1cd8`. Both are per-killer exp multipliers; neither is written by
anything srrevamp models, so they stay open rather than guessed.

**What moved:** a real value, shipped. Party kills now pay what the engine pays.

## How the engine actually rolls a drop (2026-09-15)

`RefItemDrop.cpp` was the other file the source-path lever named on srrevamp's
critical path. Drop *tables* are still server-side database tables absent from
every client archive — that closure stands — but the **drop ALGORITHM is in the
binary**, and it turns out srrevamp's imported `MonsterDrop`/`DropGroupEntry`
rows were being interpreted wrongly in two ways. Neither field had a use-site
behind it; both were named from the column and left at that.

### The assigned-drop roll

`CRefDropData__AddAssignedItemDrop` (`0x00724a00`, named from its own assert)
walks the monster ref object's assigned-drop vector — 0x30-byte records at
`refObj+0x28c` — and for each record with a non-zero group id at +0:

```c
count = rand() % (max - min + 1) + min       // BYTES at record+6, +7
for (i = 0; i < count; i++) {                // `} while (uVar5 < local_4)`
    if (resultList full) break;
    roll = (rand()<<15 | rand()) % 1000000;  // mov ecx,0xf4240
    if (roll <= dropRatio * 1000000.0)       // fld DWORD [rec+8] ; fmul QWORD 0xb45bc0
        produce one item from the group;
}
```

**Two corrections fall out, and both change behaviour rather than wording:**

1. **`DropAmountMin/Max` is an ATTEMPT COUNT, not a stack size.** The engine
   picks a count in that range and then rolls `DropRatio` **independently for
   each attempt**. A row of 1..3 at 10% yields nothing most kills and three items
   rarely — a binomial, not "roll once then choose a quantity". The two models
   agree only when `DropRatio` is 1.0.
2. **`DropRatio` is a probability FRACTION in [0, 1]**, compared against a
   per-million roll. Two `rand()` calls are combined because MSVC's `rand()`
   yields 15 bits. The scale `0xb45bc0` is `QWORD` — a **double**, 1000000.0 —
   while the ratio itself is `fld DWORD`, a float32; the usual operand-size
   split, in one expression.

### The group pick

`RefItemDrop_RollGroupDrop` (`0x00724e30`) selects within a group by
**cumulative** weight on the identical per-million scale: it accumulates
`round(selectRatio * 1000000)` (a float32 at entry+0x24) and takes the first
entry whose running total reaches the roll. That the same scale drives both is
what establishes the two ratios as fractions on one common scale rather than two
differently-encoded numbers. A group whose ratios do not sum to 1 genuinely
selects nothing sometimes — a real outcome, not an error.

### What shipped

`refdata.RollAssignedDrop` and `refdata.SelectFromGroup` implement the above
exactly, with `DropRollScale = 1000000` as a named recovered constant, and the
struct comments now carry the semantics instead of the column names. The tests
are written to separate the two mechanics rather than merely exercise one:
`TestRollAssignedDropIsPerAttempt` runs 3 attempts at ratio 0.5 and asserts a
zero-yield rate near **0.125**, because a roll-once model would give **0.5** —
so a regression to the wrong mechanic fails loudly instead of drifting.

**What did NOT move, stated plainly.** `combat.LootTables` is still own design
and still what a kill actually rolls. Two things block the real path and neither
is a value to recover: an operator must bring the tables, and `combat.Monster`
carries `CodeName` but no numeric `RefObjID`, which is the key those tables use.
What changed is that the machinery to consume that data faithfully now exists
and is tested, so the remaining gap is data and plumbing rather than
understanding.

**What moved:** no shipped number, but two field semantics went from unexamined
to recovered — and one of them (`DropAmountMin/Max`) was being read in a way
that would have produced visibly wrong drop rates the moment real data arrived.

## Monster rank scales SPEED, not experience — and offset 0x1cd8 is three fields (2026-09-15)

Went after the long-open `killer+0x1cd8` / `+0x1cdc` pair, which last tick's
exp-share work had put back in view. The tick nearly produced a wrong shipped
value, and the thing that stopped it was insisting on the consuming use-site.

**The near-miss.** `CGObjMob::FUN_004c1550` is a clean four-way table:

| rank (`mob[0x1cd8] & 0xf`) | multiplier |
|---|---|
| 1 | **1.5** |
| 4 | **3.0** |
| 6 | **1.7** |
| 0, 3, 5, 7, 8 | 1.0 |

and the rank byte is copied from `refObj+0x50`. The domain 0-8 matches
characterdata column 15's rarity values exactly (0 normal, 1 champion, 3/8
unique, 4 giant, 5 titan, 6 elite), and the obvious next sentence writes itself:
*champions give 1.5x experience, giants 3x*. srrevamp already carries `Rarity`,
so it would have shipped.

**It is not an experience multiplier.** `CGObjMob::vslot_215` is what consumes
it, and it multiplies the mob's two movement fields (`+0x16c`, `+0x170`) and
publishes both into the ParamKeeper — `mov edi,0x17` then `mov edi,0x18`, i.e.
params **23 and 24**, which `Char_PublishCombatStats` had already established as
the MOVEMENT pair. So the rank multiplier is a **movement-speed scale**:
champions and giants move faster. Nothing about experience. srrevamp does not
model monster movement speed at all, so there is nothing to ship — which is a
far better outcome than shipping a 3x exp bonus that the game does not give.

**Offset 0x1cd8 means three different things by receiver class**, which is what
made the exp reading tempting in the first place:

- `CGObjMob` — the rank BYTE (with the float multiplier at +0x1cdc)
- `CGObjSiegeStruct` / COS — an integer timer (the writes are `0x1d4c0` = 120000
  and `0x124f80` = 1200000, i.e. 2 and 20 minutes)
- `CGObjPC` — a **float**, and this is the one `Formula_MonsterExpReward` reads
  (`fld DWORD PTR [edi+0x1cd8]`)

That is the fourth time this project has been caught by a per-class offset, and
the first time the check was run *before* the claim rather than after.

### What the PC's term actually is

`GObjPC_RecalcLevelDiffExpScale` (`0x004e30d0`) is its only float writer:

```c
ref = FUN_0059e870(pc + 0xa30);                 // a byte, from a list walk
if (ref > 0x78) { pc[0x1cd8] = pc[0x1cdc] = 1.0f; return; }
pc[0x1cd8] = clamp(1 - (charLevel - ref) * 0.1, 0.1, 1.9);
pc[0x1cdc] =        1 - (ref - charLevel) * 0.1;
```

K is `fmul QWORD ds:0xb45ec0` = **0.1, a double**; the clamp bounds are 0.1 and
1.9. It is recomputed on exactly three events — `CGObjPC::vslot_212` (PC load),
`GObjPC_SetLevel`, and `Mastery_LevelUp`.

**What the reference byte denotes is NOT recovered, and is deliberately not
guessed.** Recomputation on mastery level-up, and `0x78` being exactly 120 — the
mastery cap this project already recovered — both fit the reference being the
character's highest mastery level, which would make this the familiar "mastery
lagging your level costs you experience" rule. That is two coincidences and no
use-site, which is precisely the shape of reasoning that produced the wrong
answer for characterdata column 79 twice. It stays a hypothesis, written down as
one in `leveldata.go` beside the formula.

**What moved:** no shipped number. A live multiplier on a shipped formula went
from an unexamined field to a bounded, characterised term with its recompute
triggers known, and a tempting 3x experience bonus was correctly *not* shipped.

## The mastery-lag experience penalty, settled by a use-site (2026-09-16)

Last tick characterised the float at `pc+0x1cd8` that `Formula_MonsterExpReward`
multiplies every kill by, and **explicitly refused to name its reference byte**:
two coincidences pointed at "highest mastery level" — recomputation on
`Mastery_LevelUp`, and `0x78` being exactly the recovered single-mastery cap of
120 — but that is the shape of reasoning that got characterdata column 79 wrong
twice, so it was written down as a hypothesis. This tick settled it properly.

**The use-site that settled it.** `FUN_0059e870` walks a list under `pc+0xa30`
and returns the **maximum** byte at `entry[0x10][8]+0x20`, skipping entries whose
`[0x10]+0xc` is 3. Its neighbour `FUN_0059e7c0` walks the **identical** list with
the identical skip rule and identical value path, but **sums** instead — and
`Mastery_LevelUp` calls it and compares `that sum + the levels requested`
against its total-mastery cap:

```asm
59c569  CALL 0x59e7c0            <- the sum
59c570  MOVZX EAX,BYTE [EBP+0xc] <- levels requested
59c574  ADD  ECX,EAX
59c57e  FCOMP QWORD ds:0xb46130  <- against 240.0
```

A function whose result is the quantity a *mastery cap* is checked against is
summing mastery levels. Its twin over the same list is therefore the highest
mastery level. Named `Mastery_SumLevels` and `Mastery_MaxLevel`.

A third, independent corroboration: `CMainProcess_RollByEffectiveLevel`
(`0x0060c4b0`) takes `max(characterLevel, Mastery_MaxLevel())`, which only makes
sense if the two are on the same scale.

### VALUE SHIPPED: the mastery penalty

```
expScale = clamp(1 - (charLevel - maxMasteryLevel) * 0.1, 0.1, 1.9)
         = 1.0 when maxMasteryLevel > 120
```

K is `fmul QWORD ds:0xb45ec0` = **0.1, a double**; the clamp bounds are the
floats at `0xb45eb8` (0.1) and `0xb45f18` (1.9). Shipped as
`leveldata.MasteryExpScale`, applied in `session.applyMasteryExpScale` on the
kill-reward path ahead of the party bonus.

**SCOPE, and it is a sharp one.** The engine does **not** special-case a
character with no mastery — the only escape is a reference above 120, which no
real character reaches. So a level-10 character who has never raised a mastery
really does fall to the 0.1 floor, and that is the mechanic rather than an
oversight. srrevamp now reproduces it. The one place this implementation
deliberately departs from the engine is a lookup FAILURE: the engine always has
the number to hand, so a store error here returns the award unscaled rather than
charging the player 90% of a kill for srrevamp's own problem.

**Also found, and NOT promoted.** `Mastery_LevelUp` carries **two** total-cap
shapes: the flat `0x14b` (331) this project already recorded, and a second
branch comparing against the double **240.0** at `0xb46130` alongside a term
involving twice the character level. Which branch runs depends on a selector
this pass did not identify, and the `2 x level` term's operand was not pinned
down, so `session.MasteryTotalCapPerLevel` is left at its sourced 3 rather than
changed on a half-read branch. Recorded as open.

**What moved:** a real mechanic, shipped — and a hypothesis that was correctly
refused last tick became a citation this tick by finding the use-site rather
than by growing more confident about the coincidences.

## The mastery cap is three rules, not one (2026-09-16)

Closing out the open item left by the mastery-penalty tick: `Mastery_LevelUp`
was recorded as enforcing "a FLAT total of 330", and a second branch comparing
against 240.0 had been spotted but not read. It is neither one rule nor two —
there are **three**, selected by a byte at `(charData+0x18)+0x88`:

| selector | total-mastery rule |
|---|---|
| **0** | refuses when `sum + requested >= 0x14b` — a flat **330**, with no level term at all |
| **1** | allows only when `total <= 240.0` **and** `total <= level + level` |
| **2** | no total cap whatsoever |
| other | error `0x3801` |

240.0 is the double at `0xb46130`, compared with `FCOMP QWORD`; the level term is
literally `level + level`, i.e. **2 x** the character level, not 3.

**And a rule srrevamp already had, now cited rather than assumed.** Past the cap
branch, `Mastery_LevelUp` applies a per-mastery check and refuses with error
`0x3804` when `characterLevel < currentMasteryLevel + levelsRequested`. So a
single mastery may never exceed the character's level — which is exactly the
`levelCap := owned.Level` bound `session` already enforced on the strength of a
plain assertion. That comment now carries the citation.

The full error vocabulary: `0x3801` bad mastery or selector, `0x3802`
insufficient skill points, `0x3803`, `0x3804` exceeds character level, `0x3805`
total cap.

**`MasteryTotalCapPerLevel` stays at its sourced 3.** None of the three branches
is `3 * characterLevel`, so the sourced retail rule and this binary's rules are
still genuinely different shapes — but the note in `skill.go` now records all
three instead of one, which is materially better information for whoever revisits
the decision. Worth flagging one coincidence for that future reader: selector 1
saturates at **240**, which is exactly the level-80 total the retail account
reports, reached by a different route (`min(240, 2 x 80)` is 160, so the two do
NOT agree at level 80 — the 240 matches only as a ceiling, not as the binding
constraint there).

**The selector is NOT identified, and deliberately so.** It is read from the same
field that a skill's own `+0xc4` is compared against (`funcs_550.c:309`) and that
indexes a small table at `DAT_00c8262c` (`funcs_550.c:372`), both of which fit it
being the character's race/country — China/Europe being exactly the kind of split
that would carry different mastery rules. That is a shape argument with no
use-site behind it, which is the reasoning that was wrong twice on characterdata
column 79 and was correctly refused two ticks ago on this very field's neighbour.
It stays open.

**What moved:** no value. One shipped rule gained a citation, one recorded rule
turned out to be a third of the real rule, and the remaining unknown is now a
single named byte rather than a vague branch.

## 28 skill codes joined to what they actually do (2026-09-16)

The largest item on the open list was "80 of 102 skill codes unidentified". The
codes' *field offsets* were recovered long ago; what was missing is what the
engine does with each field. A code's meaning is settled by whoever READS it, so
the lever is a reader census rather than reading codes one at a time.

**The census.** Grepping every function in the server dump for reads of the 87
known skill-field offsets, and ranking by how many DISTINCT code fields each
touches, puts one function far ahead of everything except the parser:

	RefSkill_ParseParams          87   (the parser, by construction)
	Skill_ApplyEffectsToParams    34   <- the lever
	Combat_ResolveDamage          28
	FUN_00589d20                  24
	FUN_00589f10                  16
	FUN_00593f50                  12   (cura, curt, heal, rcur, resu, rmut, tran)

`Skill_ApplyEffectsToParams` (`0x00594ac0`, now named) reads a skill's parsed
fields and pushes them into the target's ParamKeeper — the applier whose teardown
is the already-named `GObjPC_OnEffectExpired`. Because the dump annotates each
`SetParam` with its param id, pairing each skill-field read with the ids written
within the next 14 lines produces a **code → param** join for 28 codes. The full
table is in `docs/protocol/skill_params.md`.

**The controls ran first, and this is the part that makes the join trustworthy.**
Six rows were already established by entirely independent means and all six
reproduce exactly: `irgc` → 25, 26; `er` → 9; `hr` → 11; `stri` → 1; `mpi` → 4;
and `dru` → 128, 129, 130, **131**.

Two rows are worth singling out because each confirms an earlier *correction*
rather than merely agreeing with a fact:

- **`dru` → four params.** When the tag vocabulary was extracted, a by-hand read
  of the decompiled C had recorded `drua` as writing three params and missed the
  fourth behind a `goto`; the disassembly caught it. This join, built from a
  completely different function by a completely different method, independently
  lands on four.
- **`luck` → 173.** `luck` is one of the seven tags `Stat_ApplyTaggedModifier`
  recognises and ignores. An earlier version of `param_tags.md` called those
  tags DEAD and said a tag the dispatcher ignores "has no effect on a
  character's stats"; that had to be narrowed to "not a character-stat
  modifier". Here is the skill code `luck` writing param 173 — the narrowing was
  necessary, and the original wording would now be provably wrong.

**Readable straight off the param registry**: `apau`/`apru`/`tpad` move the damage
bounds (13-16), `defr`/`pmdp` the defences (5, 6, 7), `hst3`/`hste` the movement
pair (23, 24), `er`/`terd` parry and `hr`/`thrd` attack rate, `reat` the block
145-150.

**Limits, written into the doc rather than left implied.** This is a proximity
join: six rows are controlled, the rest rest on the same mechanism and the same
14-line window. A row is good evidence about which params a code touches and is
NOT a claim about the code's full semantics — duration, stacking and targeting
are not in it. It also covers only the codes this one function handles; the
combat-side and cure/resurrect codes are untouched.

**What moved:** no value. srrevamp models skill damage but no stat buffs, so none
of this is wired — it is the vocabulary for when that changes, and it took the
unidentified-code count from 80 down to 52.

## The combat-side skill codes, and a correction to last tick's census (2026-09-16)

Continued last tick's reader census into `Combat_ResolveDamage`, which had come
second at 28 distinct skill-field offsets. **The headline number turned out to be
an artefact of the method, and that is the more useful finding.**

Twenty of those 28 codes appear exactly once each, all inside one
`== 0 && ... == 0` chain spanning about twenty lines: a single composite guard
asking whether the skill carries any effect field at all before taking the
plain-attack path. A code named in that guard is tested for presence, not acted
on. **Ranking functions by distinct offsets read therefore over-counts anything
carrying a large null-guard**, and the fix is to weight by reads per code. By
that measure the function really acts on `att` (15 reads), `da` (12), `tant` and
`tnt2` (5), `ck` and `dtnt` (4), `kb`, `lfst`, `pdmg` (3).

This does not undermine last tick's join: `Skill_ApplyEffectsToParams` was
validated by six independent controls, not by its offset count. But the count is
what selected it, and the same count would have pointed somewhere useless if the
guard had been bigger.

**Two codes identified.**

- **`da` is a conditional damage percentage.** When the skill carries `da` and
  the target's `vf[0xfc]()` is 8, both damage fields are scaled by
  `da[0] / 100`. It scales BOTH (`+0x24` and `+0x28`), not one. What kind 8
  denotes is not recovered — `vf[0xfc]` is compared across the whole binary
  against only 0, 8 and 11 — so this is "a bonus against one specific target
  kind" and deliberately no more than that.
- **`kb` is knockback.** Gated on four conditions simultaneously (the skill
  carries `kb`; the attacker's ref object has bit 1 at `+0x258`; the result byte
  is not already 4; and `GObjPC::FUN_005a1a20()` passes), it sets the hit-result
  byte to **5** and does position arithmetic from `kb[1]`, copying both
  coordinate triples.

**A near-miss, recorded because it is the same class of error as the guard
chain.** Five instructions before the `kb` branch sits `x / 1000.0 + 0.5` — both
constants `QWORD`, so doubles — which reads exactly like a knockback duration in
seconds and would have been a tidy result. It belongs to the preceding block, not
to `kb`, and is left unattributed. Proximity inside one function is no more
evidence than proximity inside one expression.

**What moved:** no value — srrevamp has neither a target-kind concept for `da`
nor a knockback result for `kb`. Two more codes identified (52 -> 50 unknown),
and the census tool gained a documented failure mode before it could mislead a
later pass.

## VALUE SHIPPED: chance rolls are not memoryless (2026-09-16)

`combat.RollChance` carried a disclosure saying the engine "also keeps a
per-actor accumulator... reproducing it needs per-actor state this project does
not carry". That blocker stopped being true a while ago — the package grew
`berserk.Tracker` and `mana.Tracker` — so the note was describing an obstacle
that had dissolved. This tick implemented it.

**The mechanism**, from `Chance_RollWithBadLuckProtection` (`0x00599cc0`),
reached from `Combat_ResolveDamage` through `GObjPC_RollChanceForActor`:

```c
if (chance == 0)   return false;      // no roll, no state touched
if (chance >= 100) return true;       // likewise
roll = rand() % 101;
entry = find(container, key);
if (entry) {
    if (entry.acc < roll) { entry.acc += chance;       return false; }
                            entry.acc += chance - 100; return true;
}
if (chance < roll) { insert(key, chance*2);       return false; }
                     insert(key, chance*2 - 100); return true;
```

The two seeds look like special cases and are not: `chance*2` and
`chance*2 - 100` are exactly what the update rule produces from a starting value
of `chance`, so the whole function is **one** rule:

	succeed when acc >= rand()%101, acc starting at chance
	then acc += chance        on failure
	     acc += chance - 100  on success

That is bad-luck protection. Each failure raises the effective chance by the
base chance; each success spends 100 of it. **The long-run rate is unchanged** —
the accumulator gains exactly `chance` per roll and loses exactly 100 per
success — while long dry streaks get progressively more likely to break.

**Scoping, and what is grounded versus what is not.** The accumulator lives in a
map keyed by `(objectId & 0xFFFFFF) | tag<<24`, built at the call site as
`and ecx,0xffffff` then `or ecx,<tag>000000`. Seven distinct tags appear, six of
them ASCII: `B`, `C`, `D`, `E`, `H`, `M`. So the engine keeps separate
accumulators **per actor and per kind of roll** — that separation is recovered,
and srrevamp now reproduces it. Only one tag has a use-site: the `0x43` ('C')
call inside `Combat_ResolveDamage`. The other letters are NOT identified, so the
Go constants are named for what they gate (`ChanceCritical`, `ChanceBlock`)
rather than for letters this project cannot pin, and `ChanceBlock` says so.

**Shipped** as `combat.ChanceTracker` / `RollChanceTracked` / `ChanceMemory`,
threaded through `ResolveBlow` and its four call sites. The block roll is the
DEFENDER's and the critical roll the ATTACKER's, so a blow draws on two
different actors' streaks. A nil memory falls back to the memoryless
`RollChance` exactly, which is what every test asserting an exact blow relies
on. A monster's streak is dropped when it dies, since the engine's accumulator
lives on the object and cannot outlive one.

The test that matters asserts **both halves at once**: over 400k rolls at 20%,
the tracked long-run rate must match the memoryless rate to within 1%, and the
longest dry streak must be strictly shorter. Checking only the rate would pass
an accumulator that did nothing; checking only the streaks would pass one that
inflated the chance.

**Two things caught before they shipped.** A comment claimed `Hub.Despawn` calls
`Forget` — there is no `Despawn`; the claim was written from expectation rather
than from the code, and was replaced with the real cleanup point (monster death)
plus an honest note that monster and character ids share the key space and can
collide harmlessly.

**What moved:** a real mechanic, shipped, and a disclosure that had outlived its
own blocker.

## VALUE SHIPPED: the server's own gain-rate knobs (2026-09-16)

Set out to recover `berserk.Duration`, whose disclosure said the timer "is
genuinely not recovered" because every caller of the body-mode setter passes
0/0xff. Searching the *clear* side instead led to the Hwan reference table
(`_REFHWANLEVEL`, loaded into a vector at `DAT_00d6aa14 + 0x8d0`) and, via the
string `HwanGainFactor` sitting in `.rdata`, to something better: a block of
**server configuration knobs** with their defaults and ceilings.

`CMainProcess_LoadGainRates` (`0x00427050`) reads them at startup. Every knob has
the same three-step shape:

```c
value = atol(setting) / 100.0;   // the setting is a PERCENTAGE
if (value <  1.0) value = 1.0;   // the branch that logs "<knob>: system default"
if (value >= cap) value = cap;   // a per-knob ceiling
```

| knob | global | cap | source of the cap |
|---|---|---|---|
| `ExpRatio` | `0xc82518` | **2.5** | `0xb45b90` |
| `ExpRatioParty` | `0xc8251c` | **2.5** | `0xb45b90` |
| `DropItemRatio` | `0xc82520` | **3.0** | `0xb45b84` |
| `DropGoldAmountCoef` | `0xc82524` | **2.5** | `0xb45b90` |
| `HwanGainFactor` | `0xc82528` | **10.0** | `0xb45b44` |

All caps are `fld DWORD`, so float32.

**Two findings inside that are worth stating on their own.**

1. **A rate below 1x cannot be expressed.** The `< 1.0` branch is not input
   validation, it is the branch that logs "system default" — so the engine has
   no way to configure a server slower than retail, and neither does srrevamp
   now.
2. **The default is 1x, confirmed twice.** The `< 1.0` fallback sets it, and
   independently the globals are statically initialised to `0x3f800000` (1.0f)
   before any setting is read.

**The exp knobs are alternatives, not factors.** `GObjPC_ReceiveKillReward` does
`fVar1 = ExpRatio; if (pc[0x72e] != 0) fVar1 = ExpRatioParty;` — `pc[0x72e]`
being the party field recovered earlier — so a partied character takes the party
knob *instead of*, not *as well as*, the solo one. Multiplying them would have
been the natural implementation and would have been wrong; there is a test that
fails if anyone does.

**Shipped** as `internal/rates`, read from the environment under the game's own
knob names, applied to a kill's experience (choosing by party membership) and to
its gold. `DropItemRatio` and `HwanGainFactor` are carried with their caps but
applied to nothing, because srrevamp's loot table and berserk gauge are still own
design — recorded rather than quietly hooked to the wrong thing.

**What did NOT move.** `berserk.Duration` is still own design; the Hwan table is
real and `hwanleveldata.txt` is in Media.pk2's server_dep listing, so the
duration is plausibly a column in it, but no gameplay reader of the table's
entry fields was found and no column layout was recovered. The disclosure is
updated from "genuinely not recovered" to name the table that probably holds it.

**What moved:** four real constants and a parse rule, shipped, from a search that
set out after something else entirely.

## Berserk has no timer, and that is now proven rather than unfound (2026-09-16)

Last tick left this as "blocked on one more read". The read is done, and the
answer is a negative with a mechanism behind it — which is the difference
between a closure and a failed search.

The old disclosure said the duration was "genuinely not recovered" because every
caller of the body-mode setter passes `0xff/0`. **That was not even accurate:**
two of the eleven call sites pass a real state-change slot and a real float. The
earlier pass had generalised from a sample.

**The mechanism.** `IGObj::SetBodyMode` can carry a duration:

```c
if (param_3 != 0xff && 0.0 < param_4)
    *(float *)(state + 0x10) = param_4;
```

so a body mode gets a timed life only when the state-change slot is real and the
float is positive.

**Berserk is body mode 1.** `Combat_ResolveDamage` reads `IGObj_GetBodyMode`
(vtable slot 64, now named) and sets the berserk damage flag on `== 1` — the same
byte at `(*(this+0x30))+3` that `SetBodyMode` writes. That ties the mode number
to berserk through the damage path rather than by assumption.

**The enumeration.** All eleven call sites were read, including the two whose
arguments Ghidra lost — one copies another object's mode and passes `0xff,0,0`;
the other sets up `local_74 = {.., 2, 0xff}`, mode 2 with no timer. Exactly two
carry a duration, and **both pass body mode 2, not 1**. Every mode-1 and every
variable-mode site passes `0xff`, the value that skips the timer branch.

So the engine has a body-mode timer, uses it for another mode, and does not use
it for berserk. How a real berserk ends is therefore not a duration this project
failed to find — it is a different shape. `_CHAR.RemainHwanCount`, the persisted
charge count already recovered beside `Orbs`, is the obvious candidate: a berserk
spends a charge rather than running a clock. **Not promoted** — no use-site.

`berserk.Duration` stays 20 seconds and stays own design, now with the same kind
of proven reason `mana`'s regeneration rate carries.

**A dead end worth recording so nobody repeats it.** The Hwan reference table
`_REFHWANLEVEL` / `CRefHWANLevel` is real, its record is 0x30 bytes, and
`hwanleveldata.txt` ships in Media.pk2's server_dep — all of which made it look
like the place a duration would live. It is not: the server loads the table and
uses only its SIZE, to bounds-check the level `IGObj::UpdateHwanLevel` will
accept. No gameplay path reads its entries at all.

**What moved:** no value. One disclosure went from "not recovered" to a proven
negative, one inaccurate claim in it was corrected, and a promising-looking table
is now marked as a dead end for this question.

## CORRECTION: berserk DOES have a timer, and it is 60 (2026-09-16)

**The previous entry in this ledger is wrong and is retracted.** It concluded
"berserk has no timer, and that is now proven rather than unfound", with a
mechanism and an enumeration behind it. The mechanism was right. The enumeration
was not, and the way it failed is the one this project keeps relearning.

**How it failed.** The enumeration grepped the DECOMPILED dump for call sites of
`SetBodyMode` and found eleven, none of which passed body mode 1 with a
duration. But the berserk activation handler lives at about `0x00515bfd`, in a
region **Ghidra never recovered as a function** — so it is absent from the dump
entirely. "All eleven call sites" was all eleven *decompiled* call sites. The
disassembly has a twelfth, and it is the only one that mattered.

That is the same lesson as the caller list that missed three callers and the map
that looked empty: **a census over the dump is a census over what Ghidra
recovered**, not over the binary. The dump's 34,113 functions are not all of it.

### What the activation handler actually does

```
if (GetBodyMode() == 1)        -> error 3        // already berserk
if (charData[0x86] < 5)        -> error 1        // not enough charges
GObjPC_AdjustHwanCount(-5)                       // SPEND ALL FIVE
dur = GetParam(60) + GetParam(195)
SetBodyMode(mode = 1, stateSlot = 0, dur, 0)
```

The slot is **0, not 0xff**, so `SetBodyMode` takes exactly the timer branch the
previous entry described and hands `dur` to **`AJStateChanger`**, whose per-tick
update is a float countdown (`*(float *)(this+0x10) -= elapsed`).

### The value

`GObjPC_InitStats` sets param 60 with `ParamKeeper_SetParam(0, 0, _DAT_00b461bc)`
and `fld DWORD ds:0xb461bc` = **60.0f**. Param 195 is `hwit` — the client's
`PARAM_HWAN_TIME_INCREASE`, and the same id last week's skill-code join mapped —
and InitStats sets it to 0, its registry default. So an unbuffed berserk lasts
exactly **60**, and `hwit` extends it.

**The UNIT is inferred, not read.** What is recovered is the number and that it
counts down as a float against elapsed time; no conversion appears anywhere in
the `AJStateChanger` module, so the tick's delta unit was never actually read.
Seconds is the only reading that makes sense of a float countdown from 60.0 with
a buff term capped at 100 — but that is an inference and is labelled one in the
constant's comment.

### The charge model, recovered

Berserk **requires all five charges and spends all five at once**. That grounds
`Orbs = 5` for a third independent time: `CUsedItemLimit` refuses an item at 5,
`GObjPC_AdjustHwanCount` clamps to [0, 5], and activation both demands and
spends 5. The adjuster also refuses a positive delta while body mode is 1 — you
cannot bank charges mid-berserk — which confirms mode 1 is berserk from a third
direction.

srrevamp's 0..100 gauge filling to full is the same shape as "five charges, spend
all five" by luck rather than design; `Max` and `FillPerHit` stay own design.

**What moved:** `berserk.Duration` 20s -> 60s, shipped with a test that also
guards against drifting back to the placeholder. And a confidently-worded wrong
conclusion, committed and pushed one tick ago, is retracted with its cause named.

## Measuring the dump's blind spot, and re-checking what rested on it (2026-09-16)

Last tick's retraction was caused by a census over the decompilation dump being
mistaken for a census over the binary. Rather than move on to another value, this
tick measures that gap and re-checks the conclusions standing on it.

**The measurement.** `.text` is 7,176,192 bytes; the dump's 34,113 functions
cover 5,936,050 of them. **17.3% of the executable section is invisible to every
grep this project runs** — 1.24 MB in 31,578 gaps. Most is CRT and template code,
but filtering to the game-logic band (`0x401000-0x700000`) and discarding padding
by int3/zero density still leaves **145 real-code gaps, about 30 KB, 6.1% of the
band**.

The map finds its own precedent: `0x00515a52` (702 bytes) is exactly the region
holding the berserk activation handler that broke last tick's claim.

**The re-check, which is the point.** For each gap, disassemble it and ask which
functions it calls. Against the thirteen functions this project's enumerations
depend on — the pool setters, the generic adjust, `GainExpAndLevel`, the chance
roll, `EnsureParam`, both mastery walks, `SetBodyMode`, `RecalcLevelDiffExpScale`
and the param accessors — **only two gaps call any of them**:

- `0x515a52` — the berserk handler, already found and already corrected.
- `0x4a4561` — calls both `ParamKeeper_SetParam` and `ParamKeeper_ReadParam`.

Everything else is clean. **The pool-writer enumeration behind `mana`'s
no-regeneration closure, the exp-grant enumeration, the mastery work and the
chance-roll work are all safe**: no invisible code calls any of those functions.
That is a real validation of four earlier conclusions against the exact failure
mode that broke a fifth.

**The one gap that mattered.** `0x004a4570` is a 4.3 KB function Ghidra never
recovered. It writes params 23, 24, 5, 6, 9, 11, 140, 169, 183 and — the
interesting part — **178, 179, 180, 181**, which are on `berserk`'s "proven zero
for an unbuffed character" list.

It does not overturn that claim, and the reason is specific rather than
hopeful: it writes them with `SetParam(slot 2, ctx 5, ...)` and calls the REMOVE
function for the same ids at the same ctx. Slot 2 keyed by a ctx, applied and
removed as a pair, is a temporary modifier — an unbuffed character has no ctx-5
entry, so the params sit at the registry default of 0.

What it did change is the claim's **reasoning**. It was written as "none of the
three baseline functions writes them"; there is now a demonstrable fourth writer,
so that phrasing was load-bearing on a census that cannot be complete. Restated,
it rests on the param registry's defaults plus the observation that every writer
found — visible or not — is a keyed modifier. That form does not require having
seen every writer.

**Shipped** as `client/tools/ghidra/dump_gaps.py`, with `--calls` for exactly the
publish-time question: *does code I cannot see call the functions my enumeration
depends on?* It answers "safe" or names the gap.

**What moved:** no value. A tool that makes the dump's blind spot measurable, a
17.3%/6.1% number for how big it is, four enumerations re-validated against it,
and one claim restated so it no longer depends on a census that cannot be
complete.

## The server's own SQL, and a storage divergence found by reading it (2026-09-16)

Surveying what the 145 invisible gaps actually contain (using the tool shipped
last tick) turned up something better than the gaps themselves. One gap at
`0x0043d6b0` is full of raw SQL, which pointed at a lever this project had never
used: **the binary states its own database schema, in its own words.**

Extracted: **67 distinct SQL statements naming 25 tables**, now in
`docs/protocol/server_sql.md` verbatim. This is the least ambiguous evidence
available here — the server spells out its column names, its join conditions and
which id each table is keyed by, with nothing inferred.

The gap survey is worth recording on its own, since it says what Ghidra missed:
the invisible regions in `0x515xxx-0x51bxxx` are **command and packet handlers**
(one calls `Mastery_LevelUp`, several call `COpenMarketMgr` handlers, several
read from `MsgBuf`), `0x0043d6b0` is DB loading, and 78 of the 145 gaps carry no
identifying evidence at all.

### The finding: the warehouse is per ACCOUNT, not per character

The item containers are keyed by four different owners, and the binary is
unanimous about which:

| table | keyed by |
|---|---|
| `_Inventory` | `CharID` |
| `_InventoryForAvatar` | `CharID` |
| **`_Chest`** | **`UserJID`** |
| `_InvCOS` | `COSID` |
| `_GuildChest` | `GuildID` |

Four separate `_Chest` statements all filter on `C.UserJID` and none mentions a
character id, and the server's own error text is `failed to load user's chest
size [UserJID: %d]` — so the warehouse's **capacity** is an account property
too. Every character on an account opens the same warehouse.

**srrevamp keys its warehouse and its `storage_gold` by character**, so each
character gets a private warehouse. That is a real divergence from the game.

### Why it is recorded and not fixed

Correcting it is a data migration rather than a code change: every existing
account's per-character warehouses have to be merged into one, and a merge that
overflows the slot limit **destroys items belonging to live testers**. The gold
column moves too. That is a supervised change with a backup behind it, not
something to slip into an unattended pass — so it goes on the open list, with
the citation, rather than being half-done tonight.

The alternative — shipping the key change and letting the merge happen
implicitly — would have looked like progress and lost player items.

Two smaller facts came free from the same queries: `_ITEMS.ID64` is the item
INSTANCE id that every container references (bindings and rentals hang off it
via `nItemDBID`), and an empty slot is a real row with `ItemID = 0 or NULL`
rather than a missing one.

**What moved:** no value. A new evidence class opened (the binary's own SQL, 67
statements), a real divergence found and cited in `internal/storage`, and it is
on the open list as a migration to do deliberately.

## The client's 163 param names, joined to the server vocabulary (2026-09-16)

The client dump carries **163 `PARAM_*` localisation keys** — the game's own
English wording for its stat vocabulary. This project has been corrected by them
twice before (`'era'` is parry, not evasion; `'hra'` is attack rate, not hit
rate), so joining the whole set to the server-side vocabulary was overdue.

Written up in `docs/protocol/param_names.md`, **in two tiers on purpose**. A
client key whose suffix *equals* a server tag or code is the game naming that
thing; a key that merely *resembles* one is an abbreviation argument, which is
precisely the reasoning that got characterdata column 79 wrong twice. Twenty
joins are exact; the rest are listed as candidates for a later use-site, not as
answers.

### Two independent confirmations of SHIPPED values

Both arrived by routes that never touched the client, which is what makes the
agreement worth something:

- **`PARAM_MC_COUNT` ↔ `mc`.** `refdata.HitCount`/`HitsFor()` was recovered from
  the `mc` param's `(2, N)` shape with N in 1..5. The client calls it a COUNT.
  The citation is now in `refdata.Skill`.
- **`PARAM_HWAN_TIME_INCREASE` ↔ `hwit` ↔ param 195.** Last tick's berserk
  duration is `GetParam(60) + GetParam(195)` with a base of 60, read out of the
  activation handler's disassembly; `hwit → 195` came from the skill-code join
  over `Skill_ApplyEffectsToParams`. The client names param 195 "Hwan time
  increase". Three derivations from three different places meeting on one id is
  the strongest confirmation this project can get.

### The seven ignored tags, explained

All seven tags the stat dispatcher recognises-and-ignores have client display
names, which settles the narrowing made earlier: they are live game concepts,
not dead strings.

	astr -> PARAM_ASTRAL     atha -> PARAM_ATHANASIA   dura -> PARAM_DURA
	er   -> PARAM_ER         luck -> PARAM_LUCK        rep  -> PARAM_REPAIRING_CHARGES
	soli -> (no key)

`rep` and `dura` now have a *reason* rather than just an observation:
**repairing charges and durability are item condition fields, not character
stats**, so a stat dispatcher skipping them is correct behaviour rather than a
gap. Note the evidence for that is the two keys sitting together in the key set,
which holds regardless of whether `rep` is literally short for "repairing" —
the tier-2 caveat on the name does not weaken the explanation.

Eighteen client names still have no server-side match (`PARAM_ABSORB`,
`PARAM_AGGRO`, `PARAM_REFLECT`, `PARAM_STUN`, `PARAM_SLEEP`, `PARAM_STEALTH`
and the rest) — each is a game concept whose server id is unjoined, and they are
listed as the next thing to mine.

**What moved:** no value. A third evidence class joined to the other two, twenty
exact names for the vocabulary, two shipped values independently confirmed, and
a reason found for why seven tags are ignored.

## Auditing a shipped value that rested on four rows (2026-09-16)

`combat.Monster.DefensePercent` is marked REAL, and `Hub.Spawn` passes the
monster's LEVEL for it, on the grounds that characterdata columns 73 and 74
"equal the monster's level on every row of the ORIGINAL client's table" — with
four examples named. Four rows is the sample size that has misread a
characterdata column **twice** on this project, and the columns feed
`MitigateDamage`, so every blow against every monster depends on it. It was
worth measuring rather than trusting.

**The measurement**, over the extracted tables (which are UTF-16, and the
project's column numbers turn out to be 0-indexed — two probe corrections before
a single number came out):

	12,963 rows with a level        -> 98.34% have both columns == level
	 7,495 MOB_ rows with a level   -> 99.45% have both columns == level, 41 diverge

So the rule is real rather than a coincidence of four rows. **It is not
universal**, and the exceptions are exactly the population a designer would
hand-tune: bosses, uniques and quest clones. `MOB_EU_KERBEROS` is level 110 with
24. `MOB_TQ_WHITESNAKE` is level 110 with 105. The `MOB_QT_*_CLON` quest spawns
give the two columns *different* values — `MOB_QT_01_ARCHER_CLON` is level 29
with 29 and 54 — which the current code cannot express at all, since it passes
one number for both.

**All 11 species this server spawns were checked individually** and every one
holds the equality, so passing the level is correct today. The comment now says
that, with the failure set named, instead of implying the rule is universal.

**What moved:** no value — the number is right for srrevamp's roster. What
changed is its standing: a claim resting on four observations is now a
measurement over 7,495, with the 41 rows that break it identified and the
condition under which the shortcut stops working written down (add a boss or a
quest clone and the real columns have to be carried on `Species`).

Worth recording separately: **the probe was wrong twice before it was right** —
the tables are UTF-16 rather than ASCII, and this project's characterdata column
numbers are 0-indexed rather than 1-indexed. Both failures returned a confident
"0 rows match", which is the shape that gets mistaken for a finding.

## Verifying 55 "grounded" numbers instead of trusting the word (2026-09-16)

Last tick found a shipped value whose GROUNDED label rested on four hand-checked
rows. That is a category of risk rather than one bug: `cmd/server`'s
`monsterSpecs` carries ~55 numbers all labelled real, and a label is a claim
about provenance. Provenance rots — a transcription slip, a column that shifts
between table versions, a species renamed upstream — and every one of those
leaves the comment saying "real" while the number drifts.

So this tick re-derived all of them from the client's own tables.

**The direct columns** — Level (57), MaxHP (59), Defense (71), Critical (78),
for all 11 species: **44 fields, 0 mismatches.**

**The derived one** is where an error would actually hide. `AttackMin/AttackMax`
is not copied from a column; it is two hops — characterdata column 83 names a
SKILL, and that skill's `att` parameter carries the range. Extracting
`skilldata_*.txt` from Media.pk2 and walking the chain:

	MOB_CH_MANGNYANG  col83=160 -> MSKILL_CH_MANGNYANG_ATTACK01  att run (5,200,17,19,100,28003)  spec 17-19
	MOB_CH_GYO        col83=165 -> MSKILL_CH_GYO_ATTACK02                                          spec 35-40
	MOB_WC_EARTHGHOST col83=210 -> MSKILL_WC_EARTHGHOST_ATTACK02                                   spec 219-261

**11 of 11 matched**, and the skill code names corroborate the chain
independently: column 83 for `MOB_CH_MANGNYANG` resolves to a skill literally
called `MSKILL_CH_MANGNYANG_ATTACK01`. The `att` run's third and fourth words
are the min and max, exactly as `skill_params.md` documents.

**Total: 55 verified, 0 mismatched, 0 unresolved.**

**Shipped** as `client/tools/verify_monster_specs.py`, so this is repeatable
rather than a one-off assertion, with both table-reading traps written into its
docstring — the tables are UTF-16, and this project's characterdata column
numbers are 0-indexed. Each of those cost a probe attempt last tick, and both
failed by returning a confident "0 rows matched".

**What moved:** no value, and that is the result. Every grounded number in the
monster table is now verified rather than asserted, the one two-hop derivation
is confirmed end to end, and there is a tool to re-run after anyone edits the
table.

## The client's itemdata shards overlap, and the exporter did not notice (2026-09-16)

Last tick verified the hardcoded monster numbers. The same provenance question
applies to a far bigger surface — the ~15,000 items `export-refdata` reads out of
the client's own tables — except there the risk is not a mistyped constant but a
wrong column index or a bad assumption about the input files.

**The column map checks out.** Verified against independent anchors this project
already records: `ITEM_CH_SWORD_01_A` reads Price **890** and SellPrice **427**
at `fPrice`/`fSellPrice` — exactly the "Copper Sword 890 buy, 427 sell" in
`shop.go` — and `ITEM_ETC_HP_POTION_01` reads MaxStack **5000**, matching the
test fixture. The indices are right.

**The input files are not what the exporter assumes.** Two measurements:

- **itemdata rows come in two widths**, 161 fields (15,338 rows) and 160 (6,224).
  That one is harmless: the 161st is a trailing empty field, so no index shifts.
  characterdata (105) and skilldata (119) are uniform.
- **The shards OVERLAP.** Of 15,338 distinct item ids, **6,224 appear in more
  than one shard**. Comparing numbers as numbers rather than as text, 5,616 of
  those are the same row written differently (`0` against `0.0`) — but **608
  genuinely disagree**. `itemdata_1000.txt` and `itemdata_5000.txt` give
  `ITEM_CH_SHIELD_01_A` a defence of 1.3 and 1.25 respectively; the shields drift
  by a few hundredths across a whole block of ids. One is an older copy of the
  table sitting beside a newer one.

The shards are supposed to be disjoint id ranges. They are not.

**What that meant in practice.** `export-refdata` streamed every row from every
file with no duplicate detection, so a shell glob put both copies in the CSV and
left which one reached the database to the importer's upsert order — that is, to
the order the operator's shell happened to expand `itemdata_*.txt`. The outcome
was correct only by accident, and silently wrong if the glob order changed.

**Fixed**: rows are now collected keyed by id with the LAST occurrence winning —
the same rule the upsert already followed, made explicit instead of accidental —
and the exporter reports how many ids collided and how many of those actually
conflicted. `sameRecord` compares numbers as numbers, because reporting 5,616
formatting differences would bury the 608 that matter.

**What moved:** no shipped number changed. An unnoticed dependency on shell glob
order became a deterministic rule with a diagnostic behind it, and the 608 real
conflicts are now visible to whoever runs the import instead of being resolved
silently.

## skilldata is clean, and a previous validation had run on a partial table (2026-09-16)

Last tick found the client's **itemdata** shards overlap — 6,224 duplicate ids,
608 of them conflicting — and made the exporter deterministic about it. The
obvious next question is whether skills have the same problem, since skill
values drive combat. They do not, and finding that out turned up something else.

**skilldata is clean.** All seven shards pulled from Media.pk2:

	33,632 rows, uniformly 119 fields
	33,632 distinct skill ids
	0 ids appearing in more than one shard

So the overlap problem is specific to itemdata. That is worth stating as a bound:
the fix shipped last tick does not need a twin on the skill side, and a future
reader should not go looking for one.

**The skill column map is confirmed** against an anchor this project already
records independently. `SKILL_CH_SWORD_SMASH_A_01` (id 3) carries the `att` run
`(5, 143, 15, 18, 143, …)`, and `session`'s own test fixture asserts
AttackPercent **143**, DamageMin **15**, DamageMax **18**. The exporter reads run
positions 1, 2 and 3 — exactly those three.

### The find: a validation measured on a partial extraction

`attackParam` scans the whole row for the `att` literal rather than walking the
Param block, and its comment justifies that with a measurement: the literal never
appears before column 69 and never twice, "0 of **31,605** rows". That is a
careful, well-made argument — and it ran on however many skilldata shards
happened to be on disk at the time. Only `skilldata_5000.txt` was extracted when
this tick started.

Pulling all seven and re-running it:

	rows scanned              33,632   (was 31,605 -- 2,027 rows unmeasured)
	rows carrying 'att'       30,064
	rows with 'att' before 69      0
	rows carrying 'att' twice      0
	lowest column it appears at   69

**Both claims hold exactly on the complete table**, so the conclusion was right —
but it was right on 94% of the data and stated as though it were all of it. The
comment now says 33,632 and records why the figure moved.

This is the same failure shape as the dump-gap work two ticks ago: a census is
only as complete as the corpus it ran over, and the corpus is easy to assume.
There the missing 17% was code Ghidra never recovered; here it was 6% of a table
nobody had extracted.

**What moved:** no value. skilldata proven free of the overlap that afflicts
itemdata, the skill column map confirmed against an independent anchor, and a
previous validation re-run on the full corpus with its numbers corrected.

## "114 untouched client tables" surveyed, and a quest disclosure corrected (2026-09-16)

The open list has carried "114 untouched client data tables" as a bare count for
a long time. Turning it into something actionable: list what Media.pk2's
`textdata` actually holds and cross-reference against the subsystems srrevamp
still calls own design.

That immediately contradicted one of them.

**`internal/quest` said** its invented catalog existed because "no real
_RefQuest-equivalent data has been catalogued yet to import from". Media.pk2
carries two quest tables, and the claim had evidently never been checked:

| table | rows | what it holds |
|---|---|---|
| `questdata.txt` | 697 | quest id, code name (`QNO_*`), and the `SN_*` localisation keys for name, payment, conditions and NPC |
| `questcontentsdata.txt` | 989 | quest code, display name, a category (0/1/3), a **prerequisite quest code** on 373 rows, up to eight `SN_CON_*` step keys, and a numeric field on 442 rows |

So the quest **graph** is real and importable — ids, code names, prerequisites
(`QNO_CH_PRIEST_1` requires `QNO_WC_PRIEST2_1`), and step counts
(`QNO_CH_PRIEST_1` has eight). The `SN_*` keys resolve to real text through the
same textdata mechanism the NPC chat already uses.

**What is genuinely missing** is the part that would let the catalog be replaced
wholesale: machine-readable objective TARGETS. A step is a localisation key
pointing at human text, not a `(monster id, count)` pair, so "kill N of monster
X" still cannot be imported. That much of the original disclosure was right — it
was the blanket "no data" that was wrong.

**One thing deliberately not claimed.** The numeric field on 442 rows runs
**5..110**, exactly this client's character level range, clustering at 101-110.
A level requirement is the obvious reading. It is recorded as a range argument
with no use-site behind it and left unasserted — that is the shape that produced
the wrong answer for characterdata column 79 twice.

**What moved:** no value; srrevamp's two invented quests stay, because the piece
needed to replace them genuinely is absent. What changed is that the reason is
now accurate and points at the 697 real quests that ARE importable, instead of
claiming nothing exists.

## A real bug found by finishing the table survey: the catalog shadowed two real skills (2026-09-16)

Finishing last tick's cross-reference of srrevamp's own-design subsystems against
the client's tables. `learnableskill.txt` turns out to be small and unrelated
(205 rows of NPC-to-skill teaching pairs), but checking it raised a sharper
question about `skill.Catalog`, whose disclosure said to "extend once real
_RefSkill data informs what should exist" — and real skill data IS now imported,
33,632 rows of it.

**The collision.** `skill.Catalog` occupies ids **1 and 2**. In the client's own
skilldata:

	id 1  SKILL_PUNCH_01           the unarmed attack
	id 2  SKILL_CH_SWORD_BASE_01   the basic sword swing
	id 3  SKILL_CH_SWORD_SMASH_A_01

so the two invented entries sit exactly on top of two of the most-used skills in
the game.

**The bug.** The LEARN path already preferred refdata and fell back to the
catalog. The USE path had the order reversed — catalog first. So on a server with
real refdata loaded, a player learned the real skill 2 and then **used an
invented "Whirlwind" with a flat +10 bonus instead of the real 60%-of-weapon
swing**. The two paths disagreed about what skill 2 even was.

This project already knew skill 2 is the basic swing: `skilldamage_test.go` has
asserted "SKILL_CH_SWORD_BASE_01: 60% and no flat damage" for a while. The fact
and the bug sat next to each other without meeting.

**Fixed** by making both paths try refdata first and fall back to the catalog,
which is the rule the rest of the project already follows — `shop.Price` states
it outright: "The real number is what a player pays, so it wins."

The catalog's ids are deliberately NOT renumbered out of the real range:
renumbering would orphan every character that has already learned 1 or 2, and
the ordering fix makes the collision harmless.

`TestRealSkillsWinOverTheOwnDesignCatalog` pins the two facts that make this a
bug rather than a preference — the catalog really does occupy the colliding ids,
and the real basic swing really is a sub-100 percentage with no flat damage, so
the shadowing changed damage rather than just naming.

**What moved:** a behavioural fix. Skills 1 and 2 now resolve to the game's own
skills on any server with refdata loaded, instead of to invented ones.

## Closing the bug class: every real-vs-fallback precedence audited (2026-09-16)

Last tick's bug was not really about skills. It was a **precedence inversion**:
invented data consulted before real data. That is a class, not an incident, so
this tick audits every place srrevamp makes that choice.

**Result: the skill path was the only inversion.** Every other decision prefers
real data, verified in the code rather than from the comment claiming it:

| decision | order | correct |
|---|---|---|
| `shop.Price` | real `item.Price` first, formula second | yes |
| `shop.SellValue` | real `SellPrice` first, fraction second | yes |
| kill experience | `levelTable.KillExp` overrides `monster.ExpReward` | yes |
| `combat.RollGold` | falls back to the flat only when the range is absent (`max <= 0 \|\| max < min`) | yes |
| monster attack | `raw := monster.Attack`, overridden whenever `AttackMax > 0` | yes |
| mastery cost | level table's column 2 first, disclosed cost second | yes |
| skill damage | real `att` params first, disclosed per-level second | yes |
| **skill resolution** | **catalog first** — fixed last tick | was NO |

That bounds the damage: one inversion, found and fixed, and nothing else of the
same shape.

### A latent instance of the same collision, recorded before it bites

`quest.Catalog` uses ids **1 and 2**. The client's `questdata.txt` gives those to
real quests — id 1 is `QEVENT_GUIDE`, id 2 is `QTUTORIAL_CH`, the Chinese
tutorial — and real quest ids run **1..1051 with no gap at the bottom**, so any
small invented id collides.

It is **not** a bug today, and the reason is specific rather than lucky: nothing
imports real quests, because the objective TARGETS are not in the client tables
(established last tick). There is no real quest data to shadow. It becomes a bug
the moment the quest graph is imported — which last tick showed is possible.

Written into `internal/quest` with the real quest names and the instruction that
matters: when real quests are wired in, fix it the way the skill path was fixed —
**try the real table first and fall back to the catalog** — rather than
renumbering, which would orphan existing progress.

**What moved:** no value. A bug class opened last tick is now bounded by an audit,
and the one remaining instance of it is documented at the site with the fix
prescribed in advance.

## The stat-tag vocabulary is complete: magicoption.txt names every tag (2026-09-16)

Fifteen tags were left explicitly unresolved by the dispatcher passes, with the
instruction not to guess them from their abbreviations. The client's
**`magicoption.txt`** names all fifteen outright — it stores each item
magic-option's stat tag as a big-endian multi-char literal in the same row as its
`MATTR_*` code name, so the mapping is stated rather than inferred.

	rsli -> MATTR_RESIST_SLEEP        rsti -> MATTR_RESIST_STUN
	rfei -> MATTR_RESIST_FEAR         rdii -> MATTR_RESIST_DISEASE
	rcsi -> MATTR_RESIST_CSMP         nrep -> MATTR_NOT_REPARABLE
	rein -> MATTR_REINFORCE_ITEM      reis -> MATTR_REINFORCE_ITEM_SET
	duru -> MATTR_DUR                 hr   -> MATTR_HR
	ape  -> MATTR_APE                 intj -> MATTR_INT_3JOB
	inta -> MATTR_AVATAR_INT          luca -> MATTR_AVATAR_LUCK
	mdia -> MATTR_AVATAR_MDIA

Five of them are resistances, which is why they never surfaced in the damage
paths the earlier passes walked. **56 tags in total** appear in the table; the
full map is in `param_tags.md`.

### It settles an argument, and corrects a guess this project floated

The seven tags `Stat_ApplyTaggedModifier` recognises and ignores were explained
as **item condition fields rather than character stats**. That explanation rested
on `PARAM_REPAIRING_CHARGES` sitting beside `PARAM_DURA` in the client's key set
— suggestive, and labelled tier-2 at the time. The table settles it with the
game's own naming:

	dura -> MATTR_DEC_MAXDUR    rep  -> MATTR_REPAIR    nrep -> MATTR_NOT_REPARABLE
	soli -> MATTR_SOLID         astr -> MATTR_ASTRAL    atha -> MATTR_ATHANASIA
	luck -> MATTR_LUCK

Decrease-max-durability, repair and not-repairable are unambiguously item
properties. A stat dispatcher skipping them is correct behaviour, now on data
rather than on an abbreviation argument.

**And it corrects one guess.** The superseded paragraph in `param_tags.md`
floated "`dura` for a duration, say" while warning against exactly that kind of
reading. `dura` is **durability**. The warning was right and the parenthetical
was wrong; both are now marked.

`PARAM_REPAIRING_CHARGES` → `rep` is promoted out of tier 2 in
`param_names.md`, since MATTR_REPAIR names it directly.

**What moved:** no value. The tag vocabulary went from 31 resolved + 15 unknown +
7 argued to **56 named from the game's own data**, one floated guess is corrected
in place, and a tier-2 caveat is retired.

## An item-effect code vocabulary, and a naming probe that had to be thrown away (2026-09-16)

Last tick's win came from a client table naming a code vocabulary. Trying the
same for **item effects**, after `BCS1` turned up in the item-use dispatcher two
ticks ago with nothing behind it.

**Two clean negatives first**, both worth recording so they are not retried:

- `itemeffect.txt` is not the vocabulary. It is 46 rows mapping item code names
  to *visual* skill-effect code names, nothing to do with mechanical effects.
- **itemdata has no param block** of the kind skilldata has. Censusing every
  2-4 character multi-char literal across all 15,338 item rows from column 100
  on yields 7 strings, all low-count decoding artefacts (`dddP`, `u0`, `lppu`).
  The skill vocabulary's technique does not transfer to items.
- The codes are not in **any** extracted client table. Like drop tables and quest
  objectives, item-effect codes are server-side.

**The vocabulary, from the binary itself.** Censusing the four-byte comparisons
in the two item-use dispatchers (`GObjPC::FUN_0049f090` and `FUN_0049f590`) and
decoding them big-endian gives **eight item-effect codes**:

	BCS1  BFI1  PSU1  UIL1  UIU1  UQL1  USL1  USU1

These are solid — they are literal `cmp` operands in the dispatch, the same shape
that yielded the stat-tag vocabulary.

**One is named.** `BCS1` gates `INC_INVENTORY_SIZE`: its branch calls
`GObjPC::FUN_00864aa0`, which compares against that string via
`mov ecx, 0xae57d4`. That is a direct reference inside the branch, not a
proximity guess.

### The probe I threw away

Trying to name the other seven the same way — walk each code's branch, follow its
calls, report the first string those functions reference — returned
`INC_INVENTORY_SIZE` for **four different codes**. That is not a finding; four
codes do not share one meaning. The 80-instruction window was bleeding across
branch boundaries into the same neighbouring helper.

It is recorded because the output looked exactly like a result: a tidy table with
plausible entries, produced by a method that had just worked elsewhere. The tell
was the uniformity, not anything in the individual rows. Seven codes stay
unnamed.

**What moved:** no value. An eight-entry item-effect vocabulary recovered from
the dispatcher, one entry named with a direct citation, three negatives bounded,
and a false naming pass discarded before it reached a doc.

## The discarded naming pass, redone correctly — and shipped as a tool (2026-09-16)

Last tick recovered eight item-effect codes (`BCS1`, `BFI1`, `PSU1`, `UIL1`,
`UIU1`, `UQL1`, `USL1`, `USU1`) and threw away the pass that tried to name them,
because a fixed 80-instruction window gave four of them the same answer. This
tick redoes it with the method that works, and ships it.

**The fix** is the one the tag-dispatcher work already used: scope the walk to
the branch. Enter at the comparison's `je` target, follow jumps, stop on reaching
any other code's comparison site or a `ret`. Follow calls exactly one level,
because a branch often names itself only inside a helper.

**The control passes.** Scoped correctly, exactly **one** code resolves —
`BCS1 -> INC_INVENTORY_SIZE`, the one independently verified by a direct string
reference — against four last tick. The other seven return nothing, which is the
honest answer rather than a borrowed one.

**Three further avenues closed**, so nobody retries them:

- the codes appear in **no** extracted client table;
- the server's own SQL has no effect table naming them;
- the `.rdata` strings that look like the codes (`PSUVW`…) are x86 instruction
  bytes, not data.

Characterising the seven by their **calls** instead of their strings does not
help either: the branches reach only `Assert_BreakIfDebugger`,
`__security_check_cookie` and a singleton getter, delegating the actual work to
unnamed helpers. Two of them (`PSU1`, `UIU1`) also touch a time function, which
hints at a timed effect and is **not** recorded as a finding — it is proximity
again, and proximity is what produced the discarded table.

**Shipped** as `client/tools/ghidra/dispatch_walk.py`, with the failure it exists
to prevent written into its docstring and a built-in warning: if every resolved
code returns the same answer, that is the signature of a walk escaping its
branch, not of codes sharing a meaning.

A first version of the tool **failed its own control** — it read only strings
referenced directly in the branch and so missed `BCS1`, whose name lives in a
helper. Caught by running the control before committing; the call-following fix
is in.

**What moved:** no value. Seven codes stay unnamed on purpose, one is confirmed,
and the method that keeps getting this wrong is now a tool that checks itself.

## The skill-code census was 58% noise, and two consumers are pure guards (2026-09-16)

Reading `FUN_00593f50` to name the cure/heal codes turned up a false positive
that matters more than the codes did: line 52's `(**(code **)(iVar3 + 0x254))(…)`
is a **vtable call at offset 0x254**, not a read of the `kb` field. The census
that selected this project's skill-code lever counts those as evidence.

**Measured dump-wide over every skill-field offset:**

	any occurrence      2,851
	VTABLE calls        1,670   (58.6%)
	typed FIELD reads     664   (23.3%)

`er` (0x27c) is the extreme — **407 vtable calls against 4 real reads**. More
than half of what the census treated as evidence was a virtual call unrelated to
skills.

**Applying both corrections** — typed reads only, then weighting by codes read
more than once (the guard-chain fix found earlier) — gives the first honest
consumer ranking. Two results stand out:

- **`FUN_00589d20` (24 codes) and `FUN_00589f10` (16) drop off entirely.** Every
  one of their codes is read exactly once: they are pure guard functions. The
  naive ranking put them at the top, and a future tick would have been spent
  reading functions that do nothing with those codes.
- **`Skill_ApplyEffectsToParams` falls from 34 distinct codes to 23**, tying
  rather than leading. The right lever was picked partly by luck.

**What survives.** The code → param join is unaffected: it was validated by six
independent controls that reproduced exactly, and its mechanism — pairing a field
read with the `SetParam` annotation that follows — cannot be produced by a vtable
call. The *selection* was contaminated, not the join.

**What was not claimed.** Three functions are each dominated by a single code —
`FUN_0091f330` by `lfst` (8 reads), `FUN_00593f50` by `heal`/`resu`,
`FUN_00586700` by `tel2`/`tele` — which reads like life-steal, healing and
teleport handlers. Neither of the first two carries a confirming string, and
`FUN_0091f330` is a vtable slot in the quest band. Naming a function from its
dominant code's abbreviation is exactly the reasoning this project keeps
rejecting, so all three stay unnamed.

**What moved:** no value. A census method leaned on for several findings is now
measured rather than assumed, two apparent top consumers are exposed as guards,
and the one conclusion built on it is shown to rest on controls rather than on
the contaminated ranking.

## Two more skill codes: mechanic recovered, name withheld (2026-09-16)

Using last tick's corrected consumer ranking — typed reads only, weighted by
codes read more than once — to read what `Combat_ResolveDamage` genuinely acts
on. `tant` (293 skill rows) and `tnt2` (550) each get 4 real reads.

**The mechanic, from the use-site:**

```c
acc = state[0x1c] + src[0x20];
acc = round(acc * (code[1] / 100.0 + 1.0));
state[0x1c] = code[0] + acc;
```

Each code carries a **(flat, percent) pair** — scale by `1 + percent/100`, then
add the flat amount. Both have run length 3 (code plus two words), so every word
is accounted for and none is spare, which is a decent internal check on the
reading.

**They are alternatives.** `if (tant == 0) { if (tnt2 != 0) … } else …` — `tant`
takes precedence and `tnt2` applies only in its absence, with both arms computing
the identical formula. The codes differ in *when*, not in *what*.

**The name is withheld deliberately.** The field they scale, `state[0x1c]`,
belongs to an object built a few lines earlier in the damage path (fields
0x24-0x48 filled, including the float 2.0 at +0x48) — the shape of a timed
status-effect record, not the blow's damage, which lives in the separate fields
`da` scales. Which quantity `+0x1c` holds is not settled, and the client's
`PARAM_TIME_BOMB` is a tempting match for `tant`/`tnt2` that is pure
abbreviation reasoning. Recorded with the mechanic and no name.

**What moved:** no value. Two codes go from unidentified to
mechanic-known-semantic-unknown, which is a real step and an honest stopping
point — and the corrected ranking is what pointed at them rather than at the two
guard functions the old ranking ranked first.

## The damage floor of 1 is the game's own, not this project's (2026-09-16)

Chasing what `state[0x1c]` holds — the field `tant`/`tnt2` scale, left open last
tick — ran into something more valuable a few lines away.

`combat.MitigateDamage` floors a blow at 1, and its comment said: *"The floor
stays at 1 here rather than the game's 0. That is own design and disclosed."*
**That is wrong about the game**, and wrong in the direction that makes srrevamp
look less faithful than it is.

The zero in the old reading is real but is not the end of the pipeline.
`Formula_MitigatePhysicalDamage` clamps its result at 0; then
`Combat_ResolveDamage` floors the finished blow:

```c
if (damage == 0) {
    if (local_d0 == 0) { damage = 1; }
    else { /* a different path for skills with no attack parameter */ }
}
```

**`local_d0` decides which**, and it is set to 1 only when the skill carries
NEITHER `att` (0x230) nor `ck` (0x248) — a buff or utility skill. So
`local_d0 == 0` is exactly the case of a blow that HAS an attack parameter,
which includes every ordinary swing (`SKILL_CH_SWORD_BASE_01` carries `att` at
60%). For those the engine guarantees at least 1 damage.

So srrevamp's floor is **recovered, not invented**. The earlier note read the
mitigation clamp and stopped there, missing a floor applied one stage later —
which is why the comment now says where in the pipeline each clamp lives, rather
than just naming a number.

`TestDamageFloorIsTheGamesOwn` pins it, including a sweep asserting no
combination of raw damage and absorption can drive the result below 1.

**A note on how this was found.** It came out of a question deliberately left
open — "what is `state[0x1c]`?" — rather than from a search for it. That
question is still open: `+0x1c` accumulates, is floored at 1 under a *different*
condition, and belongs to an object whose class is not identified. The floor
finding sat four lines above it.

**What moved:** no number. A value shipped as own design turns out to be the
game's, which is the direction this project wants corrections to run, and the
comment now carries the pipeline position that made the earlier reading wrong.

## Magical weapons dealt 1 damage: srrevamp models one of the engine's two damage halves (2026-09-16)

Last tick's floor correction came from reading one stage of the damage pipeline
and stopping. That suggested a systematic question — **is srrevamp's damage
ORDER also incomplete?** — so this tick traced every touch of the damage field
in `Combat_ResolveDamage`.

**The engine computes TWO damage halves and sums them:**

```c
dmg[0x28] = Formula_MitigatePhysicalDamage(...)    // physical
dmg[0x24] = Formula_MitigateMagicalDamage(...)     // magical
...
damage    = dmg[0x28] + dmg[0x24]
```

srrevamp reads only `PhysAttackMin/Max`. `MagAttackMin/Max` is imported into
`refdata.Item` and **never used**.

**Measured over a real client's itemdata**, of 2,927 items carrying any attack
value:

	physical only   1,049
	magical only      828
	both            1,050

So **828 items — every staff and magic weapon — have no physical damage at
all.** Reading only the physical columns gives them min = max = 0, the blow
lands on `MitigateDamage`'s floor, and the weapon does **1 damage**.

### What shipped, and what deliberately did not

Fixed: when a weapon has no physical damage, the magical columns are used.
Items that carry physical damage are untouched.

**Not fixed: the sum.** Three sites zero one half or the other — a skill flag,
and bits 4 and 8 of the ref object's `+0x2b4`. How often a blow really carries
both is a question about flags this project has not read. Summing them for the
1,050 items that carry both would roughly double their damage — including the
Copper Sword, whose magical 25-28 exceeds its physical 15-16 — on an unread
condition. That is a balance change dressed as a fix, on a server with live
testers.

What is unambiguous regardless of those flags is that a weapon with no physical
damage should not deal 1. That much is shipped; the rest is written down with
exactly what has to be read before anyone acts on it.

**What moved:** magical-only weapons now deal their real damage instead of 1.
The larger question — whether a blow sums both halves — is recorded as open with
the deciding flags named, rather than guessed.

## 2026-09-16 — the damage-half question, settled; and two wrong rows in the skill-param table

The previous entry named exactly what had to be read before the damage sum could
be acted on: *"a skill flag, and bits 4 and 8 of the ref object's `+0x2b4`"*.
Both have been read. The answer closes the question, and it also **corrects the
framing of the previous entry**, which was aimed at the wrong object.

### `+0x2b4` is a skill param, not a "ref object" field

Grepping writers of `+0x2b4` landed inside `SkillGlobal::RefSkill_ParseParams`,
the skill parameter parser. So `+0x2b4` is a *skill* field, filed there by the
param code `pw` (`0x00007077` — a two-character tag; Ghidra renders the compare
as a 16-bit value and `005879c1` shows it is a full `cmp edx,0x7077`).

### The bits mean physical and magical, and two sources say so

`Combat_ResolveDamage` computes two halves and sums them:

	rec[0x28] = Formula_MitigatePhysicalDamage(...)
	rec[0x24] = Formula_MitigateMagicalDamage(...)
	rec[0x20] = rec[0x28] + rec[0x24]

and each formula returns 0 unless its bit is set in **`att` value[0]** — bit 4
for physical (`0040e450`), bit 8 for magical (`0040e830`). Independently, their
raw-damage builders read different stats: `0040db50` reads param
`(max ? 1 : 0) + 13`, `0040dc10` reads `+ 15`, and the recovered param registry
already named 13/14 "phys damage low/high" and 15/16 "mag damage low/high"
without reference to any of this.

`att` value[0] is the word this project had been reading *past* for a year while
consuming the three numbers behind it.

### The sum was never the risk

Measured over the real table — 36,389 skilldata rows, 31,605 carrying `att`:

	 5 {1,4} 17,075 physical      10 {2,8}  6,971 magical
	 6 {2,4}  4,055 physical       9 {1,8}  2,528 magical
	                               8 {8}      966 magical
	 0/1/2       10 neither

**Zero rows of 31,605 set both bit 4 and bit 8.** The two halves are mutually
exclusive by authoring, so the engine's sum always has exactly one live term.

The previous entry's worry — "summing them for the 1,050 **items** that carry
both would roughly double their damage" — counted items, and the gate is on the
**skill**. The caution was right; the reason given for it was not.

### `pw` inverts the same mask, and only two skill families use it

`pw`'s bits *suppress* rather than enable: bit 4 zeroes the physical half, bit 8
the magical one, applied to the base blow and to a second damage record. All 61
`pw` runs in the real table belong to Cold or Fire "Wall" skills —
`SKILL_CH_COLD_BINGBYEOK_*` carries 7 (kills physical),
`SKILL_CH_FIRE_HWABYEOK_*` carries 11 (kills magical). Whether the holder hangs
off the attacker or the target is **not settled** and is left open rather than
asserted.

A third code shares the vocabulary: `skc` (field `0x490`) is AND-ed against the
mask as a filter — `(*att_v0 & *skc_v0) != 0` — so `att` writes it, `skc` tests
it, and `pw` inverts it. One encoding, three consumers.

### Two rows of the recovered param table were wrong

Chasing `pw` found it already in `docs/protocol/skill_params.md` with field
`0x434` — which belongs to the *next* tag, `rt`. A second walker was written
that follows each `je` to its target instead of reading the fall-through. It
agrees with the table on **88 of 90** fixed-run codes and disagrees on two:

	pw   0x434 -> 0x2b4      (0x434 is rt's,  which was missing)
	skc  0x584 -> 0x490      (0x584 is spi's, which was missing)

Both corrected, both missing tags added, both hand-verified in the disassembly.
The two errors share a cause: `pw` and `skc` are the only codes whose handler
*rewrites the value it points at*, and that shape defeated the extractor's
handler detection. The failure had a signature and the signature is exhausted.

The walker also finds ~55 further tag comparisons in neither table. That is
recorded in `skill_params.md` as a **lead, not a finding** — it has already
over-reported once (it read the in-handler `cmp edx,0x4` value tests as tags
until constrained), so the vocabulary size stays open.

### What shipped

- `refdata.Skill.AttackType` — `att` value[0], exported as a strict-suffix CSV
  column 28 and persisted in SQL. An export predating it reads 0.
- `combat.AttackType` with `IsPhysical`/`IsMagical`/`Known` and the whole
  recovery written where it is used, plus tests pinned to the measured row
  counts so a later edit that swaps the bits fails loudly.
- The mask threaded through `performAttack`; a magical skill now draws on the
  weapon's magical attack columns.

### What deliberately did not ship

Routing a magical skill to the magical columns **unconditionally**. Of 1,582
real items carrying any attack value, **574 have physical damage and no magical
at all**, so an unconditional reroute drops every caster holding one of those to
the floor of 1. Whether that is the engine's behaviour turns on whether
Intellect feeds params 15/16 the way Strength feeds 13/14 — which has **not**
been read.

So the magical columns are used only where they exist: the 560 items carrying
both now answer a magical skill correctly, the 574 physical-only ones are
untouched. Strict improvement, nothing to regress.

**What moved:** the damage-half question is closed with a measurement instead of
a guess, one of the three "unrecoverable" param codes turned out to be two
*wrong* rows rather than missing ones, and the skill-param table gained two
codes and lost two errors.

**Still open:** whether Intellect feeds params 15/16; whether `pw`'s holder is
the attacker or the target; the ~55 unverified tag comparisons.

## 2026-09-16 (later) — Intellect feeds the magical half, and a real bug it exposed

The previous entry left one named blocker: *"whether Intellect feeds params
15/16 the way Strength feeds 13/14"*. It does, and reading it found a bug in the
code that entry had just shipped.

### The parameter graph, read edge by edge

`GObjPC_InitStats` (`004e3200`) declares the chain explicitly — these are the
binder's own annotated calls, not an inference from symmetry:

	 1 (str) -> 17 -> 13     phys low      34 -> 17 at slot 3
	 1 (str) -> 18 -> 14     phys high     36 -> 18 at slot 3
	 2 (int) -> 19 -> 15     mag low       35 -> 19 at slot 3
	 2 (int) -> 20 -> 16     mag high      37 -> 20 at slot 3

Param 2 carries the game's own tag `int` in the recovered registry, so Intellect
is named by the binary rather than by its position in the pair. Slot 3 is the
percent scale, so each derived term is `stat * reinforce / 100`.

### The bug

`session.attackerDamage` passed **Strength** into the magical columns. It had
done so since the magical-weapon fallback shipped, and the previous tick
propagated it into the new mask-driven path. Fixed: the magical half scales with
Intellect.

Worth stating plainly — **symmetry alone would not have justified this fix**.
"Str feeds physical, so Int must feed magical" is precisely the suggestive curve
this project has been wrong on before. The edge list is a use-site; that is why
it was read.

### The selection now lives in one place

The rule was inline in `session.attackerDamage` with a **copy of itself in the
test**, and the copy was already stale: it lacked the damage-type branch added
the tick before, so the test went on asserting the old rule after the rule
changed. Both are replaced by `combat.WeaponRange`, which the test now calls
directly. The Intellect guard was checked by reintroducing the bug — it fails
with `got 110-110, want 50` and passes when restored.

### The unconditional reroute: now fully grounded, still not shipped

The previous entry deferred this on an unread step. That step is read, and it
says the reroute would be **faithful**:

`Char_PublishCombatStats` (`00497830`) writes params 34-37 **unconditionally** —
the only branch substitutes `0.0`, it never skips the write. So a physical-only
weapon writes param 35 = **0** rather than leaving it at the registry default of
**100**, slot 3 scales Intellect to nothing, and the magical half really is 0.
(The default mattered: a param nothing writes falls back to its default, and 100
would have meant a 1.0 scale and Intellect flowing through. It is written, so it
does not.) Measured: all 574 physical-only items carry no magical reinforce and
all 448 magical-only carry no physical reinforce — no exceptions either way.

It is still not shipped, for a different and better reason than last time. The
engine can afford to give 1 damage there because **it refuses the cast first**:
skills carry `ReqCast_Weapon1/2` (skilldata columns 50/51), and srrevamp does not
model them — `refdata/skill.go` says so outright. Shipping the penalty without
the prevention would hand a tester holding a sword 1 damage from a skill the
real game would not have let them cast.

**What moved:** the magical half now scales with the right stat, one grounded in
the engine's parameter graph; the selection rule and its test are no longer two
copies; and the reroute's blocker changed from "a fact nobody has read" to "a
feature that has to be built first".

**Next step, now unblocked and named:** export `ReqCast_Weapon1/2` and gate skill
use on the equipped weapon. That is the last thing between here and the faithful
magical damage path.

## 2026-09-16 (third) — the weapon gate, and a retraction of the previous entry

The previous entry named its own next step: *"export `ReqCast_Weapon1/2` and gate
skill use on the equipped weapon"*, and justified deferring the magical reroute
on the claim that **the engine refuses the cast first**. Reading the gate
disproved the justification. Both reasons that entry gave were wrong, and the
reroute has now shipped.

### The gate, named by the binary

The skilldata row loader `SkillGlobal::FUN_005893e0` validates every row and
names the field in its own error string:

	if (skill[199] == '\0' || skill[200] == '\0')
	    FUN_00936640(0x2000000, "ReqWeapon Error [RefSkill ID: %d]", skill[4]);

So `CRefSkill+199/+200` are the two required-weapon bytes, and **0 is invalid** —
the loader refuses it. The check is `FUN_0058d480`: the equipped weapon's code is
`TID >> 11`, `0xff` is an unused slot, both `0xff` means no requirement, an empty
hand reads as **1**, and a mismatch returns error **0x300d**.

Columns 50/51 carry them. The memory note listed those columns from a schema
listing; they are now confirmed by the data confirming itself — grouping 36,389
real rows by the family in their `Basic_Code` puts every one of 24 families on
the code its own name says it should have (`SKILL_EU_AXE` → 9, `SKILL_EU_STAFF` →
11, `SKILL_CH_SPEAR` → 4 and 5, …). Full table in
`docs/protocol/skill_params.md`.

### The retraction

**"The engine refuses the cast first."** It has the gate, but **4,144 of the
10,465 magical attack skills require no weapon at all** — both bytes `0xff`,
including every CH elemental nuke. For 40% of exactly the skills in question the
engine does not refuse, so the justification did not hold.

**"It would drop a caster holding a sword to 1 damage."** Also wrong. The
skill's own flat `att` damage is added to the bound inside the builder
regardless of the weapon (`0040dc10` reads the descriptor's `+0xc`), and across
those 4,144 rows the median flat is **2,068** against a median percent of
**263**. The weapon's contribution is the small term, not the blow. srrevamp
already adds that flat separately as `damageBonus`, so the shape matched all
along.

What survives from that entry is the part that was actually read: the magical
half draws params 15/16, `Char_PublishCombatStats` writes params 34-37
unconditionally (the only branch substitutes 0.0, it never skips the write), so
a physical-only weapon writes param 35 = 0 rather than inheriting the registry
default of 100. The weapon's share of a magical blow really is zero. That was
right; the two conclusions drawn around it were not.

### What shipped

`combat.WeaponRange` now routes a magical blow to the magical columns
**unconditionally** — the weapon contributes nothing when it has no magical
attack, which is the engine's behaviour. The old `item.MagAttackMax > 0`
condition remains only for a blow with **no known mask**, and is now labelled a
stand-in rather than a rule: the engine has no maskless blow, because a plain
swing runs the weapon's own basic-attack skill and that skill carries the
matching mask. srrevamp's `OpAttack` passes `AttackPhysical` for every weapon, so
the fallback stands in for picking the right basic skill, and disappears when
`OpAttack` resolves one.

### Method note

This is the third tick in a row where the *previous* tick's deferral reasoning
turned out to be wrong while its measurements held. The pattern is consistent:
the numbers read out of the binary survived, and the sentences about what they
implied for srrevamp did not. Deferrals deserve the same "what would show this is
wrong" treatment as findings — all three would have been caught in one tick by
asking "how many real rows does this claim actually cover?" before writing it
down.

**What moved:** the magical damage path is complete and faithful; the weapon gate
is fully recovered with its vocabulary confirmed 24 ways.

**Next step:** export item TIDs so the gate can be wired -- `refdata.Item` carries
none today, which is the only thing between here and enforcing ReqCast_Weapon.

## 2026-09-16 (fourth) — the weapon gate, wired

The previous entry named its next step as "export item TIDs, the only thing
between here and enforcing ReqCast_Weapon". **That premise was wrong in the
cheapest possible way: the TIDs were already exported.** `refdata.Item` has
carried `TypeID1..4` at CSV columns 20-23 with SQL columns to match for as long
as `ITEM_FORMAT.md` has existed. The compiler said so within a minute of trying
to add them ("TypeID1 redeclared"), which is the good version of this mistake --
but it is the fourth consecutive tick whose stated next step contained a claim
nobody checked. Checking took one grep.

### TID4 is the weapon code, and itemdata confirms the vocabulary

The engine's item tests use paired masks all over the binary -- `& 0x780` for
bits 7-10 and `& 0xf800` for bits 11-15 -- which fixes the packing: **TID3 at
bits 7-10, TID4 at bits 11-15**. So `FUN_0058d480`'s `equippedTID >> 11` reads
**TypeID4**, not a flat weapon enum as the previous entry's table implied.

Every weapon row in real itemdata is `(TypeID1, TypeID2, TypeID3) = (3, 1, 6)`,
and under that category each family occupies exactly one TypeID4 -- 112 rows
apiece, no family split:

| 2 CH sword | 3 CH blade | 4 CH spear | 5 CH tblade | 6 CH bow | 7 EU sword | 8 EU tsword |
| 9 EU axe | 10 EU darkstaff | 11 EU tstaff | 12 EU crossbow | 13 EU dagger | 14 EU harp | 15 EU staff |

plus **16 = `ITEM_FORT_FORTRESS_HAMMER`/`_AXE`**, which matches
`SKILL_*_FORTRESSWEAPON` -> 16 from the other table and is the code the engine
special-cases into `GObjPC::FUN_004f1130`.

**This corrects three names the previous entry invented.** It read the weapon
names off the *skill* families that require them, and got: 10 "wand" (really
`DARKSTAFF`), 11 "staff" (really `TSTAFF`), 15 "cleric rod" (really `STAFF`).
The skill family that requires a code is not the item's name for it -- exactly
the "a name is not a use-site" rule, applied one table too early.

Code 1 is confirmed from a third direction: **`SKILL_PUNCH_01` requires exactly
code 1**, and the engine's `if (code == 0) code = 1` makes an empty hand satisfy
it. (TypeID4 1 under the weapon category holds fireworks, 10 rows -- so 1 is not
a weapon family, it is the "nothing wielded" slot.)

### What shipped

- `refdata.Skill.ReqCastWeapon1/2` -- skilldata columns 50/51, exported as
  strict-suffix CSV columns 29/30 and persisted in SQL.
- `combat.SkillAllowsWeapon` reproducing `FUN_0058d480`, with the 16 codes named
  from **itemdata's** own families, and a table test walking each branch.
- The gate enforced in the skill-use path: a mismatch answers "wrong weapon for
  this skill" instead of casting.

### Two compatibility rules, both load-bearing rather than defensive

**Zero requirement bytes permit the cast.** Zero is *invalid* in the real table
-- the row loader refuses it with "ReqWeapon Error" -- so a zero here can only
mean an export predating the columns. Refusing on it would lock every skill on
every existing deployment.

**An unreadable weapon permits the cast, but an empty hand does not.** These look
identical by value: an item row imported before the `type_id` columns existed
carries `TypeID3 = TypeID4 = 0`, which is exactly what an empty hand looks like.
Treating that as bare hand would refuse every weapon-requiring skill to a
character holding a perfectly good sword, on a deployment whose only fault is an
old import. `equippedWeaponType` returns a `known` flag so the two cases stay
distinct.

**What moved:** the weapon gate is recovered, confirmed three ways, and enforced;
the TID packing is read off the binary's own masks rather than inferred from
field widths; three invented weapon names are corrected.

**Next step:** the gate covers `skill[0x3a0] == 0`, the ordinary path.
`FUN_0058d480`'s other branch walks a list at `+0x3a0` with a `switch` on its
first word -- an override that some skills carry. Nothing reads it yet, and what
it overrides is unrecovered.

## 2026-09-16 (fifth) — the skill-param vocabulary closes: 148 codes, zero unknowns

Two ticks ago this project recorded an open lead: a second walker over
`RefSkill_ParseParams` found "roughly 55 further tag comparisons in neither
table", unverified, with the question *"whether the vocabulary is really ~105 or
~145 is open"*. **Closed: it is 148, and 44 codes were added.**

It was closed by a structural test rather than by reading more disassembly,
which matters because the disassembly is what was unreliable.

### The test, and why it fails loudly

Walk every real skilldata row's Param block from column 69 using a table's run
lengths. A wrong run lands the cursor on a *value* instead of the next code and
derails the rest of the row, so a bad entry shows up as **fewer** clean walks,
not as a silent pass.

| table | fixed | varlen | clean | varlen-stop | unknown |
|---|---|---|---|---|---|
| doc table as it stood | 89 | 15 | 19,155 | 1,609 | 15,625 |
| + 30 fixed-run codes | 119 | 15 | 19,990 | 1,845 | 14,554 |
| + 14 stoppers | 119 | 29 | 19,990 | 16,399 | **0** |

**Zero of 36,389 rows hit an unrecognised code.** Each of the 30 was also added
alone against the unmodified table: 24 raise the clean count by themselves, 4 are
neutral (their rows stop later on a different code), and none lower it.

### The walker was a good finder and a bad measurer

Walking with the walker's whole 145-tag table scores **910** clean — far worse
than the 89-code doc table. Its run lengths are unreliable: it accumulates
`add ecx,N` over a fixed instruction window and under-counts any handler that
adds more inside a branch. So only the entries real data actually exercises,
where the walk confirms the run, were published.

That is the `pw`/`skc` lesson arriving from the other side. That correction came
from a walker disagreeing with the table; this one comes from **real data
disagreeing with the walker**. Neither artefact is authoritative on its own.

### One class of code explains every remaining gap

Nine of the fourteen stoppers have no recovered field, and `efr` — the single
most common stopper, 9,538 rows — shows why. It is dispatched by an ordinary
`cmp edx,0x656672`, but its handler reads `mov edx,[eax+0x4]` and **branches on
its own first value** before storing anything, so its field and run depend on
that value. A scanner looking for the next `mov [esi+N],eax` finds the wrong one
or none.

That is the same shape that mis-filed `pw` and `skc`, so the two failures the
last three ticks turned up are one failure: **value-dispatched handlers**. They
are recorded as operationally variable-length, with the mechanism named rather
than smoothed over.

### A justification that was quietly conditional

`export-refdata`'s whole-row scan for the `att` literal was defended by "on the
19,839 rows that walk cleanly, the walk and the scan agree 19,839 times and
differ 0". Under a 104-code table, 15,625 rows stopped at an unrecovered code --
so "the rows that walk" was doing unexamined work in that sentence.

Re-run on the complete vocabulary: 19,990 rows walk end to end, walk and scan
agree on 18,727 and differ on 0, and the `att` literal appears as some other
code's VALUE **exactly 0 times** across every walked run. That last number is
the scan's actual failure mode, now measured directly instead of argued from the
schema.

**What moved:** the skill-param vocabulary went from 104 codes with 15,625
unexplained rows to 148 codes with none; a load-bearing justification in the
exporter is no longer conditional on the part of the table nobody had read.

**Next step:** the nine value-dispatched stoppers (`bu`, `cr`, `curl`, `efr`,
`es`, `fz`, `ko`, `setv`, `sl`). Their handlers branch on value[0], so each needs
reading individually -- `efr` first, at 9,538 rows by far the most used.

## 2026-09-16 (sixth) — the nine "stoppers" were fixed runs, and a third mis-filed field

The previous entry named the nine value-dispatched stoppers as the next step,
`efr` first. All nine are decoded. **They are not variable-length at all** — each
is a fixed run, and classifying them as stoppers was this project's own error,
not a property of the parser.

### The dispatch form that hid seven of them

Tag dispatch takes two shapes, and only one had been modelled. The obvious one is
`cmp edx,IMM` / `je`. The other is a **cumulative subtraction chain**, where each
branch tests the running *sum* of the immediates:

	587725:  sub edi,0x6272  / je   -> 'br'  (0x6272)
	58772d:  sub edi,0x3     / jne  -> 'bu'  (0x6272 + 3 = 0x6275)

Seven of the nine appear only in that form, so "no comparison found in the
disassembly" was a fact about the scanner. Teaching the extractor to accumulate
`sub` chains found all seven immediately.

### `efr` is a fixed run of 7 whose value picks the field

Its handler reads value[0] and branches to one of three stores — 1 → `0x28c`,
2 → `0x290`, 3 → `0x294`, anything else no store — but **every path adds the same
7 words**. So the run was constant all along; only the destination varies.

### The numbers

| table | fixed | varlen | clean | varlen-stop | unknown |
|---|---|---|---|---|---|
| start of the previous pass | 89 | 15 | 19,155 | 1,609 | 15,625 |
| after that pass | 119 | 20 | 19,990 | 2,111 | 14,288 |
| after these 11 | 130 | 21 | **33,965** | 2,424 | **0** |

**33,965 of 36,389 rows (93.3%) now walk cleanly end to end**, up from 19,155.
`efr` alone is worth +6,183 rows, `bu` +879, `fz` +856, `setv` +762. None of the
11 lowers the clean count when added on its own.

### A third instance of one bug, and a limit worth stating

`br`'s real handler stores to **`0x278`**; the table said `0x318`, which belongs
to `bu` — the next tag in the same `sub` chain. That is the identical
`je`-target-versus-fall-through mis-pairing that had already mis-filed `pw` and
`skc`. Three instances, one cause, now also seen across `sub` chains.

**The walk cannot catch this class.** `br`'s run (3) was correct, and a walk only
ever exercises run lengths — a field offset is never tested by walking. So the
correction rests on the disassembly alone, and the walk's authority is bounded:
**it validates runs, never fields.** Worth recording plainly, because the
previous two entries leaned on the walk as though it validated entries whole.

**What moved:** the skill-param vocabulary reaches 151 codes with zero
unrecognised rows and 93.3% of the table walking cleanly; the nine "variable
length" codes turn out to be fixed runs; a third mis-filed field is corrected.

**Next step:** the 21 remaining stoppers (`ao`, `bbuf`, `cbuf`, `efta`, `eshp`,
`fitp`, `hitm`, `hntp`, `lkdr`, `lks2`, `nbuf`, `nmf`, `nmh`, `php1`, `pmp1`,
`reqi`, `rpkt`, `slcc`, `ssou`, `trap`, `odar`) account for the last 2,424 rows.
They were classed variable-length by the original extractor, and the nine just
decoded are a reason to distrust that classification rather than inherit it.

## 2026-09-16 (seventh) — the 21 stoppers, a shipped bug found, and a tool so this stops being ad-hoc

The previous entry warned against inheriting the "variable-length" label for the
21 remaining stoppers. Checking each: **10 are genuinely variable-length**, 3
were fixed runs, 1 is something else entirely, and 7 remain unfound. Chasing the
"something else" found a bug this project shipped two ticks ago.

### `ssou` is a parse TERMINATOR, and my delta test could not see it

`ssou`'s handler writes the counter and cursor back to their globals, stores
`0x354`, and **returns from the parser**:

	5890dc:  mov [esi+0x354],eax
	5890e5:  ret                      <- never reaches the loop tail

My extractor walked straight past that `ret` into the *next* handler and
reported `ssou` as run 4, field `0x264` — which is `spda`'s. The per-code test
then rated it "confirms", because adding it raised the clean count by 103.

**It also derailed 189 rows, and the test never looked.** Of 292 rows reaching
`ssou`, 103 happened to land on a terminator after skipping 4 words and 189
landed mid-value. A run-length test must check that **UNKNOWN does not rise**,
not only that clean does; a wrong run can buy clean rows by luck. The verifier
below reports all three columns for exactly this reason.

### `reqi` fills the weapon gate's override list — and srrevamp was refusing legal casts

Two ticks ago the weapon gate shipped with an open question: `FUN_0058d480`
checks `ReqCastWeapon` only inside `if (skill[0x3a0] == 0)`, and nothing was
known about `+0x3a0`. It is filled by the `reqi` parameter:

	588f5d:  lea edi,[esi+0x3a0]           ; a five-slot list
	588f63:  cmp edx,0x5 / je              ; capped at 5
	588f6c:  cmp DWORD PTR [edi],0x0 / je  ; first free slot
	588f79:  mov [esi+edx*4+0x3a0],eax

So **a skill carrying `reqi` never has its weapon bytes consulted.** Measured:
1,094 real skills carry `reqi`, and **517 of them also carry a weapon
requirement the engine ignores**. srrevamp has been refusing those casts since
v0.1.197. Fixed: the gate now applies only when the list is empty, which is the
faithful half — what the other branch checks is still unrecovered, and declining
to apply a check the engine would not apply is the right half to ship.

`reqi`'s own field was also wrong in the table: it said `0x2a4`, which belongs to
`rhru` (`00588f9f`). That is the **fourth** instance of the
`je`-target-versus-fall-through mis-pairing, and this one this project introduced
itself an hour earlier by copying the figure out of the occurrence table.

### `reqn`, and a name off the open ledger

`reqn` (0x7265716e, one `sub edi,5` past `reqi`) is variable-length with field
**`0x3b4`** — a field the open-items ledger has carried unnamed as `vf[0x3b4]`.

### A verifier, checked in

`client/tools/verify_skill_params.py` parses the table out of the markdown,
walks every real Param block, and reports clean / varlen-stop / **unknown**,
exiting non-zero if any row ends on a code the table lacks. Three ticks of
claims about this table rested on throwaway scripts; now they are reproducible,
and the tool's docstring states plainly what the walk does **not** test:

> field offsets. No walk ever reads a field, so a code filed under the wrong
> offset walks exactly as well as a correct one.

Four mis-filed fields have now been found (`pw`, `skc`, `br`, `reqi`) and the
walk caught none of them.

### Where it stands

| | fixed | varlen | clean | varlen-stop | unknown |
|---|---|---|---|---|---|
| start of this tick | 129 | 20 | 33,203 | 2,344 | 842 |
| now | 132 | 21 | **34,707 (95.4%)** | 1,682 | **0** |

**What moved:** the vocabulary is 153 codes with zero unrecognised rows;
`skill+0x3a0` is named and the gate corrected; `0x3b4` comes off the ledger; the
measurement is a checked-in tool rather than a script in a scratch directory.

**Next step:** what the `reqi` list HOLDS, and the branch `FUN_0058d480` takes
when it is non-empty -- that branch switches on the first word of each entry.
517 skills currently get no weapon check at all because of it.

## 2026-09-16 (eighth) — the cast-requirement list, decoded and enforced

The previous entry left the weapon gate half-finished on purpose: a skill
carrying `reqi` had its weapon bytes correctly ignored, but the check the engine
runs *instead* was unrecovered, so those 517 skills got no requirement check at
all. That branch is now read, and the other half is shipped.

### The record is (TypeID3 category, TypeID4 type)

`reqi` is a three-word run carrying **(kind, value)**, and the check's own
arithmetic settles what they mean: it compares the kind against
`(itemTID >> 7) & 0xf` — the TypeID3 field — and the value against
`itemTID >> 11`, TypeID4. Value 0 means any.

Measured over 1,552 real records, the kinds land exactly on the TypeID3
vocabulary `refdata.Item` already documented for its own reasons:

| kind | category | records | values |
|---|---|---|---|
| 6 | weapon | 1,216 | 2-15, the weapon TypeID4 set |
| 4 | shield | 179 | 1, 2 |
| 10 | EU light armour | 94 | 0 (any) |
| 9 | EU robe | 34 | 0 (any) |
| 14 | not equipment -- a character flag | 23 | 1 |

Two independent tables agreeing on a vocabulary neither was consulted about is
the kind of confirmation this project trusts. The weapon values are the same
TypeID4 set recovered from itemdata two ticks ago, and the armour kinds are the
ones `item.go` names from `ITEM_FORMAT.md`.

### `reqn` names `0x3b4`, an open-ledger item

`reqn` sets `CRefSkill+0x3b4`, and the loop reads it to require that **every**
entry match rather than any one:

	if (skill[0x3b4] != 0) { if (!matched) goto fail; matches++; }

966 real skills use the ANY form, 128 the ALL form. The open-items ledger has
carried `0x3b4` unnamed as `vf[0x3b4]`; it is the cast-requirement conjunction
flag.

### What shipped

- `combat.CastRequirement` / `SkillAllowsEquipment` / `ParseCastRequirements`,
  with the recovery written where it is used and a table test walking every
  branch including both list forms.
- `refdata.Skill.ReqCastList` (packed `kind:value;...`) and `ReqCastAll`,
  exported as strict-suffix columns and persisted in SQL.
- The skill-use path now takes the engine's *other* branch rather than skipping
  the check: a list is matched against worn equipment, and a mismatch answers
  "wrong equipment for this skill".

### Deliberately permissive, and said so

Kind 14 always passes. Its case tests a character flag via vtable `+0x584` and
`FUN_00498610`, not equipment; the flag is unrecovered, and refusing a cast on a
condition this project cannot evaluate would be worse than allowing it. 23
records carry it, all item-mall and event skills.

An unreadable equipment set also passes, on the same reasoning as the weapon
gate: an item row imported before the `type_id` columns carries both type fields
zero, which is indistinguishable by value from wearing nothing.

### A constant caught by its own check

`reqn`'s literal was hand-typed as 1919250910 and is 1919250798. The project's
rule -- let Python compute multi-char constants, hand-typing has been wrong twice
-- caught it within a minute because the value was verified rather than trusted.
Third time it has paid for itself.

**What moved:** the weapon gate is complete on both branches; `0x3b4` comes off
the open ledger; 517 skills that had no requirement check now have the engine's.

**Next step:** the kind-14 character flag (vtable `+0x584` arg 4, and
`FUN_00498610`) is the last unmodelled term in the gate, on 23 item-mall skills.

## 2026-09-16 (ninth) — 195 virtual-function names and their vtable slots

The previous entry named the kind-14 character flag as next. That affects 23
skills; naming coverage sits at **21.7%** (7,386 of 34,113), so the tick went to
a systematic lever instead, and the flag stays open.

### The lever

The server's base classes implement most virtuals as a **stub that logs and
returns**, so a derived class that forgets to override one is caught at runtime:

	CGameServer::FUN_00936640(0x2000000,
	    "## Illegal ## IGObj::SetBodyMode TypeID: %u", ...);

**213 such strings exist**, each naming its method in the binary's own words.
Finding the stub's address in `.rdata` then gives its slot, because a stub sits
at the same index in every vtable of the hierarchy. 202 resolve to exactly one
slot, 195 of them `IGObj`.

This is the same pattern that named `IGObj::SetBodyMode` a week ago from a single
string. Harvesting the whole family at once is what the naming-coverage note has
been recommending; it had not been run.

### Why the slots are trustworthy, tested rather than asserted

The vtable base comes from walking backwards until a dword stops being a `.text`
pointer. That is a heuristic, so it was checked against facts recovered without
it:

- The `SetBodyMode` stub appears in **14 different vtables** and lands at slot
  **198 in all 14** — the figure recovered earlier from the berserk activation
  handler.
- Five further slots each explain a call site this project had been reading
  blind, and each fits its observed use:

| offset | slot | name | what was already observed |
|---|---|---|---|
| `0x1c` | 7 | `IGObj::IsPC` | tested for "is not a PC" |
| `0x28` | 10 | `IGObj::IsMonster` | both raw-damage builders call it |
| `0xf8` | 62 | `IGObj::GetLifeState` | the guard opening **both** mitigation formulas — so it means *both parties must be alive*, which nothing had established |
| `0xfc` | 63 | `IGObj::GetMotionState` | tested `== 8` |
| `0x100` | 64 | `IGObj::GetBodyMode` | tested `== 1`; the berserk handler's own `if (GetBodyMode() == 1)` |
| `0x104` | 65 | **`IGObj::GetParam`** | the most-cited unnamed virtual in this project's comments |

### A name this project invented, corrected

`berserk.go` called slot 64 `CGObjChar::IsBerserk`. The binary calls it
`GetBodyMode`, twin of `SetBodyMode` at 198. The implementation at `0x004aa5b0`
does return "is the body mode 1", which is why the invented name looked right —
and it is the *second* time that file has had to retract a name it made up for a
body-mode function. Corrected in place.

### What it does not recover, stated

Virtuals with **no base-class stub** leave no string. That includes all four
vtable calls in the cast-requirement check (slots 353, 372, 399, 400), so the
weapon and armour checks in `FUN_0058d480` stay unnamed.

Seven names resolve to **two** slots — `GetCurHP` [66, 68], `GetCurMP` [67, 69],
`ExpandInventory` [173, 174] and four more. Two hierarchies whose layouts differ
by an inserted virtual, not an error; they are listed as ambiguous rather than
assigned one.

### Shipped

- `docs/protocol/igobj_vtable.md` — the 195-slot table with its validation.
- `client/tools/ghidra/recover_vtable_slots.py` — regenerates it, and **asserts
  the two independently-recovered slots**, exiting non-zero if the arithmetic
  breaks.
- `combat.go` and `berserk.go` now name `IGObj::GetParam` and `IGObj::GetBodyMode`
  instead of describing them.

**What moved:** 195 virtuals named with their slots, from 6 to ~201 known slots
in this hierarchy; six vtable offsets the damage code cites by number now have
names; one invented name retracted.

**Next step:** apply these names to the dump (`ApplyKnownNames.java` exists), and
read the remaining `IGObj::` slots against their call sites — `GetLifeState`
alone settles what the mitigation guard means, and there are 189 more.

## 2026-09-16 (tenth) — the vtable names, measured against the whole dump

The previous entry shipped 195 named slots and said the next step was reading
them against their call sites. Doing that produced one measurement worth keeping
and one correction to that entry.

### 88.6% of every vtable call in the server now has a name

Joined against every `(**(code **)(*x + 0xNN))` in the dump: **15,249 of 17,207
call sites (88.6%)** resolve to a name, across 170 of the 353 distinct offsets
called. Most-called: `GetGameID` 1,181, `GetQuestStatus` 1,056, `GetQuestData`
609, `SaveQuestNow` 578, `GetWorldID` 561, `IsPC` 532.

In the combat shards the top calls are `IsPC` 84, `GetParam` 56, `GetLifeState`
34, `GetLevel` 34, `IsMonster` 29 — a fair description of what a damage routine
does, which is a sanity check on the names rather than a new claim.

### "Ambiguous" was a guess, and it was wrong

The previous entry said seven names sat at two slots because of "two hierarchies
whose layouts differ by an inserted virtual". That was an explanation invented to
cover a result, not read from anything. Comparing the **implementations** at both
slots settles it, and the answer is two different things:

- `GetCurHP` (66, 68) and `GetCurMP` (67, 69) hold the **same function at both
  slots in all 14 vtables** — one method the layout lists twice, which is what
  multiple inheritance does.
- `ExpandInventory` (173, 174), `RaiseEvent` (80, 81) and the two CollectionBook
  predicates hold **different functions** — distinct methods whose stubs share a
  log string, i.e. overloads.
- `GetWorldLayerEventHandlers` (182, 188) is genuinely mixed (same in 1 vtable,
  different in 19) and is reported that way rather than forced into either box.

Both slots are real in every case, so the table now carries **209 slots** rather
than dropping these seven.

**The scoping mattered and nearly went wrong.** The first run compared the two
slots across all 274 vtables in the binary and reported `GetCurHP` as "same in
14, different in 207" — meaningless, because slot 66 means something different in
each unrelated vtable. Restricting the comparison to the vtables that actually
contain the method's own stub gives a clean answer. A comparison is only evidence
about the thing it is scoped to.

### An absence that is correct

Slot 224 is called 313 times and is not in the table, which looks like a gap. Its
implementation is a ten-byte accessor (`return this->f34->f20`) and the dump's
RTTI annotation places it on `CGItem`, `CGItemContainer`, `CGItemEquip` and their
siblings. It is a **CGItem-family** virtual with no `IGObj` stub because it is not
an `IGObj` method. Recorded so the next tick does not chase it as missing.

**What moved:** the slot table is correct where it was guessed, 14 slots larger,
and now carries a measured statement of how much of the dump it explains.

**Next step:** the same harvest on the CLIENT dump (43,460 functions, 22 shards),
which has its own `## Illegal ##` stubs and its own hierarchy -- the tool takes a
`--dump` path and should run unchanged.

## 2026-09-16 (eleventh) — a handoff premise that was wrong, and real inventory bounds

### The named next step did not exist

The previous entry said the `## Illegal ##` harvest should "run unchanged" on the
client dump. **The client dump contains zero such strings** — 16 `Class::Method`
strings in total, against the server's 213. That idiom is a server-side debugging
convention, not an engine-wide one.

(This paragraph also said "there is no client binary on the RE box". **That was
wrong** — see the correction in the thirteenth entry. The stub finding stands on
its own; the binary claim was an unchecked aside.)

One grep, before any work. That is the fifth handoff sentence in this run to
carry an unchecked claim, and the first to cost nothing, because the claim was
checked before it was acted on.

For the record, the client's own numbers: **14.8% named** (6,440 of 43,460), with
the unnamed concentrated in `GlobalDataManager` (2,027), `UI_SILKMALL` (1,807),
`UI_ALCHEMYBOX` (966) and `Map` (706) — UI and data-manager code, not the
gameplay core.

### Inventory: the caps are real, the base is not

`inventory.SlotsPerCharacter = 50` was own design, and its comment said "easy to
change later", which quietly implied the number was unconstrained. It is not.
`CGObjPC::ExpandInventory` (0x004e1910, **vtable slot 173** — named by last
tick's harvest, which is how this was found at all) refuses an expansion unless
both hold:

	count <= cap - size     and     size + count < 100

so the size after any expansion is at most `cap`, and never reaches 100. `cap` is
**0x4d = 77**, raised to **99** by a condition at `GObjPC::FUN_004e13b0`.

The slot-174 overload (0x004e19d0) is a different thing and caps at **0x70 =
112**, routing through `AQ_StorageExpander` — that is STORAGE, not inventory. The
two are easy to conflate and they differ.

**What is NOT claimed.** `FUN_004e13b0` is 1,359 bytes and was not read, so what
unlocks the 99 cap is not stated. And the STARTING size stays unrecovered: the
live field is `this + 0x1c2c` and it persists as the `_CHAR` column
`InventorySize` at charData+0xac, but **nothing in the dump writes +0x1c2c** —
the write reaches it through a register, the failure mode this project already
has a name for. So 50 remains own design rather than being replaced by a number
that merely looks plausible.

### What shipped

The bounds as named constants with their citation, and
`TestSlotsPerCharacterFitsTheEngine`, which fails with the disassembly reference
if a later change puts srrevamp outside what the engine can represent. Checked by
setting the value to 120: it fails on both conditions and passes when restored.

This is the upgrade available here — not "own design" to "recovered", but **own
design to own design inside a recovered bound**, with a test holding it there.

**What moved:** one of the 51 own-design values in `internal/` now has real
limits attached and a guard; the client's naming profile is measured; a wrong
next-step premise was caught before it cost anything.

**Next step:** the starting inventory size, via whatever writes `+0x1c2c`. A
register-indirect write is exactly what `dump_gaps.py` and an `objdump` sweep
are for, rather than another grep of the decompiled C.

## 2026-09-16 (twelfth) — two dead ends closed properly, and a third cap

This tick is mostly negatives. They are recorded because each was reached by a
**complete enumeration** rather than a grep that came back empty, which is the
difference between "not there" and "I did not find it".

### The inventory base is not written anywhere in `.text`

The previous entry guessed that the write to `this + 0x1c2c` "reaches it through
a register". That was speculation dressed as an explanation. Searching the full
125 MB disassembly — not the decompiled C, which cannot see such things — finds
**nine reads of `[reg+0x1c2c]` and zero writes**. The only other occurrence is
`mov WORD PTR [eax],0x1c2c`, which stores the number, not to the field.

So the field is never individually assigned. It is filled by a bulk operation —
a DB row load or a container's own generic code — and the starting inventory size
stays **not found yet**, with this as the record of where the search stopped.
`inventory.SlotsPerCharacter = 50` remains own design inside the recovered bound.

### The 129 error codes have no server-side names

The engine returns numeric codes (`0x300d` wrong weapon, `0x18fe` container
full, `0x183e` berserk charges, …) — **129 distinct** `0x18xx`/`0x30xx`
immediates, the commonest being `0x1809` (19 sites), `0x1811` (18), `0x1806`
(15). A code→name table would name that many failure paths at once.

There is none *in the server* to harvest: it carries just **9** `UIIT_` strings,
passed as message *names* on paths that send text, not as labels for the numeric
codes. The mapping lives client-side.

**"and there is no client binary on the RE box" was wrong** — see the correction
below.

### A third capacity cap, and the first two confirmed in assembly

Re-reading `CGObjPC::ExpandInventory` at instruction level rather than trusting
the decompiler confirmed 77 and 99 (`mov eax,0x4d` / `mov eax,0x63` at 4e196d /
4e1974) and turned up a cap the decompiled C had shown only as `< 0xd3`:

	4e192c  mov eax,[ebx+0x21d8] ; mov al,[eax+0x1c]   <- a BYTE count
	4e194d  cmp ecx,0xd2 ; jle ok                      <- at most 210
	4e1957  mov ax,0x18fe                              <- refused

So `ExpandInventory(count, kind=3)` caps a third container at **210** and refuses
with error `0x18fe`. **Which container kind 3 is has not been identified** — a
byte count and a 210 cap fit several, and naming it on that would be a guess.
Shipped with its citation and no name.

Three distinct caps now: 99 inventory, 112 storage, 210 kind-3. The test asserts
they stay distinct, because collapsing them would lose a distinction the engine
makes.

**What moved:** two speculative leads are now closed with enumerations instead of
guesses; a third recovered cap with its error code; the first two caps confirmed
in assembly rather than through the decompiler.

**Next step:** the client binary is the blocker for both the error-code table and
the `## Illegal ##` harvest's client half. Getting `SRO_Client.exe` onto the RE
box would unblock both at once -- worth more than either dig alone.

## 2026-09-16 (thirteenth) — retraction: the client binary was on the box all along

Two entries above claimed "there is no client binary on the RE box". **Both are
wrong.** There are three copies and a Ghidra project:

	/opt/sro-files/client/sro_client.exe          (11.5 MB)
	/opt/sro-files/client/sro_client_NODLL.exe
	/mnt/silkroad/pserver/client/sro_client.exe
	/home/ghidra/re_client/sro_client_re.gpr

It could hardly have been otherwise — the 43,460-function client dump was made
from something. A `find` took seconds and was not run, because the claim entered
as an aside to a different finding and was never treated as a claim.

**This is the sixth unchecked assertion in this run, and the first to reach a
pushed commit.** The previous five were caught in the next tick's opening grep.
The difference is that those were load-bearing "next step" sentences, which now
get checked by habit, while this one rode along inside a conclusion about
something else. The habit needs to cover asides, not just handoffs.

### What is actually true about the error-code lever

Rechecked with the binary in hand, so this replaces the closed-off version:

- The client dump carries **1,133 distinct `UIIT_` message names** (the server
  has 9).
- `UI_SILKMALL::FUN_007b8b40` is the client's server-error dispatcher: a single
  switch over **643 distinct case values**, including the `0x18xx`/`0x30xx`
  codes the server returns.
- But it does **not** resolve them to text inline. Each case either `break`s or
  calls a helper (`FUN_0046e3d0`, 435 call sites across the dump) with the code
  in a register, so the code→text mapping is data-driven rather than a literal
  table in the switch.

So the lever is **not blocked by a missing binary** — it is blocked by the
mapping living behind a helper and the text tables. An earlier version of this
entry said "found it" on seeing the switch; that was premature, and the
extraction that followed mapped 222 codes onto one string because it was reading
the dump's header annotation rather than the function body.

**What moved:** a false blocker removed, the real one named, and the dispatcher
located with a citable size.

**Next step:** `FUN_0046e3d0` — what it does with the code, and whether the text
id it produces is derivable. That is the whole 643-code vocabulary if it resolves.

## 2026-09-16 (fourteenth) — the error-code vocabulary, and a false "unrecoverable"

The previous entry closed the error-code lever as blocked: the client's switch
"does not resolve them to text inline … the mapping is data-driven rather than a
literal table". **That was wrong, and wrong for the reason this project keeps
rediscovering: it was a statement about the decompiler.**

Every case ends in a call whose argument Ghidra drops, because it arrives in a
register:

	case 0x180f:
	  RefData_worldmapguidedata::FUN_0046e3d0();

Reading that helper settled it — `FUN_0046e3d0(short *)` walks a UTF-16 string to
its length and forwards it, so it takes a **string**, not a code. In the
disassembly the string is right there:

	7b8ca6:  push 0xdc7ea0          <- pointer to a UTF-16 message name
	7b8cab:  lea  ecx,[esp+0x3c]
	7b8caf:  call 0x46e3d0

### 95 codes recovered

MSVC compiles the switches sparsely, so a case value takes two tables —
`movzx ecx,[eax+IDX]; jmp [ecx*4+JMP]` giving `case base+i -> JMP[IDX[i]]` — plus
the dense form where the jump table is indexed directly. Walking both and reading
the string each target pushes yields **95 of the dispatcher's 643 cases**.

They are immediately legible and obviously right: `0x180f NOT_ENOUGH_GOLD`,
`0x1810 HIGHER_LEVEL_REQUIRED`, `0x1830 HIGHER_STRENGTH_REQUIRED`,
`0x183a CANNOT_BE_TRADED`, `0x0004 ERR_COMMON_TOO_FAR`.

### The check that makes it trustworthy

`0x183e` resolves to **`UIIT_MSG_STRGERR_CANNOT_BE_USED`**, and this project had
already recovered `0x183e` from the *server*: `CUsedItemLimit::FUN_004a05b0`
returns it refusing an item at its use limit. A server-side item-use limiter and
a client-side "cannot be used", from two binaries, agreeing without either being
consulted about the other.

**Coverage stated honestly:** the `0x30xx` family is NOT resolved, including
`0x300d`, the wrong-weapon code this project uses elsewhere. Those cases sit in
category branches that route through a different helper. This is a large sample,
not the whole vocabulary.

### A stale reason, corrected

`equipment/rules.go` explained skipping ReqStr/ReqInt with "characters have no
stats yet". That stopped being true when `character.Character` gained `Str` and
`Int`. The right reason turned out to be better: **no item in the table carries
either requirement** — measured over a complete real itemdata, the count of rows
with a non-zero ReqStr or ReqInt is **zero**, on columns verified against the
exporter's own `fReqStr = 59` / `fReqInt = 60` rather than assumed.

So the decision was correct and its stated reason was false. Implementing the
check would be dead code; the engine's own refusals for it (`0x1830`, `0x1831`)
exist and the shipped data never triggers them. A false explanation for a correct
decision is worse than none, because the next reader acts on it.

Three of srrevamp's equipment refusals turned out to match the game's own, and
now carry its codes: `ErrWrongRace` = `0x182f COUNTRY_MISMATCH`, `ErrWrongGender`
= `0x1816 GENDER_MISMATCH`, `ErrLevelTooLow` = `0x1810 HIGHER_LEVEL_REQUIRED`.

**What moved:** 95 error codes named with an independent cross-binary check; a
"data-driven, unrecoverable" conclusion retracted; a stale justification replaced
with a measured one.

**Next step:** the `0x30xx` branch of the dispatcher -- a different helper, and it
holds `0x300d`, which the weapon gate already returns.

## 2026-09-16 (fifteenth) — 445 error codes, and a bug in my own walker

The previous entry recovered 95 codes and named the `0x30xx` branch as next. The
branch is still not decoded, but chasing it found something better: **a bug in
the extractor that was discarding most of the table.**

### The walker was throwing away the common case

Reading the `0x30xx` case bodies in assembly showed the shape:

	7b90c7:  push 0xdc6ca8
	7b90cc:  jmp  0x7b966d      <- a SHARED TAIL does the lea+call

Most cases do not call the helper themselves. They push the string and jump to a
tail that makes the call. The walker treated a `jmp` as the end of a block
whenever a push was outstanding — so it kept only the minority of cases that
inline the call, and silently dropped the rest.

Following the jump **with the push still in hand** took the table from **95 to
445 of the dispatcher's 643 cases.**

That is the second time in two ticks that a conclusion about this function was
really a statement about the tool reading it: first Ghidra dropping the register
argument, then my own walker dropping the jump.

### A second cross-binary check, and a name off the open list

`0x18fe` resolves to **`UIIT_STT_STORAGE_EXPANSION_USE_ERORR`** (the game's typo).
Three ticks ago this project recovered `0x18fe` from the **server** — the refusal
`CGObjPC::ExpandInventory` returns on its `kind == 3` path — and wrote:

> WHICH container kind 3 is has NOT been identified … naming it from that would
> be the kind of guess this project has paid for.

The client answers it. Kind 3 is the **storage expansion** path, and the "USE" in
the name fits: it is reached by using an expansion item. Two binaries agreeing
without either being consulted about the other, which is the standard this
project accepts — and a name recovered rather than guessed, three ticks after
refusing to guess it.

`inventory.MaxThirdContainerSlots` is accordingly now `MaxStorageExpansionSlots`.
**One tension is flagged rather than resolved:** `MaxStorageSlots` is 112 via
`AQ_StorageExpander` and this path caps at 210. Two limits in the same area of
the engine; which governs what is not established.

`ErrNoRoom` also gains the game's name for the same refusal: `0x281c`
`UIIT_MSG_STRGERR_INVENTORY_FULL`.

### Coverage, stated honestly

445 of 643. The remainder either `break` without a message, or `goto` into the
middle of another case's block *after* its push, where no string can be
attributed. The `0x30xx` family is entirely unresolved — their bodies are visible
in the decompiled C and do call the helper, so they are recoverable; the
category-4 inner switch's jump table is simply not decoded by this walker.

**What moved:** the error vocabulary went 95 -> 445 with a second independent
check; one open "not identified" became a recovered name; a real bug in a
checked-in tool was found and fixed.

**Next step:** the category-4 inner jump table. Its preamble does not use the
`sub`/`cmp`/`movzx` shape the walker looks for, so finding how MSVC dispatched
that one switch is the whole remaining gap.

## 2026-09-16 (sixteenth) — the weapon gate confirmed from the other binary

The previous entry named the category-4 jump table as the whole remaining gap. It
was, and it was one instruction:

	7b9823:  add eax,0xffffcffd      <- `eax -= 0x3003`

MSVC normalises a switch's case base with an **`add` of a negative immediate** as
readily as with a `sub`, and the walker only knew `sub`. That single missing
shape was the entire `0x30xx` family. **614 of 643 cases** now resolve.

The progression is worth keeping, because every jump was a bug in the reader and
none was new data:

| | codes | what was wrong |
|---|---|---|
| first | 95 | — |
| second | 445 | stopped at `jmp` with a push outstanding, dropping every case that uses the shared call tail |
| third | 614 | knew only `sub eax,base`, not `add eax,<negative>` |

### `0x300d` is `UIIT_SKILL_USE_FAIL_WRONGWEAPON`

Four ticks ago this project named `FUN_0058d480` "the weapon gate" from the
**server alone**, reasoning from the code it returns when the equipped weapon
matches neither of a skill's `ReqCastWeapon` bytes. The client names that code
`SKILL_USE_FAIL_WRONGWEAPON`. The whole reading — the gate, the two bytes, the
`TID >> 11` comparison, srrevamp's "wrong weapon for this skill" — confirmed from
a binary that was never consulted about it.

Its neighbours came with it: `0x3003 NOTLEARN`, `0x3006 WRONGTARGET`, `0x300f
BROKEN_WEAPON`.

### An error code named three vtable slots

`docs/protocol/igobj_vtable.md` lists slots 353, 372, 399 and 400 as unreachable:
they have no base-class stub, so the harvest that named 209 others leaves no
string for them. But `FUN_0058d480` returns `0x300f` when slot `0x5d0` (372),
`0x63c` (399) or `0x640` (400) returns 0 — and `0x300f` is **BROKEN_WEAPON**.

So all three are **serviceability checks**: a cast requirement wants the item
present *and* not broken, and these are the second half. That is a meaning, not a
symbol — their method names are still unrecovered, and slot 353 is unknown on
both counts. Worth recording as a technique: when the stub harvest comes up
empty, the error a function returns on that path can still say what the call was
for.

### A requirement srrevamp cannot yet apply

`combat.CastRequirement.Satisfied` now records that the engine also demands the
matched item be serviceable. srrevamp has no per-instance durability —
`refdata.Item` carries DurabilityMin/Max as reference data, but an equipped item
has no wear state — so nothing can be broken and the check has nothing to apply
to. Disclosed in place rather than silently skipped, so that adding durability
later comes with the requirement already written down.

**What moved:** the error vocabulary is effectively complete (614/643); the
weapon-gate recovery has independent confirmation; three vtable slots the
previous lever could not reach have their purpose.

**Next step:** 614 codes now name refusals across the whole server. Grepping the
server for `mov ax,0x<code>` returns and joining against this table would label
a large number of failure paths at once -- a naming lever over functions, not
just constants.

## 2026-09-16 (seventeenth) — the error codes name functions, and find a free skill

The previous entry proposed joining the error table against the server's returns
to label failure paths. That works, and the codes say what each function does —
`005c6550` returns the guild-alliance refusals, `005c6b60` the guild-war ones,
`006182a0` the specialty-trade ones.

**The counts first published here — "1,014 server functions return a known error
code, 704 of them still `FUN_`" — were wrong, inflated roughly tenfold by a
collision this entry did not test for. The real figures are 157 and 117. See the
twenty-second entry.**

### A flaw caught before publishing

The first join put `UIIT_MSG_PARTYERR_UNKNOWN_ERROR` inside a magic-option
function, which is nonsense. The cause: **the client dispatcher selects a
CATEGORY before switching on the code**, so the same 16-bit value carries
different messages in different categories, and the extractor had merged them
into one code→name dict.

Measured after keying by `(category, code)`: of 614 distinct codes, **605 are
unambiguous and 9 are category-dependent**. The 9 are the low generic ones
(`0x0003` is `PARTYERR_INVALID_TARGET`, `STRGERR_INVALID_TARGET` *or*
`ERR_COMMON_INVALID_TARGET`) — precisely the set most likely to be grepped up by
accident. They are now split into a separate file and excluded from the table.

### The engine's skill-use preconditions, in order

`FUN_0058d8f0` is the precondition check, and its returns enumerate it:

	NOTLEARN · WRONGTARGET · NOTENOUGHLEVEL · DUPLICATE · CANT_BATTLE_STATE
	GROGGY · DO_STEALTH · MUSICAL_RANGE · TIMEDELAY_COOL_TIME · NOTENOUGHHP
	NOTENOUGHMP · OVERLAP · RUNOUT_AMMO · PATH_INTERRUPTED

srrevamp checks known, cooldown, mana, weapon and cast requirements. Comparing
against that list found one the data already supported.

### 16 skills were free to cast

`refdata.Skill.ConsumeHP` has been exported, stored in SQL and **never read**.
Sixteen real skills carry a health cost — all
`SKILL_EU_BARD_RECOVERA_ABNORMALTIME_*`, 495 to 2,543 across their levels — and
srrevamp let them be cast for nothing.

Measured before implementing, because the last time a requirement column looked
enforceable (`ReqStr`/`ReqInt`) **no item used it** and the check would have been
dead code. Here 16 of 36,389 rows use it: rare, but not nothing.

The comparison was read in assembly rather than assumed:

	58e279  cmp DWORD PTR [esp+0x10],0x0   ; the cost
	58e27e  jle skip                       ; a cost <= 0 is not checked
	58e280  call [edx+0x108]               ; vtable slot 66 = IGObj::GetCurHP
	58e28c  cmp eax,[esp+0x10]
	58e290  jge ok                         ; passes on EQUAL
	58e292  mov ax,0x3013                  ; NOTENOUGHHP

So the bar is `currentHP >= cost`, not "must survive". And `0x108` / the MP
check's `0x10c` are **slots 66 and 67** — `GetCurHP` and `GetCurMP` from the
vtable harvest two ticks ago, which also settles which of that duplicated pair
the combat code uses.

Shipped as `combat.CanPaySkillHealth` with the boundary pinned by test, checked
**before** mana so a cast short on health never spends mana on the way to being
refused — the engine's own order.

**One edge disclosed:** the comparison permitting `currentHP == cost` is read;
whether the engine then treats the caster as dead is not. srrevamp's own rule
applies, which composes two known facts rather than inventing one, but it is the
gap in the citation.

**What moved:** 1,014 failure paths joined to names; a category-collision bug
found and split out; a skill cost that was exported for months and never charged.

**Next step:** `NOTENOUGHLEVEL` and `RUNOUT_AMMO` are the next two preconditions
with data behind them -- skilldata carries a required level, and bows in real
itemdata have an ammo type.

## 2026-09-16 (eighteenth) — `cnsm` named, and two near-misses

The previous entry named `NOTENOUGHLEVEL` and `RUNOUT_AMMO` as the next two
preconditions with data behind them. One of them was not what it looked like,
and the other named a parameter code.

### `NOTENOUGHLEVEL` is the transform path, not a skill level check

The check at 0058de94 compares the caster's level against a byte at `[edi+0x198]`
and, on the face of it, looks like "this skill needs character level N". It is
not, and the offset nearly caused a wrong attribution.

**The near-miss:** grepping for what writes `+0x198` found
`ReferenceData::RefObjChar_ExtractData` — a **characterdata** loader, not
skilldata. Offset 0x198 is generic, and treating a `CRefObjChar` field as a
`CRefSkill` one would have been the characterdata-column-79 mistake in a new
costume.

Reading what `edi` actually holds settles it: it is a **reference record looked
up from the refdata singleton** (`ds:0xd6aa14`) by an id off the request, and the
branch immediately above returns `UIIT_STT_EU_BAN_HAWN_TRANS`. This is the
**transform** path — the caster's level against the mob being transformed into.
srrevamp has no transform skills, so it is not missing a check.

### `cnsm` is the ammunition a skill spends

`cnsm` (field `0x2a0`, run 4) entered the parameter table by a mechanical pass
that recorded where each code files its values and nothing about meaning. Its
use-site names it:

	58e337  call [edx+0x1c]                ; slot 7 = IsPC -- players only
	58e348  cmp DWORD PTR [esi+0x2a0],0x0  ; the `cnsm` field
	58e353  call 0x4ec220                  ; look for ammunition
	58e360  mov ax,0x300e                  ; RUNOUT_AMMO

All **448** `cnsm` runs are ranged — 331 `SKILL_CH_BOW` carrying (4, 1, 1), 117
`SKILL_EU_ROG`/`_CROSSBOW` carrying (4, 2, 1) or (4, 2, 3) — and the record turns
out to be the **same (TypeID3, TypeID4, count) shape the cast-requirement list
uses**, plus a quantity.

### A correction to this project's own TypeID3 note

`refdata.Item` says TypeID3 4 is "shields". Itemdata says it is shields **and
ammunition**, separated by TypeID2: (3,**1**,4,1) is `ITEM_CH_SHIELD`,
(3,**3**,4,1) is a quiver; (3,**1**,4,2) is `ITEM_EU_SHIELD`, (3,**3**,4,2) is
bolts.

**The second near-miss:** that raised an obvious worry — does `equipment.SlotFor`
put arrows in the shield slot? It does not, and for a reason rather than by luck:
it rejects anything whose TypeID2 is not `TypeEquipment` (1) before it ever looks
at TypeID3. Checked rather than assumed, and the guard is now documented as
load-bearing so nobody removes it as redundant.

### What is disclosed rather than shipped

srrevamp neither stocks nor spends ammunition, so the `cnsm` requirement has
nothing to check. Recorded in the skill-use path beside the health cost, so that
adding quivers later comes with the rule already written down.

**What moved:** a parameter code named from its use-site; this project's TypeID3
note refined; two wrong attributions caught before they were written down.

**Next step:** `OVERLAP` (0x300c) and `DUPLICATE` (0x3039) are the remaining
preconditions with plausible data behind them -- skilldata has an `Overlap`
bitfield at column 18 that nothing has decoded.

## 2026-09-16 (nineteenth) — the party cap, recovered; and a refusal vindicated

The previous entry named `OVERLAP` and `DUPLICATE` as next. Checking before
spending the tick: both govern **buff stacking** — the `OVERLAP` path tests the
skill's `hide` (`0x428`) and `lnks` (`0x370`) parameter fields against a state
value — and srrevamp models no buffs or status effects. Decoding the `Overlap`
bitfield would ground nothing srrevamp uses, so the tick went to a value it does.

### Two party caps, and the flag that chooses

`party.MaxSize` was own design. The engine enforces its cap at join time, and
there are **two**, selected by a flag on the party:

	5145cc  test BYTE PTR [ecx+0x10],0x1   <- bit 0 of the party's flags
	5145d0  je   clear
	5145d4  cmp  DWORD PTR [ecx+0x1c],0x8  <- set:   full at 8
	5145df  cmp  DWORD PTR [ecx+0x1c],edx  <- clear: full at 4 (edx=4 at 5145af)

with `+0x1c` the member count. **Which cap is which was not readable from the
numbers** — but the error each branch raises settles it, because the client names
them: bit 0 set sends `PARTYERR_MEMBER_FULL_EXP_SHARED_PARTY`, clear sends
`..._NONEEXP_SHARED_PARTY`.

So **bit 0 of the party's `+0x10` is the exp-sharing flag** — an entry this
project's open-items list has carried unnamed — and an exp-sharing party holds 8
while a non-sharing one holds 4. This is the error-code table paying off a third
time: it did not name a function here, it disambiguated two constants.

srrevamp's parties share experience unconditionally, so 8 applies. `MaxSize`
5 → 8, with `MaxSizeNotShared = 4` recorded beside it.

### A refusal that was right, on a number that was right

The comment being replaced had found two loops bounded at 8 near the party module
and **declined to use them**:

> they sit in CMainProcess functions that call CGuild__BroadcastToLocalMember,
> before the CParty code begins, so that 8 is far more likely a guild alliance's
> slot count (unions hold eight guilds) than a party's. A loop bound that lands
> on the expected number in the wrong module is a coincidence, not a citation.

The answer turned out to be 8. **The refusal was still correct**, and that is the
point worth keeping: a right answer reached on wrong evidence is not a recovery,
and adopting it then would have made every later reader believe a citation
existed where none did. The number is adopted now because the join-time check
itself says so. The old reasoning is preserved in place rather than deleted.

**What moved:** one more own-design value grounded, with a test walking a party
to the cap; `bit 0 of the party's +0x10` comes off the open list; the error table
proves useful for disambiguating constants, not only naming functions.

**Next step:** the same party function tests **bit 2** of those flags at 5145b6
and nothing names it. The other `PARTYERR_*` codes -- `OUT_OF_LEVEL`,
`TOO_LOW_CREATOR_LEVEL` -- point at level rules srrevamp has no equivalent for.

## 2026-09-16 (twentieth) — level 5 to start a party

The previous entry named the party level rules as next. One of the two codes it
pointed at does not exist in the server, and the other gave a clean rule.

### `OUT_OF_LEVEL` is client-only

`PARTYERR_OUT_OF_LEVEL` (`0x2c07`) appears in the client's message table, and a
level range between party members is the obvious thing it would mean. **The
server never returns it** — `0x2c07` is nowhere in its `.text`. Whatever enforces
a member level range, if anything does, is not in the party code. Recorded so the
next reader does not go looking for it there.

### `TOO_LOW_CREATOR_LEVEL` is level 5, at two sites

	513fe2  mov  eax,[edx+0x124]   <- vtable slot 73 = IGObj::GetLevel
	513fea  call eax
	513fec  cmp  al,0x5
	513fee  jae  ok
	513ff0  mov  ax,0x2c0a         <- PARTYERR_TOO_LOW_CREATOR_LEVEL

and identically at `00514218`. That is the fourth time the recovered vtable table
has paid off inside a fresh dig — slot 73 `GetLevel` again.

**Joining has no level requirement**, which is the half worth reading both sites
for. `FUN_00514170` reaches the level check only on the branch where the
character has no party; with a party in hand it compares against that party and
answers `0x2c1d` instead. So a level-1 character can be pulled into an existing
party but cannot start one.

### Shipped

`party.MinLevelToCreate = 5`, enforced in `Hub.Create`, with `Member.Level`
carrying the leader's level and `handlePartyCreate` reading it from the character
store. Tests pin the boundary (every level below 5 refused, 5 itself allowed
because the comparison is `jae`) and the join exemption.

**Six existing tests failed on the new rule, which is the right outcome** — they
were creating parties with level-0 leaders. Fixing them turned up a detail worth
noting: `character.MemStore.Create` and `GetByID` both return **copies**, so a
test cannot raise a level by writing to the returned struct; it has to go through
`SetLeveling`. The first fix did exactly that and silently did nothing.

**What moved:** another own-design value grounded and enforced, with the
surprising half (join is unrestricted) established rather than assumed; one
client-only error code identified as such.

**Next step:** bit 2 of the party flags, tested at 5145b6 and still unnamed --
the same place bit 0 was, so the same technique may name it.

## 2026-09-16 (twenty-first) — bit 2 resists, and a shipped value gets its check

The previous entry named bit 2 of the party flags as next, on the reasoning that
the technique which named bit 0 would work again. **It does not**, and the tick
is mostly the record of why plus a confirmation it turned up on the way.

### Bit 2 is not nameable by the two available levers

It is tested once, at `005145b6`, in the shape of a permission check: the actor
must equal the party's `+0xc` **or** bit 2 must be set, else the function
returns. That shape suggests "members other than the leader may invite" — and a
shape is not a meaning, which is the whole reason this project reads use-sites.

- **The error-code lookup fails.** What named bit 0 was the refusal each branch
  raised. Here the branch bails with a silent `ret` and no code, so the client
  names nothing.
- **Tracing the writer fails.** Offset `0x10` is generic enough that the binary
  has hundreds of unrelated writes to it, and none can be attributed to a party
  without another anchor.

Recorded in `party.go` beside the named bits so the next reader does not repeat
both blind.

### A value srrevamp already ships, now actually checked

Knowing bit 0 exists raised a question about something already shipped: the party
exp bonus is applied unconditionally, but the engine has an exp-sharing flag — is
the bonus gated on it?

**It is not.** The chain at `4d6bb9` applies the bonus when two things hold and
neither is the flag:

	4d6bc1  mov  eax,[edx+0x1c]   <- vtable slot 7 = IGObj::IsPC
	4d6bc8  cmp  eax,0x1          <- players only
	4d6bcd  cmp  DWORD [edi+0x1cb8],0 / je   <- and only with a party

So srrevamp is correct, and now correct *with a citation* rather than by not
having asked.

The same read settled a second thing that had been assumed. The member count the
bonus multiplies comes from `GObjPC::FUN_004ea230`, which is four instructions:
assert a party exists, then `return *(party + 0x1c)`. **That is the same field
the join-time cap compares against 8 or 4** — so it is the total party size, not
a subset filtered by range or eligibility, and passing `len(pt.Members)` is
right. A test now ties the two constants together, so changing `MaxSize` without
thinking about the bonus fails loudly.

**What moved:** a dead end documented with both techniques that failed; two
previously-unexamined assumptions behind a shipped value turned into citations;
`party + 0x1c` established as one field serving both the cap and the bonus.

**Next step:** `PARTYERR_CREATE_PARTY_REFUSED` and `JOIN_PARTY_REFUSED` (0x2c0c,
0x2c17) are the remaining party codes the server actually returns -- unlike
OUT_OF_LEVEL, which it does not.

## 2026-09-16 (twenty-second) — a tenfold overcount, and the floor that fixes it

The previous entry named two party codes as next. They exist in the server (one
site each), but `CREATE_PARTY_REFUSED` and `JOIN_PARTY_REFUSED` relay a player
declining an invite rather than encoding a rule with a value, so the tick went to
the systematic lever instead — and found a mistake in it.

### 704 was really 117

Two entries ago this project published: *"1,014 server functions return a known
error code, 704 of them still `FUN_`."* Building the domain attribution on top of
that produced an obviously wrong answer — **329 unnamed functions attributed to
PARTY**, which is not a believable shape for a game server. That implausibility
is what prompted the check, and the check found the cause:

**Error codes start at 1, and `mov eax,0x2` is overwhelmingly "return 2".**

	unnamed functions "returning an error code"   704
	...returning ONLY codes below 0x100           587
	0x0002 (PARTYERR_UNKNOWN_ERROR) attributed to 381 functions
	0x0004 (ERR_COMMON_TOO_FAR)     attributed to 335 functions

With a floor at `0x100` the same join gives **157 functions returning a real
error code, 117 still `FUN_`, 88 attributable to a single domain** — STRG 28,
GUILD 22, TC 11, FLEAMARKET 5, SKILL 5, PARTY 5.

The earlier entry is corrected in place rather than left to be quoted.

### Why this one slipped through

The low-code collision is the same *class* of error as the category collision
caught two entries ago — a value that means one thing in the table and another in
the wild — but it presented differently. The category collision announced itself
(`PARTYERR` inside a magic-option function, visibly absurd). This one produced
large, plausible-looking counts, and large numbers read as success.

**A join's failure mode is inflation, and inflation looks like a good result.**
The guard is to ask what the join would report if the key space overlapped
something common — here, small integers — rather than to admire the total. That
is now in the tool's docstring, which states the floor as the whole trick and
shows the numbers with and without it.

### Shipped

- `client/tools/ghidra/label_by_error_code.py` rewritten with the floor, the
  contamination figures, and `--out` for the table.
- `docs/protocol/error_attributed_functions.md` — the 88 attributions by domain,
  each row carrying the codes that justify it, and headed by a statement that an
  attribution is not a name.

**What moved:** a published count corrected by a factor of nine; 88 unnamed
functions attributed to a part of the game with evidence attached; a tool that
can no longer produce the inflated version.

**Next step:** the `TC` domain (11 functions) is unidentified -- its codes are
`TC_ERROR_OPEN_GOLD`, `TC_ERROR_OPEN_LEVEL`, `TC_ERROR_NOT_OPEN_7D`, so it is
something opened with a gold cost and a level requirement, and those are two
recoverable values.

## 2026-09-16 (twenty-third) — TC is the Training Camp, and an item-duplication bug

The previous entry named the unidentified `TC` domain as next. It is the
**Training Camp**, and reading its open handler turned up a real bug in srrevamp
on the way.

### TC named, with two constants

The codes say it outright — `TC_ERROR_TRAININGCAMP_NOTHING`,
`..._ALREADY_ENTRY`, `..._OTHER_TRAININGCAMP_ENTRY` — and the server's own log
string `"Failed TO Post AQ_TrainingCamp!"` agrees. `FUN_004e4680` is the open
handler and reads whole:

	if (GetLifeState() != 1)  return 0x6807;   // slot 62 -- must be alive
	if (GetLevel() < 0x3c)    return 0x6809;   // slot 73 -- LEVEL 60
	gold_hi = *(int *)(charData + 0x7c);
	if (gold_hi < 1 && (gold_hi < 0 || *(uint *)(charData + 0x78) < 100000))
	                          return 0x680a;   // 100,000 GOLD

Opening a training camp costs **100,000 gold** at **level 60**. srrevamp has no
academy, so these are recorded rather than used. Two things confirm themselves:
slots 62 and 73 from the vtable table again, and `charData+0x78` `RemainGold` as
a **64-bit** quantity with `+0x7c` its high half — which the server's own SQL
already implied by writing it `%I64d`.

### `SPECIFY_POSITIVE_NUMBER_ONLY` found a duplication bug

The `STRG` attributions showed `UIIT_MSG_STRGERR_SPECIFY_POSITIVE_NUMBER_ONLY`
(`0x1829`) raised from three separate storage handlers. Its companion `0x1814`
`..._ENABLEINPUT_FEWERTHAN_REMAIN` is the upper bound. **The engine guards both
ends of a quantity; srrevamp guarded only the upper one.**

`inventory.RemoveItem` checked `quantity > slot.Quantity` and nothing else. Every
negative value passes that, and the removal is

	slot.Quantity -= quantity

so a negative quantity **added items**. `internal/storage` had the guard;
`internal/inventory` did not, in both the memory and SQL stores. `AddItem` was
the milder version of the same gap — a silent no-op that reported success.

Fixed with `ErrInvalidQuantity` in all four places, and tests that assert the
holdings are unchanged after a refused call rather than only that an error came
back.

**A test caught a wrong assumption of mine mid-write**: the first version
asserted "a single stack of 5", but a `MemStore` with no max-stack source splits
into five slots of one. The store was right and the expectation was wrong; the
assertion now sums quantities instead of matching a shape.

**What moved:** a domain named and two of its constants recovered; an item
duplication path closed in both inventory stores, found by comparing srrevamp
against the engine's refusals rather than by reading srrevamp's code.

**Next step:** `STRGERR_CANNOT_DEAL_NORMALCY` appears in six separate STRG
functions and nothing has decoded what "normalcy" gates -- it is the most common
single refusal in that domain.

## 2026-09-16 (twenty-fourth) — the guild member cap, and two verifications

The previous entry named `STRGERR_CANNOT_DEAL_NORMALCY` as next. It is a
mismatch check inside a phase machine — `cmp ax,0x1` on a state, then a field
comparison, refusing when they disagree — so "normalcy" is the engine's phrasing
for "this trade is not in a state where that makes sense". That raised two
questions about srrevamp's trade code, and **both answers were already correct**:

- Acting on someone else's trade is structurally impossible: every `Hub` method
  keys off the caller's own `characterID`.
- Confirm-then-swap, the classic trade exploit, is already defeated —
  `SetOffer` clears **both** confirmations, so changing an offer forces the other
  party to confirm again. `SetOffer` also already rejects negative gold and
  quantity, the same rule this project only just added to inventory.

Verified rather than assumed, which is the point; the tick then moved to a domain
where srrevamp had nothing.

### Guilds had no member cap at all

`0x4c13` is `UIIT_MSG_GUILDERR_MEMBER_FULL`, and the join path pushes it when
`FUN_005d0fb0` answers 1. That predicate is short enough to read whole:

	level = *(char *)(*(int *)(guild + 4) + 0x38);
	if (level == 0)        { Assert; level = 1; }
	if (4 < (byte)(level-1)) Assert;                  // levels are 1..5
	return table[level-1] <= *(uint *)(guild + 0x24); // <- member count

The table is five dwords at `.rdata 0x00ade8dc`: **15, 20, 25, 35, 50** — and
five is exactly the range the assert allows, which is what makes the table
boundary certain rather than guessed.

**srrevamp's `Guild` is `{ID, Name, LeaderID, Members}` with no cap and no
level.** Every guild is therefore a level-1 guild, so `MaxMembers = 15` — taking
a larger entry would grant capacity the game makes you earn. The full table ships
as `MaxMembersByLevel` with `MaxMembersFor(level)` clamping to the engine's own
1..5, so adding guild levels later has the rule already written.

Enforced in both stores. The SQL one counts **inside the same transaction as the
insert**, so two simultaneous joins cannot both see room.

**Not claimed:** the three dwords following the table (5400, 50400, 135000) look
like a guild-experience curve. Nothing read so far uses them, so they are
mentioned and left alone.

**What moved:** a capacity rule that did not exist in srrevamp, grounded and
enforced with the cap and the check pinned together by test; two trade-exploit
questions answered against the code rather than assumed.

**Next step:** `GUILDERR_PERMISSION_DENIED` (0x18e6/0x18e7, and 0x4c1e) is raised
from 21 functions -- more than any other single guild code -- and srrevamp's
guild has only RoleMember and RoleLeader, so whatever permission model sits
behind those is richer than what it models.

## 2026-09-16 (twenty-fifth) — guild permissions are a bitmask, not a role

The previous entry guessed that whatever sits behind `GUILDERR_PERMISSION_DENIED`
is "richer than" srrevamp's two roles. It is, and now with a shape.

### The model

`FUN_005d0f80` is the predicate, and it is four lines:

	member = FindMember(characterID);
	if (member == 0) return false;
	if (member->rec == 0) Assert;
	return (*(uint *)(member->rec + 0x54) & required) == required;

So each member carries a **32-bit permission mask at `record + 0x54`**, a caller
passes the mask it needs, and **every** bit must be set — an equality, not a
non-zero test. That distinction is the whole reason to read it: a non-zero check
would let a warehouse-only member pass a two-bit requirement.

### What the bits gate, from the handlers rather than the positions

Seven call sites carry a required mask. Each one's meaning comes from the errors
its own handler raises:

| bit | mask | handler | evidence |
|---|---|---|---|
| 0 | 0x01 | `FUN_00514f10`, the join path | also raises `GUILDERR_MEMBER_FULL` |
| 3 | 0x08 | `FUN_005c7440`, `FUN_005c74d0` | raise `GUILD_WAREHOUSE_LIMIT` |
| 4 | 0x10 | `FUN_005c6480` | raises `GUILDERR_INVALID_MASTER_COMMENT`, `_TITLE` |

**Bit 2 (0x04) is not named.** Two call sites require it and neither handler
raises an error code, so nothing says what it gates. Bits 1 and 5-31 appear at no
call site — which is an absence of evidence, not evidence they are unused, and
the comment says so.

### Nothing enforces this yet, and that is scope rather than oversight

srrevamp's guild Store is Create/Join/Leave/Get. There is **no kick, no disband,
no invite** — so there is no permissioned operation to protect, and adding
enforcement now would guard nothing.

The divergence worth recording is `Join`. In the engine a character is brought in
by a member holding `PermInvite`; in srrevamp `Join` is self-service, so anyone
may join any guild by id, uninvited. That is a missing feature rather than a bug,
and `PermInvite` is the bit it will check when built.

Shipped as `guild.Permission` with the three named bits, a `Has` method
reproducing the all-bits equality, and a test that specifically fails if `Has`
is ever weakened to a non-zero check.

**What moved:** a permission model recovered with three of its bits named from
use-sites; the honest gap (bit 2, and bits nobody exercises) stated; a
divergence in `Join` written down with the bit that will close it.

**Next step:** bit 2's two call sites -- `GObjPC::FUN_004b1750` and
`FUN_005c49a0` -- raise no error codes, so naming it needs a different lever than
the one that named the other three.

## 2026-09-16 (twenty-sixth) — "no real friends-list data to RE" was untested

The previous entry named guild permission bit 2 as next. It gates a permission
srrevamp does not enforce, so the tick went looking for an ungrounded value in
code srrevamp actually runs — and found one hiding behind a claim.

### The claim

`friend.go` opened with:

> Entirely own design; no real friends-list data to RE.

The first half is true of the request/accept shape. **The second half was never
tested**, and it is wrong: the server has a friend system with its own error
family, and the domain attribution had already surfaced one function in it.

This is the same shape as the party cap, which was labelled "own design, and NOT
grounded" until the join-time check turned up. A package comment asserting
absence deserves the same scrutiny as a finding.

### The cap is 20

`FUN_005d7620` handles a friend request and checks the list before growing it:

	5d7734  mov ax,0x6409                   <- FRIENDERR_ALREADYFRIEND, just above
	5d7746  cmp DWORD PTR [esi+0x14],0x14   <- the friend count, against 20
	5d774a  jb  ok                          <- strictly fewer than 20 may add
	5d775d  mov ax,0x6408                   <- else FRIENDERR_FULLLIST

What ties `[esi+0x14]` to the friend list rather than to some other count is the
company it keeps: the comparison sits between an ALREADYFRIEND check and a
FULLLIST refusal, both named by the client.

The comparison is `jb`, so **20 is a full list, not a permitted one** — the same
kind of boundary the party cap needed read rather than assumed.

### What srrevamp had, and what it has now

**No cap at all, in either store.** Accepting a request inserted both directions
unbounded.

Now `MaxFriends = 20`, enforced at both moments the engine does:

- **on request**, because `FUN_005d7620` refuses there rather than letting a
  request sit and fail on acceptance;
- **on acceptance**, for **both** characters, because a friendship is mutual and
  both lists grow.

The SQL store counts inside the same transaction as the insert, and the check
sits after the `DELETE … RETURNING` that consumes the request — so a refusal
rolls that back and the pending request survives rather than being silently
eaten. A test asserts exactly that, not merely that an error came back.

**Not claimed:** the engine has `0x640f FRIENDERR_TARGETLISTFULL` for the other
side, but **the server never returns it** — `0x640f` appears nowhere in its
`.text`, like `PARTYERR_OUT_OF_LEVEL` before it. Where the engine enforces the
target's limit is not established. srrevamp checks both sides because it writes
to both; that is the conservative reading, and the comment says so rather than
implying the engine was read that way.

**What moved:** an untested absence claim replaced with a recovered constant;
a capacity rule that did not exist in srrevamp, enforced at both stores and both
moments, with the boundary and the rollback behaviour pinned by test.

**Next step:** `friend.go` still carries the request/accept shape as own design,
and the engine's `0x640a FRIEND_SYSCANCEL` / `0x640e FRIEND_SYSPROGRESS` suggest
a request lifecycle with states srrevamp does not model.

## 2026-09-16 (twenty-seventh) — auditing every "nothing to recover here" claim

The previous entry named the friend request lifecycle as next. The more valuable
thing it had actually produced was a **method**: two package comments asserting
absence had both been wrong, and the error-code table makes re-testing them
cheap. This tick applied that to all fifteen.

### The method, and what it does not prove

The server refuses actions with numeric codes the client maps to `UIIT_*` names,
so **a subsystem that exists in the server almost always has an error family**.
Its presence is evidence there is something to recover; its absence is evidence
there is not.

It is not proof. A constant reached on no failure path leaves no code, so "no
error family" narrows where to look rather than closing the question. Every
"holds" in the audit means *no engine error family was found*, and the doc says
so in those words.

### The probe lied first, and was caught

A first pass matched substrings and reported five domains that do not exist:
`mana` matched `FORT_MANAGER`, `leveldata` matched `RENT_EXP_ITEM`, and `quest`
matched `REQUESTED_JOB`, `QUESTION_GUILD` and `FREQUEST_WAR`. Same inflation
failure mode as the error-code join two entries ago — a key space overlapping
something common — caught this time before anything was written down. The fix is
to match the domain **prefix**, not the word anywhere in the name.

### Result

Of fifteen claims: **four were wrong or incomplete and are now recovered**
(party, friend, guild, inventory — all in previous entries), and **eleven hold**.
The two most worth stating as tested rather than assumed:

- **`duel`** — the only PvP codes are two spellings of `FRPVP_DURING_CHANGE`,
  about switching free-PvP mode. There is no challenge/accept/refuse family, so
  the duel system really is srrevamp's own invention. Marked tested in place.
- **`quest`** — only 4 genuine codes, all specific mechanics (Roc entrance,
  trap-making), no system limit.

Shipped as `docs/protocol/absence_audit.md`: the verdicts, the method, its
limits, and the false-positive warning so the next sweep does not repeat the bad
probe.

### Where this leaves the project

For every package that carries such a claim, the **values** half of the goal is
as closed as this lever can make it. What remains is the harder half — naming
functions, at **21.7%** on the server and **14.8%** on the client.

**What moved:** eleven bare assertions became tested ones and four had already
been overturned; a reusable audit with its own failure mode documented.

**Next step:** the values lever is close to exhausted, so the naming half is
where the remaining work is. The client is the weaker side and has no
`## Illegal ##` convention -- finding what it *does* have is the open question.

## 2026-09-16 (twenty-eighth) — the client's naming lever, and a probe I should have re-run

The previous entry closed the values half and named the open question: the client
has no `## Illegal ##` convention, so what does it have? **Asserts, intact.**

### A probe I abandoned instead of fixing

Seventeen entries ago this project ran a source-path probe against the client,
got nothing, and moved on — noting the regex might be wrong without re-testing
it. The regex was wrong. The client has **424 assert sites across 123 source
files**, and every one carries a path like
`D:\vss-od\Silkroad\Client\client\CObjCharacter.cpp`.

Nothing was published on that empty result, so no claim needs retracting. But
"the probe might be wrong" written down and not acted on cost seventeen entries.

### What an assert carries

	FUN_0049e490(0x765, "...\CObjCharacter.cpp", "dwSlotPos < EQUIP_VISUAL_COUNT");

A **source file** (attributing the enclosing function to a translation unit), a
**line number** (ordering functions within it), and the **expression text**,
which names variables, members and constants from the original source. 307
distinct expressions, 295 functions carrying one, **263 of them still `FUN_`**.

The obvious regex fails: Ghidra breaks the call across two lines, so a
line-oriented grep finds the file and loses the expression — a first pass counted
34 expressions where there are 307.

### Read the expression, not just the guard

The guard gives the bound; **the operator in the expression decides the
off-by-one**, and both shapes occur:

| constant | expression | guard | value |
|---|---|---|---|
| `EQUIP_VISUAL_COUNT` | `dwSlotPos <` | `8 < p` | 9 |
| `DEFAULT_WEAR_NUM` | `nDefaultWearNum <` | `1 < p` | 2 |
| `AUTO_POTION_COUNT` | `byType <` | `2 < p` | 3 |
| `MAX_MAGPARAM_PER_ITEM` | `m_btMagicParamNum <=` | `0xc < v` | **12**, not 13 |

"One past the guard" as a rule would have made the last one wrong. It also has an
independent check: the **server** bounds the same quantity with `0xc <` at three
sites and logs `"Item's MagParamNum(%d) is out of range"`. Two binaries, one
number.

**None of these is used by srrevamp** — no magic options, no quickslots, no
auto-potions, and its equipment slots are server-side rather than the client's
visual ones. They are recorded because they are recovered, and the doc says so
rather than implying a pending fix.

### Shipped

`client/tools/ghidra/harvest_client_asserts.py` and
`docs/protocol/client_asserts.md`: the constants with their operators, the
whole-file regex, and 263 unnamed functions placed in a translation unit.

**What moved:** the client's naming lever identified after being wrongly
abandoned; 263 functions attributable to a source file; four constants recovered,
one of them confirmed across both binaries.

**Next step:** the attribution is per-file, not per-function. `CObjCharacter.cpp`
alone has 23 asserts in it -- pairing their LINE NUMBERS with function order
would turn a file attribution into an ordering, which is the step from "belongs
here" toward a name.

## 2026-09-16 (twenty-ninth) — interpolating the client attribution, and withholding 88% of it

The previous entry named this: pair the asserts' line numbers with function order
to turn a file attribution into something stronger. Two tests were run and both
changed the answer.

### The naive form is unsound

Within a file, address order should match source-line order. Of 172 adjacent
pairs, **only 119 (69.2%)** are ordered. The violations have a shape —
`line 1084 -> 23`, `2234 -> 897`, `4392 -> 2339` — large then small, i.e. a
translation unit emitted in **several separate runs**. Splitting on that: 123
files, 176 ascending runs, 1.43 per file.

### The rule that holds, and its reach

*If the nearest asserted function below and above name the same file, the one
between is in that file.* Leave-one-out over the 295 asserted functions is
**110/110 correct**.

**The test cannot reach far.** Its spans are bounded by assert density; applied
to unnamed functions the spans have a median of **127** and a maximum of **516**.
Only **12%** of the 4,972-function yield falls inside the validated range.

### A second validator that cannot settle it

19,154 client functions already carry a `Class::` prefix, so the interpolated
file can be checked against it. Agreement is **61.5%**, and only 72% even at span
<= 30 where leave-one-out said 100%.

That is not proof of error. The two measure different things: a `.cpp` holds
several classes, and the biggest disagreements are `UI_ALCHEMYBOX` (209) and
`UI_SILKMALL` — **module attributions from an earlier pass, not real class
names**. Comparing one inference against another settles nothing, and saying so
is more useful than picking whichever number is larger.

### What shipped, and what did not

**579 interpolated functions in spans <= 30**, where leave-one-out has coverage
(65 predictions there, all correct). Total client attribution: **263 direct + 579
= 842**.

**4,393 are withheld.** The rule may well hold for them, but nothing available
validates a 500-function span, and this project has twice published a number that
looked like success and was inflation — the 704-function error-code join, and the
329 "party" functions. The pattern is consistent enough to plan around.

**What moved:** a plausible technique tested to destruction and then salvaged at
the scale it survives; client attribution more than tripled, with the unvalidated
majority named and left out.

**Next step:** what would validate a long span is an independent per-function
signal that is not itself an inference -- the asserts' LINE NUMBERS are one, since
a function's line must fall between its neighbours' if the run is contiguous.
That is testable on the 295 asserted functions.

## 2026-09-16 (thirtieth) — the withheld 4,393, released; and a matcher that lied twice

The previous entry withheld 88% of the client attribution as unvalidated and
named what would settle it: *"an independent per-function signal that is not
itself an inference"*. There is one, and it was already in the dump.

### RTTI is data, not inference

5,545 client functions carry a class recovered from the binary's own
`ClassHierarchyDescriptor`. The previous entry lumped these in with the
call-graph and module attributions and dismissed the whole set as "one inference
against another" — **too broad**. The module ones are inferences; the RTTI ones
are read out of the binary.

### The matcher was the problem, twice

Comparing class name to file name as strings gives **15.1% agreement**, and the
failures are `CResObjSimple` vs `ResObject.cpp`, `CCompChar` vs
`CompoundObj.cpp`, `CICUser` vs `ICharactor.cpp` — obviously the same file,
invisible to a substring test.

That is the second probe in two entries whose own logic produced the misleading
answer; the first was substring-matching error domains, which invented five that
do not exist. **When validating a mapping, test consistency, not string
similarity.**

### Consistency settles it

Does each RTTI class land in one file? **79 of 80 (98.8%)**, against a **7.2%**
baseline for attribution drawn at random over the same file distribution. Every
mapping is coherent: `CCompChar` -> `CompoundObj.cpp`, `CCObjCharacter` ->
`CObjCharacter.cpp`, `CResObjSimple` and `CResChar` -> `ResObject.cpp`.

And it holds where leave-one-out could not reach:

	span <= 30   100%  (n=19)      span <= 500  100%  (n=15)
	span <= 100   98%  (n=41)      span > 500   100%  (n=5)

**The long buckets are small — 20 samples above span 100.** Evidence, not proof,
and the doc prints the sample sizes rather than summarising them as "validated".

### Released

All **4,972** interpolated functions. Total client attribution: **263 direct +
4,972 = 5,235** of 43,460 functions, up from 263 two entries ago.

Withholding them last entry was right on what was then known — the only validator
available was disagreeing. It was superseded by finding a better validator, not
by deciding the old evidence mattered less.

**What moved:** the client's file attribution went 263 -> 842 -> 5,235 across
three entries, each step gated on a test rather than on the yield looking good;
and a validation technique (consistency over string similarity) that has now
failed twice as string matching.

**Next step:** attribution is not a name. `CompoundObj.cpp` holds 229 attributed
functions and the asserts inside it name members and locals -- `m_btMagicParamNum`
and the rest -- so per-function naming from expression text is the next rung.

## 2026-09-16 (thirty-first) — three levers measured, three exhausted, and the ceiling

The previous entry named per-function naming from assert expression text as next.
The client's asserts carry no `__FUNCTION__`, so they cannot name functions —
they name **members** (79 distinct, e.g. `m_btMagicParamNum`), and client runtime
structs are not what srrevamp reads. So the tick measured the naming levers
instead of guessing which had yield left.

### Vtable slots applied to implementations: spent

209 slots reach **275 distinct implementation addresses** across the 14
IGObj-family vtables — not 14x209, because most virtuals have a single
implementation shared by every derived class. **271 are already named**; 4 remain,
all `IGOBJ::` spelling variants. Applied.

### The server names its own functions in log calls — and that is spent too

The server's logger passes the function's name as an argument:

	CGameServer::FUN_00936640(0x2000001, "## %s %s %d ## CharName[%s]...",
	                          "...\GStorage.cpp", "CGStorage::SetItem", 0x26e, ...)

**106 distinct `Class::Method` literals** exist (the client has 1). An earlier
sweep here missed them by looking for `::` *inside format strings*, where these
sit as a separate argument.

The control settles both questions at once: of the 108 functions carrying such a
literal, 104 are already named, and in **104 of 104 the literal matches the
existing name**. So the literal is the function's own identity, and a previous
pass already applied it. Four remain; **three are not applied** because
`AI::CMsg` and `AI::CSquad` look like RTTI type tags rather than methods.

### The ceiling, measured

Of **26,727** unnamed server functions, only **5,971 (22.3%)** contain any string
literal. The other **20,756 cannot be reached by a text-based lever at all**. And
**13,408 of the unnamed are under 128 bytes** — accessors, thunks, template
instantiations.

That is the honest shape of the gap between 21.7% and 100%: most of it is not
game logic, and most of what remains has no text to name it by.

### What this tick is

Mostly negative, and deliberately so. Three levers were measured rather than
re-run on the assumption that a big multiplier was waiting — the vtable one
looked like 14x and is 1.3x. `docs/protocol/naming_ceiling.md` records all of it
so the next pass does not repeat the estimate.

**What moved:** four implementations named; three levers marked exhausted with
the evidence; a measured ceiling for text-based naming.

**Next step:** naming now has to come from structure rather than text -- call-graph
position, vtable shape, data-flow into known fields. The client's 5,235 file
attributions are the largest untapped structural signal, since a file groups
functions that a call graph would otherwise have to rediscover.

## 2026-09-16 (thirty-second) — a constant that was named without being checked

The previous entry pointed at structural naming as the remaining work. Before
starting something that large, a cheaper question: does srrevamp handle every
item category the real tables contain? It does not, and the reason was a name
nobody had tested.

### `FamilyAccessory = 7` is not accessories

`equipment/rules.go` carried `FamilyAccessory = 7` among its TypeID3 families.
**Every TypeID3 == 7 row in a real itemdata is a JOB SUIT** —
`ITEM_EU_F_TRADE_TRADER_01`, `ITEM_CH_M_TRADE_HUNTER_04_01`,
`ITEM_CH_F_FRPVP_VOUCHER_D` — 111 items across TypeID4 1, 2, 3, 5, 6, 7 for
trader, thief, hunter and free-PvP. The name was invented and never checked
against the table it describes.

It is the same failure as `party.MaxSize` and `friend`'s "nothing to RE": a
plausible statement written once and quoted thereafter. The difference is that
those two asserted an absence and this one asserted an identity, so the absence
audit could not have caught it.

### Where accessories actually are

Two families, one per race, each holding exactly the same three pieces —
measured over a complete itemdata, **99 items apiece**:

	TypeID3  5  China   TypeID4 1 earring, 2 necklace, 3 ring
	TypeID3 12  Europe  TypeID4 1 earring, 2 necklace, 3 ring

**Neither family was in srrevamp's list**, so `SlotFor` returned "not
equippable" and **594 real items could not be worn**.

### Shipped

`FamilyJobSuit = 7` replacing the wrong name, `FamilyChinaAccessory = 5` and
`FamilyEuropeAccessory = 12` added, `PieceEarring/Necklace/Ring` as their own
numbering (the armour pieces use the same 1/2/3 for different things), and
`SlotEarring`, `SlotNecklace`, `SlotRing` wired through `SlotFor` and the SQL
store's slot validation.

**The slots are APPENDED, not inserted.** A `Slot` is persisted as its integer,
so giving an existing value a new meaning would silently move every equipped item
on every live character. A test pins all twelve slot numbers for exactly that
reason, and a second asserts that a job suit resolves to no slot at all.

**What this tick is:** checking a name rather than trusting it. The catalogue of
such names is small and finite, and two of them have now been wrong.

**What moved:** 594 items became equippable; a misnamed constant corrected against
the table it claims to describe; three slots added without disturbing persisted
data.

**Next step:** the same question for the other invented names in that file --
`PieceHelm..PieceBoots` were measured ("136-140 of each, with no exceptions") but
`SlotExtra` is described only as "tracked but has no gameplay yet", which is a
placeholder rather than a reading of anything.

## 2026-09-16 — the engine has an item-to-slot resolver, and it named slot 8

The previous tick ended by asking what `SlotExtra` was. The answer is not in the
item table and not in the client: it is a single server function, and finding it
settled the whole slot model rather than one name.

### Finding it

`docs/protocol/error_codes.md` already carried `0x180e
UIIT_MSG_STRGERR_EQUIPITEM`. Three sites in the server return it; the middle one
is inside `CGItemEquip::vslot_317` (`0x00497070`), the equip check. That function
delegates the actual slot question to `GObjPC::FUN_00496c20` (`0x00496c20`) —
**the engine's item-to-slot resolver**, a switch on the item's packed type word.

This is the error-code table paying for itself a second time. The route to the
function was a message name, not a guess about what an equip check might be
called.

### What the resolver says

Full table in `docs/protocol/ITEM_FORMAT.md`. The load-bearing part is the armour
arm, which maps `TypeID4 -> slot` as

	1 -> 0   2 -> 2   3 -> 1   4 -> 4   5 -> 3   6 -> 5

**a permutation, not the identity.** srrevamp's `Slot` order came from the
client's equipment-window artwork; the piece numbering came from the item table.
That permutation is exactly the map between them. Two independently derived
orderings agreeing on a non-trivial permutation is not a coincidence that a wrong
model survives — **srrevamp's slot numbering is the engine's own.**

Verified cell by cell against a real client's complete itemdata: 11,772
`TypeID1 == 3` rows, and the codename suffixes settle each armour row
independently of the switch (`_HA_`/`_CA_` head, `_SA_` shoulder, `_BA_` body,
`_LA_` leg, `_AA_` arm, `_FA_` foot). No disagreement anywhere.

### Three things srrevamp had wrong

- **Slot 8 is the JOB SUIT.** `TypeID3 == 7` returns 8, and every row there is a
  trade outfit. `SlotExtra` was a placeholder; it is now `SlotJobSuit`, and 128
  more real items equip.
- **There are TWO ring slots.** `vslot_317` demands an exact slot match
  everywhere except a ring, where it accepts 11 **or** 12. srrevamp had one.
- **Ammunition is equipped, in the shield slot.** The resolver has a second arm
  for `TypeID2 == 3, TypeID3 == 4` returning 7. A bow user gives up the shield to
  carry arrows. srrevamp refused quivers outright — another entry in the
  "refuses what the engine allows" column, alongside the 517 skills.

### The correction that matters most

`refdata/item.go` carried a note, written the same day, saying `SlotFor` was
"already correct about this for a reason worth noting rather than by luck: it
rejects anything whose TypeID2 is not TypeEquipment (1) before it looks at
TypeID3 at all, so ammunition never reaches the shield branch."

**Rejecting ammunition is not correct — it is the bug.** The note reasoned
carefully about srrevamp's own code and never asked the engine, then congratulated
the code for the behaviour that was wrong. A plausible-sounding mechanism is not
evidence about the game, and writing one down makes the error harder to find
later, not easier.

### The names came from the client, and were already in the repo

`docs/protocol/EQUIP_SLOTS.md` has listed the equipment window's per-slot artwork
since it was written:

	8  equip_slot_specialdress.ddj   11  equip_slot_l_ring.ddj   12  equip_slot_r_ring.ddj

The artwork knew there were two ring slots before this project did, and named
slot 8 before the item table was asked what lives there. `SlotRing`/`SlotRing2`
are therefore `SlotRingLeft`/`SlotRingRight` — the game's own words. **A
recovered artefact sitting unread is indistinguishable from one not recovered.**

### Free re-confirmations

`vslot_317` independently re-confirms four already-shipped values from a source
none of them came from: `ReqGenderAny == 2` and `CountryAny == 3` (each is the
value that makes the comparison pass), and `ReqStr`/`ReqInt` tested against
`GetParam(1)` and `GetParam(2)` — the Strength and Intellect param ids.

### Shipped

`SlotJobSuit` (was `SlotExtra`), `SlotRingRight` added at 12,
`SlotRing -> SlotRingLeft`, `TypeExpendable`, `FamilyAmmunition`, `MaxEquipSlots
= 13`, `NoSlot = 0xff`, and `SlotAccepts` for the ring pair. `SlotFor` now mirrors
the resolver arm for arm; `Refusal` goes through `SlotAccepts`.
`TestSlotForMatchesEngineResolver` holds all 23 representative rows,
`TestRingTakesEitherSlot` the pair, `TestSlotsFitEngineBound` the 13-slot bound.
Slot 12 is appended, so no persisted value changes meaning.

**What moved:** the equipment slot model went from "eight slots the client's
artwork implied, plus four guesses" to the engine's own thirteen, with a
use-site for every one.

**Next step:** `WearableSlots` is the last unexamined claim in that file — it
asserts the accessories carry no model the client draws, which is a statement
about the client that has never been checked against the client. The avatar's
equip-visual struct keeps *eight* entries twelve bytes apart, which is where to
look.

## 2026-09-16 — the client's half of the slot model, and a correction to the tick above

The previous tick ended pointing at `WearableSlots`: it asserted the accessories
"carry no model the client draws", which is a statement about the client that had
never been checked against the client. Checking it found the claim true, a
neighbouring one false, and a mistake in the tick that set the question.

### EQUIP_VISUAL_COUNT is 9, and that is the line

`CObjCharacter.cpp` asserts the bound twice, worded differently, which is what
makes the off-by-one safe:

	:1893   guard `8 < dwSlotPos`                "dwSlotPos < EQUIP_VISUAL_COUNT"
	:770    guard `p < 0 || 8 < p`   "(nEquipSlot >=0 ) && ( nEquipSlot < EQUIP_VISUAL_COUNT)"

Both stop at 8 and both expressions are strict `<`, so the count is 9 — slots
0..8. It bounds a nine-entry array at `CObjCharacter+0x38`, stride twelve.

### The accessories really are not drawn

Not by absence of evidence — by the client's own branch. Its appearance installer
(`0x00a61010`) splits on the slot before touching a model:

	if (8 < slot) {                        // 9..12
	    if ((slot < 0xd) && (item != 0))
	        FUN_00a5ff00(slot, item);      // a separate path
	    return 0;                          // no mesh, no visual record
	}
	// 0..8 fall through to the +0x38 array and the model attach calls

So `WearableSlots` was right to exclude them, and now has a citation instead of an
assertion. `slot < 0xd` is also a **third independent witness** for the 13-slot
bound, from the other binary.

### But the job suit is drawn, and was missing

Slot 8 is inside that range. The client's own item-to-visual-slot resolver,
`GlobalDataManager::FUN_009db5e0` (`0x009db5e0`), sends `TypeID3 == 7` --
`(w & 0x780) == 0x380` -- to slot 8, which is on the mesh path. A trade outfit is
worn and seen. `WearableSlots` now has nine entries, and a test holds the two
lists to the split the installer makes: `WearableSlots` exactly 0..8,
`AccessorySlots` exactly 9..12, together covering all 13 with no overlap.

### The cross-binary confirmation is now complete

`FUN_009db5e0` is the client's `GObjPC::FUN_00496c20`, arm for arm: the same
armour permutation `1→0 2→2 3→1 4→4 5→3 6→5`, weapons to 6, shields to 7 by
`TypeID3 == 4` with `TypeID4` in {1,2}, job suits to 8, and accessories to
9/10/11 by `TypeID4` 1/2/3 under `TypeID3` 5 or 12. The character-appearance
packet parser that calls it (`0x009de2f0`) filters with byte-identical bitfield
tests to the server's: `& 2 == 0`, `& 0x1c == 0xc`, `& 0x60 == 0x20`.

Two binaries, compiled separately, agreeing on all twelve slots and on the type-id
packing that addresses them.

### THE CORRECTION: "SlotExtra was an invented name" is wrong

v0.1.225 renamed `SlotExtra` to `SlotJobSuit` and justified it by calling the old
name a placeholder this project made up. **It was the client's own word.** The
equip-visual debug dump (`0x00a5e360`) prints this slot as `"EXTRA [ %d ] [ %d ]"`,
reading `this + 0x98` — which is `0x38 + 8*0xc`, slot 8 exactly.

What was a placeholder was the *comment*, "tracked but has no gameplay yet",
which described this project's ignorance rather than the slot. The rename still
stands: the client has two names for slot 8 and they disagree (`EXTRA` in the
debug dump, `specialdress` in the window artwork), and the item table breaks the
tie. But the stated reason was false, and a false reason attached to a correct
change is exactly the failure this tick's own predecessor was written to warn
about — it would have taught the next reader that `EXTRA` in the binary is not
worth trusting.

Noted in place in `equipment.go` and `EQUIP_SLOTS.md` rather than quietly fixed,
so a reader who finds `EXTRA` in the client does not conclude the Go name drifted.

### Shipped

`EquipVisualCount = 9`; `SlotJobSuit` added to `WearableSlots`; the
`AccessorySlots` claim replaced with the installer branch that proves it;
`TestWearableSlotsAreTheVisualRange` holding both lists to the client's split;
the v0.1.225 justification corrected in the two places it was recorded.
`EQUIP_SLOTS.md` gains the bound, the installer branch, the client resolver and
the two-names note.

**What moved:** the slot model is now confirmed from both binaries independently,
and every membership claim in `equipment.go` has a use-site behind it.

**Next step:** `DEFAULT_WEAR_NUM == 2` fell out of the same file
(`CObjCharacter.cpp:771`, guard `p < 0 || 1 < p`) and is unexplained — two
"default wear" sets, selected by `FUN_00a5cca0(this, nDefaultWearNum, nEquipSlot)`
alongside a character-data byte at `+0x9c`. That is what a character with an empty
slot is drawn wearing, which this project currently handles by giving every new
character a real starting kit.

## 2026-09-16 — DEFAULT_WEAR_NUM, and what a bare slot is drawn as

The last tick left `DEFAULT_WEAR_NUM == 2` unexplained. It is fully recovered
now, and it answers a question `GiveStartingKit` had been guessing at.

### The setter and the builder

`CObjCharacter::FUN_00a5cca0` (`0x00a5cca0`) takes `(nDefaultWearNum,
nEquipSlot)` and asserts both through the game's own source:

	CObjCharacter.cpp:770   "(nEquipSlot >=0 ) && ( nEquipSlot < EQUIP_VISUAL_COUNT)"
	CObjCharacter.cpp:771   "(nDefaultWearNum >=0 ) && ( nDefaultWearNum < DEFAULT_WEAR_NUM)"

Guards `p < 0 || 8 < p` and `p < 0 || 1 < p`, so 9 and 2. It keeps the results
in a two-entry array at `this + 0x11c`, eight bytes apart.

`CObjCharacter::FUN_00a5c760` (`0x00a5c760`) builds what to draw, and it is an
ordinary **packed TypeID** — the same 16-bit word the equip resolvers read. It
starts at `0x2c` (TypeID1 3, TypeID2 1, family and piece clear), fills the
family from the race byte at character-data `+0x9c`, and the piece from the wear
number. Letting Python apply the masks rather than reading them by hand:

	China   garment/none  wear 0 -> 0x18ac  3/1/1/3     wear 1 -> 0x20ac  3/1/1/4
	China   protector/up  wear 0 -> 0x192c  3/1/2/3     wear 1 -> 0x212c  3/1/2/4
	Europe  robe/none     wear 0 -> 0x1cac  3/1/9/3     wear 1 -> 0x24ac  3/1/9/4
	Europe  light/up      wear 0 -> 0x1d2c  3/1/10/3    wear 1 -> 0x252c  3/1/10/4

**Every one is TypeID4 3 or 4 — the mail and the pants.** Those are the two
slots a character is never seen bare in, and nothing else gets a default. The
race byte at `+0x9c` is 0 China / 1 Europe, matching `Country`.

### The family follows what you are already wearing

The second input is `CObjCharacter::FUN_00a5c670` (`0x00a5c670`), which walks the
nine visual slots and returns the class of the first armour it finds: 1 for
TypeID3 1 or 9, 2 for 2 or 10, 3 for 3 or 11, 0 if it reaches the end. Its loop
bound `8 < i` is a **fourth independent witness** for EQUIP_VISUAL_COUNT.

The classes then collapse into two: the client's switch groups `case 0: case 1:`
and `case 2: case 3:`, so wearing nothing gets the same default as garment/robe,
and armour/heavy the same as protector/light. Modelled as a comparison rather
than a four-way table, because that is what the binary does.

### Why it was worth recovering

`GiveStartingKit` carries a long note about not drawing a default set, because
"that would make the character look dressed while the equipment window, the
inventory and the server all disagree". That reasoning is right, and it was
missing a fact: **the client already does this, for exactly two slots, by
design.** Which also explains the shape of the original's starter kit — it ships
no hat, shoulder guard or gauntlet because a bare helm slot is not a bare
character. The client draws nothing there and never did.

So srrevamp does not need to prevent a character unequipping their mail for
decency's sake, and a kit that omitted the mail would still look dressed — which
is the silent disagreement, not the loud one. A test now holds the kit to
covering both default-wear slots for that reason.

### Shipped

`DefaultWearCount = 2`, `DefaultWearSlots = {SlotMail, SlotPants}`,
`DefaultWearPieces`, `ArmorClassNone/Garment/Protector/Armor`, `ArmorClassOf`
and `DefaultWearFamily`, all in a new `defaultwear.go` with the addresses and
source lines. `TestDefaultWearTypeWords` recomputes all eight type words from
the client's own masks rather than asserting the table above;
`TestStartingKitFillsTheDefaultWearSlots` pins the kit to them.

**What moved:** the last unexplained constant from CObjCharacter.cpp is closed,
and a design note that was reasoning without a fact now has one.

**Next step:** `FUN_00a5ff00(slot, item)` — the path slots 9..12 take instead of
the mesh, from the appearance installer. It is what an accessory *does* do
visually, and it is the one branch of that function still unread.

## 2026-09-16 — item sets: the mechanism recovered, the bonus disclosed

`FUN_00a5ff00` was the last unread branch of the client's appearance installer
— the path slots 9..12 take instead of the mesh. It is not a rendering path at
all. It is the **item set** tracker, and pulling on it recovered a whole system
plus one new grounded itemdata column.

### What the client keeps

A map, per character, from set id to a two-word record:

	FUN_00a5ff00(slot, item)   bit = 1 << slot
	                           if ((bit & mask) == 0) { count++; mask |= bit; }
	FUN_00a5ffd0(slot, item)   if ((bit & mask) != 0) { count--; mask &= ~bit; }
	                           if (mask == 0) erase the entry
	FUN_00a60220(item)         return count == popcount(setdef + 0xa4)

`0x00a5ff00`, `0x00a5ffd0`, `0x00a60220`. Both map helpers (`0x00675f60`,
`0x00a5edf0`) are red-black tree walks — `+0x15` is `_Isnil`, `[3]` the key — so
it is genuinely `map<SetID, {slotMask, count}>`. `FUN_009733c0` (`0x009733c0`) is
an unrolled popcount. **A set is complete when the character wears one piece in
each of its slots** — distinct slots, not items. When it matches, the installer
sets a byte at `character + 0x1a0`.

The removal path `0x00a60160` derives its bit from
`GlobalDataManager::FUN_009db5e0`, last tick's visual-slot resolver, which is
what proves the bits are slot numbers rather than anything else.

### The game's own names

	server table     _REFSETITEMGROUP,  class CRefSetItemGroup, record stride 0x54
	client file      textdata\refsetitemgroup.txt
	server class     CSetMagicOptionOP : IBindingOptionOP
	asserts          "This SetID[%d] is not registered in _RefSetItemGroup table!!"
	                 "Invalid Set ID is used!! [SetID:%d] [MagicOptGroupID:%d]"

So a completed set grants a **magic option** — the same mechanism as an item's
own magic options, bound by the set rather than by the item.

### itemdata column 62 is SetID, grounded twice

**From the binary:** `RefObjItem::vslot_001` (`0x006a3d50`) reads its fields
consecutively — `+0x198 +0x19c +0x1a0 +0x1a4 +0x1a8 +0x1ac`. The exporter
already pinned 57..61 to the first five (61 is ItemClass, held by the engine's
own `"ItemClass must be not zero"` assert), so column 62 is `+0x1ac`. And
`CSetMagicOptionOP::PutoutTheBindingItem` (`0x0066c620`) reads exactly
`*(item[0xd] + 0x18) + 0x1ac` and logs it as `[SetID:%d]`.

**From the data:** joining column 62 to the set table's own code names, the race
and gender spelled in an item's name match those in its set's name on **360 of
360** rows that spell both. Three decoy columns that also hold only legal set ids
score ~25%, which is chance for a four-way split.

The first probe of that join reported 0/0 — `\b(CH|EU)_(M|W)\b` cannot match
`CH_M_HEAVY`, because `_` is a word character and `M\b` fails before it. The
probe was broken, not the hypothesis; checking it was the difference between
this column and no column.

### The shapes agree with the mechanism

Of the 42 sets a real itemdata references, **30 list more than one item for some
slot** (gender and rarity variants) — counting items would never complete those,
counting distinct slots does, and that is what the client's `(bit & mask) == 0`
guard is for. The slot shapes:

	36 sets  {0,1,2,3,4,5}   the six armour pieces
	 2 sets  {9,10,11}       the three accessories
	 2 sets  {6}             a weapon alone
	 2 sets  {7}             a shield alone

Every piece of every set resolves through `SlotFor`, none left over.

### What is NOT known, and why it is not guessed

The set table's twelve trailing columns hold the reward. A populated row reads
`0 21 2 0 3 0 4 0 0 0 0 0`, which admits at least three readings — six
(count, group) pairs, a group id followed by thresholds, or two blocks of six —
and no loader was found that settles them. **So srrevamp models set MEMBERSHIP
and COMPLETION, which are recovered, and grants nothing.** Guessing a pairing
here is exactly the shape of mistake that cost this project characterdata col 79
twice.

### Shipped

`refdata.Item.SetID` from column 62, wired through the exporter, the CSV
importer (appended as a strict suffix, so older exports still load), and the SQL
store — the field-by-field round-trip tests caught the last of those, which is
what they exist for. New `equipment/itemset.go` with `SetProgress`, `SetsWorn`
and `Complete`, mirroring the client's counter; four tests including the
slots-not-items distinction and the ring pair.

**What moved:** a whole system identified by the game's own names, one new
itemdata column confirmed from two directions, and an honest boundary drawn
around the part that is not decoded.

**Next step:** `MagicOptGroupID` in that second assert is the link from a set to
its reward, and magic options are a system this project has touched before
(`ReferenceData`'s magic-option validators were named in the assert-harvest
tick). Following the group id from `CSetMagicOptionOP` into the magic-option
tables is the way into the twelve columns that does not require guessing them.

## 2026-09-16 — the set bonus, decoded one tick after being disclosed

The previous entry said the set table's twelve trailing columns "admit at least
three readings and no loader was found to settle them", and shipped nothing on
that basis. Following `MagicOptGroupID` out of the second assert, as that entry
proposed, settled them — **without ever reading the loader**, which is the part
worth recording.

### The chain

	CSetMagicOptionOP::vslot_003 (0x0066c060)    recompute, per dirty set
	  -> FUN_0066c360 (0x0066c360)               set -> MagicOptGroupID
	    -> FUN_0066c3d0 (0x0066c3d0)             worn count -> tier key
	    -> GObjPC::FUN_0066e020 (0x0066e020)     set row from _RefSetItemGroup
	    -> FUN_006a7320 (0x006a7320)             tier key -> group id
	  -> FUN_006beec0                            group id -> the option list
	                                             (fails => the [SetID][MagicOptGroupID] assert)

Two of those are small enough to read outright:

	FUN_0066c3d0(count):   if (count < 2) return 0;  return 1 << (count - 2);

	FUN_006a7320(row):     while (bit != 0) { if (found(bit)) return group; bit >>= 1; }
	                       return 0;

So **bonuses start at two pieces**, the tier key is a shifted bit, and the
search walks DOWN one piece at a time — meaning the rule is "the highest tier
you have reached", not an exact match. Five pieces of a six-slot set earn the
four-piece bonus.

### The columns, settled by prediction rather than by pattern

`refmagicoptgroup.txt` names its own tiers: group 2 is `MAGIC_11_SET_A_
DEFENSE_2`, group 3 `..._DEFENSE_4`, group 4 `..._DEFENSE_6`. In the set row
for `ITEM_11_SET_A_CH_M_HEAVY` those three sit at positions **2, 4 and 6** of
the twelve.

If position means piece count, that predicts something checkable: an ACCESSORY
set has only three slots, can never reach six pieces, and must therefore leave
position 6 empty. It does —

	ITEM_11_SET_A_CH_M_HEAVY   pos 2 DEFENSE_2   pos 4 DEFENSE_4   pos 6 DEFENSE_6
	ITEM_11_SET_A_ACCESSORY    pos 2 ACCESSORY_2 pos 4 ACCESSORY_4 pos 6 (empty)
	ITEM_11_SET_B_CH_M_HEAVY   pos 2 B_DEFENSE_2 pos 4 B_DEFENSE_4 pos 6 B_DEFENSE_6
	ITEM_11_SET_B_ACCESSORY    pos 2 B_ACCESSORY_2 pos 4 B_ACCESSORY_4 pos 6 (empty)

— three name-to-position agreements plus an absence the reading predicts in
advance. **The last ten of the twelve columns are the MagicOptGroupID for
wearing exactly N pieces, indexed by N (2..11).**

### The column that looks like a tier and is not

Positions 0 and 1 remain unknown, and position 1 is the interesting one: its
values ARE legal group ids, so an "is it a valid id?" test passes and would
have promoted it. Two things say it is something else — the armour sets hold
**21** there, which is `SOCKET_STONE_CRITICAL_E`, a socket stone with nothing to
do with sets; and SET_B's accessory row holds **5**, which is SET_**A**'s
accessory group. A set pointing at another set's bonus is not a tier.

That test (all four probe values were legal group ids) was the one that failed
to discriminate. What discriminated was the group table's own names — the same
lever that has paid every time it has been reached for.

### Shipped

`MinSetPiecesForBonus = 2` and `SetProgress.BonusTier(tiers)`, implementing the
highest-tier-not-exceeding rule with the two addresses behind it.
`TestBonusTierPicksHighestNotExceeding` walks 0..6 pieces against
`ITEM_11_SET_A`'s real tier table; `TestAccessorySetHasNoSixPieceTier` keeps the
prediction that decoded the layout as a standing test. The "not decoded" notes
in `itemset.go` and `refdata/item.go` are corrected in place, saying what they
used to claim.

srrevamp still grants nothing: it has no magic-option system to grant into, and
`refmagicoptgroup.txt` is not loaded. What it has now is the whole rule, tested.

**What moved:** a disclosure became a recovery in one tick, and the method is
worth repeating — when a value's meaning is ambiguous, find the table that
NAMES its own entries and make a prediction that can fail.

**Next step:** `refmagicoptgroup.txt` itself. Its rows are
`(group, seq, ?, codename, paramId, ?, value, 0)` — and `paramId` 357/358/359/
362/363/389/390 are in the same id space as the GParamKeeper params this project
already recovered (`reference_sro_server_internals`). Joining them would make
the bonuses concrete, and would also test the param map against a table it was
not derived from.

## 2026-09-16 — the stat-tag vocabulary: 4 tags become 53, and a correction I did not make

The previous entry proposed following `refmagicoptgroup.txt`'s id column into the
param space. It does not go there — it goes to `MagicOption.txt`, and that table
turned out to be worth far more than the bonuses it holds.

### The table names the engine's tags itself

The engine addresses a stat by a short ASCII string packed big-endian into a
word. This project had **four** of these — `era`, `bri`, `hra`, `cri`, from the
characterdata columns — and no list.

`MagicOption.txt` column 2 is an option's human code name and column 7 is the
packed tag it modifies. Every row pairs a name with a tag, with nothing
inferred:

	MATTR_INT -> 'int'   MATTR_STR -> 'str'   MATTR_BLOCKRATE -> 'bri'

**53 distinct tags, and all 53 packed constants appear in the server binary**,
compared in `Stat_ApplyTaggedModifier` (`0x00498690`) — a binary-search tree on
the packed value ending in `GObjPC::ParamKeeper_SetParam`. Full table in
`docs/protocol/magic_options.md`.

### Column 29 is the item kind, and it is the part that settles meanings

	MATTR_CRITICAL  'cri'   weapon      MATTR_EVADE_CRITICAL  'evcr'  shield
	MATTR_BLOCKRATE 'bri'   shield      MATTR_EVADE_BLOCK     'evbl'  weapon

Attacker's weapon, defender's shield, both ways round — **exactly the
opposition `MitigateDamage`'s note already describes**, from a table none of it
was derived from.

It also re-confirms three things established earlier this session, each from an
artefact that had nothing to do with them: the accessory split (`rsti` on
necklace, `rcsi`/`rsli` on earring, `rdii`/`rfei` on ring), the job suits
(`strj`/`intj` on hunter/thief/trader), and the armour pieces (`hp`/`mp` on
armor/helm/mail/pants).

### The correction I was about to make and didn't

`combat.go` calls param 9 (`'era'`) the **parry rate** and param 11 (`'hra'`)
the **attack rate**. The new codenames are `MATTR_AVATAR_ER` and
`MATTR_AVATAR_HR`, and I had the edit half-written to change "parry" to
"evasion" on the strength of expanding `ER`.

Column 29 stopped it: `MATTR_ER` sits on **armor** and `MATTR_HR` on
**weapon** — the parry ratio and attack ratio the game displays. The existing
comment was right and the expansion of the initials would have been the error.
**Initials are not evidence; the use-site is.** The near-miss is recorded
because the rule usually appears here as "a curve is not evidence", and this is
the same rule wearing a different disguise — a plausible expansion of an
abbreviation is a guess.

(There is a real nuance underneath: `era`/`hra` ARE the avatar variants, a
separate family sitting on cosmetic pieces, distinct from base `er`/`hr`. That
is recorded without reclassifying params 9 and 11, whose mapping came from the
dispatcher and was not re-derived this tick.)

### And a fourth hand-typed tag went wrong, mid-tick

A probe for tag constants in the server dump returned **zero functions** while a
probe run minutes earlier had found all 53. Two faults, both mine: it searched
only the decimal form when Ghidra prints hex, and `'str'` was hand-typed as
`7565170` when `0x737472` is `7566450`. The empty result was a fact about the
probe. That is now the fourth time a hand-typed tag has been wrong here, which
is why the constants ship as a function of the string.

### Shipped

`internal/combat/paramtags.go`: the twelve tags this project's comments name, as
string constants with their MATTR code names, plus `PackTag`/`UnpackTag`.
`paramtags_test.go` holds each against the packed value the real table carries,
pins the byte order, and asserts the avatar variants stay distinct from the base
pair — the distinction that stopped the wrong correction.
`docs/protocol/magic_options.md` carries all 53 with their item kinds.
`MitigateDamage`'s note gains the second-artefact confirmation.

**What moved:** the tag vocabulary went from 4 names to 53, all cross-checked
against the binary; four shipped combat values gained an independent
confirmation; and a shipped comment was verified rather than damaged.

**Next step:** `Stat_ApplyTaggedModifier`'s dispatch arms differ — most tags end
in `ParamKeeper_SetParam(0, ...)` but `'era'` and `'hra'` use slot **1**. The
slot is the combining rule (slot 0 sums by ctx, slot 3 is the percent scale, per
`reference_sro_server_internals`), so enumerating which tag uses which slot
would recover the arithmetic for a whole family at once, rather than one stat
at a time.

## 2026-09-16 — tag to param id: a whole recovery behind one dropped register

The previous entry proposed enumerating which ParamKeeper *slot* each tag uses.
That turned out to be the smaller half. `Stat_ApplyTaggedModifier`
(`0x00498690`) also decides **which param id** each tag writes — and the
decompilation cannot show it.

### Why the C output is blind here

The dispatcher's leaves call `GObjPC::ParamKeeper_SetParam`, whose param id
arrives in **EDI**. Ghidra does not map that register to a parameter, so every
leaf decompiles to the identical

	GObjPC::ParamKeeper_SetParam(0,param_3,fVar1);

and the 53-way switch appears to do the same thing 53 times. In the asm each
leaf is `mov edi,N` immediately before the call. A whole recovery was sitting
behind one dropped register, in a function that had already been read and named.

**This is the general lesson worth keeping:** when a decompiled switch looks
like it has identical arms, the distinguishing value is probably in a register
the decompiler dropped. Check the disassembly before concluding the arms are the
same.

### The control licensed the rest

A walker binds each `cmp eax,TAG / je LEAF` to the param its leaf loads. Six of
the results were already known from functions the dispatcher has nothing to do
with:

	bri  -> 10   cri  -> 12    GObjMob_PublishStats' consecutive publish run
	evbl -> 56   evcr -> 57    Combat_ResolveDamage's block and critical rolls
	str  -> 1    int  -> 2     the damage pipeline's own GetParam calls

**All six came back right.** That is what licenses the other fourteen, which
are new: `hpa` 3, `mp` 4, `hra` 11, `hpmp`/`hprg` 25, `mprg` 26, `rals` 27,
`bu` 30, `mpna` 53, `drua` 128, `brna` 10, `strj`/`strv` 1, `intv` 2.

`hra` -> 11 is a seventh confirmation in passing: `MitigateDamage`'s note
already named param 11 as `'hra'`, from the other direction.

### What the walk cannot say, and is not guessed

The resist tags (`fz`, `ps`, `zb`, …) share one tail block, each setting its own
EDI before jumping in. A conservative walk gives them different answers from an
exhaustive one, and the exhaustive walk reaches params 27, 29, 30, 31 and 32
from every one of them. The family occupies that range; which tag takes which,
this walk does not separate. None of them ships, and a test asserts their
absence so a later tick has to explain itself rather than quietly fill them in.

### A finding that refines rather than overturns

Params 25 and 26 are written by `MATTR_REGENHPMP`, `MATTR_AVATAR_HPRG` and
`MATTR_AVATAR_MPRG` — the engine has HP/MP regeneration parameters. This does
NOT reopen the earlier "there is no passive regen" finding, which was about what
writes the pools by default: nothing does. Regeneration is a stat items grant,
not a baseline. Two compatible claims, recorded together so the next reader does
not take one for a contradiction of the other.

### Shipped

`combat.ParamFor`, twenty tag-to-param bindings with the six controls named in
the comment. `TestParamForHoldsTheIndependentlyKnownSix` keeps the control
standing — if a future re-read disagrees with one of those six, the re-read is
what to doubt. `TestParamForExcludesTheAmbiguousResists` pins the deliberate
absence. `client/tools/ghidra/recover_tag_params.py` is the walker, with its
control and its limits in the docstring. `docs/protocol/magic_options.md` gains
the full table.

**What moved:** fourteen new stat-parameter bindings, six shipped ones
re-confirmed from an unrelated function, and a reusable method for the next
dispatcher that looks like it has identical arms.

**Next step:** the same walk over the OTHER two functions that carry all eight
probe tags — `GObjPC::FUN_004909f0` and `FUN_00491bd0` (both unnamed). They are
tag dispatchers too, and whatever they do with the tags is a second, independent
reading of the same vocabulary; agreement would extend the control set, and
disagreement would be worth more.

## 2026-09-16 — the two other tag functions are debug formatters, and they name everything

The previous entry proposed running the same param-id walk over
`GObjPC::FUN_004909f0` and `FUN_00491bd0`, on the reasoning that they carry all
eight probe tags and are therefore dispatchers too.

**They are not dispatchers.** Neither calls `ParamKeeper_SetParam` at all, and
pointing the walker at them would have returned nothing — which is the kind of
empty result this project has learned to distrust, so it was worth checking what
they are before running it. They are **item debug formatters**: they build a
human-readable dump of an item and its magic options, `[DBID: %I64d, RefID: %d]`,
`[Dur: %d/%d]`, and then one line per option.

That is better than what was proposed. Each option line is a literal like
`"block rate +%d"` or `"evcr +%d%%"`, guarded by the tag constant — so the tag,
**the engine's own human label**, and **the unit** come out together. 41 tags get
a label. Two previously-unnamed functions get an identity.

### What it settles

- `dura` prints as **flaw**, with a MINUS sign: `"flaw -%d%%"`. That is
  `MATTR_DEC_MAXDUR` — a durability penalty, and the only negative option in the
  table. Inferring it from the code name would have been a guess; the format
  string is the use-site.
- `cri` -> **critical**, `rein` -> **reinforce**, `bri` -> **block rate**,
  `hpmp` -> **regen hpmp**.
- The five elemental resists get their meanings — `ps` **anti-toxin**, `fz`
  **anti-frostbite**, `bu` **anti-burn**, `es` **anti-eshock**, `zb`
  **anti-zombie** — even though the previous tick could not separate their param
  ids. A name and an id are different questions; this answers the first.
- The `AVT`/`Ava` prefixes confirm the avatar family split from the game's own
  display code, a third artefact after the code names and the item-kind column.

### The distinction that had to be got right

`+%d` versus `+%d%%` is a property of **the bonus, not the stat**. `block rate
+%d` is flat because the option adds five POINTS; the block rate itself is still
a percentage srrevamp rolls against 0..100. Reading "flat" as "this stat is not
a percentage" would have been a real regression, and a test now stands against
it.

### Two probe faults, both caught before shipping

The extractor attributes a literal to the most recently seen tag constant, which
can bind it to a neighbour. `int` came back labelled `"Ava hr"` and `soli`
labelled `"resist stun"` — labels that plainly belong to another tag, which is
how they were spotted and dropped.

Worse, a first and looser literal pattern swept up `"ape(%d%%): %d"`-style lines,
where the `%%` is a **probability** and not the value's unit. That alone produced
six false unit conflicts. Tightening the pattern to literals that are exactly
`label ±%d[%%]` cut it to the two real ones.

### The one real disagreement, disclosed

`0x004909f0` prints `"hp +%d%%"`; `0x00491bd0` prints `"hp +%d"`. Both literals
are really in the binary, so the **engine** disagrees with itself here rather
than the probe being wrong. Which governs is not established, so `hp` ships no
unit and a test pins the absence.

### Shipped

`combat.BonusUnit` (nine tags, flat or percent) and `combat.LabelFor` (sixteen
tags whose label the spelling does not give), with the bonus-not-stat warning
carried in both the comment and a test.
`TestBonusUnitIsAboutTheBonusNotTheStat` guards the misreading;
`TestBonusUnitExcludesHP` pins the disclosed conflict.
`docs/protocol/magic_options.md` gains the full table and the note on how the
noise rows were caught.

**What moved:** 41 tags gained the engine's own name for them, two unnamed
functions gained an identity, and the elemental resists became meaningful even
though their param ids remain open.

**Next step:** `FUN_00491bd0`'s bless family — `"ape(%d%%): %d"`, `"solid(%d%%): %d"`,
`"atha(%d%%): %d"`, `"luck(%d%%): %d"` and `"unknown bless[%d]"`. Those print a
PROBABILITY and a value, which is a different shape from every other option, and
`"unknown bless"` means the formatter enumerates a closed set it can fall off —
so the set is discoverable from the same function.

## 2026-09-16 — the bless family: four options that roll a chance, and a closed set proved by its fallback

The previous entry pointed at `FUN_00491bd0`'s odd literals — `"ape(%d%%): %d"`
and friends, which print a probability as well as a value, plus an
`"unknown bless[%d]"` fallback. Reading that branch out gives a named family and
a struct.

### Four, and the binary says four

`ape`, `luck`, `soli`, `atha` — `MATTR_APE`, `MATTR_LUCK`, `MATTR_SOLID`,
`MATTR_ATHANASIA` — each printing two numbers, the first read from the option
record's `+0x14`, a field no other branch touches. They fire by chance rather
than applying flatly.

**What makes the set closed is the fallback, not the enumeration.** A tag
reaching that group and matching none of the four prints

	FUN_00425f70("unknown bless[%d]", tag);

An author who writes that expected nothing else to arrive there. That is better
evidence than counting the branches, because counting cannot tell a complete
list from a list someone stopped extending.

`rep` (`MATTR_REPAIR`) is in the same branch group and is NOT one of them: it
prints `"rep: %d,"` with no chance and at **`value - 1`**. The stored number is
one more than the displayed one — recorded because an off-by-one hiding in a
display path is exactly what gets re-derived wrongly later.

### The per-item option record, from two readers

The dumper prints `+0x04` as the tag and `+0x10` as the value. The accessor
`FUN_004927e0` (`0x004927e0`) independently returns `+0x10` and writes `+0x04`
back through EDI. The bless branch adds `+0x14`, the chance.

	+0x04  tag (packed)     +0x10  value     +0x14  chance (bless only)

The options live in a container at `GObjPC + 0x5c0` and are **looked up, not
indexed**, so there is no stride — worth stating, because the obvious assumption
would be an array. The 12-per-item cap was already known from the client's
`"m_btMagicParamNum <= MAX_MAGPARAM_PER_ITEM"` assert and is now attached to the
record it bounds.

### A negative result, and what it does and does not mean

No column of `MagicOption.txt` is populated on every bless row and no plain row.
So the chance is **not** a distinct reference column. That is consistent with
`+0x14` being a per-item-instance field rather than a table one — but consistency
is not proof, and this tick did not separately establish where the value is
written, so the doc says so rather than asserting it.

### Shipped

`combat.BlessTags` (the four), `TagAstral/TagLuck/TagSolid/TagAthanasia/
TagRepair`, `LabelFor[TagSolid] = "solid"` (the only one whose label differs
from its spelling), and the `MagicOption*Offset` / `MaxMagicParamsPerItem`
constants. Three tests: the closed set with its literals, the packed constants
against the dumper's comparisons, and the record-shape guard.

Nothing consumes any of it — srrevamp implements no magic options. It is
recorded because an implementation that modelled these four as unconditional
would be wrong, and the cost of finding that out later is higher than the cost
of writing it down now.

**What moved:** a named, closed family of four probabilistic options; the
per-item magic-option record from two independent readers; one display
off-by-one caught.

**Next step:** `"[OptLvl: +%d] "` at the top of the same dumper reads
`*(item[0x34] + 0x2c)` as a single byte — the item's option LEVEL, distinct from
the per-option values. `MagicOption.txt` has a level column (col 4) and
`refmagicoptbyitemoptleveldata.txt` is named for exactly this relationship, so
the two can be joined: which options an item can carry at a given option level.

## 2026-09-16 — CheckEquipsetIntegrity: a validator that names four things at once

The previous entry proposed joining the item option level to
`refmagicoptbyitemoptleveldata.txt`. The route there ran through
`CGPCInventoryOP::CheckEquipsetIntegrity` (`0x004bb020`) — already a named
function, already used once for `ReqGender` — and the validator turned out to
be worth more than the join.

A validator is a dense source for this kind of work: every refusal it makes is a
rule stated with its bound, and the engine's log strings name the concepts.

### What it gave

**1. `vslot_317` has a real name.** The validator calls vtable offset `0x4f4`
— slot 317, the equip check this project read in v0.1.225 — and names it in the
failure message:

	"Equiped already but CanBeEquipedAt() failed!! [Char: %s, Slot: %d, Item: %s]"

`CanBeEquipedAt`, the engine's spelling with one `p`. Renamed in the comments
that cite it. **Not renamed:** `internal/mana/mana.go` cites
`CGObjChar::vslot_317`, a different class where slot 317 means something else
entirely — the project already knows a slot number means nothing across
unrelated vtables, and checking that before a global rename is why it did not
become a wrong edit.

**2. Ammunition is "Bullet", and slot 7 is the only place it is legal.** The
condition spells the exception out:

	if ((notEquip != 1) || (slot != 7))
	    "Item is neither Equip nor Bullet! [Char: %s, Slot: %d, Item: %s]"

A fourth confirmation of the v0.1.225 finding, and the first time the engine's
own word for the concept appeared. A test now pins that `SlotFor` sends
ammunition to slot 7 **and nowhere else** — the half a resolver can get wrong
without anything noticing.

**3. An item's option level is bounded at 250.** `if (0xfa < item[0xd]->optLevel)`
→ `"Item OptLevel is invalid!!!"`. The guard fires above `0xfa`, so 250 is legal
and 251 is not. Shipped as `equipment.MaxItemOptLevel` with the point that
matters attached: **this is a validation ceiling, not a balance figure.** Real
items reach single digits; 250 is where the engine stops believing the number.
Reading it as "items go up to +250" would be manufacturing a design decision out
of a sanity check, and the test is named to interrupt that.

**4. A fourth witness for the slot count.** Its loop runs `local_c` from 0 and
returns success at `0xc < local_c` — exactly slots 0..12. That is now the
server's equip check, the server's resolver, the client's appearance installer,
and this.

### And one for the open list

`vslot_0x454` gates `"Equiped Avatar Item!!"`, so **0x454 is an avatar-item
predicate** — one of the two unresolved gating slots in `CanBeEquipedAt` from
v0.1.225. `FUN_004890f0` is the bullet predicate and `FUN_00488e40` a second
avatar one. Not wired into anything; recorded so the next reader of
`CanBeEquipedAt` does not re-derive them.

### Shipped

`equipment.MaxItemOptLevel = 250`, the `CanBeEquipedAt` name in every comment
that cited the slot number, the "Bullet" confirmation on `FamilyAmmunition`, and
the fourth slot-count witness. Two tests:
`TestMaxItemOptLevelIsTheEnginesCeiling` (bound plus the validation-not-balance
warning) and `TestAmmunitionIsAllowedOnlyInTheShieldSlot`.

### A stale duplicate of a corrected claim

`ITEM_FORMAT.md` still read "weapons 6, shields 4, **accessories 7**" — the exact
claim corrected in v0.1.224, which had been fixed in `equipment/rules.go` and
left standing in the doc. Fixed, with a note saying what it used to say.

Worth recording as a pattern rather than a one-off: **a correction applied in one
place and not the other is how a fixed error comes back.** The grep that found it
(`accessories 7`) took a second and should be part of making any correction, not
a thing stumbled on two weeks later.

**What moved:** one function got its engine name, one bound became grounded,
the ammunition rule went from "allowed there" to "allowed only there", and a
corrected claim stopped contradicting itself across two files.

**Next step:** the join this tick set out to do and did not reach.
`refmagicoptbyitemoptleveldata.txt` is 359 rows of 5 columns and the engine
names its key in a log string — `"can't find MagicOptGroup[%s]:MagicOptLevel[%d]
from MagOptEachLevel at RefMagicOptByItemOptLevel"`. The `%s` is the telling
part: the group is looked up by NAME, not by the numeric id the set table uses,
so the two tables are keyed differently and the joining function is where that
is reconciled.

## 2026-09-16 — the metric that could not move

This tick set out to finish the `MagicOptGroup[%s]` join and then, per the
prompt's other option, measured naming coverage. The measurement is the finding.

### The join, first, because it did close

The lookup message's `%s` was the clue and it holds up.
`ReferenceData::FUN_006a6660` copies **seven dwords — a 28-byte inline name —
from row+0x08** onto the stack for that `%s`, so `_RefMagicOptByItemOptLevel`
keys a magic-option group by **name**. `_RefMagicOptGroup` keys it by **id**:
`FUN_006beec0` is the by-id lookup, and it says so itself —
`"Can`t find MagicOptGroup(ID:%d) within _RefMagicOptGroup table"`. Two tables,
two keyings, reconciled at load time. Assert anchor for the harvest lever:
`ReferenceData.cpp:1566`.

(The first probe for that message returned nothing. The literal is `can\'t` in
the dump, and the pattern `can.t` needs exactly one character between "can" and
"t" where there are two. An empty grep is a fact about the grep.)

### The measurement

	server  7,386 named of 34,113  (21.7%)
	client  6,440 named of 43,460  (14.8%)

**Identical to the figures recorded on 2026-09-15**, before roughly fifteen ticks
of active reverse engineering. Not approximately — exactly.

The reason is not that nothing was recovered. It is that **every name went into
srrevamp's comments and docs, and nothing writes one back into the Ghidra
project the metric reads.** Checked rather than assumed: `0x00497070` is still
`CGItemEquip::vslot_317` in the dump, `0x009db5e0` still
`GlobalDataManager::FUN_009db5e0`, and five more the same. And the pipeline
cannot do it — `re_tick.sh` runs analyzeHeadless with `-readOnly`, so a rename
is structurally impossible there, and `/opt/srrevamp-re/` has no names-import
path at all.

**A goal stated as "every game-logic function named" was being measured against
an artefact the work never touched.** Fifteen ticks is how long that took to
notice, and the only reason it surfaced now is that the prompt lists the
measurement as an option and nobody had taken it.

### What now closes the loop

`docs/protocol/recovered_names.tsv` — 24 names read out of the binaries this
session, each with its address, its binary, and its evidence. The `origin`
column is the part that matters: **`engine` for the binary's own word,
`descriptive` for one this project chose.** Four are the engine's
(`CanBeEquipedAt`, `RefMagicOptGroup_FindByID`, `RefSetItemGroup_FindBySetID`,
`IsBullet`); twenty are descriptive, and a descriptive name is a claim like any
other, which is why each carries its evidence in the row.

`client/tools/ghidra/ApplyRecoveredNames.py` applies them, and refuses to guess:
a row with no function at its address, or whose function already carries a real
name, is reported and skipped rather than overwritten — an existing name may be
the engine's own and better than the one offered. It needs a NON-readOnly
analyzeHeadless run, which the docstring says in so many words.

### The file was wrong when written, and the check caught it

Two rows claimed `client` for `0x004909f0` and `0x00491bd0`, which are in the
**server** dump — I read them from `decomp_server/funcs_214.c` and typed the
wrong binary. A pass that resolves every row against the two dump indexes found
both; after the fix, **24 of 24 verified present and still unnamed**. That pass
is worth running before any future application, and a Go test now guards the
file's shape (address format, binary, origin, non-empty evidence, no duplicates)
so the cheap mistakes cannot come back.

**What moved:** the two keyings of the magic-option-by-level tables; 24 names
made durable and machine-applicable instead of living only in prose; and an
honest account of why a headline metric has been flat.

**Next step:** apply the file. That needs one non-readOnly analyzeHeadless run
per binary and a forced dump rebuild afterwards (the tick only rebuilds when the
binary is newer than `DONE`, which a rename does not change) — so it is a
deliberate operation, not a side effect, and it should be done when nothing else
is in flight. Re-measuring straight after is what proves the loop is closed.

## 2026-09-16 — the names applied, the metric moved, and a correction to the tick before

The previous entry said applying the names needed one non-readOnly
analyzeHeadless run per binary and a forced dump rebuild. That is exactly what
it needed, and it worked.

	server  7,386 -> 7,394 named   (+8)
	client  6,440 -> 6,455 named   (+15, all of them)

**+23 of 24.** The missing one is not a failure: `0x00497070` was
`CGItemEquip::vslot_317`, and the coverage counter treats `vslot_` as named
already, so renaming it to `CanBeEquipedAt` improved the name without changing
the count. Worth knowing before someone reads a discrepancy into it.

Spot-checked in the rebuilt dumps rather than trusted from the script's output:
`00497070 CGItemEquip::CanBeEquipedAt`, `00496c20
GObjPC::ResolveEquipSlotForItem`, `004890f0 CGPCInventoryOP::IsBullet`,
`009db5e0 GlobalDataManager::ResolveVisualSlotForItem`. They are really there.

### THE CORRECTION: the previous entry overstated the gap

v0.1.235 said "**nothing** writes them back into the Ghidra project" and
"`/opt/srrevamp-re/` has no names-import path at all". The second is true. The
first is not, and the difference matters: **`client/tools/ghidra/
ApplyKnownNames.java` already existed**, carrying 193 names, and its header
states the same rationale almost word for word —

	"findings that live only in commit messages are lost to the next session.
	 A name in the program survives, and shows up in every future
	 decompilation dump at every call site."

An earlier session had already seen this problem and built the tool. What was
actually true is narrower and less dramatic: **this session's 24 names were
never added to it, and nobody re-ran it.** The infrastructure was fine; the
habit was missing.

I found this only because deleting the dead Python file made me list the
directory. Had I not, the record would have kept a confident, wrong claim that
an earlier session's work did not exist.

The new script is still worth having — `ApplyKnownNames.java` hardcodes its
names in Java, `ApplyNamespaceTable.java` reads namespaces, and neither reads a
file of *names*. But it is an addition to a working path, not the first one.

### Two things that cost time, recorded so they do not again

**Ghidra 12.1.3 will not run `.py` scripts here.** The first applier was Python
and died with `SCRIPT ERROR: Ghidra was not started with PyGhidra. Python is not
available`. The dump pipeline's own `DecompAll.java` was the clue sitting in
plain sight: every script that has ever run on this box is Java. The Python file
was deleted rather than kept as a reference — a script that looks runnable and
is not costs the next reader the same ten minutes.

**The dumps re-shard.** The rebuild produced `shards=18` for the server where
the old STATUS said `shards=2133`, because `DecompAll.java ... 30 2000` puts
2000 functions in a shard and 34,113 of them need 18. Every `funcs_NNN.c` path
in earlier entries is therefore stale as a *path*; the content is identical and
found by grep either way. `functions=34113 failed=0` both before and after, which
is the number that matters.

### Shipped

All 24 names in both Ghidra projects, with each row's evidence written into the
function comment — the convention `ApplyKnownNames.java` established, because a
name a later reader can audit beats one they have to trust. Both dumps rebuilt
so the names reach every future session at every call site.
`ApplyRecoveredNames.java` replaces the Python, is idempotent (a second run
renamed nothing and refreshed 24 comments), and refuses to overwrite a function
that already carries a real name.

**What moved:** the headline metric, for the first time in fifteen ticks — and
more usefully, the 24 names now arrive free in every future dump instead of
having to be re-derived.

**Next step:** the same treatment for names recovered BEFORE this session.
`ApplyKnownNames.java` has 193, but entries in `docs/protocol/*.md` that never
reached it are the same silent loss this tick was about — `igobj_vtable.md`'s
209 slots and `error_attributed_functions.md` are the obvious places to look,
and the join is mechanical: any address in those docs whose dump entry is still
`FUN_` is a name that was recovered and dropped.

## 2026-09-16 — a lever that gives 0% and 100% depending on one regex

The previous entry proposed hunting names recovered before this session that
never reached the binaries. The first two candidates turned out to be already
done, and the third was a lever worth measuring rather than using.

### Two dead ends, checked rather than assumed

**The client assert harvest is spent as an attribution lever.** 295 functions
carry an assert and 262 are still `FUN_` — but **256 of those already have a
namespace**, leaving 6 bare. `ApplyNamespaceTable.java` had already been run.
Naming the other 256 from an assert *expression* would be inventing: the
expression says what the function checks, not what it does.

**Thunks are not a lever either.** 234 server and 135 client `thunk_FUN_`
functions exist, but Ghidra names a thunk after its target — so `thunk_FUN_X`
means the TARGET is unnamed, and there is no free name to take.

### The logger's embedded labels, and the regex that decides everything

`naming_ceiling.md` recorded the logger's literal format strings as an
unexploited lever. Re-measured: **1,242 calls with a literal, in 893 functions,
311 still `FUN_`**, 219 of them with exactly one literal — and many of those
literals open with something that reads exactly like a name:
`CharDataLoadingCompleted::`, `OnRegisterPartyReq::`, `OnGuildWarBegun`.

I had 25 candidates picked out. Then I ran the control over **already-named**
functions with the same shape:

	label matches the function's own name:    0
	label does not match:                   131        agreement 0.0%

**Zero.** The label is the class or subsystem — `CAgentMsg`, `AQ_OpenMarket`,
`CLobby` — not the method. And it is not dependably that either: against the
namespace it reaches only 76.1%, the misses being inherited methods logging
their base class.

Applying those 219 would have been the largest fabrication this project has come
near. The control cost one script.

### The same corpus, one regex tighter, is perfect

Some messages carry BOTH parts, `Class::Method `. That form controls at
**35 match, 0 miss — 100.0%**, and separates from the one-part form by regex
alone. Its yield is two still-unnamed functions, both now applied:

	0046dde0  trs_sm_trainingcampjob::vslot_007 -> Unlock
	00621fd0  GObjPC::FUN_00621fd0             -> RemoveSiegeObject

The second is the more interesting: the label names the class as
`CSiegeFortress`, while the dump's `GObjPC` namespace is call-graph inference.
The binary's own word outranks the inference, and that is recorded in the row's
evidence.

**The lesson is the split, not the two names.** One regex over one corpus gives
0% and another gives 100%. "Text that looks like a name" is not a lever; a
pattern whose agreement with known answers has been measured is.

### Shipped

Two names applied (origin=engine, control 35/35), `recovered_names.tsv` now at
26 rows, and `naming_ceiling.md` gains the fifth lever with both numbers — so
the 0% half is never re-attempted, and the 100% half is re-run against any
future dump where new messages appear.

**What moved:** two functions named from the binary's own words; three levers
measured to exhaustion instead of guessed at; and a 219-name fabrication
avoided by one control run.

**Next step:** `/opt/srrevamp-re/STATUS` is stale — it still reports
`shards=2133` because the rebuild bypassed `re_tick.sh`, which only refreshes
STATUS when it does the rebuild itself. Harmless now (the next cron tick
corrects it) but the shape is worth fixing: the tick should refresh STATUS
unconditionally, so a dump rebuilt by hand is not silently misreported to the
next session that opens cold.

## 2026-09-16 — the level-up, and a vtable identity that gave exactly the wrong answer

My own proposed next step was wrong: I said `STATUS` was structurally stale and
the tick should refresh it unconditionally. **It already does** — `re_tick.sh`
writes STATUS every tick from the DONE files, and what I saw was a one-tick lag
while my hand-run rebuild was still going. Nothing to fix. Recorded because a
"next step" built on a misreading is worth catching before someone spends a tick
on it.

So: the other half of the goal. `GROUNDING_AUDIT.md` had exactly **one**
BEHAVIOUR ASSUMPTION left — *"level-up refills HP; stat points granted at
level-up"* — which it calls the actionable part of the audit. Both halves are
now settled in `GObjPC_SetLevel` (`0x004e4d90`).

### The stat points: five granted, two spent, three left

srrevamp has used `StatPointsPerLevel = 3` on the strength of a level-9
character window showing 24 points. The engine says:

	lea edx,[esi+edi*1]     ; esi = levels gained, edi = points already held
	lea ecx,[edx+esi*4]     ; ecx = edi + esi*5
	mov [eax+0x84],cx       ; the pool becomes held + levels*5
	push esi ; mov eax,esi  ; SpendStatPoints(str = levels, int = levels)

**Five per level, two immediately auto-spent, three left to the player.** The
number is unchanged; what changed is that the reason is the engine's rather than
one screenshot's — which is the difference this project's own rules care about.

### The refill, and the slot identity that nearly settled it backwards

The level-up path calls

	heal(this, vslot(0x110) − vslot(0x108), vslot(0x114) − vslot(0x10c), 0x80)

and `igobj_vtable.md` says slots 66 and 68 (`0x108`, `0x110`) are **the same
function in all 14 vtables**. Under that reading the difference is identically
zero, the heal does nothing, and level-up does **not** refill. I had that written
down.

What stopped it: a zero delta makes four virtual calls and a guarded helper into
dead code, and authors do not write that. Checking the disassembly first ruled
out the other candidate — Ghidra dropping a register argument, which it had
already done once this session — and the calls really are `mov ecx,ebp; call
edx`, `this` only.

So the vtable claim itself had to be wrong, and it is:
**`CGObjCOS_Summoned` has `GetCurHP` (`0x004aa5e0`) at slot 66 and a different
function (`0x004a6830`) at slot 68**, and that one reads a ParamKeeper param
rather than stored HP. **Slot 68 is the computed maximum.**
`CGItemMonsterCapsule` does have the same function at both, which is how the
original measurement came out as it did.

With that corrected, the delta is `MaxHP − CurHP` and the level-up **tops both
pools up in full**. The assumption is confirmed, not refuted — but it was one
inference away from being recorded as refuted.

**A slot identity taken as universal produced exactly the wrong answer about a
game mechanic.** The vtable doc now carries the correction and the reason it
matters, because the next reader of that table will be doing the same thing.

### What is NOT shipped, and why it is filed rather than folded in

`SpendStatPoints(levels, levels)` means **a character's Str and Int each rise by
1 per level, automatically**, and srrevamp models none of it: Str and Int sit at
their starting values for life. `MaxHPFor` is `Str × 10 × 1.02^(level−1)`, so a
level-40 character here has roughly a third of the health a real one has.

That is a schema change (Str/Int must travel through `SetLeveling`, touching the
store interface and both backends) and a large balance change on a server the
user plays from tagged releases. Folding it into the tick that found it would
make a naming-and-grounding tick silently triple everyone's health. It is filed
as the new open item in `GROUNDING_AUDIT.md`, with the citation, so the next tick
can do it deliberately.

### And a paraphrase that had lost its qualifier

`character.go` said *"nothing writes charData+0x74/+0x76 anywhere in the
binary"*. `GObjPC_SpendStatPoints` writes both. The claim that actually holds is
the narrower one it was paraphrasing — nothing writes an initial *constant*
there — and the original still says so correctly ten lines further down. Fixed.
**A paraphrase that drops the word doing the work turns a true absence into a
false one.**

### Shipped

`StatPointsPerLevel` grounded with the engine arithmetic and a test written as
the relationship (5 − 2 = 3) rather than a bare equality; `GROUNDING_AUDIT.md`'s
last behaviour assumption closed as RECOVERED and a new, bigger one opened;
`igobj_vtable.md` corrected; the `character.go` paraphrase repaired.

**What moved:** the audit's actionable list went from one vague assumption to one
precise, cited, unimplemented mechanic — which is a better thing to have.

**Next step:** implement the automatic +1 Str / +1 Int per level. It needs
`SetLeveling` to carry Str and Int, the memstore and sqlstore to persist them,
and a test that a level-40 character has Str 20+39 rather than 20 — and it will
move every derived HP/MP number on the live server, so it wants its own tick and
its own release note.

## 2026-09-16 — the stat growth, implemented

The previous entry filed the automatic +1 Str / +1 Int per level rather than
folding it into the tick that found it, because it is a schema change and a large
balance change. This is that tick.

### Verified once more before building on it

Two of the three functions in the chain had lost their arguments to Ghidra, so
the decompilation alone could not say what was written. `FUN_0051dc00` and
`FUN_0051dbd0` turned out to be plain **setters** for charData `+0x74` and
`+0x76`, not incrementers — the increment is at the call site, and the asm is
explicit:

	movzx ecx,WORD PTR [eax+0x74]   ; current Str
	add   cx,si                     ; + the amount being spent
	call  0x51dc00                  ; SetStr(Str + amount)

with the Int half the same against `+0x76`. `SpendStatPoints` then republishes
**ParamKeeper param 1**, which independently agrees with
`combat.ParamFor[TagStr] == 1` recovered from the tag dispatcher two ticks ago —
two unrelated functions, one answer.

### What shipped

`character.StatGrowthPerLevel = 1`, and `SetLeveling` extended to carry Str and
Int. That last part is deliberate rather than convenient: the engine grants the
points and spends two of them **in one level-up**, so making it one call here
keeps the two from drifting apart. Both stores persist it; the death-penalty path
passes Str and Int through unchanged, with a comment saying so, because a reader
seeing new arguments on that call should not have to work out whether a death
also changes stats.

The level-up's own HP/MP refill now reads the **new** Str and Int rather than the
stale record — which is what the engine does, since it heals by
`GetMaxHP − GetCurHP` computed after the level has been set.

### The balance change, stated plainly

`MaxHPFor` is `Str × 10 × 1.02^(level−1)`. The exponential term is the smaller
half of the growth and the Str term the larger, so a level-40 character goes from
Str 20 to Str 59 and from roughly 428 health to roughly 1,263. **Every existing
character on the live server keeps whatever Str its row holds** — the growth
applies from the next level gained, not retroactively — so an established
character will lag a freshly-levelled one until it catches up. That is a real
consequence of fixing this late rather than early, and it is better said here
than discovered.

A test pins the level-40 ratio against the ratio of the Str terms, and pins that
a level-1 character is unaffected.

### A small trap avoided

The `characters` table's Int column is named **`intel`**, not `int` — the schema
had already stepped around the reserved word. My first `UPDATE` used `int = $5`
and would have failed at runtime on the SQL backend while every in-memory test
passed. Caught by reading the schema rather than by the tests, which is the order
that matters for a column name.

**What moved:** the audit's newest open item, closed the same day it was opened;
one recovered mechanic implemented end to end; and the last of the level-up
arithmetic now matches the engine's.

**Next step:** `StartingStr = 20` and `StartingInt = 20` are still OWN DESIGN, and
now they matter far more than they did — every level multiplies them. The audit
says the category is closed because creation happens on the AgentServer, which
this project has no artifact of. Worth one probe to confirm that is still true
now that the stat *growth* is known: if any client-side character-creation
preview computes a starting HP, it would name the starting Str.

## 2026-09-16 — an absence worth measuring, since the numbers now multiply

The previous entry proposed one probe: whether a client-side creation preview
names the starting Str, now that `StatGrowthPerLevel` makes `StartingStr` and
`StartingInt` multiply at every level. The answer is no — and the useful part is
that the negative is now measured across three artifacts instead of inferred from
one.

The audit had closed the whole character-creation category on `SR_GameServer.exe`
writing no constant to charData `+0x74`/`+0x76`. That is sound reasoning about
one binary. It is also exactly the shape of claim this project has been burned by:
a negative from a single artifact, stated as if it were about the game.

So three were asked:

- **characterdata's player rows.** 78 rows match `CHAR_(CH|EU)_(MAN|WOMAN)` and
  **zero carry a non-zero MaxHP** — the column that would give Str away, since
  MaxHP is `Str × 10` at level 1. There is no bare `CHAR_CH_MAN` row at all; the
  player rows are class and appearance variants (`_NOBLE`, `_EXORCIST`, …).
- **The client's character-creation screen.** Its strings are `UIO_NEWCHAR_*` —
  race, gender, class, and `_EXPLANATION` text. It previews an appearance, not a
  stat line, so there is no formula in the client either.
- **`LevelData.txt`.** Nine columns, none of them a stat.

The value stays own-design. What changed is that the reason is three measurements
rather than one silence — which matters now in a way it did not a week ago,
because at level 40 a wrong starting Str is a wrong health total by the same
ratio.

### A lead found on the way, deliberately not promoted

`LevelData.txt`'s columns 6, 7 and 8 hold a triple of large, mutually **identical**
values that grow fast — 70,875 three times at level 1, 2,388,750 three times at
level 2. Three identical values invites reading them as the three jobs (trader,
thief, hunter) and calling them job experience.

**That is a curve plus a coincidence of arity**, which is the exact shape that got
characterdata col 79 wrong twice. Nothing is claimed; the observation is recorded
in `leveldata.go` so the next reader starts from it rather than rediscovering it,
and it will stay unclaimed until a use-site reads one of those fields.

### Shipped

The absence upgraded in `character.go` and `GROUNDING_AUDIT.md`, with the three
probes and their counts; the LevelData lead recorded as a lead. No value changed,
so nothing needed wiring — which is the right outcome for a tick whose finding is
that a number cannot be recovered yet.

**What moved:** a single-artifact negative became a three-artifact one, on the two
values that the previous tick made the most load-bearing in the whole stat model.

**Next step:** the LevelData triple has a natural use-site to look for — the job
system. `strj`/`intj` were measured onto `hunter, thief, trader` in the magic
options work, and `_RefSetItemGroup`'s job suits occupy equipment slot 8, so the
three-job vocabulary is already partly recovered. Finding the server function that
reads a job's experience would settle columns 6–8 the honest way.

## 2026-09-16 — hunting a use-site, finding two probe faults and a blind spot

The previous entry left `LevelData.txt`'s columns 6–8 — a triple of identical
large values — unclaimed, and proposed finding the job system's reader to settle
them honestly. The hunt came back empty, and everything useful this tick is a
by-product of how it failed.

### The search, and what it actually establishes

Every consumer of the level record goes through `RefLevel_GetEntry`
(`0x00411130`). There are **ten**, and between them they read exactly three
offsets: `+0x8/+0xc` (the 64-bit exp to next), `+0x10` (the mastery cost) and
`+0x1c` (the kill-exp unit). **Nothing reads past `+0x1c`.**

That is not proof the columns are dead — the table is an array off the
reference-data singleton and code could index it without the accessor — but the
straightforward search is now done and recorded, so the next attempt starts
elsewhere instead of here.

### Two probe faults, both the same cause

My extractor found "offsets read from the variable holding the entry" and
reported `FUN_00631050` reading `+0x28` and `+0x30`, and `Mastery_LevelUp`
reading `+0x20`. Both were wrong, and for one reason: **Ghidra reuses a variable
name across scopes, and the extractor did not track bindings.**

- `FUN_00631050`'s `iVar5 + 0x28` is a `std::string` SSO check on a *different*
  `iVar5` — `if (*(uint *)(iVar5 + 0x28) < 0x10) iVar5 = iVar5 + 0x14;` is the
  short-string-optimisation test, not a level-record field.
- `Mastery_LevelUp`'s `iVar5 + 0x20` is the *mastery* record's level, from
  `iVar5 = *(int *)(iVar3 + 8)`, not the level record at all.

An "offsets read from variable X" scan over decompiled C is unsound without scope
tracking. Both faults were caught by reading the surrounding lines rather than
trusting the extraction — which is the only reason two invented level-record
fields did not end up in a doc.

### What the failed hunt confirmed on the way

`Mastery_LevelUp` sums `RefLevel_GetEntry(level) + 0x10` across the levels
between a mastery's current and target level, and refuses with `0x3802` when the
character's skill points (charData `+0x80`) are less than the sum. That
**independently confirms column 2 as the per-level mastery cost** — a claim
`leveldata.go` already made from the server summing "exactly this field", now
with a second reading of the same use-site. charData `+0x80` is the skill-point
pool, next to `+0x84` (stat points) recovered two ticks ago.

### A blind spot in the error-code table

`Mastery_LevelUp` raises `0x3802` and `0x3804`, and **neither is in
`error_codes.md` — the whole `0x38xx` family is absent** while `0x30xx` (52
codes) and `0x3cxx` (27) are present.

The reason is the harvest's pattern. It scans for `mov ax,0xNNNN` / `mov
eax,0xNNNN`, the shape of `return ERRORCODE`. `Mastery_LevelUp` assigns its codes
to a **stack local** instead, so they are invisible to it. The gap is a property
of the probe, not of the game.

Two numbers for judging that table's completeness, measured: the scan finds 445
distinct codes ≥ 0x100 in ax/eax, of which **201 are not in the table**. Some of
that is legitimate — a code the client has no message for cannot be named — but
it bounds what "605 codes" means.

### Shipped

The measured negative on columns 6–8 and the confirmation of column 2, both in
`leveldata.go`; the error-code blind spot in `error_codes.md` with the two codes
that exposed it and the 445/201 figures. No value changed.

**What moved:** one dead end closed with a measurement instead of a shrug, one
shipped column confirmed from a second use-site, and a harvest that had been
treated as complete now carries its own limits.

**Next step:** widen the error-code harvest to the assignment forms it misses —
`mov WORD PTR [ebp-N],0xNNNN` and the register-to-local shapes — and re-run it.
`0x38xx` is a whole family the table has never seen, and `Mastery_LevelUp` shows
there is at least one real subsystem behind it.

## 2026-09-16 — widening the error-code scan, and why widening alone would be wrong

The previous entry found that the error-code harvest only sees `mov ax,0xNNNN` —
the shape of `return ERRORCODE` — and so had never seen the `0x38xx` family that
`Mastery_LevelUp` raises into a stack slot. This is that fix, and the interesting
part is what stopped it being a bad one.

### The client half first, because it changes what "missing" means

`0x3802`, `0x3804` and `0x3805` **are** in the client — handled in
`UI_SILKMALL::FUN_007b8b40`, a large dispatcher keyed on a category and then a
code. But they are handled by `if (param_2 == 0x3802)`, not by a `case` label,
and they route to shared endings rather than to a per-code message string.

So the same class of blind spot exists on both sides of the join, and the
conclusion is narrower than "the table is missing names": these codes may have
**no client message name at all**, which would make their absence from
`error_codes.md` correct rather than a gap. No name was invented for them.

### Widening the server scan, and the trap in doing so

Widened to any 16-bit immediate move, including into a memory local:

	narrow (mov ax/eax):        445 distinct values in 0x100..0xffff
	wide   (any reg or local): 1206
	seen only by the wide scan: 761

**761 new values is not 761 new error codes.** Loop bounds, sizes, masks and
offsets all look exactly like this, and taking the wide scan at face value would
be the same mistake the `0x100` floor exists to prevent, one level up — that
floor stops a small return value being read as a code; nothing in the pattern
stops an arbitrary immediate being read as one.

**The join is what makes it safe.** Require every match to be a code the client
already names, and the widening adds reach without adding guesses:

	narrow:  157 functions touch a named code, 117 still FUN_,  88 single-domain
	wide:    298 functions touch a named code, 204 still FUN_, 143 single-domain

**208 named codes are raised only in a form the narrow pattern could not see.**
The name table is the validation, not the pattern.

### Shipped

`label_by_error_code.py` widened, with the 1,206-vs-445 figures and the reason
the join is load-bearing written into it — because the next person to read that
regex will wonder why it is so permissive.
`error_attributed_functions.md` regenerated: **143 single-domain attributions
across 15 domains**, up from 88. The biggest movers are STRG (34), SKILL (28),
GUILD (24) and FORT (17).

No srrevamp value changed — this is an attribution table, and the doc says in its
own words that an attribution is not a name.

**What moved:** 56 more unnamed server functions now have a grounded statement of
which subsystem they belong to, and the tool that produces them no longer has a
silent blind spot.

**Next step:** the 44 "mixed domains" functions are the interesting residue —
each raises codes from two or more subsystems, which usually means a shared
helper (an inventory move that can fail as STRG or as GUILD storage). Those are
where a single function ties two systems together, so they are better reading
than the single-domain ones for anyone mapping how the server is put together.

## 2026-09-16 — the mixed-domain residue, read rather than promoted

The previous entry proposed the 44 mixed-domain functions as better reading than
the single-domain ones, because a function that fails as both `FORT` and `GUILD`
is usually where those systems meet. That held, and the payoff came from reading
one rather than from the list itself.

### The list, and what it is not

The combinations cluster — FORT+GUILD 7, INSTANCEDUNGEON+INTERACTION 2,
COSPET+STRG 2, QUEST+SKILL 2 — and the shapes are legible from the refusal sets:
`FUN_004a00c0` raises `CANT_USEITEM` + `PORTALSTONE_FAIL` +
`CANT_TELEPORT_WITH_CART` (a portal-item use path), `FUN_0058d8f0` and
`FUN_0059dc80` both raise `CANNOT_MAKE_TRAP` with `SKILL_USE_FAIL_OVERLAP` (the
trap-summoning skill), `FUN_00514010` raises
`CANT_PARTY_WITH_OPPONENT_IN_BATTLE_ARENA` with `PARTYMATCH_JOIN_ERROR_DUPLE`.

**Not one of those was promoted to a name.** A union of refusals is an inference
about purpose, and the attribution doc's own rule is that an attribution is not a
name. The residue's value is in choosing what to read, not in what it appears to
say.

### Reading one, and the constant it gave

`0x00526910` (COSPET + STRG) is the **trade-offer handler**, and its first line
is the find:

	if (*(byte *)(param_2 + 3) < 0xd) return 0x1806;   // WRONG_POSITION

It refuses a slot below 13 before it even fetches the item — because what is
*worn* cannot be put into a trade. `0xd` is `equipment.MaxEquipSlots`, recovered
independently four times over.

So **the engine keeps equipment and backpack in ONE index space**, worn items at
slots 0..12 and the backpack from 13. A second use-site agrees without knowing
about the first: `CheckEquipsetIntegrity` validates exactly slots 0..12 of that
same storage, calling `CanBeEquipedAt` on each.

### What that changes, which is a reading and not a number

`inventory.MaxSlotsExpanded = 99` is documented as "the largest inventory the
engine will ever produce". True — but it counts the equipment slots, so it is
**at most 86 usable backpack slots, not 99**. Nothing here was wrong; what was
missing is the sentence that stops someone reading 99 as 99 free slots.

srrevamp models the two spaces separately, which is a different design rather
than a wrong one, so no value changed. A test now holds the two models to the
engine's single array — `MaxEquipSlots + SlotsPerCharacter` must fit inside
`MaxSlotsExpanded` — placed in the equipment package because it is the only one
that imports both.

### Shipped

The mixed-domain map and its caveat in `error_attributed_functions.md`; the
shared-index-space note in `inventory.go` with both use-sites;
`TestSrrevampSlotsFitTheEnginesCombinedArray`.

**What moved:** one of the 44 read and turned into a grounded fact about how the
engine indexes items, and a cap that was correct but easy to misread now says
what it counts.

**Next step:** `FUN_00480a20`, the function the trade handler delegates to — it
is already in the STRG attribution list with five refusals including
`NOT_ENOUGH_OPPONENT_INV_SPACE`. That is the actual trade transaction, and the
space check inside it is where the engine decides whether a trade fits, which is
a rule srrevamp's own trading would need.

## 2026-09-16 — the trade transaction, and an item-loss bug closed with the engine's own rule

The previous entry proposed reading `FUN_00480a20`, the function the trade-offer
handler delegates to, because its refusal set includes
`NOT_ENOUGH_OPPONENT_INV_SPACE` and that is where the engine decides whether a
trade fits. It is, and srrevamp had a documented hole exactly there.

### What the function gives

	if ((byte)param_3 < 0xd) return 0x1806;           // slot 0..12 is worn, not tradeable
	iVar6 = FUN_0047eda0();
	if (iVar6 < 0xc) { ...                             // at most 12 items in an offer
	  iVar7 = CGStorage__CountEmptySlot(0xd, -1);      // count the partner's free slots FROM 13
	  if (iVar7 < iVar6 + 1) return 0x1836;            // NOT_ENOUGH_OPPONENT_INV_SPACE

Three things. A trade offer holds **at most 12 items**. The partner must have at
least **one free slot per offered item**. And `CountEmptySlot(0xd, …)` counting
from 13 is a **fourth independent confirmation** that the backpack starts at slot
13 — after the trade-offer handler's `slot < 0xd`, `CheckEquipsetIntegrity`'s
0..12 loop, and `CanBeEquipedAt`'s own bound.

### The bug it closes

`executeTrade` carried this comment:

> Items have already left both givers' inventories at this point. If AddItem
> fails here … the item is **lost** rather than returned — a known,
> low-probability gap. **A production system would pre-check recipient capacity
> before ever removing anything; that check isn't implemented yet.**

The engine's check is precisely that pre-check, so it is now implemented as
`tradeSpaceShortfall`, called before any gold or item moves.

**The new test fails without it, and the failure message is the bug**:
`crediting item to recipient: inventory: no room for item` — raised *after* the
item had already left the giver. With the check, the trade is refused cleanly and
the giver still holds the item, which is what the test asserts.

### Two details copied deliberately

**It counts empty slots and ignores stacking.** An item that would have merged
into an existing stack is still required to have a free slot. That is
conservative, and matching it is the point: a trade refused for space it would
technically have had is a far better failure than an item that vanishes.

**The engine checks earlier than srrevamp now does.** It refuses at *offer* time,
so the player learns while arranging the trade; srrevamp checks at commit, which
closes the item-loss hole but reports later. That difference is written into the
code rather than left for someone to discover.

What remains is only the race — a slot free at validation and taken by the time
the trade commits — which needs a transaction spanning the character and
inventory stores, not a better check. The comment now says that instead of
describing a missing check.

### Shipped

`tradeSpaceShortfall` with the engine's rule and the three citations;
`TestTradeRefusesWhenRecipientIsFull`, verified to fail without the fix; the
stale "not implemented yet" comment replaced by what is actually left.

**What moved:** a real item-destruction path closed, using a rule read out of the
engine rather than invented, and the slot-13 boundary confirmed a fourth time.

**Next step:** the 12-item offer cap and the `0x1836` refusal are recovered but
unused — srrevamp's `trade.Offer` is a single item plus gold, so neither applies
to its model yet. If the offer ever becomes a list, both are already grounded and
should be taken from here rather than chosen.

## 2026-09-16 — the item capability flags: nine engine-named predicates, one flags word

The previous entry's next step was a non-action — the 12-item offer cap does not
fit srrevamp's single-item model — so this tick took the vein that produced the
last two findings instead: **srrevamp's gaps against the engine's refusals.**

A sweep for admitted gaps in srrevamp came back nearly clean (two hits, neither a
game rule), so the sharper question: the engine has refusals named
`CANNOT_BE_TRADED`, `CANNOT_BE_DROPPED`, `CANNOT_DEAL_AT_SHOP` — **item flags**,
and srrevamp models none of them.

### The recovery

The trade handler refuses `0x183a CANNOT_BE_TRADED` when `vslot(0xc4)` returns
zero. `0xc4` is slot 49, and the base implements it as an `## Illegal ##` stub
that names itself: `IGObj::CanTrade`. There are **nine** such stubs, consecutive
in memory 0x30 apart — `CanTrade, CanSell, CanBorrow, CanDrop, CanPick,
CanRepair, CanRevive, CanUse, CanThrow`.

`CGObjCOS_Summoned` implements all nine, and each override is two lines reading
**one bit of one flags word** at ref row `+0x8c`:

	bit 0 CanTrade   bit 4 CanDrop    bit 7 CanRevive
	bit 1 CanSell    bit 5 CanPick    bit 8 CanUse
	bit 3 CanBorrow  bit 6 CanRepair  bit 9 CanThrow

plus a tenth at bit 10 with no stub to name it. **Zero means refuse** — a set bit
is permission. Full table and the parser's construction in
`docs/protocol/item_capability_flags.md`.

`0x1838 CANNOT_BE_DROPPED` is deliberately **not** in that family despite the
matching name: its guard is a TID lookup, a different mechanism.

### Two failed probes, kept

The bits are settled; **which itemdata columns feed them is not**, and both
attempts failed in ways worth recording.

**A partial extraction that looked complete.** A regex over the parser's field
reads captured 11 where it has many more, and produced indices 2, 3, 4… —
positions within that subset, which look exactly like column numbers. Promoting
them would have invented seven columns. This is the same fault as the
level-record offsets two ticks ago: an extraction over decompiled C that does not
account for everything it is counting.

**A shape prediction that failed cleanly, which is the useful kind.** If seven of
these are consecutive boolean columns, itemdata should hold a run of seven
columns containing only 0 or 1. There is exactly one — columns 41..47 — and
`ITEM_CH_SWORD_01_A_DEF` reads **0 across all seven**. A sword must be tradeable
and a set bit is permission, so that run is not the flags. A discriminator search
(sword 1, quest item 0) gave 17, 22, 23, 26, 33 — scattered, no run.

### Shipped

`docs/protocol/item_capability_flags.md`: the nine names, the bit map with an
implementation address for each, the flags-word construction, and an explicit
section on what is not established and what was tried. No srrevamp value changed
— without the columns there is nothing to wire.

**What moved:** a whole permission system identified by the engine's own names,
with ten bits mapped to predicates by use-site, and an honest boundary around the
half that is still open.

**Next step:** recover `RefObjCommon_ExtractData`'s **full** field order. It is
the blocker for these columns and for anything else in `_RefObjCommon`, and the
partial-regex approach is now proven inadequate — it wants the disassembly, where
each field read is an unambiguous `mov` from `[cursor + base]` with the cursor
advancing by a known width, rather than decompiled C where the reads take several
shapes.

## 2026-09-16 — the parser's field order, from the disassembly the C could not give

The previous entry ended with the column hunt blocked and named the reason: a
regex over decompiled C captured 11 of the parser's fields where it has many
more, and the approach was "proven inadequate — it wants the disassembly, where
each field read is an unambiguous `mov` from `[cursor + base]`". That turned out
to be exactly right.

### What the disassembly gives

Every field read in `RefObjCommon_ExtractData` is a `mov` through indexed
addressing `[cursor + base*1]`, followed by a field-counter increment and a
cursor advance of the field's own width. **41 reads**, against the regex's 11.

Better, each read's value can be followed to the stack slot it is stored in, and
the flags expression names the slot it takes each bit from. That makes the chain
exact — read → slot → bit → predicate:

	read 11  esp+0x11  bit 0  CanTrade      read 16  esp+0x27  bit 6  CanRepair
	read 12  esp+0x26  bit 1  CanSell       read 17  esp+0x25  bit 7  CanRevive
	read 13  esp+0x12  bits 12/13           read 18  bl        bit 8  CanUse
	read 14  esp+0x13  bit 4  CanDrop       read 19  al        bit 9  CanThrow
	read 15  esp+0x23  bit 5  CanPick

**Nine consecutive reads immediately before the flags word is assembled, in the
same order as the nine stubs.** Not an inference from adjacency — every row is a
slot the flags expression actually reads.

### And the column numbers are still not the read numbers

The obvious next move is to call read *n* column *n*. **It is wrong, and there is
a clean anchor proving it.**

Read 9 writes row `+0x88`. `CanBeEquipedAt` reads `+0x88` as the item's Country
(refusing with `0x182f COUNTRY_MISMATCH` unless it is 3), and `ITEM_FORMAT.md`
pins Country to **itemdata column 14**. So read 9 is column 14 — a gap of five.

The cause is in the pattern itself: **string columns are consumed by a helper
call, not by an inline indexed `mov`**, so they never increment this count. The
gap is therefore not a constant to add — it grows by one per string column
passed, and `_RefObjCommon` has several near the front.

Had I applied the naive mapping, `CanTrade` would have been published as column
11. The Country anchor says it is at least 16, and "at least" is not a column
number.

### Shipped

`item_capability_flags.md` gains the field-order table with its stack-slot
bindings, the Country anchor, and the reason the gap is not constant. No
srrevamp value changed — the columns are still what would make this usable.

**What moved:** the bit order went from "nine consecutive reads, probably these"
to an exact slot-by-slot binding, and the remaining blocker is now one specific,
named thing rather than a general difficulty.

**Next step:** count the string-consuming helper calls interleaved with the 41
inline reads. Each is one column. With those in place every read has a column
number, the Country anchor becomes a check rather than a puzzle, and the nine
capability flags become wireable into `refdata.Item`.

## 2026-09-16 — the column arithmetic falls out, and the data refuses the answer

The previous entry's next step was to count the string-consuming helper calls so
every read gets a column number. That worked, was confirmed three ways, and then
the data rejected the conclusion drawn from it — which is the part worth keeping.

### The arithmetic, and a prediction that landed exactly

Two helpers consume a field without an inline indexed read. `FUN_006b2ef0` reads
a length-prefixed string; `FUN_006b1a80` ends with `param_1[10]++`, which is the
field counter at `+0x28`. Between read 1 and read 2 there are four of the first
and one of the second — **five consumed columns**, which is exactly the gap the
Country anchor predicted last tick.

	READ0 -> column 0     READ1 -> column 1     READn -> column n+5  (n >= 2)

Confirmed three ways, none of them the one that produced it: a real row's columns
2..6 are exactly five strings (code name, display name, `xxx`, and two `SN_`
ids); READ4..READ7 land on columns 9..12, which are TypeID1..4 and read 3/1/6/2
for a sword; READ9 lands on column 14, Country, reading 0 for a China sword and 3
for a MALL item.

That arithmetic is a tool for the whole `_RefObjCommon` prefix.

### And then the data said no

Applying it to the nine capability reads gives columns 16..24. Checked against
real rows, `ITEM_CH_SWORD_01_A_DEF` would read **`CanTrade = 0`, `CanDrop = 0`,
`CanRepair = 0`** — a sword is plainly all three — and `ITEM_ETC_GOLD_01` would
read **`CanDrop = 255`**, which is not a boolean at all.

The 255 is the loud one. A boolean column holding 255 is not a near-miss to
argue with; it says the reading is wrong.

**Since the arithmetic is anchored three times, the fault is in the read → slot →
bit binding**, and the extraction shows where: slots `esp+0x11` and `esp+0x12`
are each **written twice**, by reads 2 and 3 and again by reads 11 and 13. My
heuristic paired each read with the next store within a few instructions, which
cannot say which write is live when the flags expression runs. There is no branch
between the two groups — both execute — so the question is real.

I could have shipped columns 16..24. The sword row is what stopped it, and the
only reason the sword row got checked is that the map made a claim specific
enough to test.

### Shipped

`item_capability_flags.md` gains the read-to-column arithmetic with its three
anchors, and a section saying plainly that applying it to the flags contradicts
the data, why the binding rather than the arithmetic is at fault, and what would
fix it. No srrevamp value changed.

**What moved:** a reusable column arithmetic for `_RefObjCommon`, established and
triple-checked; and one wrong answer caught by the data before it became a doc.

**Next step:** re-derive the slot binding properly — for each stack slot the
flags expression reads, find the **last** write before `0x6a34e6` rather than the
first write after each read. That is a small change to the extractor and it
decides whether the capability columns are 16..24 or the earlier group at 7..12.

## 2026-09-16 — the capability columns confirmed, and a wrong exemplar corrected

The previous entry rejected the column mapping because
`ITEM_CH_SWORD_01_A_DEF` reads `CanTrade = 0` and "a sword is plainly
tradeable". Re-deriving the slot binding by **last write before the flags
expression**, as that entry proposed, gives **exactly the same answer** — so the
binding was never the problem.

**The exemplar was.** `_A_DEF` is the *starter* row, and starter gear is the one
class of sword the real game binds to the character. I rejected a correct mapping
on a badly chosen representative item.

### What settles it

A distribution over item classes rather than one row:

	group                          CanTrade (col 16)   drop mask (col 19)
	ordinary swords (136 of 160)   1                   255
	starter, _A_DEF (all 52)       0                   0
	quest, ITEM_QNO_ (all 558)     0                   0
	cash shop (247 of 267)         1                   255

Starter and quest items bound, ordinary and cash-shop items free. That is the
real game's behaviour, **predicted by the mapping rather than fitted to it**.

And column 19 is the detail that proves it. The flags expression extracts *two*
bits from that slot (`((b & 2) << 9 | b & 1) << 4`), and column 19 is the one
column in the block holding **255/128/223/192** where its neighbours hold 0/1. A
boolean column would not need masking; a masked column that happened to be
boolean would be a coincidence.

### What that makes the 255 from last tick

Last tick I called the 255 "the loud one — a boolean column holding 255 is not a
near-miss to argue with". That was right to stop on and wrong about why: the
value was loud because the column **is a bitmask**, which is evidence *for* the
mapping. A signal that something does not fit one's model can mean the model is
wrong in a smaller way than assumed.

### Shipped, wired and enforced

`refdata.Item` gains `CanTrade`, `CanSell` and `CanDrop` from columns 16, 17 and
19 — through the exporter (which emits bit 0 of the mask column rather than the
raw byte), the CSV loader as a strict suffix, and the SQL store with the new
columns **defaulting to TRUE**, so an older import leaves items unrestricted
rather than silently forbidding every trade.

**And the engine's own refusal is now enforced.** `TradeHandler` takes an item
lookup and `executeTrade` refuses a bound item before anything moves, as the
engine does with `0x183a CANNOT_BE_TRADED`. A deployment with no reference data
enforces nothing by design — `items` is nil, and an unknown item is "no opinion"
rather than a refusal, because `CanTrade` is a bool and an unknown item would
otherwise read false and fail every trade.

`TestTradeRefusesUntradeableItem` checks both directions: a bound item is refused
and stays with its owner, a tradeable one still goes through.

**What moved:** nine capability predicates went from named-but-unusable to three
of them grounded, wired and enforced — and srrevamp stopped letting players trade
away starter and quest gear the real game pins to the character.

**Next step:** `CanSell` is now in `refdata.Item` and unused. The shop's sell path
is the obvious consumer, and the engine has the matching refusal ready —
`0x183b CANNOT_DEAL_AT_SHOP`, raised by `GObjPC::FUN_006182a0` when `CanSell`
answers zero — so it is the same shape of change as this one, with the citation
already in hand.

## 2026-09-16 — CanSell enforced, and the zero value that would have broken everything

The previous entry's next step was to wire `CanSell` into the shop's sell path,
with the engine's refusal already in hand. Done — and the interesting part is a
hazard the field's own type created.

### The refusal

`GObjPC::FUN_006182a0` calls `CanSell` (vtable slot 50) and returns
`0x183b UIIT_MSG_STRGERR_CANNOT_DEAL_AT_SHOP` when it answers zero.
`shop.Service.Sell` already had the item in hand, so the check went in exactly
where the engine makes it — **before the item is removed**, so a refusal costs
nothing. New `shop.ErrCannotSell`, and a test asserting the inventory is
untouched after a refusal.

That handler turned out to be the specialty/trade-goods path rather than the
ordinary one (its other ten refusals are `SPECIALTY_ERR_*`), but the `CanSell`
check is the same check, and the flag is the item's own.

### The hazard, which is about Go rather than the engine

`CanTrade`/`CanSell`/`CanDrop` are **permissions: a clear bit forbids.** Go's zero
value for a bool is false. So an export made before those columns existed loads
every item as un-tradeable and un-sellable, and a server running it refuses every
trade and every sale **with nothing in the logs to explain it**.

The SQL store already defaulted `TRUE`. The CSV loader did not, and the two have
to agree or the same export behaves differently per backend. Fixed: an absent
column now means unrestricted, set in the loader rather than left to each caller
to remember, with a test holding both halves — an older row loads unrestricted,
and an explicit zero still forbids.

**The remaining sharp edge is deliberate.** A `refdata.Item` built by hand still
zero-values to "forbidden", and the shop test caught it immediately — the sale
was refused with `shop: this item cannot be sold`. That is the right behaviour to
keep: a literal is written by someone who can see the field, an old export is
not. The fixture now says `CanSell: true` because that is what it means.

### Shipped

`shop.ErrCannotSell` and the check; `TestSellRefusesUnsellableItem`;
`TestCapabilityFlagsDefaultToUnrestricted` guarding the loader default against
the SQL default. Two of the three recovered flags are now enforced where the
engine enforces them.

**What moved:** un-sellable items can no longer be sold, and a footgun that would
have silently disabled trading and selling on every pre-existing export is closed
before anyone met it.

**Next step:** `CanDrop` is the last of the three and srrevamp has no drop path to
enforce it in — items are removed by `RemoveItem`, with no player-facing "drop"
action. That makes it the first of these flags with nothing to wire into, so the
honest move is to leave it carried-but-unused and say so, rather than invent a
drop action to justify the field.

## 2026-09-16 — nine more names applied, and a characterisation corrected

`CanDrop` was the standing next step and it is a deliberate non-action: srrevamp
has no player-facing drop action at all — items leave an inventory through
`RemoveItem` — so the flag is carried and unused, and inventing a drop action to
justify a field would be the wrong order of work. Said here rather than left as
an open item that looks unfinished.

So this tick took the other standing thread: the names this session recovered
after the last apply.

### Applied

Nine, all `descriptive` with the evidence in the row:

	SetStr / SetInt / SetStatPoints   the three charData setters behind the level-up
	ApplyHPMPDelta                    the level-up's heal, guarded per-pool on non-zero
	RefData_ReadStringField           one call per string column in the row parser
	TradeOfferItem                    refuses slot < 0xd and a non-tradeable item
	OfferItemToPartner                the offer transaction and its space check
	DropItem                          returns 0x1838 CANNOT_BE_DROPPED
	SellItemAtSpecialtyShop           calls CanSell, returns 0x183b

	server  7,394 -> 7,404 named  (+10)

Ten rather than nine because `RemoveSiegeObject` from v0.1.237 was applied to the
project but its dump was never rebuilt — so it only became visible now. Worth
knowing: **applying a name and rebuilding the dump are separate steps, and the
metric only sees the second.**

### A characterisation corrected

v0.1.244 read `FUN_0047eda0` as counting the items in a trade offer. It is not:
it walks a two-entry array of party records, matches one by its first field, and
returns a field from the matched record — a **lookup**, not a count.

The number it returns is still what gets compared against 12, so the *conclusion*
("an offer holds at most 12 items") stands; what was wrong was the description of
how the engine gets there. A function summarised from its caller rather than read
is a claim about the caller.

### Three candidates deliberately not named

`FUN_0042e750` tests for TypeID 3/2/2, which a real itemdata has exactly one row
of (`ITEM_ETC_TRANS_MONSTER`) — too thin a basis for a name.
`FUN_00498610` tests TypeID3 == 14, the avatar family, then calls three unnamed
functions; and `GObjPC::FUN_00483f40` is the tenth capability predicate with no
stub to name it. All three are read and understood in shape but not in purpose,
which is not enough.

**What moved:** nine names into the binaries where every future session sees
them, one wrong description corrected, and three candidates left alone.

**Next step:** the client half of the applier has not run since the first batch,
and two of the 35 rows are client-side additions waiting. More usefully, the
client dump has not been rebuilt since then either — so the client figure
(6,455) is current but will drift the moment anything is applied. Running both
halves and rebuilding both dumps is the cheap way to keep the metric honest.

## 2026-09-16 — every writer of the capability word, enumerated

The named next step was housekeeping — run both applier halves, rebuild both
dumps — and it was **based on a wrong premise**. Verifying first showed all 35
names already applied and visible, client half included: *rows verified
unnamed-and-present: 0, already named: 35*. Nothing was pending. That is twice
now a "next step" has assumed work remained without checking, and the check costs
one command.

So the tick went to a real open item instead, and then to a better one behind it.

### The false lead, and what it opened

`0x180b CANT_BE_STORED` looked like it might be the unaccounted **bit 2** of the
capability word. It is not: the constant appears at exactly **one** site in the
binary, inside `SellItemAtSpecialtyShop`, so it is a specialty rule rather than a
general storage flag.

But the probe raised the better question. `RefObjCommon_ExtractData` touches the
flags word only four times, and none of those touches set bits 2 or 3 — yet
`CanBorrow` reads bit 3. So who writes them?

### Every writer, in the whole binary

Scanning every `or`/`mov`/`and`/`xor` into `[reg+0x8c]` and keeping the ones
inside a row parser gives **five instructions, total**:

	6a351b  mov [esi+0x8c],ecx      RefObjCommon   bits 0, 1
	6a3529  mov [esi+0x8c],ecx      RefObjCommon   the same, | bit 12
	6a3536  or  [esi+0x8c],0x2000   RefObjCommon   bit 13
	6a3595  or  [esi+0x8c],edx      RefObjCommon   bits 4,5,6,7,8,9,14
	6a5cb4  or  [edi+0x8c],eax      RefObjChar     bits 10, 11

`RefObjItem`'s own extract touches `[esp+0x8c]` — the stack — and never the row.

Two results fall out, and both are the kind of absence this project wants:
**enumerated, not inferred.**

- **Bits 10 and 11 exist only on CHARACTER rows.** `RefObjChar_ExtractData`
  contributes them from two of its own columns, so an item can never have them.
  Bit 10 is the tenth predicate (`GObjPC::FUN_00483f40`) — a question only a
  character can answer yes to, which is why no stub names it for items.
- **Bits 2 and 3 are never written at all.** So **`CanBorrow` always returns 0**:
  nothing in the game is borrowable, for any object type. The predicate exists,
  has a stub and an implementation, and is answered "no" by construction. Bit 2
  has neither a writer nor a reader — a gap in the numbering, not something this
  project failed to find.

If srrevamp ever models borrowing, the grounded answer is *false for everything*,
and that is the engine's answer rather than an omission here.

### Shipped

`item_capability_flags.md` gains the complete writer list and what it settles.
The bit table now says bit 2 is dead and `CanBorrow` always answers zero, each
with the reason. No srrevamp value changed — this closes questions rather than
opening behaviour.

**What moved:** the capability word went from "nine named bits and two mysteries"
to fully accounted for, by enumerating writes across the whole binary rather than
reasoning about the parser I happened to be reading.

**Next step:** the same enumeration is worth running on the OTHER shared ref-row
fields. `RefObjChar_ExtractData` contributing bits 10/11 means character rows
extend the common prefix in ways items do not, and the column arithmetic
established two ticks ago (`READn -> col n+5`) applies to characterdata as well —
so the two characterdata columns behind bits 10 and 11 are recoverable by exactly
the method that worked here.

## 2026-09-16 — bits 10 and 11 traced to characterdata, and a near-miss on the capability columns

The named next step was to recover the two characterdata columns behind
capability bits 10 and 11, using the column arithmetic on
`RefObjChar_ExtractData`. Done — and on the way it nearly overturned the
capability mapping shipped two ticks ago.

### The scare, and why it was not one

Counting every column consumer in `RefObjCommon_ExtractData` gave **47** (41
inline reads, 5 string calls, 1 other). But the arithmetic only works if
`RefObjChar` continues from there, and it does not: starting at 47 puts `+0x198`
(Level) at column 48 when the established anchor says **57**. A shift of nine.

Nine uncounted consumers in the common parser could have meant the capability
columns were wrong. **They are not**, and the check is exact: of the 5
`RefData_ReadStringField` calls, **four are before the capability block and one
after**; the single `FUN_006b1a80` is before. So exactly five consumers precede
read 2, `READn -> col n+5` holds through the whole block, and the table confirms
it instruction by instruction — READ14 lands on column 19, READ17 on 22, READ19
on 24, exactly as shipped. All nine uncounted consumers are *after* the block.

That also matches the empirical check from two ticks ago, where the mapping
predicted starter and quest items bound and ordinary items free. Two independent
confirmations of the same columns, and a third route that would have broken them
if it could.

### The columns, anchored twice

With `RefObjChar` starting at column 56, its reads land `+0x198` on **column 57**
(Level) and `+0x19c` on **column 59** (MaxHP) — both already established. A real
characterdata agrees: column 57 reads 1/2/3 for pets, 95 for a monster, 100 for
an NPC; column 59 reads 360/441/524 and 6,000,000 for a boss, with player rows
at MaxHP 0, exactly as the starting-stat audit found.

	bit 10  <- characterdata column 67
	bit 11  <- characterdata column 68   (always 0 in a real table)

### What column 67 separates

It splits the COS families perfectly, no exceptions either way:

	COS_P (pets)      9,826   all 1        COS_GUILD   3,514   all 0
	COS_C               124   all 1        COS_GUARD   3,079   all 0
	COS_T (transports)   94   all 1

Set on every player-ownable COS, clear on every guild soldier and guard.

**The predicate is not named.** Bit 10's reader is `GObjPC::FUN_00483f40`, the
tenth entry in the `CGObjCOS_Summoned` block, and unlike the nine above it has
**no `## Illegal ##` stub** — the engine offers no word for it. A clean split
between ownable and non-ownable COS describes what the flag *separates*; it is
not the engine's name for what the flag *permits*, and the two are not the same
claim. Nothing was invented.

**What moved:** two more capability bits traced to their columns with two
anchors and a class-level check; the shipped capability columns survived a route
that could have falsified them; and a tenth predicate is now characterised
without being named.

**Next step:** the nine uncounted consumers in `RefObjCommon_ExtractData` are
worth identifying — four calls to `0x9dd03d`, two to `0x402090` and a handful of
singletons, all after the capability block. Each that turns out to consume a
column shifts every `_RefObjCommon` field after it, so the columns past 24 are
not yet safe to derive, and saying which of those calls are consumers is what
makes the rest of that prefix reachable.

## 2026-09-16 — the missing columns were a loop, and it identifies itself

The named next step was to identify the nine uncounted consumers in
`RefObjCommon_ExtractData`. **They are not consumers**, and the hypothesis that
they were is disproven: four are CRT (`_free`, `_atol`, `__stricmp`,
`__security_check_cookie`) and the other six touch neither the stream cursor at
`+0x1c` nor the field counter at `+0x28`.

### A better instrument

The engine keeps its own column index in the stream at `+0x28` and bumps it once
per column, so **counting `add DWORD PTR [reg+0x28]` plus the two helper calls
counts columns directly**. It catches read forms a regex over addressing modes
misses — 42 increments against 41 matched reads.

### The real cause, and it names itself

**A loop.** `0x6a36ab..0x6a3700` runs four times (`mov eax,0x4`, decremented per
iteration) and consumes two columns each — a dword then a byte, written to
`row+0xb4` and `row+0xb8` with a stride of 8. Static counting sees two columns
where the engine consumes eight.

Four `(dword, byte)` pairs is the shape of the **four `(ReqLevelType, ReqLevel)`
requirement pairs**, and `ITEM_FORMAT.md` documents those at **columns 32..39**
from the data side. The counter says the loop begins at column **32** and ends at
**39**.

**That is a third anchor**, independent of the two that established the
arithmetic (the five-column string prefix, and Country at column 14) — and the
first one *after* the capability block, where nothing had reached before.

### The residual, stated rather than rounded away

Accounting now reaches **54** columns; the `RefObjChar` anchors require **56**.
Two consumers are still invisible to the counter scan. That is a precise
residual, not a mystery: the instrument is validated (it lands column 32 exactly),
the class of explanation is known (loops and unmatched read forms), and what is
left is two instructions.

Columns past 39 stay underivable until those two are found. **The capability
columns at 16..24 are unaffected** — they sit long before the loop, and their five
preceding consumers were enumerated individually.

**What moved:** a wrong hypothesis removed, a better instrument established and
validated against a third independent anchor, and the parser's one column-eating
loop identified as the requirement pairs.

**Next step:** find the two. The counter scan matches `add DWORD PTR
[reg+0x28]`; an `inc`, an `add` through a different operand shape, or a second
short loop would all be invisible to it. Diffing the engine's own counter — the
value at `+0x28` when the parser returns, if a caller checks it — against the 54
would say exactly where to look, and `RefObjChar_ExtractData` has the same
instrument available to cross-check.

## 2026-09-16 — the two missing columns were never missing

**What moved.** `RefObjCommon_ExtractData` consumes **58 columns (0..57)**, not
56. The long-running hunt for "the two unaccounted columns" was chasing a gap
between a count that was two short and a row width that was wrong in the first
place: a real client's itemdata rows have **161** columns and characterdata
**105**, so 56 was never either table's width — it was a mis-measured prefix.

**Why the count was short.** The instrument was right (count the stream's own
column counter at `[edi+0x28]`, plus the two helpers that bump it internally)
and it counted **call sites rather than executions**. Two loops sit in the
parser:

- the requirement pairs, `6a36ab..6a3700`, 4 trips x 2 fields -> columns 32..39;
- five asset-path strings, `6a3a30..6a3a45`, 5 trips x 1 string -> columns 52..56.

The second hid the whole discrepancy: one `call 0x6b2ef0` that runs five times.
Its trip counter is `[esp+0x28]`, and a previous pass found exactly that
instruction, correctly identified it as stack rather than the stream, and moved
on — both readings of `+0x28` were right; only one was the relevant one. **A
scan over instruction forms cannot see a loop; it has to be given trip counts.**

**The contradiction that broke it open.** `RefObjChar_ExtractData` makes *zero*
string calls, yet characterdata columns 52..56 are five strings — so the common
parser had to read them, while its five string calls were already placed at
columns 2..6. Both were true: there are **nine** string columns (2,3,4,6 and
52..56), plus column 5 through `FUN_006b1a80`. Counting five was the error.

**Checks, none of them the thing that produced the map.** Four anchors land
exactly: `fID = 1` on a 4-byte store at `+0x8`; `fCountry = 14` on a 1-byte
store at `+0x88`; `fMaxStack = 57` on the final 4-byte store at `+0x184`; and
the four requirement pairs on the 4x loop's (4-byte, 1-byte) pairs at 32..39.

**Columns 52..56**, five `std::string`s at `+0xf4` stride `0x1c`: the worn/world
model `.bsr` (52), the ground-drop model `.bsr` (53), the inventory icon `.ddj`
(54), and two mostly-`xxx` columns. Columns past 39 were blocked on this and are
now derivable.

**The rule that hid it.** `READn -> col n+5` holds only through column 51; the
five-string block then consumes 52..56 with no inline read, so the next inline
read is column **57**. srrevamp's constants are raw indices rather than derived
through the rule, so none were wrong — but the rule as written produces wrong
ones past that point. Corrected in `docs/protocol/item_capability_flags.md`.

### Wired through: all four item requirement slots

Following the column map to its use-site recovered
`CGItemEquip::CheckEquipRequirements` (`0x004919e0`), which `CanBeEquipedAt`
calls before any of its other tests. Full spec in
`docs/protocol/item_requirements.md`. Two rules there are easy to invert and
both change real answers:

- **within a category the slots are OR** — `need`/`met` are one bit per
  category. The seven real rows with two level requirements are all
  `ITEM_MALL_STATS_POINT_RECALL*`, e.g. `(1,1)` and `(1,40)`: that item needs
  level **1**. Requiring every slot would have locked it to 40, which is the
  bug a naive "now check all four" would have shipped;
- **across categories it is AND.**

`refdata.Item` now carries all four slots (it carried one), `export-refdata`
emits columns 34..39 alongside 32/33, and `equipment.CheckRequirements` applies
the engine's rule. The mastery (513..518) and tier (769) categories take a
lookup and **a nil lookup leaves them unenforced** — srrevamp tracks neither
value, and refusing every mastery-gated item would be further from the engine's
answer, not closer.

**No level outcome changes on real data**, and that is the honest claim: the
gain is that the model matches the engine, the previously-invisible
requirements on 3,372 rows are carried, and enforcement is one lookup away.

**Corrected in passing.** `equipment/rules.go` called 513..518 "the European
masteries' own ids". Real Chinese rows use 513/515/518 and European ones
514/516/517/518 — the range spans both races.

**Not a data bug.** 24 rows carry requirement type 10, which would trip the
engine's own "This Mastery Type is not exist!" assert. They are all
`ITEM_ETC_GUILD_*_SOLDIER*_SCROLL`, TypeID `3/3/12/1` — ETC items that are used,
never equipped, so the equip checker never sees them. Type 10 belongs to the use
path's vocabulary, not this one.

**Also recovered:** the engine source path
`D:\WORK2005\Source\SilkroadOnline\Server\ServerCommon\ReferenceData.cpp`,
and a second parser (`ReferenceData::FUN_006a8d80`, the item-package table)
using the identical `count = 4; do { read; [+0x28]++; ReadStringField(); }
while(--count)` idiom — so loop-expansion is the norm in these parsers, and any
earlier column count taken from call sites alone should be re-checked.

**Open, and now unblocked:** columns 40..51 and 58..57+ are derivable from the
map; characterdata column 57 is level-shaped (`MOB_CH_MANGNYANG` = 1, 140
distinct values topping out at 110) while itemdata's is stack-shaped (1/250/500),
and both land in the same `+0x184` field — worth a reader of `+0x184` to settle
what the engine calls it.

## 2026-09-16 — naming by vtable slot: 53 names, and the 209 that were wrong

**What moved.** 53 server functions named, applied to the Ghidra project
(`applied 53, kept 0, no function 0, failed 0`). Full method: `Create` x23,
`Update` x11, `OnTimeout` x4, `DoJob` x4, `CreateWorld` x4, `PublishStats` x2,
`ExtractData` x2, plus three singles. See
`docs/protocol/vtable_slot_propagation.md`.

**The lever.** RTTI already gave the dump every function's class, vtable slot
and base chain — **5,992 server functions carry a slot tag and only 520 had a
real leaf name.** MSVC lays a derived vtable out with the base's slots as a
prefix, so a name known at slot N of a base is the same method at slot N of any
descendant. Validated before use against the 466 already-named slot-functions:
**458 agree (98.3%)**.

**Most of this tick was spent NOT shipping the wrong 209.** Propagating by slot
number alone offers 271 names, 209 of them `GetRefObjID` at slot 1 — which on
those classes is the MSVC scalar deleting destructor
(`*this = &vftable; if (flag & 1) free(this); return this`). The obvious guard
(require a shared base that has a function at that slot) does not help, because
`CBase` is a universal root and has its own slot 1, so every pair "shares an
ancestor". Excluding ancestors common to more than a fifth of all 747 classes
drops the offer to 69 with agreement unchanged; reading the bodies then rejected
14 more (`GetRefObjID` x7, still destructors; `Assert_BreakIfDebugger` x6, a
global helper's name leaking through a mislabelled function; a bare thunk).

**The three genuine ground-truth misses are the shape to remember**: `COnDead`,
`COnUpdate` and `COnSetupQuest` each override slot 1 with a different method.
Sibling agreement is not guaranteed — a candidate is only safe when every name
the rule finds normalises to the same method.

**Worth having by itself:** `RefObjItem::ExtractData` and
`RefObjStruct::ExtractData` are the siblings of `RefObjChar_ExtractData` — the
per-table parsers behind this week's column work, now named.

### Checked and already grounded — three constants not re-shipped

Harvesting the server's assert expressions (70 sites, 49 distinct expressions,
32 `m_` member names) produced the engine's own named limits. All were already
recovered, and re-deriving them independently is a cross-check rather than
progress:

| constant | value | already at |
|---|---|---|
| `MAX_CASHITEM_TID_COUNT` / `MAX_TID1..4_COUNT` | 2, 8, 4, 16, 32 | `equipment/rules.go`, same `ReferenceData.cpp:2466-2470` citation |
| `MAX_MAGPARAM_PER_ITEM` | 12 | `combat/paramtags.go`, from the **client's** `<=` assert |

The server's own site for the last one is an independent second source with a
different operator: `m_InstanceInfoOfItem.m_btMagParamNum < MAX_MAGPARAM_PER_ITEM`
guarded by `0xb < v`, against the client's `<=` guarded by `0xc < v`. Two
binaries, two operators, one number — and it reveals the struct:
`m_btMagParamNum` is a byte at `+0x24` with up to 12 `uint32` params at `+0x28`.

**Newly grounded:** `MAX_LOCALOBJID_BITS = 21`, from `CGObj::Create`
(`0x00484b80`) — the exponent `0x15` feeding a pow-by-squaring loop, the mask
`id & 0x1fffff` (2^21-1), and the engine's own
`"GOBJID is Overflow!! [Max: %d]"`. A GOBJID's local-id field is 21 bits, so
2,097,152 objects.

**Bounds verified against real data**, not just read off the asserts: across
23,327 itemdata and 13,291 characterdata rows, **zero** TypeID values fall
outside the recovered limits.

**Not promoted.** Column 7 is 0/1 and matches `btCash`'s bound, and `c7 == 1`
rows are 160x more likely to be MALL/CASH-named (32.1% against 0.2%). That is a
correlation, not a use-site, and 68% of `c7 == 1` rows are fireworks and
speed-ups rather than MALL-named. Left open rather than called CashItem. Column
8 is 0 on every item row and 1 on every character row — a living/non-living
discriminator, and **not** the cash flag, which is worth recording because the
five-byte block that `ReferenceData::FUN_006a8090` reads
(cash, TID1..4) tempts exactly that misreading.

## 2026-09-16 — column 55 recovered, and an open contradiction at column 57

**What moved.** **Column 55 is a tagged string and the parser reads a number out
of it**: it skips the table's `"xxx"` placeholder, searches for the literal
`"GP:"`, and `atoi`s the remainder into `_RefObjCommon+0x180`. Both literals are
the binary's own (`0xb090cc` = `"GP:"`, `0xae8110` = `"xxx"`), the branch is at
`6a3add..6a3ba2`, and the real data agrees exactly -- across 23,327 enabled
itemdata rows column 55 takes five values: `xxx` (23,298), `GP:5000` (24),
`GP:20000` (2), `GP:30000` (2), `GP:1000` (1). Characterdata uses the same
column for a different vocabulary (`FORTRESS_SAMARKAND` and eight more, 37
rows), which the `"GP:"` search does not match. Full note in
`docs/protocol/item_capability_flags.md`. This is one of the columns that opened
up when the prefix turned out to be 58 wide.

**Two things checked rather than assumed.**

*The 58-column walk is branch-clean.* v0.1.254's walk assumed every consuming
site executes once; loops were expanded but **branches were never tested**. Of
81 forward jumps inside the parser, exactly one skips a consuming site --
`6a3104 jmp 0x6a3c70`, the early return when column 0 (service) is zero. Nothing
is conditionally skipped on the success path, so the 58 columns stand.

*`RefObjCommon::ExtractData` is a `__thiscall` and the dump's signature is
wrong.* `6a30dc mov [esp+0x14],ecx` stashes `this`; Ghidra dropped the `ecx`
parameter, the same failure as `Stat_ApplyTaggedModifier`'s EDI argument.
`RefObjItem` and `RefObjChar` pass **their own `this`** (`6a3d93`/`6a3d9a`,
`6a58ff`/`6a5906`), so they do not hold a separate common record -- they are
one, by inheritance.

### OPEN: what the engine calls column 57

Following `+0x184` to a use-site produced a conflict I could not resolve, and it
is recorded here rather than forced, because it bears on a value srrevamp uses
(`export-refdata`'s `fMaxStack = 57`).

**For "RefItem ID":** all three `ExtractData` overrides assert `this+0x184`
non-zero and pass it to `CGameServer::FUN_006ba850(0xc|0xd, id)`, whose failure
logs `"Can't find associated item data [RefObjCommon ID: %d, RefItem ID: %d]"`.
That callee returns a row stream (same `+0x18/+0x1c/+0x20/+0x28` shape), so it
is a genuine table lookup. The engine also has a member `m_dwLink`, from the
assert `dwItemID == m_dwLink`.

**For MaxStack:** column 57 has **18 distinct values** across 23,327 enabled
itemdata rows (1 x19,679, then 250, 500, 50) -- no foreign key looks like that
-- and it is **0 on 6 enabled item rows and 328 enabled character rows**, which
the non-zero assert would reject.

**Ruled out, each by measurement rather than argument:** a mis-counted column
(the walk is branch-clean, and four independent anchors land); the wrong object
(`this` reaches the parser in ecx and the overrides pass their own); a
client/server table-version split (both copies are 105 columns for
characterdata, 161 for itemdata).

**What would settle it:** read `CGameServer::FUN_006ba850` itself -- whether its
second argument is a row key or a table/kind selector. An 18-value key into a
small per-kind table would reconcile both halves; a per-row key would mean the
column attribution is wrong despite the anchors.

Until then srrevamp keeps reading column 57 as MaxStack, which is what the data
supports, with the conflict written at the constant.

### Closed: the vtable-slot lever is exhausted

v0.1.255 flagged the `## Illegal ##` stubs as the obvious multiplier. They are
**already fully applied** -- 207 functions carry such a label and 206 already
hold the label's own method name. The limit is the hierarchy: only **24 classes
derive from IGObj**, so its 202 named slots leave just **10** unnamed functions
to propagate to, and 6 of those are the `GetRefObjID` destructors already
rejected. Ground truth against IGObj's slots is 228/230 (99.1%); both misses are
this project's renames of the engine's own `OffsetSkillPoint` and
`OffsetExpPoint`.

**Worth noting for the ledger:** the engine's names for two functions srrevamp
renamed descriptively are `IGObj::OffsetExpPoint` (slot 92) and
`IGObj::OffsetSkillPoint` (slot 93) -- the canonical EXP and SP entry points.

## 2026-09-16 — column 57 resolved: one index, two formats

**The open item from v0.1.256 is closed**, by running exactly the test recorded
there: read `CGameServer::FUN_006ba850` and see whether its second argument is a
row key or a kind selector. **It is a row key.** Full write-up in
`docs/protocol/refobj_binary_format.md`.

	FUN_006ba850(kind, key):
	  for each stream in the loaded list:
	    kind 0xc,0xd,0xe -> save cursor/col; cursor = col = 0;
	                        id = *(int *)(stream->base);   // the row's FIRST field
	                        restore; if (id == key) return stream

**The resolution: the server does not parse the text tables at all.** It parses
a binary record -- 4-byte fields, 2-byte length-prefixed strings -- whose last
common field is a foreign key to the type-specific record. The client's
`itemdata.txt` is the **denormalised join** of the two and does not carry that
link: no itemdata column is per-row unique, and characterdata's only unique
columns are 1 and 2 (ID and code name). So binary field 57 and text column 57
are different fields sharing an index, and `fMaxStack = 57` reads the text
correctly. The contested flag is removed from the constant.

**Two structural findings fell out.**

*The binary tables are self-describing.* `FUN_006b1a80` -- which the 58-field
count depended on and which I had accepted merely because it bumps the counter
-- is a **schema-driven field skipper**: it fetches a schema through the
stream's own vtable, walks per-column records (stride 0x54) matching
`stream->col + 1` against `+0x30`, then advances the byte cursor by that
record's width at `+0x24`. Field 5 really is consumed, so v0.1.254's 58 stands,
now for a real reason.

*`"xxx"` is the tables' null placeholder and the parser erases it* --
`strcmp(this+0x48, "xxx")` then clear (`6a3173`..`6a318c`), which is also why
the `"GP:"` scan on column 55 tests for it first.

### CORRECTION — every itemdata count in these docs is inflated

Found while testing the above. `/var/tmp/tables/itemdata_*.txt` is a **mixture
of two extractions**: globbing it gives 23,317 enabled rows but only **16,819
distinct IDs**, because the coarse files are supersets of the fine ones
(`itemdata_15000.txt` contains 11000/12000/13000/14000; `itemdata_5000.txt`
contains 1000/2000; `itemdata_30000.txt` contains 26000). The game's own index
(`/var/tmp/idparts/itemdata.txt`) names 63 shards, one per 1000-ID range, and
only **20** are on the box -- so the corpus is partial as well as duplicated.
characterdata is clean (13,291 rows, 13,291 IDs).

**What this invalidates:** counts only. Every "N of 23,327 itemdata rows"
written this week -- the requirement-slot census, the capability-flag counts,
the TypeID row totals -- is inflated by roughly 39% and drawn from a partial
corpus; read them as proportions, not censuses. **What survives:** the shape and
existence claims. "Zero TypeID values out of bounds" is a superset check;
"column 55 takes five values", "column 57 has 18 distinct values" and "no column
equals the ID" are unaffected by duplicates.

**Rule going forward:** deduplicate itemdata by ID before counting, report
distinct IDs rather than rows, and state that the corpus is partial.

## 2026-09-16 — the death-cause enum, and three levers measured as exhausted

**Closed the queue's item 2 blocker.** The byte at victim `+0x1CB4` that
`GObjPC_OnDeath` compares against 5 is the **death cause**; see the work-queue
entry above for the derivation. `leveldata.DeathCause` now carries it, with
`DeathPenaltyFactorFor` encoding the engine's `!= 5` test rather than `== 3`,
and five tests including the one that would catch the enum being read backwards
(a monster death must cost more than a player death). The penalty constants'
names, `KilledByMonster` / `KilledByPlayer`, were an inference from the
multipliers and are now the engine's own distinction.

**`IsPC` is vtable slot 7** — worth recording on its own, because slot 7 turns
up all over the combat and object code and the `## Illegal ##` stub names it
outright, with `IsNPC` at 8 and `IsMonster` at 10.

### Three levers measured and found exhausted

Recorded so the next tick does not re-probe them:

| lever | measurement | verdict |
|---|---|---|
| binary table schema | the 0x54-stride column records are runtime DB metadata; no column-name table exists in the exe (`CodeName128`, `TypeID1`, `NameStrID128` all absent) | not statically readable |
| vtable propagation on the **client** | 5,839 slot tags but only **24** named (class, slot) pairs to seed from; 18 candidates, 16 of them `scalar_deleting_destructor` | no seed |
| cross-binary shared classes | 105 classes appear in both dumps, but **zero** unnamed client functions sit at a server-named slot — the server's named slots are concentrated in `IGObj`, which is not a client class | no overlap |

The client's own unexploited pool remains its **263 assert-carrying functions
that are still `FUN_`** (`docs/protocol/client_asserts.md`). An assert names the
source file and the expression, so it yields a class and member names rather
than a method name — which is why it has not moved the leaf-name metric.

## 2026-09-16 — the damage pipeline, split by side

Ran the probe queue item 3 recorded (resolve `Combat_ResolveDamage`'s register
arguments). It closed the item, and it found the entry stale: the mitigation
model was already shipped and the attacker/defender question already settled by
monotonicity. The walk settles it **independently** — the formula asks the EDX
object `IsMonster` and `GetMonsterClass` and then reads a param off the *other*
object, so EDX is the target — and produces the genuinely new part, **the roles
of all eight damage params and which character supplies each**. The param
registry had their bounds and an empty role column; it now has the table, and
the bounds agree with it without having been used to derive it.

**A mechanic named, not shipped:** an anti-monster-class damage bonus (attacker
param 259, applied as a percentage, only when the defender is a monster whose
`GetMonsterClass()` is 3). srrevamp publishes no source for param 259, so it is
unreachable rather than missing; `combat.go` now says so, along with the other
three attacker percentages the formula reads (128/129, 189, 178/179).

**Third lever this session found already-worked.** `IGObj::GetLifeState` (slot
62), `GetParam` (65) and `GetMonsterClass` (75) were all already in
`docs/protocol/igobj_vtable.md`, including the note that the `GetLifeState`
guard means *both parties must be alive*. Between this, the `## Illegal ##`
stubs and the TypeID constants, the pattern is clear: **check the docs for the
thing before probing for it.** The probes that paid this session were the ones
aimed at an explicitly recorded open question, not at a lever that looked
promising.

## 2026-09-16 — passive regeneration exists, and the tick is a timer callback

**This overturns a shipped claim**, reached by following up the previous tick's
param-read correction: 29 param ids are read only through `EvaluateParam`, and
two of them — 25 and 26, `'hprg'` and `'mprg'` — are read in a function nobody
had looked at.

**The tick is `CGObjPC::vslot_362` (`0x004e2990`)**, registered as a timer:

	4a6dd3  fld  DWORD PTR ds:0xb45dc0   ; 4.0 -- the interval
	4a6ddc  mov  eax,0x4ac6f0            ; the slot-362 thunk -- the callback
	4a6de6  push esi                     ; this
	4a6de7  lea  edi,[esi+0x18c]         ; the timer list
	4a6df0  call 0x4ab640                ; register

**Why it was missed, and it is a probe lesson rather than an oversight:** slot
362 is never *called*. A caller search returns zero. The thunk's address appears
**exactly once in the entire image**, at `0x004a6ddd`, as the immediate of that
`mov` — so only an address search over the image finds it. The earlier pass
searched for callers of the pool writers, found no clock, and stopped; the clock
is one indirection further out.

**What the tick does**, from the disassembly — the decompiled C loses the x87
stack, and the entire formula lives there:

	if (GetLifeState() != 1) return;                     // alive
	if (curHP == maxHP && curMP == maxMP) return;        // nothing to do
	if (GetBodyMode() not in {0, 4}) return;
	if (this[0xa2d]) {                                   // HP enabled
	    amount = ftol(curHP * EvaluateParam(25) / 100.0) // 'hprg'; 100.0 at 0xb45af0
	    if (amount < 1) amount = 1                       // FLOOR OF 1
	    bound  = ftol(curHP * 0.5)                       // 0.5 at 0xb45c50
	}
	if (this[0xa2c]) { the same, EvaluateParam(26) 'mprg' }

asserting against `GObjPC.cpp:0xdf9` (3577).

**Two findings that change the model, not just the claim:**

1. The rate is a percentage of the **current** pool, not the maximum, so
   regeneration accelerates as it fills.
2. The **floor of 1** means the engine's unbuffed rate is not zero. The old note
   reasoned "`'hprg'`/`'mprg'` default to 0, therefore the resting rate is zero"
   and never saw the floor. A live, damaged character recovers 1 per tick with no
   buff at all.

**Monsters take a different source entirely.** `CGObjMob::vslot_362`
(`0x004c1b00`) reads its amount from `_RefObjCommon+0xd4` — characterdata
**column 40** by the recovered column map, which is a use-site rather than a
curve. The data agrees from the other side: all 52 `CHAR_` rows hold **-1**
there and the engine skips a negative, while MOB rows span 0..5483 with a 0.611
correlation to MaxHP (Mangyang 3 against 54 HP).

**Shipped.** `mana.RegenInterval` is now **4 s** and real, the per-tick amount is
the engine's shape (`mana.RegenPerTick`: percentage of current, floored at 1,
capped at the deficit), and the tracker applies ticks in turn because
percent-of-current compounds and cannot be multiplied out. Five tests, including
one that fails if the percentage is taken of the maximum again.

`RegenPercentPerTick = 4` stays **own design and is now disclosed with a
reason**: the engine's literal rate is `'mprg'`, which srrevamp has no source
for, so shipping it would mean 1 MP every four seconds for every caster. The
shape is the engine's; only the percentage is ours.

**Not implemented, deliberately:** the `curHP * 0.5` bound. The comparison that
applies it sits at `0x004e2c00`, which this pass did not read, so its direction
is unknown and guessing it would be inventing a rule.

