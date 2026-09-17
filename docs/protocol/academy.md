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

### Which role each class is — still not recovered

The shared refusal's name carries 41, which matches class 2. That says which
floor the client's message was written for, not which role holds it.

Two other functions, `FUN_005e0790` and `FUN_005e0a30`, test `class == 1` and
**skip** that member inside a loop over the camp's members — the shape of
"everyone except the master". Together with 61 sitting one above the founder
level of 60 (below), that is two suggestive readings pointing the same way, and
**it is still not a use-site that names a role**. No function tested raises a
refusal whose name says master or apprentice, and no store of the class byte was
found — it most likely arrives from `_TRAININGCAMPMEMBER.MemberClass` through the
column bind, which a scan for `mov BYTE PTR [reg+0x50],imm` cannot see.

`server/internal/academy` therefore names the constants by value and the classes
by number (`MemberClass1`, `MemberClass2`), and `MeetsMembershipLevel` reproduces
the check exactly.

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
