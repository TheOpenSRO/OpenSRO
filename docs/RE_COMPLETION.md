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
| ParamKeeper ids 0/1/2/3/4 = Level/Str/Int/MaxHP/MaxMP | `GObjPC_InitStats` pushes `charData+0x65/+0x74/+0x76`; `GObjMob_PublishStats` pushes `refobj+0x19c`/`+0x1a0` |
| Stat points per level (3) | real character window |
| Quest identity, chain, descriptions, rewards | `questdata`, `questcontentsdata` cols 3/5-12, `refquestrewarditems` |
| Quest objectives are NOT data | proven absent: no objective refdata class; `_CHARQUEST` is status+count |

## Open — the actual work queue

Ordered by value. Each line names the next concrete probe, so a cold start can
pick one up without re-deriving anything.

1. **Monster EXP per kill** — currently disclosed `ExpFor = maxHP`. Exp-gain is
   vtable slot 92 (offset 0x170); `FUN_004eac40` is the `GiveExp` wrapper, and
   it is virtual too, so there is no direct caller to read.
   **Narrowed 2026-09-15:** `FUN_004105d0` (Formulae.cpp) is the reward formula
   and it works from a **level-table lookup** (`FUN_00411130`) plus two
   level-difference modifiers (`FUN_0040fed0`, `FUN_0040ffe0`) — it does not
   touch characterdata at all. That fits the earlier proof that nothing reads
   characterdata col 79: the server computes a kill's worth from the LEVEL
   table, and col 79 is a per-species copy it ignores. *Next probe:* find which
   level-entry field the reward reads. Careful — a grep for `+ 0x1c)` in that
   region matches **vtable calls**, not field reads, and briefly looked like a
   hit. Read the actual statements.
2. **Monster defence / attack / gold** — disclosed curve.
   **Sharpened twice, 2026-09-15.** The mob stat publisher `GObjMob_PublishStats`
   is now fully readable: the dump carries each push's ParamKeeper id inline, and
   joining that to the already-settled characterdata column map gives

   | refobj | column | param | what a PC derives it from |
   |---|---|---|---|
   | `0x230` | 71 | 5 | Str (via 21) |
   | `0x234` | 72 | 6 | Int (via 22) |
   | `0x238` | 73 | 7 | — |
   | `0x23c` | 74 | 8 | — |
   | `0x240` | 75 | 9 | Level |
   | `0x244` | 76 | 10 | — |
   | `0x248` | 77 | 11 | Level |
   | `0x24c` | 78 | 12 | — |

   Every one of those reads adds 2^32 when negative, so the fields are
   **unsigned 32-bit**. Against the real `characterdata` (the Jangan ladder,
   levels 1–12, both anchors re-verified: Yeoha is col 57 = 10, col 59 = 249,
   col 82 = 3000):

   - **col 73 = col 74 = the monster's level, exactly**, every row.
   - **col 75 = col 77 = 2·level + 25**, every row.
   - col 76 = 0 and col 78 = 2 for every monster on the ladder.
   - cols 71/72 rise with level, are per-species, and 71 ≤ 72 always.

   What that rules out: 71/72 are **not** a min/max pair of one quantity, because
   the PC graph feeds 5 from **Str** and 6 from **Int** — two different sources.
   They are a physical/magical pair. Which pair (attack or defence) is still
   **open**, and the temptation to call it from the shape is exactly the mistake
   col 79 punished twice.

   *Next probe:* the read side, which is the real blocker. `ParamKeeper_GetParam`
   has only **four** call sites — every other read is inlined with the constant id
   folded into the displacement, so there is no getter to grep. `Combat_ResolveDamage`
   does not touch `obj+0x1F0+4N` either (checked: `0x1fc/0x204/0x208/0x21c/0x220`
   — those offsets are too common to signal anyway), so combat reads stats through
   something else: find what it is handed. Two angles worth trying first — the
   stat packet the server builds for the character window (its field order, matched
   against the client's own authored labels), and params **13–16**, which the PC
   graph builds as a Str-derived pair (13,14) and an Int-derived pair (15,16) and
   which therefore look far more like attack min/max than 5/6 do.

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
