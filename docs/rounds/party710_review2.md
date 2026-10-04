# Round 710 independent review (S1, the party server core)

An independent adversarial pass over `dev..worktree-agent-a779375e9b33e2da8` (`fd9da906`,
`7a4f8772`, `4fcc5872`). It is not the lane's self-review (`party710_review.md`). Everything
below was re-read in the binaries on the render box (`srgs.asm`, `sro_client.asm`, the three
decompiles), measured with the Go tests, or run live against the real server binary. No code was
changed; the coordinator applies the fixes.

## Findings, most severe first

### 1. BUG: a decline is checked before the inviter, so the ladder order is wrong
- **Where:** `server/internal/session/party.go:305-322` (`handlePartyAnswer`).
- **Evidence:** `gs:trs_wait_response::FUN_005be350` tests in this order, for both kinds:
  1. the inviter is not found: `0x2c0e` (`0x5be3e3`, kind 3; `0x5be40d -> 0x5be45b`, kind 2);
  2. the invitee is not found: 3 (`0x5be3f7`);
  3. the invitee's state byte is not 1: 2 (`edx = 2` at `0x5be370`, `0x5be3fc`/`0x5be474`);
  4. only then the answer: decline `0x2c0c` (`0x5be420`) or `0x2c17` (`0x5be3cf`);
  5. a failed post: 2.

  The Go code tests the decline first. So an invitee who says no after the inviter logged out
  gets `0xb067 [2][0x2c0c]`, where the original sends `0x2c0e`.
- **Live:** my own partybot case R6 (an inviter disconnects with a formation invitation pending,
  and the invitee declines) got `[rvIvy] <- 0xb067 [2] code=0x2c0c`.
- **Fix:** look up the inviter (`EntityByCharacterID`) before testing `accept`. Send `0x2c0e` to
  both sides when the inviter is gone, whatever the answer was.

### 2. WRONG-LABEL: "1 accepts" is READ only for kind 3; kind 2 accepts any non-zero byte
- **Where:**
  - `server/internal/party/wire.go:314-321` (`DecodeAnswer`: "The GameServer reads only the first
    byte ... 1 accepts");
  - `party_protocol.md`, opcode table row `0x3080` C->S and "Create a party" step 4.
- **Evidence:**
  - `gs:0x46cbef` reads the raw u8 (`0x404f80` returns the byte itself) and passes it in `AL` to
    `0x5be350` (`0x46cc84`).
  - Kind 3 accepts on `cmp bl,1; jne 0x5be3cf` (decline otherwise).
  - **Kind 2 accepts on `test bl,bl; jne 0x5be434`** (`0x5be41c`): any non-zero byte forms the
    party, and only a 0 declines.
  - The stock client's "no" is `[2][0x2c0c]` (`c:0x81cd9b mov BYTE [esp+0x13],2`, then
    `0x2c0c`). So **with this GameServer, the client's "No" to a formation invitation forms the
    party**: a bug in the private-server build, or a byte 0 the client never sends.
- **Fix:** keep `b[0] == 1` (copying the build's bug would turn every "No" into a "Yes"). Label it
  **OURS**, with the two instructions above, in `wire.go` and in `party_protocol.md` (step 4 and
  the `0x3080` row). Also add a test that `[2][0x2c0c]` on a kind-2 invitation declines.

### 3. BUG: a join re-files every existing member's record, swallowing their pending updates
- **Where:** `server/internal/session/party.go:369-388` (`announceJoined` calls `fullRecord`, and
  so `partyRecords.set`, for **every** member).
- **Evidence:**
  - Retail builds a record from the PC for the **joiner only** (`gs:0x5bae80` via `0x5bc210`).
  - The joiner's `0x3065` is written from the party's mirror list (`gs:0x5bc650` walks the list
    nodes at `party+0x14` and calls `0x470ba0` on each node). Nothing about the existing members
    is rebuilt or re-baselined.
  - Here, a member's change that the 1 s sampler has not yet sent (position, HP, a level) is
    written into the book as "already heard" when someone joins. The existing members never
    receive it, and a member who then stands still stays wrong on everyone's screen until the
    next change.
  - It also swaps the HP byte the members last heard (the update formula's, e.g. 11) for the
    full formula's 10.
- **Fix:** in `announceJoined`, call `fullRecord` only for the joiner. For the others, send what
  the book holds (`partyRecords.get`, mask set to `0xff`), falling back to a fresh sample only
  when nothing is filed. Alternatively, run one `sendPartyUpdates` pass for that party before the
  join is announced.

### 4. REGRESSION: pickup rights ignore the item-share bit, now that parties without it exist
- **Where:** `server/internal/session/grounditem.go:389-409` (`samePartyFunc`).
- **Evidence:**
  - The comment says "OpenSRO's parties share unconditionally ... so being in the same party is
    enough". That stopped being true with this round: `0x7060` now forms parties with flags
    `0x00`/`0x01`.
  - The engine's rule is `GetPartyFlags() & 2` (`ground_items.md`; `gs:0x4ea200`).
  - So members of an item free-for-all party can pick up each other's owned drops, which the
    original refuses.
  - `party_rules.md` gap 11 calls this rule "modelled"; the code never tests the flag.
- **Fix:** `return inA && inB && pa.ID == pb.ID && pa.Flags.ItemShare()`, and update the comment.
  One line; it does not need to wait for S2.

### 5. REGRESSION: the exp-share-only rewards now reach free-for-all parties
- **Where:**
  - `server/internal/session/combat.go:1194-1205` (`killExpFor` / `inPartyWithOthers`: the level-gap
    bonus);
  - `server/internal/session/nestkill.go:63-64` (`partyMembersNear`: nest arming).
- **Evidence:**
  - Both gate on "a party of two or more". The comments justify that with "every OpenSRO party
    shares experience".
  - Since this round, a party can be exp free-for-all (bit 0 clear).
  - `party_rules.md` (READ): the gap bonus needs bit 0 (`0x410018`); "an exp free-for-all kill
    never arms" (`0x529e0a`).
  - These are gaps 4 and 12, assigned to S2. But the plan releases S1+C1 **first** and S2+C3
    **last**, so two releases would pay the bonus and arm nests for free-for-all parties.
  - The 3 % bonus (gap 3) has the opposite fault (it should apply **only** to free-for-all
    parties), which was already true before this round.
- **Fix:** gate `inPartyWithOthers`' two callers on `pt.Flags.ExpShare()` now (two lines), or
  record the interim behaviour in the round notes and hold the release until S2.

### 6. MINOR (C1 hand-off is wrong): the client decodes an update's HP as `n - 1` over 9
- **Where:**
  - `docs/rounds/party710.md` "What C1 must know", HP/MP bullet ("draw as the client does ... its
    'max' slots are OPEN");
  - `party_protocol.md` OPEN 8.
- **Evidence (asm):**
  - Full record (kind 2 `c:0x886b88`, `0x3065` `c:0x883e87`): `push 0xa; push 0xa` before
    `0x99a2e0`. The HP and MP nibbles are stored raw with a "max" of **10** each.
  - Kind 6 calls `c:0x991f60(jid, hp, 10, mp, 10)` (`c:0x886fff..0x88701b`), and `0x991f60` does:
    - HP nibble 0: dead flag `+0x60 = 1`, HP 0 over 10;
    - otherwise: dead flag 0, **HP = n - 1 over 10 - 1 = 9** (`c:0x991fd1 lea ecx,[ebx-1]`,
      `lea edx,[ebp-1]`);
    - MP: raw over 10.
  - So the update's `1 + trunc(10 r)` is a 0-means-dead encoding. A full bar in an update (11)
    becomes 10 over 9 in the client. Whether the gauge clamps that was not traced.
  - The server bytes are right (finding-free, see "verified" below). What is incomplete is what C1
    is told to draw. If C1 draws `11/10` or `10/10`, it is wrong.
- **Fix:** replace the bullet with the two decodes above, and close OPEN 8 in `party_protocol.md`.

### 7. RACE (minor): the sampler can send a kind 6 after the kind 3 or kind 1
- **Where:** `server/internal/session/party.go:676-699`.
- **Evidence:**
  - `sendPartyUpdates` works on a snapshot from `All()` and samples through the DB for each
    member.
  - A kick, leave or dissolution in between sends kind 3 or kind 1 first. The sampler then still
    sends its kind 6 about the removed member, or to them, using the stale member list.
  - The round's fix (`replace`) stops the re-filing but not the send.
  - The client ignores a kind 6 for an unknown JID (`c:0x991f60` matches nothing), so nothing
    visible breaks; it is still a message retail never sends.
- **Fix:** before sending, re-check that both the subject and each receiver are still in that
  party (`Parties.Get`), or hold a per-party sequence that a removal bumps.

### 8. MINOR: two invitations to one target in a race answer 2 instead of `0x2c1f`
- **Where:** `server/internal/session/party.go:219-221` and `260-262`.
- **Evidence:**
  - The ladder (`checkTargetAvailable`) and `Invite` are separate lock sections. Two inviters
    passing the ladder at once make the second `Invite` fail with `ErrInvitePending`, which is
    sent as the post failure 2.
  - The original is single-threaded and would answer `0x2c1f`.
  - The self-review records this race.
- **Fix:** map `ErrInvitePending` to `0x2c1f` (`party.CodeDuplicate`), which is what the engine's
  ladder would have said.

### 9. MINOR: a zone with no frame sends region 0 and world coordinates cut to u16
- **Where:** `server/internal/session/party.go:539-546` (`partyPosition`).
- **Evidence:** when `entityFrame` fails, the record carries region 0 (bit 15 clear) and
  `int32(e.Pos.X)` etc., written as u16. Negative world coordinates wrap.
- **Fix:** no OpenSRO zone hits this today. Either label the fallback OURS, or omit the position
  bit (`MaskPosition`) for such a member.

### 10. MINOR: the sampler costs three store reads per member per second
- **Where:** `server/internal/session/party.go:496-534`.
- **Evidence:**
  - Each tick does `Chars.GetByID`, `Guilds.GetByCharacter` and `Skills.MasteryLevels` per member.
    With PostgreSQL in production, that is about 3 queries a second for each party member.
  - It also does `EntityByCharacterID`, a linear scan of every session.
- **Fix:** none needed for correctness. Before release, consider caching guild and masteries,
  which change on events, or sampling them less often.

### 11. MINOR: an invitation outlives its invitee's disconnect
- **Where:** `server/internal/session/party.go:464-475`.
- **Evidence:**
  - Only party members are cleaned up on disconnect. An invitee who drops and logs back in
    within 30 s has a dead invitation pending.
  - Every new invitation to them is refused `0x2c1f` until it times out.
  - Retail's GameServer path for this was not read.
- **Fix:** drop the invitations whose target or inviter is the disconnecting character, and send
  `0x2c10` (or nothing) to the other side. Label that OURS.

### 12. MINOR: a monster's id can name a player
- **Where:** `server/internal/session/party.go:144-157` (`reachTarget`).
- **Evidence:**
  - Monster ids count from 1 (`combat.Hub.nextID`), as character ids do. If a client sends a
    monster's id, the server resolves the player with that character id. Inside 600 units and in
    the same zone, that player is invited.
  - Retail answers 3 (the `0x26` TypeID filter, `gs:0x4a8eb2`).
  - It is labelled OURS and C1 is told to send player ids only, so this is not a wrong label. But
    the consequence (an unrelated player invited) is not written down.
- **Fix:** add that consequence to the OURS note in the round notes.

## Verified correct

**Bytes.** These were re-read in asm or the decompile, compared with `wire.go` and the fixtures,
and regenerated with `gen_fixtures.py` into a copy, which came out byte-identical (57 files):

| what | where it was read |
|---|---|
| member record, every mask, field and dungeon forms | writer `gs:0x470ba0`, sizes in `EAX`: mask; JID 4; name, model 4; level 1; HP/MP 1; region 2; x, y, z 2 or 4 each (in that order, `0x470c72..0x470cbd`); world 4, under `0x20` only; guild str; job 1; masteries 4 + 4. Reader `c:0x883620`, the same |
| `0x3065` | `gs:0x5bc650`: mask `0xff`, party id 4, leader 4, flags 1, count 1, records `0xff`; asserts count ≤ 8 or 4 by bit 0 |
| `0x3864` kind 6 | sent only when the mask is non-zero (`gs:0x5bc774 test al,al; je`); `[6][u32 JID][record]` (`gs:0x5bc77c..0x5bc7cc`). The mask mapping is `gs:0x5bb0c0` |
| `0x3864` kinds 1, 2, 3, 9 | the fixtures match the spec table; the kind-2/kind-6 dispatch read in `c:0x886b10` |
| HP/MP, full record | `gs:0x5baf96..0x5bb029`: `fild cur; fidiv max; fmul 10.0 (0xb45c60 = 40 24 00..)`, chop. `HPMPFull` agrees |
| HP/MP, update | `gs:0x5bb0ea..0x5bb1c8`: cur and max to double, `fdivr`, stored float32, `fmul [0xb45f78]` (bytes `00..24 c0` = -10.0), `_ftol2 0x9fbb40` (SSE2 `cvttsd2si`, else x87 with truncation fix-up), `ecx = 1 - eax`; 0 when HP is 0; MP `ftol(float32(r) x 10.0)`; the byte is rewritten only when a nibble differs from `[rec+0x46]`. **The claim "10 in a full record, 11 in an update" is TRUE** as server bytes. See finding 6 for what the client does with them |
| `0x3080` both ways | S->C `[kind][u32][flags]`; C->S yes `[1][1]` (`c:0x81cc79 mov ebx,1`), no `[2][0x2c0c]` / `[2][0x2c17]` (`c:0x81cd93`, `0x81cf63`) |
| `0xb060`, `0xb062`, `0xb067` | `[1][u32]` and `[2][u16]` (`Msg_SendTwoFieldReply 0x4e7250`); the `0xb060 [2][2]` quirk at `gs:0x5146bb`; full `0x2c13`/`0x2c14` by `sete` at `gs:0x5145d8`/`0x5145df` |
| `0x706c`, `0xb06c` entries | `c:0x8841f0`: `[1][pages][index][n]`, each row u32, u32, str, then six u8 (race, count, flags, purpose, min, max), then str |
| `0x706d` popup | `c:0x884660`: 4, 4, 4, 4, 4, 1, then the record |

**Ladders.**
- **`CheckCanCreate`** (`gs:0x513f90`, asm): `0x2c19`, lock `0x2c09`, life `0x2c09`, then state byte
  ∉ {0, 4} **and** `chardata+6` ≠ 0 `0x2c09` (an AND, confirmed), then level < 5 `0x2c0a`.
- **The `0x7060` handler** (`gs:0x5143b0`): CheckCanCreate, then the self-target dropped
  (`0x51443c`), then the range check `0x4a8e10`, then IsPC 3, then `0x514010`, then post.
- **`CheckCanJoin`** (`gs:0x514560`): no party, not the leader without bit 2, and the self-target
  all fail silently; then full, range, IsPC, `0x514010`, post.
- **`CheckTargetAvailable`** (`gs:0x514010`):
  - `0x2c06`;
  - life not 1 or 2: 3;
  - in a party: `0x2c12` when it is the same party (`0x514073` `sub`/`neg`/`sbb`/`and 6`), else
    `0x2c18`;
  - `pc+0x1cd0`: `0x2c25`;
  - state 1 or 3 `0x2c1f`, state 4 `0x2c25`, anything else (interaction included) `0x2c06`;
  - arena `0x2c28`.
- **Constants:** 600.0 at `0xb46198`, 320.0 at `0xb460dc`, 30.0 at `0xb45b48`, all read from the
  exe.
- **ShardManager formation** (`sm:0x44ed70`): `0x2c0f`, `0x2c09`, `0x2c18`, `0x2c23`, `0x2c20`.
- **ShardManager join** (`sm:0x44f130`): `0x2c0d` twice, `0x2c23`, `0x2c0f`, `0x2c25`, then
  `0x44e140`.
- **Job table:** `sm:0x44ed20` and `gs:0x5bc1c0` agree with `JobsMatch`.
- **Formation order** (`gs:0x5be710`): `0xb060`, add the inviter (`0x5bc210`), `0xb067`, add the
  invitee.

**Labels.** World id 1, the two highest masteries, the 1 s sampler, the dropped late answer and
the low-32-bit JID are all labelled OURS, in the code and in the round notes; the README labels
the JID too. The only wrong label found is finding 2.

**Callers.** Chat, friendlycast, uniquenotice (u32 party id), the monster-AI aggro link and
nest660 go through the new Hub correctly. `gm.go` has no party commands. There is no `0x0080`-`0x0089`
party use left on the server side; `useitem.go` only mentions it in history comments.

**Races** (`go test -race`):
- `internal/party` is clean.
- The whole `internal/session` package does not finish under `-race` in Go's default 10 minutes
  (the timeout panic fired in `TestTeleportWaivers`, with no `DATA RACE` report up to then).
- So it was rerun with `-run 'Party|Chat|Unique|Nest660|Friendly|Round666'`; the result is under
  "Test runs" below.
- Read in the code: the invitation timer and `TakeInvite` both take the hub's lock with the
  sequence check; `partyRecords` is mutex-guarded.

## Live run

I rebuilt `server/cmd/server` and `server/cmd/partybot` from the branch and ran the server on
port 25779: `-in-memory`, `-chargen-csv`, `-leveldata-csv`, the bots in `-gm-accounts`.

- **`partybot -mode scenario`: all ten steps passed**, with the same trace as the round notes
  (the message order on the formation, the cap of 4 with `0x2c14`, chat echoed to the sender,
  kick 4, leave 2 then kind 9, the dissolution at two, kind 6 position only, logout 1).
- **My own cases** (a throwaway partybot with ten characters, not committed):

  | case | result |
  |---|---|
  | R1: target at 601 units (3D, along z) | `0xb060 [2][4]` (pass) |
  | R2: NPC uid `0x7f000005`; id 999999 | `0xb060 [2][3]`; `0xb060 [2][0]` (pass) |
  | R3: two inviters, one target | the second gets `0xb060 [2][0x2c1f]`; the target hears nothing more (pass) |
  | R4: exp-share party (flags `0x01`) | **8 members accepted, the 9th refused `0xb062 [2][0x2c13]`** (pass; the scenario's cap-4 case gives `0x2c14`) |
  | R5: kick, then a non-leader invites without bit 2 | dropped silently (pass) |
  | R6: inviter disconnects, invitee declines | got `0x2c0c`, retail `0x2c0e` (**fail**, finding 1) |

## Test runs

- `go test -count=1 -p 1 -timeout 60m ./...` in `server/` against local `opensro_test`: **EXIT 0**,
  65 packages `ok`, no failures.
- `go test -race -count=1 ./internal/party/`: `ok`, no race.
- `go test -race -count=1 -p 1 -timeout 30m -run 'Party|Chat|Unique|Nest660|Friendly|Round666'
  -v ./internal/session/`: **PASS** (40 top-level tests), **0 `DATA RACE` reports**, 111 s.
- The whole `internal/session` under `-race` needs more than Go's default 10 minutes; that is a
  timeout, not a failure, and is no finding against this round.
