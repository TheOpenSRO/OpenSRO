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
| **Monster `characterdata` cols 75–78** | `'era'`→9, `'bri'`→10, `'hra'`→11, `'cri'`→12 from `Stat_ApplyTaggedModifier`; real data: col 76 = **0** for every monster, cols 75 = 77 = **2·level+25**, col 78 = **2** |
| Stat points per level (3) | real character window |
| Quest identity, chain, descriptions, rewards | `questdata`, `questcontentsdata` cols 3/5-12, `refquestrewarditems` |
| Quest objectives are NOT data | proven absent: no objective refdata class; `_CHARQUEST` is status+count |

## Open — the actual work queue

Ordered by value. Each line names the next concrete probe, so a cold start can
pick one up without re-deriving anything.

1. **Monster EXP per kill — formula RECOVERED 2026-09-15; one column index still
   inferred.** Currently disclosed `ExpFor = maxHP`; not yet replaced, and the
   reason is below.

   The whole chain is proven by use-site, end to end:

   ```
   GObjPC_GrantKillReward (004e6980)
     -> Formula_MonsterExpReward (004105d0)
     -> x2 under one condition
     -> vtable 0x694 = GObjPC_GiveExp (004eac40)   [slot read from 0x00af6090]
     -> vtable 0x170 = GObjPC_GainExpAndLevel
   ```

   The formula itself:

   ```
   lvl    = min(Char_GetLevel(A), Char_GetLevel(B))
   base   = levelTable[lvl] + 0x1c            (unsigned 32-bit)
   reward = scaleByWindow x base x B[0x1cd8] x scaleByDiff , floored at 1
   ```

   **The most valuable part is not a number, it is a rule: the reward is taken
   at the MINIMUM of the two levels.** That is the anti-powerlevelling rule, it
   is symmetric so it does not matter which party is which, and it is
   implementable today independently of any column. Both scalers
   (`Formula_ExpScaleByLevelWindow`, `Formula_ExpScaleByLevelDiff`) are level-gap
   functions; the second selects its constants from a flag at the source ref
   object's `+0x88`.

   Two vtable slots fell out and are now named: **0x124 = `Char_GetLevel`**
   (slot 73 — and it returns ParamKeeper param 0 rounded, re-confirming param 0 =
   Level) and **0x694 = `GObjPC_GiveExp`** (slot 421).

   *What is NOT proven, and why nothing shipped:* which leveldata column
   `entry+0x1c` is. Three lines point at **col 5** — `entry+0x8` is the int64 col 1
   and `entry+0x10` is col 2, both already grounded, which puts +0x1c at col 5 on
   a 4-byte progression; and col 5's magnitude (~23.5·level early) matches the
   exp pacing the game needs. But that assumes cols 3 and 4 are 32-bit rather
   than int64, and **no parser has been read to confirm it**. A promising-looking
   confirmation was chased and discarded this pass: the function family around
   `RefLevel_GetEntry` looked like per-field accessors and is not — `FUN_00411370`
   is a `std::string` constructor that merely shares the address range. This is
   the exact shape of the col-79 mistake, so the column stays inferred.
   *Next probe:* find the code that BUILDS a level record (it allocates and fills
   the struct whose `+0x8` is the int64 exp requirement) and read its stores in
   order, the way `RefObjChar_ExtractData` gave the characterdata column map.

2. **Monster attack/defence — half closed (2026-09-15).** Four of the eight
   combat columns are now grounded by **the game's own tag names**, and the
   remaining four are isolated.

   The id→name table does exist after all — not as data, as **code**.
   `Stat_ApplyTaggedModifier` (`00498690`) takes a stat tag as a C multi-char
   literal in EAX and dispatches to a specific ParamKeeper id and slot, so the
   enum can be read straight off the branches. Verified **equality branches
   only**: the compiler compiles the dispatch as a binary-search tree, and its
   `<` comparisons will happily pair a tag with the wrong branch — the first
   pass here did exactly that and had to be thrown out.

   | tag | param | slot | col | what the real data does |
   |---|---|---|---|---|
   | `'era'` | 9 | 1 (add %) | 75 | 2·level + 25 |
   | `'bri'` | 10 | 0 (base) | 76 | **0 for every monster** |
   | `'hra'` | 11 | 1 (add %) | 77 | 2·level + 25 |
   | `'cri'` | 12 | 0 (base) | 78 | 2 |

   Also read off the same function: `'int'`→2, `'hp'`/`'hpa'`→3, `'mp'`/`'mpa'`→4
   (a **third** independent confirmation of MaxHP/MaxMP), `'hprg'`→25,
   `'mprg'`→26, `'rals'`→27, `'hpna'`→52, `'mpna'`→53, `'evbl'`→56, `'evcr'`→57.

   **Careful about what is and is not claimed.** The *tags* are recovered, the
   *param ids* are proven, and the *data behaviour* is measured. Expanding the
   mnemonics to English — evasion, block, hit, critical — is the obvious reading
   and the data supports it (a monster carries no shield, and a block rate of
   zero for every single one of them is hard to read another way), but it is a
   **reading**, not a recovery, and should be labelled that way wherever it is
   used. What srrevamp can use as real, today, is the numbers: monster `'bri'`
   is 0, `'era'` and `'hra'` are 2·level+25, `'cri'` is 2.

   *Still open:* cols 71/72 → params 5/6 and cols 73/74 → params 7/8. No tag in
   the dispatcher reaches them, so they are set only from gear and refdata.
   `Char_PublishCombatStats` (`00497830`) copies them out of a precomputed
   aggregate at `obj[0x66..0x6b]` (→ 5, 9, 7, 10, 6, 8 in that field order).
   *Next probe:* find what **writes** `obj[0x66..0x6b]`; that is where a weapon's
   own damage columns turn into these params, and a weapon is a thing whose
   itemdata columns this project already knows.

3. **Combat damage model** (base + bonus − defence, no crit/dodge) — ours.
   *Next probe:* `FUN_0058e5f0` is the real damage resolution; `FUN_0040f5f0`
   applies a level-gap roll clamped to [10%, 100%].
4. **Berserk numbers** (fill 8/hit, 20 s, +50 %) — ours. The mechanic and the
   five orbs are real. *Next probe:* the `'zb'` param tag (0x7a62) in the stat
   vocabulary.
5. **Monster spawn positions** — ours by necessity (`npcpos.txt` has no
   monsters). Likely genuinely absent; prove it and it stops counting as open.
6. **Quest objectives** — proven not to exist as data; any objectives shipped
   must be own design. Closed as a *recovery*, not a gap.
7. **Loot tables** — **CLOSED as a proven absence (2026-09-15).** The mapping
   question was a non-issue: `RefMonsterID` *is* characterdata col 1 (Mangyang
   = 1933), which we already carry. The blocker is the data. The drop classes
   are real in the binary (`CRefMonster_AssignedItemRndDrop`,
   `CRefDropItemGroup`, `CRefDropItemAssign`) but **no drop table exists in any
   artifact this project has** — not in Media.pk2, not in the server's
   `SR_GameRefData/`, nowhere in the y0gi bundle (the only files matching
   "drop" are meshes for the falling-loot visuals). It lives in the server's
   SQL database. So per-monster drops stay own design *by necessity*, and
   become real the moment an operator brings that table — the schema and the
   key are both already in place.
8. **Inventory size (50)**, **unarmed damage (5)** — ours; low value, may be
   genuinely absent.

## How to work this file

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
