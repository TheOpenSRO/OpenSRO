# Quest scripting

How the engine runs a quest. This is the system behind the standing conclusion
that **quest objectives are code, not data** — there is no objectives table in
any file or database, and this document is what that looks like from the inside.

## Two hierarchies

	CQNO_<QUESTNAME>  : CBasicQuest : CQuestBase : IQuest
	COn<Event>        : CEVENTHandler

A quest is a **compiled C++ class**. `SR_GameServer.exe` names **153** of them —
`CQNO_CA_GORIA_2`, `CQNO_CH_HWAN_1_1`, `CQNO_WC_SOLDIER_SO_1` — each with its own
vftable. The name is the quest's own id, so a quest can be matched to its code by
name rather than by hunting a log string.

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

Of the 153 quest classes, only **29 carry nested handlers** — between 1 and 12
events each:

	1 event: 2 quests      7 events:  8
	2 events: 1            8 events:  2
	3 events: 5            9 events:  3
	6 events: 3           10-12 events: 5

The other **124 declare no handler classes at all**. Those are the ordinary
fetch-and-report quests the generic `CBasicQuest` machinery serves without
custom code; the 29 are the scripted ones.

## Where the rest of a quest lives

| piece | where |
|---|---|
| identity and metadata | `_REFQUEST`, loaded by `DB_Load_RefQuest` (`0x008341b0`) — the server's counterpart to `questdata.txt` |
| per-character progress | `_CHARQUEST`, with `QuestData1` / `QuestData2` |
| objectives | **nowhere** — they are the compiled handler bodies above |
| helpers the handlers call | `CBasicQuest__SetupMissionNPC` and the rest of the `CBasicQuest` surface |

## What this means for srrevamp

Any quest objectives srrevamp ships are **own design, and always would have
been** — there is no table to import. That conclusion is unchanged; what is new
is the shape a faithful implementation needs.

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
