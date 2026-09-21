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

- **Bit 2 of the party flags.** The attempt is recorded in
  `server/internal/party` so it is not repeated.
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
  and expulsion flow is NOT in `0x06b`/`0x06c`, and the places still unmapped are
  `0x061` (`0x00514530`), `0x06e` (`0x00514900`, payload `u32,u32,u8` with no
  client sender found) and `0x06f` (`0x00514af0`). `0x06d` remains the odd one:
  `0x005bf570`, 382 bytes, posts no kind and does its own work.
- **Whether the exp-sharing flag can change after creation.** Nothing read so
  far writes it.
