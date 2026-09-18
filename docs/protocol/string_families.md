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
	 9  "Failed to add item to player [JID: %d]"           identified, not read
	 7  "fail pay quest. because don`t have Catch Mob"     identified, not read

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
