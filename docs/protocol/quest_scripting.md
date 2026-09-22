# Quest scripting

How the engine runs a quest.

This is the system behind the standing conclusion that **quest objectives are
code, not data**. That conclusion survives this pass but needs one qualification
it did not have: it is established for the **153 compiled quests**, and 543 of
the game's 696 quests have neither a compiled class nor an objective row. See
"The 543 are the open part of this system".

## Two hierarchies

	CQNO_<QUESTNAME>  : CBasicQuest : CQuestBase : IQuest
	COn<Event>        : CEVENTHandler

**There are 696 quests, and only 153 are compiled.** `questdata.txt` holds
**696** enabled rows, each a quest with an id, a codename, a required level, a
title and its text ids. `SR_GameServer.exe` names **153** `CQNO_*` classes —
`CQNO_CA_GORIA_2`, `CQNO_CH_HWAN_1_1`, `CQNO_WC_SOLDIER_SO_1` — of which **145**
match a `questdata` codename directly. So **roughly a fifth of quests are
scripted in C++ and the other four fifths are not.**

A scripted quest is a **compiled C++ class**, each with its own vftable. The name
is the quest's own id, so a quest can be matched to its code by name rather than
by hunting a log string.

Its objectives are **nested handler classes**, one per event it cares about, each
deriving from `CEVENTHandler`. `CQNO_CA_GORIA_7::COnUpdate` is a distinct class
from `CQNO_CH_HWAN_1_1::COnUpdate`: same event, different compiled body.

**The handler's entry point is vtable slot 1.** The three already-named ones —
`QuestHandler_SetupQuest` (`0x008699a0`), `QuestHandler_OnUpdate` (`0x00869740`),
`QuestHandler_OnDead` (`0x00869640`) — are all slot 1 of their respective
`COn*` base, and each logs `"HandlerSetupQuest_%s(%d)"` /
`"HandlerOnUpdate_%s()"` / `"HandlerOnDead_%s()"`, resolving the same name id
`0x15a` through a virtual to fill the `%s`.

## The event vocabulary — 15 events, not 3

The standing note recorded a "SetupQuest / OnUpdate / OnDead triple". That is a
subset. Counting the nested handler classes across all quests gives the real
lifecycle:

| event | quests using it |
|---|---|
| `OnSetupQuest` | 27 |
| `OnEnterWorld` | 21 |
| `OnUpdate` | 21 |
| `OnLeaveWorld` | 21 |
| `OnInstanceInvitaionAnswered` | 20 |
| `OnEventZoneEntered` | 17 |
| `OnAfterActivated` | 10 |
| `OnPartyStatusChanged` | 8 |
| `OnAbortQuest` | 6 |
| `OnPreUseItem` | 5 |
| `OnDead` | 4 |
| `OnTimer` | 3 |
| `OnTimer_Second` | 2 |
| `OnScriptStarted` | 1 |
| `OnBodyModeChanged` | 1 |

`OnBodyModeChanged` is the same body-mode enum berserk rides on
(`IGObj::SetBodyMode`, vtable slot 198) — so a quest can react to a player going
berserk.

## The quest vtable: what a compiled quest actually overrides

`CQNO_<NAME> : CBasicQuest : CQuestBase : IQuest` gives a quest a vtable, and
counting which slots the 153 compiled quests override says what a quest *is*:

| slot | quests overriding | median size | what it is |
|---|---|---|---|
| 20 | 153 | 31 | the **scalar deleting destructor** — not an interface method; every class has one |
| 55 | 151 | 723 | **setup** — see below |
| 22 | 85 | 1230 | the **dialogue handler** |
| 103 | 41 | 304 | |
| 1 | 35 | 769 | |
| 29, 24, 32, 104, 39, 38, 23, 70, 41 … | 19 down to 2 | | a long tail |

`CQuestBase` itself carries slots 5, 6, 9, 10, 11 and 12 as **4-byte stubs** —
default implementations returning a constant. So a quest that overrides nothing
is not broken; it inherits a working default for everything.

### Slot 55 is setup, and its data is compiled in

`CQNO_CH_POTION_4::vslot_055` (`0x008904a0`) carries these literals:

	"QNO_CH_POTION_2"    <- the prerequisite quest
	"NPC_CH_POTION"      <- the NPC it attaches to
	"NPC_CH_FERRY"  "NPC_CH_FERRY2"

**So even the quest-to-NPC binding is code.** This is the same conclusion as
"objectives are code" reaching one level further out: a quest does not have a row
saying *offered by NPC X, requires quest Y*, it has a compiled method naming them
as string literals.

### Slot 22 is the dialogue

`CQNO_CH_POTION_5::vslot_022` (`0x00890c60`) references
`SN_TALK_QNO_CH_POTION_5_01`, `…_07`, `…_09`, `…_10` — the quest's own dialogue
lines, resolved through the text table. It takes the speaking object as an
argument and calls vtable slots `0x158` and `0x184` on it.

## Kill objectives compile a hook per target

Beyond the generic `OnDead`, quests declare **named per-target kill hooks** —
12 distinct kinds:

	OnDeadForGeneral1  OnDeadForGeneral2  OnDeadForGeneral3  OnDeadForGeneral4
	OnDeadForSoldier_1_1  OnDeadForSoldier_2_1  OnDeadForSoldier_2_2
	OnDeadForGhost  OnDeadForBlackSnake  OnDeadForWhiteSnake
	OnDeadForFlameMaster  OnDeadForEventMonster

This is the clearest evidence for "objectives are code": a quest needing *kill
these four named generals* does not fill in a table row, it compiles four
classes. `CQNO_CH_HWAN_1_1` alone carries `OnDeadForSoldier_1_1`,
`OnDeadForSoldier_2_1` and `OnDeadForSoldier_2_2`.

## Not every quest is scripted

Of the 153 *compiled* quest classes, only **29 carry nested handlers** — between
1 and 12 events each:

	1 event: 2 quests      7 events:  8
	2 events: 1            8 events:  2
	3 events: 5            9 events:  3
	6 events: 3           10-12 events: 5

The other **124 compiled classes declare no handler classes at all**, and a
further **543 quests have no compiled class whatsoever**.

## The 543 are the open part of this system

This is the gap, and it is why this system is PARTIAL rather than specified.
Neither data file carries objectives:

| file | rows | what it holds |
|---|---|---|
| `questdata.txt` | 696 | id, codename, required level, title, and `SN_*` text ids. **No mob, item or count columns** — a scan for `MOB_`/`ITEM_`/`NPC_` codenames across all 12 columns returns nothing |
| `questcontentsdata.txt` | 989 | the quest's **description text**: a codename, a title, and up to eight `SN_CON_*` string-id slots (cols 5-12), plus chain links to other quests. Again no mob, item or count |

So for 543 quests there is no compiled class **and** no objective row. Either the
generic `CBasicQuest` machinery serves them from something not yet found — the
`_REFQUEST` DB table is the obvious candidate, and this project has only ever
inferred its contents from its file counterpart — or they are simple enough
(talk to an NPC, receive a reward) that the lifecycle needs no objective at all.

**Settled for the data half (2026-09-17).** `DB_Load_RefQuest` (`0x008341b0`)
was read, and more usefully every loader like it: the server loads **124**
reference tables (this said 85 until round 242 found the 39 mixed-case and
`TAB_` names the census had missed) and the complete list is in
`docs/protocol/refdata_tables.md`. The quest-related entries are six —
`_REFQUEST`, `_REFCHARDEFAULT_QUEST`, `_REFSIEGEQUEST`, `_REFSIEGEQUESTREWARD`,
and the two the first census missed, `_RefQuestReward` and
`_RefQuestRewardItems` (loaders `0x83a640`/`0x83a8b0`, read at
`REFDATA_MGR+0xb40` by `FUN_009287c0`: `Can not find QuestRewardData :
QuestID [%d]`) — and **none is a table of objectives**: the two new ones are the
reward side, which strengthens rather than weakens the conclusion below.

So there is no objective data anywhere: not in the client's two quest files, not
in the server's entire reference surface. *"Objectives are code"* is now settled
by enumeration rather than by a failed search, and it holds for all 696 quests,
not just the scripted fifth.

**What remains open is narrower**: how the generic `CBasicQuest` machinery drives
the 543 that have no compiled class. They need no objective table — that much is
proven — so either they are simple enough not to need one, or the machinery
derives their behaviour from `questdata`'s own fields. Reading `CBasicQuest` is
the next probe, and it is a code question now rather than a data one.

## Where the rest of a quest lives

| piece | where |
|---|---|
| identity and metadata | `_REFQUEST`, loaded by `DB_Load_RefQuest` (`0x008341b0`) — the server's counterpart to `questdata.txt` |
| per-character progress | `_CHARQUEST`, with `QuestData1` / `QuestData2` |
| objectives, scripted quests | the compiled handler bodies above |
| objectives, the other 543 | no table exists anywhere; the generic `CBasicQuest` path is unread |
| helpers the handlers call | `CBasicQuest__SetupMissionNPC` and the rest of the `CBasicQuest` surface |

## What this means for srrevamp

Any quest objectives srrevamp ships are **own design**, for all 696 quests —
there is no table to import, and that is now proven by enumerating the server's
85 reference tables rather than by failing to find one.

A quest engine that matched this one would expose these 15 events as hooks plus
a per-target kill hook, and let a quest bind handlers to the ones it needs. That
is a concrete interface, derived from the engine, rather than a guess at what a
quest system should look like — and it is considerably richer than
"setup / update / on-kill", which is what this project would have built from the
previous note.

**Not recovered:** the bodies. Specifying the *lifecycle* does not specify what
any individual quest does; that is 29 compiled classes' worth of reading, and
nothing in srrevamp needs it until it ships those quests. The lifecycle is the
part that generalises.


## The server embeds Lua 5.1, and there is a quest SCRIPT subsystem (round 427)

Neither fact appears anywhere else in this repository; `grep -rl Lua docs/`
returned nothing before this round.

**Lua 5.1 is statically linked into `SR_GameServer.exe`.** The evidence is the
runtime's own strings — `Lua 5.1`, `$URL: www.lua.org $`, `LUA_PATH`,
`LUA_CPATH`, the package search path
`.\?.lua;!\lua\?.lua;!\lua\?\init.lua;!\?.lua;!\?\init.lua`, `lua_debug> `,
`attempt to yield across metamethod/C-call boundary`, and the metamethod name
table (`_index`, `_newindex`, `_gc`, `_mode`, `_eq`, `_add`, `_sub`, …) at
`0x00add198`. About 173 strings in all. The C API symbol names are stripped, as
expected of a static link; the functions that reference those strings all sit in
the **`0x9cxxxx`** region.

**And there is a script subsystem sitting among the quest classes:**

| what | where |
|---|---|
| `Quest Script Data Reset Start` / `... End` | `CGameServer::FUN_00580ad0` |
| `GObjPC::CNormalEvent__InsertScriptData`, logging `%s - Failed Run Script. Error:%s` | `0x92dfd0`, 883 bytes |
| the script directory `./Script/VIETNAM/` | built in four functions: `0x869b60`, `0x927a60`, `0x930820`, and `0x92dfd0`'s caller |
| `IGObj::EnterScriptMode` | an `## Illegal ##` vtable stub, so it is a real interface method |
| RTTI class `OnScriptStarted` **inside a quest class** | `.?AVOnScriptStarted@QNO_TQ_BAEKRYEOUNG_13@@` |

Every one of those addresses is in the **`0x86`–`0x93` quest-class region**,
where `CQNO_*`, `CQTUTORIAL2_*` and `CQEV_*` live.

### The hypothesis, and why it is NOT promoted

`SYSTEMS.md` records this system as **BLOCKED** on "how the 543 classless quests
attach". An embedded Lua plus a script subsystem co-located with the quest
classes is an obvious candidate answer: the 543 would be **script-driven rather
than compiled into C++ classes**.

**It is not proven, and this round could not close it.** The gap is precise:
`CNormalEvent__InsertScriptData`'s callees are at `0x9769d0` and `0x976b70`,
while the functions that reference the Lua runtime's strings are at `0x9cxxxx`.
**No call path from the script runner to the Lua runtime has been traced**, so
"quests are Lua" remains circumstantial — a script subsystem and a Lua runtime
in the same binary are two facts, not one.

**Next probe:** read `0x9769d0` and `0x976b70` and see whether they reach
`0x9cxxxx`. If they do, the chain is quest class → `InsertScriptData` → Lua, and
the BLOCKED item has its answer. If they do not, the script subsystem is
something else and the Lua is used elsewhere — which would itself be worth
knowing.

## The script subsystem IS Lua, and the quest hierarchy read (round 428)

Round 427 refused to join "there is a script subsystem" to "there is a Lua
runtime" without a call path. **The path is now traced, and it has a numeric
control that could not be a coincidence.**

	CNormalEvent::InsertScriptData  (0x92dfd0)
	  -> Lua::luaL_checkstring      (0x9769d0)   tests the type tag != 4
	     -> Lua::luaL_typerror      (0x9c1600)   "%s expected, got %s"

`luaL_typerror` is Lua 5.1's `typeerror()` matched against the upstream source,
not by shape: it formats `"%s expected, got %s"` with the expected type name and
`(&PTR_DAT_00add168)[tag]` — `luaT_typenames` indexed by the value's tag, with
`"no value"` as the fallback — then calls `luaL_argerror`. **The control is the
number 4**: `luaL_checkstring` tests the tag against 4 and names the expected
type `"string"`, and independently index 4 of the table at `0xadd168` *is* the
string `"string"` at `0xadd178`. `LUA_TSTRING == 4` in Lua 5.1. Two facts
arriving at the same constant from different directions.

So the quest script subsystem runs on the embedded Lua. `CNormalEvent` is itself
a **`CQuestBase` subclass**, which means script-driven quests are a branch of the
quest hierarchy rather than a mechanism beside it.

### The quest hierarchy, from the ClassHierarchyDescriptor chains

	IQuest
	 └─ CQuestBase                 20 slots
	     ├─ CBasicQuest           103 slots   185 direct subclasses
	     │    └─ CQuestAType
	     ├─ CNormalEvent                        8 subclasses   <- the Lua runner
	     ├─ CSummonScrollEvent                  2 subclasses
	     └─ (9 further direct subclasses)

**205 classes derive from a quest base**, every one rooted at `IQuest`. And
**slot 13 of `CQuestAType` is `0x00927a60`**, one of the four functions that
builds the `./Script/VIETNAM/` path — a vtable link from the quest classes
straight to the script directory.

### The BLOCKED item's premise is wrong

`SYSTEMS.md` records this system as blocked on: *"how the 543 classless quests
attach. CQuestBase's slot-55 default is not reachable via the dump's slot tags;
needs the vtable read directly in Ghidra."*

**`CQuestBase`'s vtable has 20 slots. There is no slot 55.** The 103-slot
vtables belong to `CBasicQuest` and its descendants, so whatever slot 55 was
observed on, it was not `CQuestBase`. Round 418's vtable index is exactly the
"vtable read" that note asked for, and what it shows is that the question was
mis-posed rather than hard.

### What is still open

Whether the 543 non-compiled quests attach **through `CNormalEvent`**.
`CNormalEvent` has only 8 subclasses, so it is plainly not one class per quest —
which is consistent with it being the generic script host, and equally
consistent with it being something narrower. **A quest-id → script mapping would
settle it, and none has been found.** That is the next probe, and it is a data
question now rather than a vtable one.

## The 542 measured, and the question re-framed again (round 429)

Round 428 said the remaining question was a data one. It is, and the data answers
the shape of it even where it does not answer the mechanism.

**The split is measured exactly.** `questdata.txt` has **696 rows**, column 2 the
quest code name, all distinct. Joined against the 205 RTTI classes whose chain
contains `CQuestBase`/`IQuest`:

| | count |
|---|---:|
| quests **with** a compiled class | **154** |
| quests **without** | **542** |

`SYSTEMS.md` said 153 and 543; the measurement lands within one, which is the
agreement a count of this kind should have.

**And the classless set is not 542 bespoke quests.** Two families dominate it and
have no compiled classes at all:

| prefix | without a class | with |
|---|---:|---:|
| `SD` | **237** | 0 |
| `FW` | **98** | 0 |
| `KT` | 51 | 6 |
| `TQ` | 36 | 23 |

`QNO_SD_GU_030`, `_031`, `_032` … are a **numbered series at a fixed level**
(105 for 55 of them); `QNO_FW_RB1_012`, `_013`, `_014` … likewise. That is
templated, repeatable content — 335 of the 542, **62 %**, in two runs of
generated quests. `FW` is fortress war (round 423's `MOB_FW_*`).

**So the framing "543 quests each need an attachment mechanism" is wrong.** A
compiled class is the **exception**, not the rule: 154 quests have bespoke logic,
and the rest are described by `questdata.txt` plus the objective table
`questcontentsdata.txt`. What has *not* been found is the generic handler that
interprets those rows, and that is the honest remaining gap — but it is a
different and much smaller question than the one the row was blocked on.

### Three tiers, which had been conflated

| tier | count | what |
|---|---:|---|
| data rows | 696 | every quest, `questdata.txt` + `questcontentsdata.txt` |
| compiled classes | 154 | quests needing bespoke logic |
| Lua scripts | **10** | `script\q_script\qno_*.txt` in Media.pk2 |

**The ten scripts are not the classless mechanism.** They pair with quests that
*do* have classes — `qno_tq_baekryoung_13.txt` against
`QNO_TQ_BAEKRYEOUNG_13`, the class carrying the `OnScriptStarted` RTTI found in
round 427. They are cutscene/dialogue content for a handful of story quests.
Round 427's hypothesis that the classless quests are Lua is **refuted for the
client-side scripts**; the server's own `./Script/VIETNAM/` directory ships with
the server and is in none of the archives this project has, so nothing can be
said about it either way.

## Hunting the generic handler: four eliminations and a static pool (round 430)

Round 429 left one gap — **the generic handler that interprets `questdata` rows
for the 542 quests with no class.** This round did not find it. What it did is
narrow the search and rule things out, which is worth recording so the next pass
does not re-walk them.

**The quest infrastructure, 26 classes** (excluding the per-quest ones):
`Quest::CQuestManager` is a **singleton**; `CGObjPC_QuestManager` is the per-PC
manager, which is the object at `pc+0x1d98` that round 428 identified as save
scope bit `0x10`; alongside them `sQuestManagerData`, `sQuestContents`,
`CRefQuest`, `CRefQuestReward`, `CRefQuestRewardItems`, `AQ_QuestDataManager`
(the DB side) and `CInstanceQuest`.

### Eliminated

- **`CRefDefaultQuest` is not it.** The name is inviting, but
  `refdata_tables.md` already maps it to **`_REFCHARDEFAULT_QUEST`** — the
  quests a character *starts with*, not a generic handler.
- **There is no registrar mapping quest codes to classes.** A sweep for
  functions carrying many `"QNO_"` literals returns only individual quest
  handlers referencing other quests; the most is 13, in
  `QNO_TQ_BAEKRYOUNG_17::OnEnterWorld::Handle`.
- **`CQEV_ALL_BASIC_*` is not it either.** There are **13** of them, each
  `CBasicQuest : CQuestBase : IQuest`. Thirteen generic slots is not a mechanism
  for 542 quests.
- **Neither manager's methods are named** — `Quest::CQuestManager` and
  `CGObjPC_QuestManager` each have only a `ScalarDeletingDestructor` named, so
  the work is in the `FUN_` functions around `0x56e000`–`0x571000` (59 of them)
  and near `0x57fd10`.

### Found

`CBasicQuest::CBasicQuest` is **`0x91e200`**, installing the 103-slot vtable at
`0x00b3ec04`. Its callers are the init functions of the thirteen
`CQEV_ALL_BASIC_*` objects, and each passes a **static global at a fixed `0x580`
stride** — `DAT_00d25780`, `d25d00`, `d26280`, `d26800`, … So a `CBasicQuest`
instance is **0x580 bytes**, and those thirteen are a **statically allocated
pool**, not heap-constructed per quest.

And **192 of the 205 quest classes carry a numbered suffix**, which is the same
templating round 429 measured on the data side, now visible on the code side.

### Next probe

The per-PC manager at `pc+0x1d98`. Its 59 unnamed functions are where a quest is
attached to a character, and one of them must decide between "instantiate the
class for this code" and whatever serves a code with no class.