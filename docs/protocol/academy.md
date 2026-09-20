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
	if (FUN_004114d0(2, 7) != NULL)        return 0x681c;  // TC_ERROR_NOT_OPEN_7D, see the correction below
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
| — | *(not invitable)* | — | — | level ≥ 60: refused, result `3` |

The caps are from assembly, `cmp eax,0x5 ; sbb ; add 1` and `cmp eax,0x2 ; sbb ;
add 1`; Ghidra shows them as `4 < count` and `1 < count`, which means the same
but hides the engine's constants.

### The invite routine assigns the role by level, and refuses 60+

The routine that sends opcode `0xb472` branches on the **invitee's** level
(`GetLevel`, vtable slot `0x124`):

	005192ce  cmp al,0x27 ; ja                     ; <= 39 -> student
	00519303  cmp al,0x3b ; ja 0x51937f            ; 40..59 -> second guardian
	0051937f  push 0x3 ; call send(0xb472) ; ret   ; >= 60 -> REFUSED

**Corrected the same day.** This section first called the `>= 60` path "a third
branch, NOT read". It is not a role: `00519305 ja 0x51937f` is the only way in,
and the block sends result `3` and returns. **There are exactly two invitable
roles.**

Result `3` is generic rather than level-specific: the same routine sends it when
the target fails vtable slot `0x1c` (`IsPC`) — i.e. is not a player. It is a small
integer, not a `TC_ERROR_` code, so the client's dispatcher has no name for it.

**The founder floor and the invite ceiling meet at one boundary**, and both
halves are read: founding needs level ≥ 60 (`GetLevel() < 0x3c` refuses) and
invites stop at 59. A character is either old enough to found a camp or young
enough to be invited into one — never both, never neither.
`TestFounderFloorMeetsInviteCeiling` fails if either constant drifts. What role
the founder holds, and whether "second" guardian means the founder is the first,
is **not** read.

### A suggestive reading this page carried was wrong

Before this pass the section noted that two functions skip `class == 1` members
inside a loop over the camp, "the shape of 'everyone except the master'", and
that 61 sits one above the founder level of 60 — two readings pointing at class 1
being the master. **Class 1 is the second guardian.** Neither reading was
promoted, and that restraint is the only reason no code shipped the wrong role.
Two hints agreeing is how a curve feels from the inside.

## The academy handlers, named (2026-09-17)

The academy's message handlers turned out to be mostly functions Ghidra had never
created (see `docs/protocol/missing_functions.tsv`). Once created, they read as a
**contiguous response-opcode series**, one handler per opcode:

| handler | answers on | refusal | independent second evidence |
|---|---|---|---|
| `TrainingCamp_HandleInvite` `0x00519230` | `0xb472` | student / second-guardian caps | read in full |
| `TrainingCamp_HandleBan` `0x005193a0` | `0xb473` | `TC_ERROR_NOT_BAN_24T` | looks up a **target** member (`FUN_005e42c0`) and checks it is not the caller (`FUN_005e3700`) |
| `TrainingCamp_HandleLeave` `0x00519510` | `0xb473`, `0xb474` | `TC_ERROR_NOT_OUT_24T` | acts on **itself**: never calls the target lookup |
| `TrainingCamp_HandleGraduation` `0x00519600` | `0xb475` | `TC_ERROR_GRADUATION_LEVER` | calls both `TrainingCampMember_IsStudent` and `_IsSecondGuardian` |

**Ban and leave are two entry points to one removal.** Both end in
`FUN_005deeb0` — now `TrainingCamp_RemoveMember` — and those two handlers are its
**only** callers, one passing a target and one passing the caller. That is also
the likeliest reading of both sending `0xb473`: a shared "member removed" notice,
with `0xb474` as leave's own reply. The notice reading is inference and is
labelled as such; the shared removal is read.

**`0x00519120` was deliberately not named here — it is now `TrainingCamp_HandleDisband`, on
the evidence in "Disband, named on both binaries" below.** It raises
`TC_ERROR_NOT_DISORGANIZATION_7D` and calls `FUN_004e4780`, the neighbour of the
founding validator `FUN_004e4680`, so disband is the obvious reading. But it
answers on **two** opcodes (`0xb470`, `0xb471`), and that validator was not read,
which leaves one piece of evidence where the named four have two. With `0xb470`
and `0xb471` both unassigned, the gap is also where a *create* handler would sit
in the series.

This fills in half of the "Windows named but not read" section below: the 24-hour
`BAN` and `OUT` windows are now attributed to the handlers that enforce them. Their
**values** are still not read.

## Every academy result goes through one dispatcher (2026-09-17)

The message map showed every academy response opcode had a second server sender in
`0x005e10b0`-`0x005e1360`. They are not `AQ_*` vtable callbacks: none is in any
vtable slot, all are attributed to `trs_wait_response`, and all are called from one
function.

`TrainingCamp_DispatchJobResult` (`0x005e0fa0`) handles the reply to an academy DB
job (`trs_sm_trainingcampjob`). It switches on message `0xbc80` by a sub-type byte
at `+0x28`, and **its ten cases cover exactly the academy response family**:

| sub-type | result sender | sends | operation |
|---:|---|---|---|
| 0 | `TrainingCamp_SendOpenResult` | `0xb470` | **open** (founding) |
| 1 | `TrainingCamp_SendDisbandResult` | `0xb471` | **disband** (see below) |
| 2 | `TrainingCamp_SendInviteResult` | `0xb472` | invite |
| 3 | `TrainingCamp_SendRemoveMemberResult` | `0xb473`, `0xb474` | ban / leave |
| 4 | `0x005e10e0` | `0xb475`, `0xb476` | graduation, and `CheckMembershipLevel`'s opcode |
| 7 | `0x005e12a0` | `0xb477` | not read |
| 0x10–0x13 | `0x005e12d0`…`0x005e1360` | `0xb47a`–`0xb47d` | not read |

So an academy operation is a request handler that starts a DB job, then this
dispatcher, then a per-operation sender. **The result side mirrors the request
side**: ban and leave share `TrainingCamp_RemoveMember` going in, and share one
result sender coming out.

Named only where the operation is already established on the request side. Sub-type
4 is left unnamed because it also carries `0xb476`, whose operation is not named.
Sub-types 0 and 1 map to `0xb470`/`0xb471`, where create and disband are expected
but not resolved. **Both resolved the same day**: 0 is open, and 1 is disband (the
disband section below).

## Open is named from the client's own string (2026-09-17)

The client handler registered for `0xb470` (`TrainingCamp_OnOpenResult`,
`0x00899630`, one of the 102 handlers created from the registration table) displays
`L"UIIT_MSG_TC_OPEN_SUCCESS"`. **Open** is the engine's word for founding a camp:
the founding validator's refusals are `TC_ERROR_OPEN_LEVEL`, `OPEN_GOLD` and
`NOT_OPEN_7D`. So the whole open chain is named, each function on two facts:

	0x00518fd0  TrainingCamp_HandleOpen      calls founding validator FUN_004e4680; replies 0xb470
	0x005e1140  TrainingCamp_SendOpenResult  dispatcher case 0; sends 0xb470
	0x00899630  TrainingCamp_OnOpenResult    registered for 0xb470; shows TC_OPEN_SUCCESS

## Disband, named on both binaries (2026-09-17)

The last section closed on "the probe that would settle it is `FUN_004e4780`'s own
checks". Those checks were read, and a second reading came from the client.
Together they name the chain:

	0x00519120  TrainingCamp_HandleDisband               request handler
	0x004e4780  TrainingCamp_CheckCanDisband             its validator (its only caller)
	0x005dd350  TrainingCamp_SecondsUntilDisbandAllowed  the window (validator is its only caller)
	0x005df140  TrainingCamp_RequestDisbandJob           queues job type 1 (handler is its only caller)
	0x005e1110  TrainingCamp_SendDisbandResult           dispatcher case 1; sends 0xb471
	0x00899730  TrainingCamp_OnDisbandResult             client, registered for 0xb471

### The validator, in order

	char[0xc]+4 == 1                         -> 0x6808
	!IsAlive()                               -> 0x6807
	char[0x733] == 0     (no camp)           -> 3        a bare integer, as InviteRefused is
	!TrainingCamp_IsMemberClass0             -> 0x6816   TC_ERROR_ORDER_WORK
	SecondsUntilDisbandAllowed() != 0        -> 0x681d   TC_ERROR_NOT_DISORGANIZATION_7D
	                                            and *out = those seconds

`0x681d` never appears as a literal in the validator: it is computed as
`(-(remaining != 0) & 0x681c) + 1`. A grep for `0x681d` finds only the handler that
compares against it. That is why "which function produces the disband refusal" had
no answer from a literal search.

**Only class 0 may disband.** `TrainingCamp_IsMemberClass0` (`0x005e43b0`) looks the
caller up in the camp's member map and tests `TrainingCampMember_IsClass0`
(`0x005e36a0`): `cmp byte [member+0x34 → +0x50], 0`. That is byte for byte the
sibling of `_IsSecondGuardian` (`== 1`) and `_IsStudent` (`== 2`). A missing member
fails the gate. The gate has 14 callers (ban, leave, graduation, the membership
check, invite accept, …), so it is general, not disband-specific. **What role class
0 is, is not read.** "The founder" is the obvious guess, and it is not written down
as a fact.

### The window is 604,800 seconds, and the decompiler dropped it

	005dd36a  mov  ecx,0x93a80     ; 604800
	005dd373  call 0x9753f0        ; span = ecx
	005dd3a7  call 0x9755e0        ; stamp from a TIMESTAMP_STRUCT on the camp record (+0x1c)
	005dd3b2  call 0x975540        ; stamp.t += span
	005dd3bb  call 0x9755c0        ; now = _time32(NULL)   (0x009dd35a, FID library match)
	005dd3ca  call 0x975530        ; span = stamp.t - now.t
	005dd3d4  setle cl ; sub ecx,1 ; and eax,ecx   ; negative or zero -> 0

The decompiled body shows `FUN_009753f0()` with no argument, because the literal
travels in `ECX`. The unit is **seconds** because `stamp.t` (`+0x24`) is the field
`_time32` fills. 604,800 is exactly 7 × 24 × 3600, so the literal and the refusal's
`7D` agree — the same two facts that ground the reopen cooldown. The window closes
**at** 604,800 seconds: a difference of 0 is not refused. **Which** timestamp this is
(founding? last change?) is not read, because no `_TRAININGCAMP` column layout is
recovered. The record's layout at `+0x1c` is year/month, `+0x20` day/hour,
`+0x24` minute/second, `+0x28` fraction, which is ODBC's `TIMESTAMP_STRUCT`.

### The client special-cases the same code, on the same opcode

	TrainingCamp_OnOpenResult    (0xb470):  on 2, show the code; if code == 0x681c read 4 more bytes
	TrainingCamp_OnDisbandResult (0xb471):  on 2, show the code; if code == 0x681d read 4 more bytes

The server's 0x681d reply is exactly that shape. It is built in `HandleDisband` as
byte 2, word code, dword seconds-remaining (`0x0051916b`–`0x0051919e`). The client's
`0xb471` parser knows that `NOT_DISORGANIZATION_7D` carries a trailing field, which
makes `0xb471` the disband result from the client's side independently.
On success the client handler does nothing visible.

### Every academy job type, mapped to the request that queues it

Every call to `CTrainingCampMamager::SendOlappedTrainingCampJobReqToSM` passes the
job type in `CL`, which is why the decompiler shows the argument as `0` at most call
sites. Read in assembly at all six sites:

| type | queued by | called only from | result |
|---:|---|---|---|
| 0 | `TrainingCamp_RequestOpenJob` `0x005dedc0` (`xor cl,cl`) | `TrainingCamp_HandleOpen` | `0xb470` |
| 1 | `TrainingCamp_RequestDisbandJob` `0x005df140` (`mov cl,1`) | `TrainingCamp_HandleDisband` | `0xb471` |
| 2 | `0x005df910` (`mov cl,2`) | `trs_wait_response` slot 2 (`0x0046cb30`) | `0xb472` |
| 3 | `TrainingCamp_RemoveMember` `0x005deeb0` (`mov cl,3`) | `HandleBan`, `HandleLeave` | `0xb473`/`0xb474` |
| 4 | `0x005def20` (`mov cl,4`) | `HandleGraduation`, `CheckMembershipLevel` | `0xb475`/`0xb476` |
| 7 | `0x005df070` (`mov cl,7`) | `0x00519900` | `0xb477` |

The sender's `switch` agrees with the table's shape. Type 0 is the only case that stores
nothing from an existing camp record. Types 1–7 all store `FUN_005e4390`'s
`[camp+4]+0x18`, presumably the camp's id (not read), and a founding job has no
camp to read it from. Type 2 asserts "can't find training camp to
**join**!" and type 3 asserts "… to **leave**! (maybe dismissed)".

This row also **explains sub-type 4 carrying two opcodes**, which is why it was left
unnamed above. Its one queuer is shared by `HandleGraduation` (`0xb475`) and
`CheckMembershipLevel` (`0xb476`), just as type 3's is shared by ban and leave. What
operation type 4 performs for the membership check is still not read, so it stays
unnamed.

### Still not explained

**Plain refusals from `HandleDisband` go out on `0xb470`**, open's opcode
(`mov ecx,0xb470` at `0x005191d0`). Only the 0x681d refusal and a failed job
request use `0xb471`. The consequence is read: `0xb470`'s client handler shows any
code, and the one code that needs a trailing field (`0x681c`) is never among these,
so the player sees the right message either way. The reason is not read. Nothing
here tells a deliberate shared "refused" channel from a copy of the open handler.

`TrainingCamp_RequestDisbandJob` re-tests the camp and the class gate, and would
answer `0x680b` / `0x6816`. From `HandleDisband` neither can fire. The validator
tested the same fields a few instructions earlier (`char[0x733]` is `[edi+0x1ccc]`
in the queuer), and nothing but an assert runs between them.

## The 24-hour windows: two read, two are a different mechanism (2026-09-17)

The previous version of this section said all three `24T` windows were "named but
not read", each "produced by a helper returning a bare flag rather than by a visible
literal". That was right about the shape, and the helper has now been read for two
of them.

### Ban and leave share one window, and one function

	005194a7  call 0x5dd3f0        ; HandleBan, on the TARGET member
	005195b3  call 0x5dd490        ; HandleLeave, on the caller's own member
	005dd490  jmp  0x5dd3f0        ; ...the same function

`TrainingCampMember_IsPast24HourWindow` (`0x005dd3f0`):

	005dd40e  mov   ecx,0x15180                  ; 86400
	005dd417  call  0x9753f0                     ; span = ecx
	005dd44b  call  0x9755e0                     ; stamp = TIMESTAMP_STRUCT at record+0x40
	005dd456  call  0x975540                     ; stamp.t += span
	005dd45f  call  0x9755c0                     ; now = _time32(NULL)
	005dd46e  call  0x975530                     ; span = stamp.t - now.t
	005dd47c  setle cl ; mov eax,ecx             ; 1 once the window has passed

Same shape as the disband window, same helpers, same reason the unit is **seconds**:
`+0x24` is the field `_time32` fills. 86,400 = 24 × 3600, and "24T" is in both
refusal names. A null member or record also answers 0, so the refusal covers "no
such member" too.

Which timestamp `+0x40` holds is **not read**. Joining is the obvious guess and is
not recorded as a fact.

**The thunk is why a sweep found only one caller.** Every `call 0x9753f0` in the
binary was checked for a preceding `mov ecx,<imm>`; only three sites load a literal
(604,800 disband, 86,400 here, 259,200 in `CTJ_PenaltyKeeper::Create`). That sweep
attributed 86,400 to ban alone, because leave calls `0x005dd490`, five bytes that
jump to it.

### Invite and entry are not clock arithmetic at the check

	4e4862  push 0x8 ; push 0x2 ; lea eax,[esi+0x1dfc] ; call 0x411440   -> 0x681f NOT_INVITE_24T
	4e48d1  push 0x9 ; push 0x2 ; lea edi,[esi+0x1dfc] ; call 0x411440   -> 0x681e NOT_ENTRY_24T
	4e48f3  push 0xa ; push 0x2 ;                        call 0x411440   -> 0x681e as well
	        (founding: FUN_004114d0(2, 7)                                -> 0x681c NOT_OPEN_7D)

`0x411440` walks a **per-character list at `+0x1dfc`** and matches each entry on a
category byte (vtable slot `0x68`) and an id (slot `0x6c`); `0x4114d0` is its twin,
returning the entry instead of a flag. **Their durations are set where the entries
are created**, which is why no literal is visible at any check.

**That list is the timed-job manager**, read end to end in round 274 — see
`docs/protocol/timed_jobs.md`. The entry holds an absolute `__time32_t` of
`now + span`, and the character's one-second tick polls it against the clock
**every ten seconds**, so an academy window can run up to ten seconds long.
A window that has passed is not merely ignored: the entry is unlinked and freed,
which is what makes the later check answer "no penalty".

#### This corrected a recorded fact, and then grounded it again

Every call site of both helpers, with the two pushed arguments:

| category | id | refuses with | in |
|---:|---:|---|---|
| 2 | 7 | `TC_ERROR_NOT_OPEN_7D` | `CInstanceTrainingCamp::CheckCanCreate` |
| 2 | 8 | `TC_ERROR_NOT_INVITE_24T` | `TrainingCamp_CheckCanInvite`, `0x004e4950` |
| 2 | 9 | `TC_ERROR_NOT_ENTRY_24T` | `TrainingCamp_CheckCanEnter`, `0x004e4aa0` |
| 2 | 10 | `TC_ERROR_NOT_ENTRY_24T` | the same two, one branch later |
| 2 | 2 | — | `CInstanceCharTrijob::HandleJoinJobGuild` |
| 2 | 1 | — | `0x00514b20`, `0x00514c40` |
| 7 | 0 | — | `GObjPC::FUN_006185f0` |

`academy.md` and `academy.go` both said the founding cooldown was grounded because
"the literal 7 is the second argument, and the error name carries the same number".
**The second argument is an id.** If it were a day count, invite would be 8 days and
entry 9 days, and both of those refusals say 24 hours; the same category also serves
the job guild with ids 1 and 2. That agreement was a coincidence, and the citation
was withdrawn.

### Where the entries are created, with their real lengths

`CTJ_PenaltyKeeper::Create` (`0x00651b20`) switches on **the same id** (slot `0x6c`)
and builds the span. Read from the jump table at `0x00651d00`, because block order is
not evidence:

| case | block | span | the academy's window |
|---:|---|---|---|
| 7 | `0x00651c5b` | `mov ecx,0x93a80` → 604,800 s | **open: 7 days** |
| 8, 9 | `0x00651c81` | `mov ecx,0x15180` → 86,400 s | **invite and entry: 24 hours** |
| 10 | `0x00651ca3` | `mov ecx,0x3f480` → 259,200 s | **a second entry block: 3 days** |
| 1 | `0x00651bb7` | `span(days=3)` | the job guild's |
| 2 | `0x00651bed` | `span(days=7)` | the job guild's |
| 3, 4, 5 | `0x00651c23` | `span(seconds=vt+0x70())` | data-driven, unread |

So all three academy windows are now **read**, and the founding cooldown's 7 is
grounded a third time — on the duration, not on the id and not on the name. The value
never changed; two of the three readings that reached it were wrong.

**A player can be told the wrong number.** Ids 9 and 10 both refuse with the string
named `NOT_ENTRY_**24T**`, and id 10's penalty lasts **three days**. Anyone reading a
window off an engine string's name has a one-in-two chance here.

**Following jumps is what completes the table.** A backward scan by address finds only
the 259,200: cases 7, 8 and 9 reach the shared tail by `jmp`. The first sweep reported
"3 literal sites in the binary" and the real count at this one call site is three.

### The two invite-side checks

	TrainingCamp_CheckCanInvite (0x004e4800), on the INVITER, from 0x00519262
	  state -> 0x6808 ; !alive -> 0x6807 ; no camp -> 3
	  not class 0 -> 0x6816          <- only class 0 may invite
	  target is self -> 3
	  penalty (2, 8) -> 0x681f NOT_INVITE_24T

	TrainingCamp_CheckCanEnter (0x004e4890), on the TARGET, from 0x0051932f
	  two state bytes at [char+0x30]+4/+6 -> 0x6806 ; !alive -> 3
	  penalty (2, 9) -> 0x681e ; penalty (2, 10) -> 0x681e
	  target's camp == inviter's -> 0x680f ALREADY_ENTRY, else 0x6812 OTHER_ENTRY

That last pair is one expression: `sbb eax,eax ; and eax,3 ; add eax,0x680f`.

## Ban and leave, read in full (2026-09-17)

	TrainingCamp_HandleBan (0x005193a0)          TrainingCamp_HandleLeave (0x00519510)
	  not in a camp      -> 0x680b on 0xb473       not in a camp      -> 0x680b on 0xb474
	  NOT class 0        -> 0x6816 on 0xb473       IS  class 0        -> 0x6816 on 0xb474
	  name not found     -> 0x6815                 own member missing -> 0x6815 on 0xb474
	  target is caller   -> 0x6816                 inside 24h         -> 0x6821 on 0xb473
	  target inside 24h  -> 0x6820                 RemoveMember(1)
	  RemoveMember(2)

**The class gates are inverses.** Only class 0 may ban (and disband); class 0 is the
only member who may **not** leave. A missing member record answers 0 from
`TrainingCamp_IsMemberClass0`, so it passes leave's gate and is caught by the lookup
after it -- which is why leave has both `0x6816` and `0x6815` paths.

**`0x6815` is not `0x6816`.** The client shows both as `TC_ERROR_ORDER_WORK`
(`0x6813`-`0x6816` all map to that one string), but the server sends `0x6815` only
for an empty member lookup and `0x6816` only for a permission failure.

Ban resolves its target **by name from the packet**, case-insensitively
(`CompareStringA(0x400, NORM_IGNORECASE|NORM_IGNOREKANATYPE)`), and a name shorter
than two characters is found as nobody.

**Leave's 24-hour refusal goes out on `0xb473`**, ban's opcode, while its other
refusals go on `0xb474` -- the same kind of crossed channel disband has, and equally
unexplained. The client's handlers for `0xb473`-`0xb476` display whatever code
arrives and carry no special fields, so a player sees the right text either way.

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

- What role member class 0 is. It is the only class that may disband
  (`TrainingCampMember_IsClass0`); class 1 is the second guardian and class 2 the
  student, each read from a count function. "Master" and "apprentice" were never
  the engine's words.
- Which timestamp on the camp record the 604,800-second disband window runs from.
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
