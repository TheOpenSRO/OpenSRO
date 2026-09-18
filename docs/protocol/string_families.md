# Naming by shared string, and what the families actually contain

**Measured 2026-09-18.** With vtable-slot propagation closed
([vtable_slot_propagation.md](vtable_slot_propagation.md)), the remaining systematic lever is
the one that worked for `ReleaseAndClear`: **a string literal shared by many unnamed functions
is one virtual, or one idiom, implemented many times.** Reading a single member names the
family, and the string — not the slot index — is the invariant.

Clustering every unnamed function in the server by the strings it holds gives **68 strings
shared by five or more unnamed functions, covering 5,082 function slots**. That number is
badly misleading, and the breakdown is the useful part.

## Most of it is the C++ runtime, not the game

	526  invalid map/set<T> iterator
	443  invalid list<T> subscript
	427  list<T> too long
	364  deque<T> too long
	355  invalid deque <T> argument
	339  invalid vector<T> subscript
	…

These are STL container template instantiations. There are thousands of them and naming them
would bury the game logic rather than reveal it. **Fourteen strings account for about 4,400 of
the 5,082.**

## Two that look like the game and are not

	364  "Unknown DB Table"
	182  "DBTable Registering Failed: %s"

The registry notes say the `%s` is the class's own table name, so 182 functions each named for
its table looks like a large grounded win. It is not available: reading `CGameServer::FUN_0073c140`
shows a **generic get-or-create template**, and the only class vtable inside it is `CDBRecord`,
the base. The table identity is supplied by the caller, not held in the function, so nothing in
the body can name it.

## What is left is small and real

Excluding the runtime strings leaves **53 game-specific families**, and they are quest and NPC
logic — `CQTUTORIAL2_*`, `CQEV_ALL_BASIC_*`, `CQNO_*`, `CQSP_*`:

	23  "fail pay quest : %s[%d] -> %s"                 -> named PayQuestReward
	19  "SN_TALK_COMMON_OK" / 23 "SN_TALK_COMMON_END"      dialogue constants
	17  "NPC_CA_POTION" and the other NPC_*_POTION ids     quest-string constants
	 9  "Failed to add item to player [JID: %d]"        -> named GiveQuestItemToPlayer
	 7  "fail pay quest. because don`t have Catch Mob"  -> named PayQuestRewardCatchMob
	12  "fail pay quest. because don`t have QuestData"     11 of 12 are PayQuestReward already

`PayQuestReward` was read at `CQTUTORIAL2_CH_1::vslot_085` (`CBasicQuest : CQuestBase : IQuest`)
before naming. Its 23 members sit at slots **85, 103 and 104**, plus two functions Ghidra never
put in a class — the same spread that makes the string, not the slot, the thing to key on.
Applied 23, failed 0.

The `SN_TALK_*` and `NPC_*_POTION` families are **string constants a quest references**, not
messages a function prints about itself, so they identify a quest's subject rather than a
function's job. They are left unnamed.

## The rule this gives

A shared string names a family only when it describes **what the function did**. A string that
names a *thing the function mentions* — a table, an NPC, a dialogue id — identifies the
subject, not the operation, and will attach the same name to functions doing different jobs.
The 182 DB registrations and the 17 `NPC_CA_POTION` holders are both that second kind.


## The client, swept the same way

The same clustering over the client's 36,971 unnamed functions gives **81 strings shared by
five or more, covering 3,360 slots**, and it yields **nothing nameable**. The large families
are the same STL instantiations, and every game-specific one is a text id the function
*mentions*:

	28  UIIT_STT_CONFIRM_BOX        16  UIIT_STT_GOLD       14  UIIT_STT_UNIT
	16  PARAM_SECOND                15  PARAM_MINUTE        14  PARAM_HOUR

These are exactly the second kind from the rule above — a confirm-box id or a time-unit token
identifies what a function *talks about*, not what it does, and dozens of unrelated functions
ask for the same one. None is named.

That the rule predicted this before the sweep was run is the reason to keep it.

## Where this lever now stands

Server: one 123-member family (`ReleaseAndClear`) and four quest families (`PayQuestReward` 23,
`GiveQuestItemToPlayer` 9, `PayQuestRewardCatchMob` 7, plus 11 of the QuestData family already
covered). Client: nothing. **The lever is worked out** — what remains behind shared strings is
either the C++ runtime or subject ids, and a fresh name now needs a different kind of evidence.


## Unique strings, not shared ones

The clustering above only looked at strings held by five or more functions. The **unique**
strings are the richer half: **273 unnamed server functions hold a string that appears nowhere
else and reads like an operation** (it contains fail/error/cannot/success/already/…). They
concentrate in `CMainProcess` (51), `GObjPC` (38), `CGameServer` (21), `AQ_CharDataLoader` (16)
and `AQ_Siege` (15).

Two sub-patterns are worth separating.

**A function announcing its own name.** A log string opening `Identifier::` or `Identifier :`
is often the function saying what it is — `"CharDataLoadingCompleted:: Create Char Instance
failed!!"`. 38 unnamed functions have such a prefix, but **30 of them are a subsystem log tag,
not a name**: `BattleArena`, `ScheduleExecutor`, `ScheduleJob`, `ALCHEMY` and `Scheduleing` are
each shared by several functions. The test that separates them is the same uniqueness rule the
SQL pass used — **a prefix used by exactly one function is a name; a prefix used by several is
a tag.** That leaves 8, of which `AQ_Siege` and `NetEngine` are *class* names and
`StorageOwner` is a data label, so three are real self-names.

**The operation named in a later segment.** `"failed : SQLAllocHandle : %s"` and
`"error : SendFileTo : %s"` open with a generic word; the operation is the second segment.
Taking the first segment would have named two functions `failed` and `error`.

Twelve names were applied from this pass, including the three `AQ_*::vslot_008`
implementations: three different AsyncQuery classes implement that one slot and each logs its
own data-load failure there, which makes slot 8 the completion virtual — named
`OnQueryCompleted` in each.

The remaining ~260 candidates each need their string read; they are a real pool, not a lever,
because no mechanical rule turns an arbitrary failure message into a name.
