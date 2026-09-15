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

1. **Monster attack/defence — cols 75–78 grounded, 71–74 still open.**
   Cols 75/76/77/78 are `'era'`/`'bri'`/`'hra'`/`'cri'` (see Grounded). The four
   that remain are cols 71/72 → params 5/6 and 73/74 → params 7/8.

   **Ruled out 2026-09-15, so nobody re-walks them:**
   - **The tag vocabulary cannot name them.** Extracted in full from all five
     dispatchers: **52 distinct stat tags** (`hp`, `mp`, `str`, `int`, `luck`,
     `cri`, `hr`/`hra`, `er`/`era`, `bri`, `hprg`/`mprg`, `zb`, `ps`, `fz`, the
     `r***` resistances, `dur*`, `evbl`/`evcr`, `soli`, `ape`, `atha`, …).
     **None of them is an attack or defence tag.** So these four are not tagged
     stats at all — they are gear-derived, which is why no modifier path touches
     them. That closes the param-code lever for this question.
   - **Keeper-index reads are not greppable.** A param read compiles to
     `obj[0x7c+N]` → byte 0x204 for param 5, and that offset collides across many
     structs: the three hits for param 5 turned out to be an equipment-slot check
     (`if (obj[0x81] == 0 || obj[0x81]+0x10 != 1) obj[0x82]`), not a keeper read.
   - **`FUN_0053f4d0` is NOT the aggregate builder** (last tick's suspicion
     confirmed): it writes two parallel blocks from one source and uses `_rand()`
     on neighbouring fields — a different struct whose offsets collide.
   - **The client's authored labels don't reach it either.** The client carries
     639 `UIIT_STT_*` label ids; `UIIT_STT_PHY_DAMAGE`/`MAG_DAMAGE` belong to the
     42KB **item tooltip** builder (`00960b50`), which describes a weapon's own
     itemdata columns, not a character's derived params.

   **Narrowed, with struct identity now settled.** `Char_PublishCombatStats`
   (`00497830`) has exactly **two** callers, one of them `FUN_004e3760` in the
   GObjPC range, which runs `FUN_004919e0` (gather) → `FUN_00498020` (a 35-byte
   wrapper) → `FUN_00497830` (publish). So the six-field aggregate really is on
   the char object, at bytes `+0x198..+0x1ac` (= `obj[0x66..0x6b]`), and
   `FUN_00495b40` zero-resets exactly that block — which independently confirms
   the block's location and extent.

   *Next probe:* the accumulator between the reset and the publish. It does not
   write the six offsets literally (grep finds only the reset), so it almost
   certainly walks them as `base + i*4` in a loop over equipment slots — search
   for a loop indexing from `+0x198` rather than for fixed offsets.

2. **Combat damage model** (base + bonus − defence, no crit/dodge) — ours.
   *Next probe:* `FUN_0058e5f0` is the real damage resolution; `FUN_0040f5f0`
   applies a level-gap roll clamped to [10%, 100%].
3. **Berserk numbers** (fill 8/hit, 20 s, +50 %) — ours. The mechanic and the
   five orbs are real. *Next probe:* the `'zb'` param tag (0x7a62) in the stat
   vocabulary.
4. **Monster spawn positions** — ours by necessity (`npcpos.txt` has no
   monsters). Likely genuinely absent; prove it and it stops counting as open.
5. **Quest objectives** — proven not to exist as data; any objectives shipped
   must be own design. Closed as a *recovery*, not a gap.
6. **Loot tables** — **CLOSED as a proven absence (2026-09-15).** The mapping
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
7. **Inventory size (50)**, **unarmed damage (5)** — ours; low value, may be
   genuinely absent.

## Naming coverage, and the denominator

Measured by `SymbolReport.java` (three states: **NAMED** — a real name, from
FID, an assert spelling out `Class::Method`, or applied by hand with evidence;
**ATTRIBUTED** — still `FUN_xxxxxxxx`, but in a namespace derived from a fact the
binary states about itself; **UNKNOWN**) and by `CodeCensus.java`, which
separates game logic from library code.

| | game-logic fns | % of binary | named | attributed | identified | of game logic |
|---|---|---|---|---|---|---|
| `SR_GameServer.exe` | 29,554 | 95.6% | 633 | 669 | **1,302** | **4.4%** |
| `sro_client.exe` | 36,457 | 91.5% | 681 | 3,016 | **3,697** | **10.1%** |
| **combined** | **66,011** | **93.3%** | 1,314 | 3,685 | **4,999** | **7.6%** |

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
- **Log strings naming a bare `Method()`** — 481 server functions reference
  exactly one, **77** still unnamed. A small remaining seam.
- **RTTI class recovery** — impossible, not merely hard. 1,871 type descriptors
  survive and **zero** are referenced, so the COL/vftable chain was stripped.

**The population nothing reaches:** 18,522 game-logic functions have no direct
caller. They are virtuals, and every call-graph lever steps past them.
`VtableAttribute.java` is the answer to that and now annotates 5,225 of them
with their table and slot — the fact this project has re-derived by hand four
times (slots 92 exp-gain, 93 SP-adder, 73 GetLevel, 421 GiveExp). Its
*attribution* yield is near zero today because too few vtable slots are
pre-attributed to vote with; it compounds as other levers seed namespaces, and
should be re-run after each of them.

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
