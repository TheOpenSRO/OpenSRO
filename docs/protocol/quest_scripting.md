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