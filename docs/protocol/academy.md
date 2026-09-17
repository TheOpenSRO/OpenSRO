# The academy (training camp)

**"Training camp" is the engine's name.** Every class, table and error code says
`TRAININGCAMP` or `TC_`; the client calls it the academy. Implemented in
`server/internal/academy`.

28 codes match, and 20 server functions return one.

## The error names carry their own numbers

This system is unusual in that several codes state the constant in the name —
`TC_ERROR_NOT_OPEN_7D`, `TC_ERROR_NOT_INVITE_24T`, `TC_ERROR_POSIBLE_41L`. That
makes them a **check on the reading** rather than a substitute for it: the
number in the name and the number in the comparison have to agree, and where
they do, both are confirmed.

## Founding a camp — `FUN_004e4680`

	if (state != ok)                       return 0x6808;
	if (!IsAlive())                        return 0x6807;
	if (GetLevel() < 0x3c)                 return 0x6809;  // TC_ERROR_OPEN_LEVEL
	if (gold < 100000)                     return 0x680a;  // TC_ERROR_OPEN_GOLD
	if (char[0x733] != 0)                  return 0x6812;  // already in a camp
	if (FUN_004114d0(2, 7) != NULL)        return 0x681c;  // TC_ERROR_NOT_OPEN_7D
	return 1;

| requirement | value |
|---|---|
| **founder level** | **60** (`< 0x3c` refuses) |
| **founding cost** | **100,000 gold** |
| **reopen cooldown** | **7 days** |

The cooldown is the clearest case of the name confirming the read: the literal
`7` is the second argument to `FUN_004114d0(2, 7)`, and the error the non-null
result raises is `NOT_OPEN_7D`. Two independent statements of the same number.

The gold test is the same 64-bit pattern the guild level-up cost uses —

	iVar1 = *(int *)(inv + 0x7c);
	if (iVar1 < 1 && (iVar1 < 0 || *(uint *)(inv + 0x78) < 100000))

— which is the **third** place in this project's recovery where a character's
gold is read as a 64-bit value at `+0x78` / `+0x7c`. Three unrelated subsystems
agreeing on that layout is what makes it settled.

`char[0x733]` is the character's camp membership pointer; it appears in eight
of the twenty functions as the "are you in a camp at all" test, refusing with
either `0x6812` (you are, and shouldn't be) or `0x680b`
`TC_ERROR_TRAININGCAMP_NOTHING` (you aren't, and should be).

## Membership levels — `FUN_00519770` (`CheckMembershipLevel`)

**CORRECTED 2026-09-17.** This section gave the refusal as code `0x6818` and the
two predicates as `a != 0` / `b() != 0`. **`0x6818` is not in the client's error
table.** The branch pushes `0x6822`, which is `UIIT_MSG_TC_ERROR_POSIBLE_41L` —
the name here was right and the number was wrong. The predicates are now read in
assembly:

	00519872  mov edx,[edi+0x34]        ; the MEMBER's record
	00519875  mov dl,[edx+0x53]          ; the member's LEVEL byte
	0051987a  call 0x5e36e0              ; [+0x34][+0x50] == 2 ?
	00519883  cmp dl,0x28 ; jbe refuse   ; class 2: level must be >= 41
	0051988a  call 0x5e36c0              ; [+0x34][+0x50] == 1 ?
	00519893  cmp dl,0x3c ; ja  pass     ; class 1: level must be >= 61
	00519898  push 0x6822                ; TC_ERROR_POSIBLE_41L

So a member record carries a **class byte at `+0x50`** and a **level byte at
`+0x53`**, and the floor depends on the class:

| class byte | minimum level |
|---:|---:|
| `2` | **41** |
| `1` | **61** |
| anything else | none |

The level compared is the **looked-up member's stored level**, not the caller's.
A `cmp eax,ecx ; jne` just before it refuses with `5` when that member is the
caller, i.e. the check is about *another* member.

### Which role each class is — RECOVERED 2026-09-17

**The engine's roles are student and guardian, not master and apprentice.** This
page used those words before any read supplied them; they came from outside
knowledge of the game. The refusal vocabulary names the real ones:
`TC_ERROR_STUDENT_COUNT_OVER` (`0x6828`) and
`TC_ERROR_SECOND_GUARDIAN_COUNT_OVER` (`0x6810`).

Each refusal reaches the class byte through a chain of calls with no inference
in it:

	STUDENT_COUNT_OVER         <- cap FUN_005e44d0 (count >= 5)
	                           <- count FUN_005e4460: members with class == 2
	SECOND_GUARDIAN_COUNT_OVER <- cap FUN_005e4450 (count >= 2)
	                           <- count FUN_005e43e0: members with class == 1

So **class 2 is a student** and **class 1 is a second guardian**, and the
membership check below reads: a student needs level ≥ 41, a second guardian
≥ 61.

| class byte | role | cap per camp | membership floor | invited at |
|---:|---|---:|---:|---|
| `2` | student | **5** | 41 | level ≤ 39 |
| `1` | second guardian | **2** | 61 | level 40–59 |

The caps are from assembly, `cmp eax,0x5 ; sbb ; add 1` and `cmp eax,0x2 ; sbb ;
add 1`; Ghidra shows them as `4 < count` and `1 < count`, which means the same
but hides the engine's constants.

### The invite routine assigns the role by level

The routine that sends opcode `0xb472` branches on the **invitee's** level
(`GetLevel`, vtable slot `0x124`):

	005192ce  cmp al,0x27 ; ja    ; <= 39 -> student cap, STUDENT_COUNT_OVER
	00519303  cmp al,0x3b ; ja    ; 40..59 -> second-guardian cap
	                              ; >= 60 -> a third branch, NOT read

What an invitee of 60 or more becomes is **not recovered**: that branch's refusal
was not read. The membership floors sit one past each band's top — 41 past 39,
61 past 59 — which suggests those checks concern outgrowing a band. That is
recorded as suggestive and not as recovered, for the reason directly below.

### A suggestive reading this page carried was wrong

Before this pass the section noted that two functions skip `class == 1` members
inside a loop over the camp, "the shape of 'everyone except the master'", and
that 61 sits one above the founder level of 60 — two readings pointing at class 1
being the master. **Class 1 is the second guardian.** Neither reading was
promoted, and that restraint is the only reason no code shipped the wrong role.
Two hints agreeing is how a curve feels from the inside.

## Windows named but not read

`TC_ERROR_NOT_INVITE_24T`, `TC_ERROR_NOT_ENTRY_24T` and `TC_ERROR_NOT_BAN_24T`
all carry **24** in their names, so three separate 24-hour windows exist around
inviting, entering and banning. **None of the three comparisons was read** — each
is produced by a helper returning a bare flag rather than by a visible literal,
the way the 7-day cooldown is.

So: the 24 is the *client's* word for these rules, and this project has not
confirmed it against the server. That is a weaker claim than the 7 and is stated
as one.

## Honour

`TC_LACK_HONOR_POINT` and `CInstanceTrainingCampHonorRank` say the camp has an
honour-point economy with ranks. `TC_ERROR_ENCHANT_HONOR_ITEM` and
`TC_ERROR_NOT_RONDO_HONOR_ITEM` say honour items exist and cannot be enchanted —
the first of those is `0x5425`, which `docs/protocol/alchemy.md` already reached
from the other side, as one of the fifteen codes the `CEnchant` family returns.
**The same code appears in both systems' vocabularies**, which is what a shared
item category should look like.

**The schema is now named**, which is not the same as knowing the rules:
`_TRAININGCAMPMEMBER.HonorPoint`, `_TRAININGCAMP.Rank`, `.GraduateCount`,
`.EvaluationPoint`, `.LatestEvaluationDate`, and `_TRAININGCAMPHONORRANK.Ranking`
(`docs/protocol/db_columns.md`). So honour is a per-member point total feeding a
per-camp rank, evaluated periodically — the shape of the economy, read off the
column names.

Nothing is recovered about how points are earned, what a rank grants, or what
`EvaluationPoint` is scored on.

## The surface

| | |
|---|---|
| classes | `CInstanceTrainingCamp`, `…Member`, `…HonorRank`, `…BuffStatus` — four, each a nine-slot vtable |
| tables | `_TRAININGCAMP`, `_TRAININGCAMPMEMBER`, `_TRAININGCAMPHONORRANK`, `_TRAININGCAMPBUFFSTATUS` |
| queries | `AQ_TrainingCampQuery`, and the `trs_sm_trainingcampjob` stored-procedure wrapper |

One class per table, and the names line up — which is worth stating because it
is the only place in this project's recovery where the class/table
correspondence is one-to-one and obvious.

## Not recovered

- Which membership branch is the master and which the apprentice.
- The three 24-hour windows, as server-side values.
- Honour points: how they are earned, what a rank grants, what
  `EvaluationPoint` is scored on. The columns are named; the rules are not.
- `CInstanceTrainingCampBuffStatus` — a camp confers a buff. Its columns are
  named (`RecipientCharID`, `BuffSlotIdx`, `DonorCharID`, `StartingTime`,
  `RemainBuffPoint`, `BuffType`), so it is a **donated, expiring, slotted** buff
  with a point budget; what the types are is unread.
- A complete column list for any of the four tables. The binary's schema pool is
  deduplicated, so it gives each table the names it **introduces**, not all it
  uses — see `docs/protocol/db_columns.md`.
