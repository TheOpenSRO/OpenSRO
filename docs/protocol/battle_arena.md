# The battle arena

The last row `docs/SYSTEMS.md` had open. What is recovered here is the system's
**shape** — its modes, its scoring kinds, its world and its currency — because
that is what the class family gives up without reading the match logic.

Implemented in `server/internal/arena`.

## Why this one needed a different lever

The error-code method that carried the fortress war, guild, party, pets,
academy and jobs **does not work here**: only five codes match `ARENA`, and two
of them are raised by the *party* system rather than this one. A system with a
thin refusal vocabulary is not a system with little structure — it is one whose
structure lives somewhere else.

For this one it lives in the vtable index. Sixteen classes, and their layout in
`.rdata` is itself evidence.

## Four modes, each a pair

| mode | match class | entry class |
|---|---|---|
| Random | `CGame_BattleArenaRandom` `0x00b075e8` | `CGame_BattleArenaRandomParticipation` `0x00b075b8` |
| Party | `CGame_BattleArenaParty` `0x00b07648` | `CGame_BattleArenaPartyParticipation` `0x00b07618` |
| Guild | `CGame_BattleArenaGuild` `0x00b076a8` | `CGame_BattleArenaGuildParticipation` `0x00b07678` |
| Job | `CGame_BattleArenaJob` `0x00b07708` | `CGame_BattleArenaJobParticipation` `0x00b076d8` |

**The pairing is structural, not read off the names.** Every pair sits `0x30`
apart in `.rdata` with the entry class first, all eight carry the same 11-slot
vtable, and the four entry classes override exactly the same slots (5, 7, 8, 9,
10) against their match counterparts. Four identical pairs laid out
consecutively is a table, not a coincidence.

`CGame_BattleArenaSchedule` and `CGameSJ_BattleArenaScheduleParticipation` make
a fifth pair of the same shape, for the schedule rather than a match.

The base of all of them declares slots 2 and 3 as `__purecall`.

## Three ways to win

`CBattleArenaInfo` (`0x00b05898`, ten slots) with three derived classes, laid
out `0x2c` apart:

| class | scoring |
|---|---|
| `CBattleArenaInfoOccupy` | holding ground |
| `CBattleArenaInfoPoint` | accumulated points |
| `CBattleArenaInfoFlag` | a flag objective |

All three override slots 0, 1 and 4; only **Flag** overrides slot 5, and the
function there carries its name (`CBattleArenaInfoFlag::FUN_00662c40`). So the
flag mode has behaviour the other two do not, which is the one asymmetry in the
family.

## Its own world

`CGameWorld_BattleArena` (`0x00aff6f4`, 55 slots) plus
`CBattleArenaContextController` (14 slots). **A match runs in a separate game
world**, the same way a fortress siege does — `CGameWorld_Siege` has 62 slots and
`CSiegeWorldContextController` 14, the same pairing.

## Arena coins are inventory items

`GObjPC::CheckCurrencyRequirement` (`0x00617360`, 1,515 bytes; named in round 348 from this very
sentence) checks currency requirements by bit, and
the arena's branch is:

	if ((flags & 0x400) != 0) {
	    if (!FindItems(inv, 10, 1))          return 0x184d;
	    total = sum of `+8` across the matching slots;
	    if (total < requirement[0x14])       return 0x184d;
	}

So **arena coins are ordinary inventory items of kind 10**, counted by summing a
per-slot quantity rather than read as a scalar on the character. `0x184d` is
`UIIT_MGS_ARENA_NOT_ENOUGH_COIN`.

The branch immediately before it does the same for **kind 9** under bit `0x200`,
refusing with `0x184a`. The two are adjacent bits and adjacent kinds, which is
how they were told apart, and `server/internal/arena` has a test that fails if
that adjacency stops holding — because it is the only thing separating them.

**The required amounts are not recovered**: `requirement[0x12]` and
`requirement[0x14]` are fields of a record this project has not mapped.

## A rule that lives in another system

`UIIT_MGS_ARENA_ERR_CANT_PARTY_WITH_OPPONENT_*` (`0x2c28`) is raised by
`CParty::CheckCanCreateForMatch`, not by anything in this family: **you cannot
form a party with someone you are matched against**. Like the job-suit/party
exclusion in `docs/protocol/jobs.md`, it is a cross-system rule that a
reimplementation building the two separately would miss.

## Not recovered

- **The match logic.** Every slot in the mode classes is unnamed, and nothing
  here says how a match starts, scores or ends.
- **The entry cost**, beyond it being paid in kind-10 items.
- **Team sizes, durations, or the schedule.** `CGame_BattleArenaSchedule` exists
  and has not been read.
- **What `CBattleArenaInfoOccupy` and `…Point` actually count.**

This row is PARTIAL on a narrower basis than the others: the structure is
grounded and essentially none of the behaviour is.
