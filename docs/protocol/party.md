# Parties

What the engine enforces about parties. Implemented in `server/internal/party`.

Small system, and most of it was already recovered — this page collects it and
adds the one rule srrevamp was missing entirely.

## Size: two caps, selected by a flag

`FUN_00514560` is the join-time check, and there are **two** limits:

	5145cc  test BYTE PTR [ecx+0x10],0x1   ; bit 0 of the party's flags
	5145d0  je   clear
	5145d4  cmp  DWORD PTR [ecx+0x1c],0x8  ; set:   full at 8
	5145df  cmp  DWORD PTR [ecx+0x1c],edx  ; clear: full at 4  (edx = 4 at 5145af)

where `+0x1c` is the member count. The numbers alone would not say which limit
applies when; the errors do, because the client names them:

| flag bit 0 | cap | refusal |
|---|---|---|
| set | **8** | `UIIT_MSG_PARTYERR_MEMBER_FULL_EXP_SHARED_PARTY` |
| clear | **4** | `UIIT_MSG_PARTYERR_MEMBER_FULL_NONEEXP_SHARED_PARTY` |

So **bit 0 of the party's `+0x10` is the experience-sharing flag**, and an
exp-sharing party holds eight while a non-sharing one holds four.

srrevamp's parties share experience unconditionally — every member counts toward
`leveldata.PartyExpBonus` and no flag turns it off — so eight is the cap that
applies, and `MaxSizeNotShared` is recorded for completeness rather than use.

**A refusal that was correct is worth keeping.** An earlier pass found two loops
bounded at 8 near the party module and declined them, on the grounds that they
sat in `CMainProcess` functions calling `CGuild__BroadcastToLocalMember`, before
the `CParty` code begins — "far more likely a guild alliance's slot count than a
party's". The answer turned out to be 8 anyway. The refusal was still right: a
correct answer reached on wrong evidence is not a recovery, and the citation
above is from the join-time check itself.

## A party leader must be level 5

**Recovered 2026-09-17**, and srrevamp had no such rule.

Two call sites enforce it, both calling vtable slot 73 (`+0x124`, the level
getter) and comparing against the same literal:

	FUN_00513f90:  if (level < 5) return 0x2c0a;   // the plain create path
	FUN_00514170:  if (level < 5) return 0x2c0a;   // the party-match path

`0x2c0a` is `UIIT_MSG_PARTYERR_TOO_LOW_CREATOR_LEVEL`, which names the rule
rather than leaving it to be read off the comparison.

The party-match path applies it **only when the character is not already in a
party** — an existing member re-listing is checked for leadership instead
(`0x2c1d` `PARTYMATCH_RECORD_ERROR_PARTYLEADER`). So the rule is about *forming*
a party, not about being in one, which is what "CREATOR" in the error name says.

Level 5 is also the floor for using a COS summoner item
(`docs/protocol/pets.md`), so it reads as a general "past the tutorial" gate
rather than a party-specific number.

## Party matching

A separate subsystem with its own nine codes (`PARTYMATCH_*`), entered through
`FUN_00514170` and `FUN_00514010`. Beyond the creator level it enforces:

| check | refusal |
|---|---|
| a job item is worn | `0x2c26` `JOBITEM_WEAR_ERR_PARTYMATCH` |
| already listed | `0x2c24` `PARTYMATCH_JOIN_ERROR_DUPLE` |
| not the leader | `0x2c1d` `PARTYMATCH_RECORD_ERROR_PARTYLEADER` |

`PARTYMATCH_RECORD_ERROR_PARTYLEADER` is the single most widely returned party
code — it appears in nine different functions — so "only the leader may do this"
is the party system's dominant rule.

## Who reads the flag word (round 269)

`GObjPC::GetPartyFlags` (`0x4ea200`) returns the byte at `party+0x10` through
`pc+0x1cb8`. Its readers, each settled at its own use-site: **bit 0**
(exp-sharing) gates the join cap above, the **aggro link** (a party member's
hit pulls neighbouring monsters in only in an exp-sharing party;
`monster_ai.md`) and the berserk party share; **bit 1** is item sharing --
`ground_items.md`: a party member may pick a reserved drop when the party
shares items (`GetPartyFlags() & 2`); `FUN_005bbae0` (from `0x5bc210` and
`CMainProcess::FUN_005bf150`) requires BOTH bits before it walks a member's
list -- unread beyond that gate. The writer of the byte -- where the create
request's type byte (`HandlePartyMsg_060` reads a u32 target and a u8 after
`CParty::CheckCanCreate`, and hands the byte to `0x5be280` with the invitation)
lands in the party object -- was not found by the store patterns this round;
the invite record carries it until the accept. **Round 271 explains why:** the
party is not created locally. On the invitee's answer `trs_wait_response::
FUN_005be4f0` (`0x5be4f0`) builds a 0x1114-byte request (`0x46cf50` constructs
it): a kind byte at `+0x28`, the requester's and the invitee's ids at
`+0x2c/+0x30`, the invite record's `+0x34` word at `+0x34`, and for a fresh
party two 0x68-byte member records (`0x5bad30`/`0x5bae80`: name, level,
HP ratio, position...) at `+0x38/+0x3c`; it is dispatched through the request's
slot 3 to another server (the party lives in the global/agent process), and the
flag byte lands in the party object when the response comes back -- a path the
local store patterns cannot see. srrevamp's parties are its own design, so
nothing shipped depends on it.

## Not recovered

- ~~**The invite and expulsion flows.**~~ **BOTH SIDES READ (round 358).**
  The full ladder is in the section below; the short form is that **invite is
  `0x062`** (`CParty::CheckCanJoin`) and **expulsion is `0x063`**.

- ~~**Bit 2 of the party flags.**~~ **READ (round 357), from a use-site.**
  `CParty::CheckCanJoin` (`0x00514560`) opens its gate with

	if (((myId == *(party + 0xc)) || ((*(byte *)(party + 0x10) & 4) != 0))
	    && target != myId)

  so **bit 2 lifts the leader-only restriction**: the caller may be the leader
  *or* any member of a party whose bit 2 is set. It is the "anyone may invite"
  option, and it is a use-site rather than a curve -- the bit appears in an OR
  with an explicit leader test and nowhere else in that function.

  `party + 0xc` is therefore **the leader's id**, which the expulsion handler
  confirms independently: `Party_HandleExpelMember_063` makes the same
  comparison before removing anyone.
- ~~**What the other party flag bits mean**, beyond bit 0.~~ **Bit 1 is read**
  -- item sharing, recorded in this page's own flags section. Bit 2 remains
  unnamed and has its own bullet above.
- **The invite and expulsion flows.** Only the refusals are enumerated -- but
  the HANDLER SIDE is now mapped (round 354), which narrows what is left.

  The party opcodes `0x060`-`0x06f` are thin: `0x060` calls
  `CParty::CheckCanCreate`; `0x063` acts on the caller's own party through
  `[0x72e]` (PARTY, per `RE_COMPLETION.md`); and `0x06b`, `0x06c`, `0x06d`
  each delegate to one function in an adjacent family at `0x005bf4d0`-`0x005bf570`.

  Three of that family are one-line wrappers around **`Party_PostRequest`**
  (`0x005bf2a0`), which takes a byte KIND and allocates a 0x1114-byte request
  object per call -- a size consistent with an object embedding the message
  buffer at `+0x1034`, so a party operation is a request *sent on*, not handled
  in place. Four call sites, four kinds:

  | kind | wrapper | reached from |
  |---|---|---|
  | `0xa` | `0x005bf4d0` | caller not found by that pass |
  | `0xb` | `0x005bf500` | caller not found by that pass |
  | `0xc` | `0x005bf530` | `GObjPC_HandlePartyMsg_06b` (client `UI_PARTY` sends `0x706b`) |
  | `0xd` | `0x005bf560` | `GObjPC_HandlePartyMsg_06c` |

  **The kinds are now read (round 355)**, and the poster turns out to switch on
  the kind itself rather than merely carrying it. Every request holds a SUBJECT
  at slot 9 and the party id at `[0x16]`; what differs is where the subject
  comes from:

  | kind | subject | validation |
  |---|---|---|
  | `0xa` | none from the client; handles the no-party case specially (vtable `0xf0`) | `Party_UserMatches`, refusing `0x2c23` |
  | `0xb` | copied from the object's own `[0x15]` | `Party_UserMatches`, refusing `0x2c23` |
  | `0xc` | read from the wire as a **u32** | none here |
  | `0xd` | read from the wire as a **u8** | none here |

  `0x2c23` is `UIIT_MSG_PARTY_USER_MISSMATCH` (the engine's spelling), which is
  what names **`Party_UserMatches`** (`0x005bf240`) -- a pairwise compatibility
  table over two small enum values whose failure is that refusal. What those
  values are is not claimed.

  **AND THE SEARCH WAS LOOKING IN THE WRONG PLACE.** `0x06b`'s reply is handled
  by `UI_PARTYMATCH::FUN_008801e0`, and that class handles **exactly one** reply
  opcode -- which by the round-344 rule (a class names an opcode only when it is
  the class's only one) makes `0x06b` a party-**matching** operation, not an
  invite. It sits with `0x069 OnRegisterPartyReq` and `0x06a
  PartyMatch_HandleModify`, which are already named for matching. So the invite
  and expulsion flow is NOT in `0x06b`/`0x06c`. **Round 356 read the three that
  were left:**

  | opcode | reads as |
  |---|---|
  | `0x061` (`0x00514530`) | requires `[0x72e]` (a party), saves the position through the already-named `CGObjCOS_Summoned::SaveCurPosAsLastTelPosition`, then calls `0x005144e0(2)`. A party-side *teleport* action, not an invite. |
  | `0x06e` (`0x00514900`) | branches on `GObjPC::PartyID` being **zero** -- the "I am in no party" path -- and only then reads a u32 target from the wire. The shape of answering an invitation. |
  | `0x06f` (`0x00514af0`) | also gated on `PartyID` being zero: when the character's `chardata+7` byte is **4** it clears that byte and `+0x1cd0`. A pending-state cleanup -- a decline or a cancel. |

  So this is not invite-and-expel as two symmetric opcodes: `0x06e` and `0x06f`
  are both things a character with **no party** does, which is the *answering*
  side. **Which is accept and which is decline is not claimed** -- `chardata+7
  == 4` is an unnamed state byte.

  **EXPULSION IS `0x063` (round 357).** It reads a u32 target, then requires all
  three of: the caller is in a party; the caller's id equals `party + 0xc`, the
  LEADER id; and the target is not the caller. Only then does it call
  **`Party_RemoveMember`** (`0x005be1a0`), which resolves the member through the
  already-named `GetMemberByJID` and branches on a REASON byte -- 4 here.

  The same function is reached with reason **2** from the party-teleport path
  (`0x061` -> `0x005144e0`), which settles what that argument `2` was: not an
  unread selector but a removal reason. **Reason 1, and the reason enum's own
  names, are still unrecovered**, and the expulsion reading rests on the three
  gates rather than on the constant 4. `0x06d` remains the odd one:
  `0x005bf570`, 382 bytes, posts no kind and does its own work.
- **Whether the exp-sharing flag can change after creation.** Nothing read so
  far writes it.


## The invite ladder, in the order the engine checks it (round 358)

`CParty::CheckCanJoin` (`0x00514560`) is the INVITE, not merely a predicate: it
ends by asking the party manager to send the invitation. Reading it through:

| # | condition | on failure |
|---|---|---|
| 1 | the caller is in a party (`[0x72e]`) | falls through silently |
| 2 | caller is the leader (`myId == party+0xc`) **or** party flag **bit 2** is set | falls through silently |
| 3 | the target is not the caller | falls through silently |
| 4 | the party is not full — `party+0x1c` against **8** when flag bit 0 is set, **4** when clear | `0x2c13` when sharing, `0x2c14` when not |
| 5 | the target is within **`0x26` = 38** of the caller (`GObjPC::IsWithinInteractionRange`) | the pending code is sent |
| 6 | the target is a **PC** — vtable slot 7, `IsPC` | code **3** |
| 7 | `0x00514010` returns 1 | its own code |
| 8 | `Party_SendInvitation(target, partyFlags)` returns 1 | its code, 2 on failure |

**`Party_SendInvitation`** (`0x005be2f0`) asserts the target has NO party, then
notifies through `GObjPC::FUN_004ea0d0(target, inviterId, inviterPartyId, …)`
and sets **`target->chardata+7 = 1`**.

That byte is what round 356 could only call "an unnamed state byte" when it
found handler `0x06f` clearing it at value **4**: it is the **pending-invitation
state**.

### The state byte, `chardata + 7` (round 359)

Every writer in the binary was swept, and the machine closes:

| transition | written by |
|---|---|
| → **2** when a party pointer is set, → **0** when it is cleared | `GObjPC::SetParty` (`0x004ea260`), which assigns `pc+0x1cb8` and syncs the byte in the same breath — the setter sitting beside `GObjPC::PartyID`, its getter |
| target → **1** on an invitation | `Party_SendInvitation`, and `Party_SendFormationInvitation` |
| inviter → **3 if it was 4, else 1** | `Party_SendFormationInvitation` (`0x005be280`), as `(state == 4) * 2 + 1` |
| **3 → 4**, anything else → **0**, then a reply is sent | `trs_wait_response::FUN_005bea90`, as `((state != 3) - 1) & 4` |
| **4 → 0**, clearing `+0x1cd0` too | handler `0x06f` (round 356) |

**There are TWO invitation senders**, and the difference is in the code rather
than inferred: `Party_SendFormationInvitation` asserts that *neither* side has a
party and passes **0** as the party id, while `Party_SendInvitation` asserts only
the target is party-less and passes the inviter's real one. One forms, one joins.

**What 3 and 4 MEAN is not claimed** — only that they are a pair the repeat path
moves through, and that `0x06f` is the exit from 4.

**Corroborated from outside the party code (round 361).** `chardata + 7` is
not a party-private byte: it is field **kind 3** of the character-state
dispatcher `CGObjPC::SetCharacterState` (vtable slot 171), which was read
without reference to any of this and writes the same offset. Kind 2 of that same
dispatcher is `chardata + 6`, the exclusive-interaction state — see
`docs/protocol/character_state.md`.

### `0x2c06` is the character lock — CLOSED, round 360

`0x00514010`, step 7 of the ladder, refuses with **`0x2c06`** when `[0xc] + 4` is
1. That byte is now read: it is the **character lock**, held while an async DB
query or a multi-step transaction is in flight against that character, and its
sole writer is `GObjPC::SetLocked` (vtable slot 342). See
`docs/protocol/char_lock.md`. `CParty::CheckCanCreate` refuses the same state
with `0x2c09`, and the academy with `0x6806`; none of the three has a client
message, which fits a guard the client is never supposed to provoke.

So step 7 does not forbid anything about parties. It declines to start one while
the character is mid-transaction.

### Still open here

`0x00514010` also returns **3** when the vtable-`0xf8` state getter returns
neither 1 nor 2. `0xf8` is a life-state getter — `TrainingCamp_CheckCanEnter`
returns the same bare `3` when it is not 1 — but **what the value 2 means is
unread**, and it is the reason the invite path accepts two states where the
academy accepts one.

The party id the invitation carries is `inviterParty + 8`, a fifth independent
use-site for `GObjPC::PartyID`.
