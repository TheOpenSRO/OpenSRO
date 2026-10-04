# Round 713, lane S3: party matching on the original's opcodes

The party-match server, built on lane S1's party core (round 710, branch `int/party`) against
round 709's specs (`docs/protocol/party_protocol.md` "Party matching", `party_rules.md` "Party
matching", `party_gui.md` §3-§5). Server only. Lane C2 builds the client windows against the same
golden fixtures.

## What was done

- **`server/internal/party/match.go`**, the ShardManager's half, `party.Matcher`:
  - **Entry numbers** come from a counter that only grows and skips 0. Numbers are never reused
    (SM `0x451290`, `0x44def0`, `manager+0x8c`).
  - **Who holds what.** The Hub records who holds which number with which flags
    (`SetListing`/`ClearListing`). It already moves a departing leader's entry to the new leader
    and drops a dissolved party's (SM `0x44e1a0`, `0x44eb30`). The Matcher keeps the rest of each
    listing (purpose, levels, title, time, the pending mark) by number. It finds the owner through
    the Hub, so the owner is always the current leader.
  - **Register** (SM `0x450680` -> `0x451290`/`0x451110`), in its order:
    `0x2c1b` already listed; then in a party `0x2c20` flags not the party's, `0x2c1d` not the
    leader, `0x2c08` full (the listing takes the party's flags); otherwise the listing carries the
    entry's flags.
  - **Change** (SM `0x450990` -> `0x4513c0`): `0x2c1c` the caller holds no entry; then the entry
    the request names is looked up: `0x2c1c` not found, `0x2c1d` not the caller's, bare 5 when the
    flags differ (fixed in review, finding 3). It replaces the purpose, levels and title and renews the time.
  - **Delete** (SM `0x450ba0` -> `0x451490`): `0x2c1c`, then `0x2c1d`.
  - **Withdraw**: a party-less owner's entry goes when it leaves the world (SM `0x4296f0` ->
    `0x451590`).
  - **Pages** (SM `0x451630`, `0x450d20`):
    - 23 to a page in number order, at most `0xfe` pages; a page past the end becomes page 0;
    - no listings at all gives `[1][0][0][0]`;
    - the requester's own entry, or its party leader's, heads every page and counts one more;
    - an entry whose owner is gone is deleted on the way.
  - **Join request ladder** (SM `0x44f850`), in its order:
    1. `0x2c18` the requester is in a party;
    2. `0x2c25` it holds its own entry;
    3. `0x2c1c` no such entry;
    4. when the entry has a party: `0x2c13`/`0x2c14` full, `0x2c1c` its leader is gone, `0x2c23`
       the leader's job does not match;
    5. `0x2c23` the job does not fit the purpose;
    6. `0x2c1e` level outside [min, max], inclusive;
    7. `0x2c1f` another request is pending;
    8. `0x2c0e` the leader is offline.
    
    On success the entry is marked pending, the requester's state byte becomes 1, and a job waits
    **15 s** (SM `0x79b018`; backstop answer 2, SM `0x420e10`).
- **`server/internal/session/partymatch.go`**, the GameServer's half:
  - **`0x7069`/`0xb069` register.** It runs `CParty::CheckCanCreateForMatch` (GS `0x514170`):
    - `0x2c09` not alive;
    - `0x2c24` a state byte other than 0 or 2;
    - `0x2c0a` level < 5 when in no party, `0x2c1d` not the leader when in one.
    
    Then the purpose rule `0x2c23` (GS `Party_PostRequest` kind 0xa -> `Party_UserMatches`), then
    the Matcher. The success echo carries the entry with the assigned number (GS
    `trs_sm_partyjob::vslot_002 0x46d3a0` reads it into the request's `+0x54`, which
    `0x5bf7d0` writes back) and the requester's party id (GS `0x5bf3ed`).
  - **`0x706a`/`0xb06a` change** (GS `0x514260`): `0x2c09`; `0x2c1d` in a party but not its
    leader; `0x2c1c` no own entry. Then the purpose rule, then the Matcher. The echo is the
    client's entry with the party id overwritten (GS `0x5bf870`).
  - **`0x706b`/`0xb06b` delete** (GS `0x5142c0`): `0x2c09`; `0x2c1c` no own entry. The echo is the
    number the client sent (GS `0x5bf900`, the request's `+0x24`).
  - **`0x706c`/`0xb06c` list**: no GameServer check; the reply is the Matcher's page.
    - Each row carries the owner's name and race, where race is the model's Country (SM
      `0x44f640`, `char+0x250`), via `character.RaceOf(Gender)`.
    - The member count is the owner's party size, or 1 without a party.
  - **`0x706d` join request.**
    - The GameServer's ladder runs first (GS `0x514300`), in this order:
      - `0x2c12` the requester is in a party;
      - success when the state byte is 0 and there is no exclusive interaction;
      - `0x2c1f` with state 1 or 3;
      - `0x2c25` with state 4;
      - `0x2c06` otherwise.
      
      A dead character may ask: the life test accepts 1 or 2.
    - Then the Matcher. A refusal from either half is `0xb06d [2][code]`.
    - On success the leader gets the relayed `0x706d`: job id, requester JID, entry, the two
      masteries, job state 4 and the requester's full record.
  - **`0x306e`**, the leader's answer, resolved as SM `0x44fbe0` and the GameServer's kinds
    0x11, 0xf and 0x10 do:
    - **0 cancel, 2 no reply**: the requester gets `0xb06d [1][answer]`.
    - **1, the requester gone**: the leader gets `[2][0x2c0f]`.
    - **1, the entry gone**: `[2][0x2c1c]` to both.
    - **1, a party-less entry**: a party of the leader and the requester with the entry's flags,
      the leader first (SM `0x44e9c0` -> `0x44e100`). The requester gets `0xb06d [1][1]`
      **twice** (see the correction below), then `announceFormed`.
    - **1, an entry with a party**: the requester and then the leader get `0xb06d [1][1]`, then
      `announceJoined`.
    - **an accept that fails**: `[2][code]` to the requester and to the leader (SM tail
      `0x44fe3b`).
  - **Disconnect**: `PartyMatchDisconnectHandler` withdraws a party-less owner's entry and clears
    a pending requester's state. It runs after `PartyDisconnectHandler` (whose removal moves a
    leader's entry, as SM `0x4296f0` does) and before `WorldDisconnectHandler`, which removes the
    session's character (fixed in review, findings 6 and 7).
  - **Expiry**: `RunPartyMatchSweep` deletes, every 60 s, each entry with no pending request that
    is more than 60 whole minutes old, telling nobody (SM `0x4504c0`; added in review, finding 1).
- **Wiring**: `cmd/server/main.go` builds a `party.Matcher` over the party Hub, adds the handler
  after `PartyHandler` and the disconnect hook before `worldDisconnect`.
- **`cmd/partybot`**:
  - `-mode match`, this round's acceptance run;
  - `-mode bot -register` (list an entry) and `-request NAME` (ask to join NAME's entry once it
    is on page 0). In bot mode, party-match join requests are answered by `-accept`.

## S1 files touched

- `server/internal/party/party.go` (9 lines):
  - a `requests` field on `Hub` and its init;
  - one test in `stateLocked`: a pending join requester is state 1. The GameServer writes 1 when
    it forwards the request (GS `0x5bf570`) and 0 when it fails (GS `0x5bfac0`,
    `MsgHandler_3c01`).
  
  The new `Hub` methods (`ListingOwner`, `setRequest`, `clearRequest`) live in `match.go`.
- `server/internal/systems/orphans_test.go`: twelve round-710 orphan entries removed, because
  they now have callers. `PartyByID` and `ItemShare` stay.
- `server/cmd/partybot/main.go`: the match opcodes added to `isParty`/`describe`, the bot-mode
  options, `-mode match`. The scenario itself is in a new file, `match.go`.
- `session/party.go`, `wire.go` and the fixtures are unchanged. Every encoder S3 uses already
  has a golden fixture: `b069_ok`, `b06b_ok`, `b06c_page`, `b06c_empty`, `706d_to_leader`,
  `b06d_*`, plus the generic `[2][code]` refusal. `0xb06a`'s success has the same layout as
  `0xb069`'s, so no fixture was added. Adding one would change the fixture count that both
  sides' tests check.

## Choices of ours (OURS), each labelled in the code

| what | choice | why |
|---|---|---|
| the job id the popup echoes | a counter that skips 0 | the ShardManager's transaction id; its numbering is its own |
| who may answer a job | only the entry's leader at request time | the engine finds the job by id and does not compare the sender; without this, anyone could accept for a party |
| the pending mark | cleared on every outcome | SM `0x44fbe0` stores 0 to `+0x34` at only three places: a party formed (`0x44ffa8`), a requester joined (`0x45029e`), and answer 0 or 2 with the requester present (`0x4504a4`). It stays set when an accept's requester is gone (`0x44fc64`), its leader is gone (`0x44fcfc`), the formation fails (`0x44ff05`), the leader's party is missing (`0x4500e6`), the join fails (`0x4501a7`), answer 0 or 2 comes with the requester gone (`0x450413`), or the answer is outside 0..2 (`0x44fc0e`). Outside `0x44fbe0` it stays set when SM `0x420e50` drops a gone leader's answer and when authorization fails (`0x421ec0`). Left set, the entry refuses every later request `0x2c1f` and is exempt from expiry |
| an answer whose requester JID is not the job's | dropped silently; the job stays pending | the check itself is READ (SM `0x421ec0`, `cmp [ebx+0x8],esi` at `0x421f3f`). The engine then releases the job and leaves the mark set; ours waits for the real answer or the backstop |
| an expired entry's owner | its state returns to 0 at once (the Hub derives it) | the engine leaves the GameServer's byte at 4 and `pc+0x1cd0` set until a relog, refusing that character `0x2c25`/`0x2c24`. A bug not replicated; on the coordinator's deviation list for the user |
| pages | built at each request from the live state | the engine serves snapshots rebuilt after each change (SM `0x451630`), so its counts can lag. Its builder can also leave an empty trailing page when the last entries are dropped as owner-gone (`[1][1][0][0]` when all were). Neither shows in normal play |
| an answer outside 0..2 | ends the job, no reply | SM `0x44fbe0` asserts and returns |
| an entry moved to a new leader before the answer | the accept is refused `0x2c1c` | the engine keeps the job's original leader (`+0x10`) and would act on that character's party state |
| the requester's two masteries | `topMasteries` (S1's choice) | the engine's pick, GS `0x5a1890`, is OPEN |
| refusals that cannot happen here | the lock (`0x2c06`/`0x2c09`), job mode with an empty alias (5), instances (`0x2c28`), `0x2c26` | OpenSRO has none of those states. `0x2c26` reads `chardata+0x13`, which is OPEN (spec) |

## Corrections to existing records

| record | says | what is true |
|---|---|---|
| `party_protocol.md`, "Party matching", the accept result | "Both requester and leader get `0xb06d [1][1]` (the leader's copy INFERRED from the second send in `0x44fbe0`)" | READ, two cases. **Party-less entry** (SM `0x44ffb3..0x4500a1`): both copies carry the **requester's** JID (`[ebx+0x78]` at `0x44ffc6` and `0x45003d`, `ebx` the requester from `0x44fc3e`). The second goes to the leader's GameServer (`[esp+0x10]+0x1c4` at `0x450081`). That server finds the requester by JID, so with one game server the requester gets it twice and the leader gets none. **Entry with a party** (`0x450333 mov ebx,[esp+0x10]`): the second copy is the leader's. **A failed accept** (`0x44fe3b`): `[2][code]` to the requester, then to the leader |
| `party_protocol.md`, "Party matching", register | the success reply carries the entry | READ: GS `trs_sm_partyjob::vslot_002 0x46d3a0` (kind 10) reads the ShardManager's u32 number into the request's `+0x54`, which `0x5bf7d0` echoes in `0xb069` and stores at `pc+0x1cd0` |
| `party_protocol.md`, "Party matching", join request | the requester's state goes to 1, the error comes back on the relay path | READ in full: a ShardManager refusal reaches the requester through `MsgHandler_3c01 0x4169d0`, which also writes the state byte back to 0 when the inner opcode is `0x706d`. A GameServer refusal never set it |
| `party_protocol.md`, Implementation lanes, S3 row | the register ladder "`0x2c1b`, `0x2c20`, `0x2c1d`, `0x2c08`, level 5" | That list is the ShardManager's half only. The GameServer's `CheckCanCreateForMatch` runs first, in its order: `0x2c09`, `0x2c26`, 5, **`0x2c24`**, then `0x2c0a` (no party) or `0x2c1d` (in a party), then `0x2c28` (GS `0x514170`); then the purpose rule `0x2c23` (GS `0x5bf2a0` kind `0xa`). The code has this order. The ShardManager's in-party order is `0x2c20`, then `0x2c1d`, then `0x2c08` |
| `party_protocol.md:231` (list entry, second u32) and OPEN 2 | "INFERRED a timestamp ... its use is OPEN" | READ: `_time32` seconds since the epoch. The expiry sweep (SM `0x4504c0`) subtracts it from `_time32` (`0x6e3cbc`; difference `0x6c1d40`) and divides by 60 (`0x6c1c40`). Only the client's use (`c:+4`) is OPEN |
| `party_protocol.md`, "Party matching" | nothing on expiry | an entry with no pending request expires after more than 60 whole minutes since its register or change (SM `0x40c703` 60 000 ms timer -> `0x40dd10` -> `0x4504c0`, `cmp eax,0x3c; jle` at `0x45055c`). The engine sends `0x386f [owner JID]` to the owner's GameServer, which has no case for it, so the client is never told |
| `party_protocol.md`, the `0x306e` row | the GameServer reads u32, u32, u8 | and the ShardManager authorizes the answer by the echoed requester JID (SM `0x421ec0`): a mismatch is dropped with no reply |
| `party_protocol.md`, "Party matching", change | change edits the caller's entry | SM `0x4513c0` looks up the number the request names: not found is `0x2c1c`, another owner's is `0x2c1d` |

## Review fixes (independent review `d73f314a`, `docs/rounds/party713_review.md`)

Applied after `git merge int/party`, which brought in S1's review fixes (`991bb1c2`). The one
conflict, in `orphans_test.go`, was resolved to the merged list. S1's `sample` now takes a
previous sample and a time; the `0x706d` record uses its `fullMask`.

| # | finding | fix | test |
|---|---|---|---|
| 1 | entries never expire | `Matcher.Sweep` and `session.RunPartyMatchSweep`: every 60 s, entries with no pending request older than 60 whole minutes are deleted silently (READ, SM `0x4504c0`). The owner's state returns to 0 through the Hub (OURS; the original leaves it stale until relog) | `TestSweepExpiresAfterSixtyWholeMinutes`, `TestMatchSweepExpiresSilently` |
| 2 | the `0x306e` requester JID is unchecked | an answer whose echoed JID is not the job's requester is dropped silently (READ, SM `0x421ec0`); the leader-only check stays (OURS); the job stays pending (OURS) | `TestMatchAnswerWithTheWrongRequesterIsDropped` |
| 3 | change ignores the number sent | `Change` looks up `e.Number`: `0x2c1c` when it is missing, `0x2c1d` when it is another owner's; the caller-has-no-entry `0x2c1c` stays first | `TestChangeLooksUpTheNumberSent`, `TestMatchChangeNamesTheEntry` |
| 4 | the pending-mark label under-counts | `TakeJob`'s comment and the OURS table list the engine's three clears and every path that leaves the mark set | (labels) |
| 5 | the second u32 is READ seconds | `Listing.Time` is relabelled READ; the spec row and OPEN 2 are in the corrections table | (labels) |
| 6 | a page could delete a logging-out leader's entry | `cmd/server` runs `partyDisconnect`, then `partyMatchDisconnect`, then `worldDisconnect`, the original's order. `rowLocked` also skips, without deleting, an owner out of the world who is still in a party | `TestPageSkipsAPartyLeaderOutOfTheWorld`, `TestMatchLeaderLogoutMovesTheEntry` |
| 7 | a requester's mark survived its logout | `Matcher.Disconnect` clears it; the job stays, so an accept answers the leader `[2][0x2c0f]` | `TestDisconnectClearsTheRequestMark`, `TestMatchRequesterLogoutClearsTheMark` |
| 8 | the leader gone answered `0x2c1c` | `[2][0x2c0f]` to the requester, before the entry lookup (SM `0x44fcf4..0x44fd5e`) | covered by the order in `resolveJoin`; reachable only by a logout racing the answer |
| 9 | the register correction's order | the corrections table now gives `gs:0x514170`'s order, which the code already had | (notes) |
| 10 | per-request pages | labelled OURS in `Page` and in the OURS table | (labels) |
| 11 | a store read per listing under the lock | `Page` takes a cheap `Online` (world hub) under the lock, and reads the race (`RaceOf`, a store read) outside it, for the sent rows only | the existing page tests |

## Self-review against the binaries

Re-read for this round, each against the decompile and, where marked, the asm:
- **GameServer**:
  - `0x514170`, `0x514260`, `0x5142c0`, `0x514300` (the four checks, orders and codes);
  - `0x514750`..`0x5148b0` (each handler replies `[2][code]` on its own `0xb06x`);
  - `0x514900` (the answer forwarder: it appends the leader's record only for answer 1 when
    party-less);
  - `Party_PostRequest 0x5bf2a0`;
  - `0x5bf570`/`0x5bf1f0` (state 1 is set only after the post succeeds);
  - `0x5bf7d0`/`0x5bf870`/`0x5bf900`/`0x5bf980`/`0x5bfac0` (the replies);
  - `0x46d3a0` (the kind-10 number);
  - `0x5beb80` and kinds 0xf `0x5bfbe0` -> `0x5bb460` and 0x10 `0x5bfc50`. The formation order
    is identical to S1's `announceFormed`, and the join order to `announceJoined`;
  - `MsgHandler_3c01 0x4169d0`.
- **ShardManager**:
  - `0x450680`, `0x451290`, `0x451110`, `0x450990`, `0x4513c0`, `0x450ba0`, `0x451490`;
  - `0x44f640` (the row);
  - `0x451630` (the pages, 23);
  - `0x450d20` (own entry first, index clamp, `[1][0][0][0]`);
  - `0x44f850` (the join ladder);
  - `0x44fbe0` (the answer: decompile and asm `0x44fc10..0x4504ab`);
  - `0x420e10`/`0x420e50` (the timeout and answer entry points);
  - `0x44e9c0`/`0x44e100` (the leader is added first: `EAX` is the first argument, the leader,
    at the call `0x44ea69`);
  - `0x44ed70`: forming a party by invitation repoints the inviter's listing, which the Matcher
    gets for free by reading the owner's party from the Hub.

No disagreement was found with the round-709 tables beyond the corrections above.

## Acceptance

**Go** (`go test -count=1 -p 1 ./...` against the local `opensro_test`; the result is at the end of
this file):
- **`internal/party/match_test.go`**, 11 tests:
  - numbering, and no reuse;
  - the register order, including flags-before-leadership;
  - change and delete;
  - pages of 23/23/4, past-the-end, own entry first, a party member seeing its leader's entry;
  - an owner gone is dropped;
  - the entry follows the leader and vanishes on dissolve;
  - the whole join ladder in order;
  - the 15 s backstop answers through its callback and clears the mark and the state;
  - an answer stops the timer;
  - Withdraw.
- **`internal/session/partymatch_test.go`**, 8 tests on the real handlers over sockets:
  - the full flow with a party-less entry: the echo, the page, the leader's `0x706d`, the double
    `0xb06d`, the formation order with the entry's flags;
  - the accept into an existing party;
  - deny, and a non-leader's answer ignored;
  - the backstop (150 ms in the test) and a late confirm ignored;
  - the join refusals (`0x2c1e`, `0x2c1c`, `0x2c25`, `0x2c1f` from both halves, `0x2c12`);
  - the register ladder (`0x2c0a`, `0x2c23`, `0x2c24`, `0x2c1d`, `0x2c20`, `0x2c08`, `0x2c1b`);
  - change, delete and the logout withdraw;
  - the race byte (Europe 1).
- `go test -race` on `internal/party` and on the session party tests (`TestMatch|TestParty`):
  clean.

**Live**, the real server binary (in memory, `-chargen-csv`, `-leveldata-csv`, the bots in
`-gm-accounts`), `partybot -mode match`: all nine steps passed. S1's `-mode scenario` still passes
all of its steps on the same server. The trace, with the login lines cut (the lines of different
bots interleave as their goroutines print):

```
--- step 1: Lia registers a party-less entry: Exp+Item Auto Share, Hunting, levels 5..20
[pmLia] <- 0xb069 [1] entry=1 party=0 flags=0x03 purpose=0 levels=5..20 "For open hunting"
--- step 2: Rex pages: Lia's entry, 1 member
[pmRex] <- 0xb06c [1] pages=1 index=0 rows=[1:pmLia(race 0, 1 members, flags 0x03, purpose 0, 5..20)]
--- step 3: Tia (level 1) asks: refused 0x2c1e, the leader hears nothing
[pmTia] <- 0xb06d [2] code=0x2c1e
--- step 4: Rex asks: Lia gets the 0x706d
[pmLia] <- 0x706d job=1 requester=pmRex(2) entry=1 masteries=0/0 job state=4 level=10
--- step 5: Sam asks while Rex's request is pending: refused 0x2c1f
[pmSam] <- 0xb06d [2] code=0x2c1f
--- step 6: Lia confirms: Rex gets 0xb06d [1][1] twice, then the formation with the entry's flags
[pmRex] <- 0xb06d [1] outcome=1
[pmRex] <- 0xb06d [1] outcome=1
[pmRex] <- 0xb067 [1] jid=2
[pmLia] <- 0xb060 [1] jid=1
[pmLia] <- 0x3065 party=1 leader=1 flags=0x03 members=[pmLia(1)]
[pmRex] <- 0x3065 party=1 leader=1 flags=0x03 members=[pmLia(1) pmRex(2)]
[pmLia] <- 0x3864 k2 joined pmRex(2)
--- step 7: Sam pages: Lia's entry now shows 2 members
[pmSam] <- 0xb06c [1] pages=1 index=0 rows=[1:pmLia(race 0, 2 members, flags 0x03, purpose 0, 5..20)]
--- step 8: Sam asks and Lia never answers: the 15 s backstop gives Sam 0xb06d [1][2]
[pmLia] <- 0x706d job=2 requester=pmSam(3) entry=1 masteries=0/0 job state=4 level=10
[pmSam] <- 0xb06d [1] outcome=2
--- step 9: Lia deletes the entry: 0xb06b [1][entry]; Rex's page no longer has it
[pmLia] <- 0xb06b [1] entry=1
[pmRex] <- 0xb06c [1] pages=0 index=0 rows=[]
--- all steps passed
```

`-mode bot -register -accept` against `-mode bot -request` was also run: the request, the
confirm, and the party formed.

No perf gate: this is a server-only round. An independent review is the coordinator's: this lane
is a fork and cannot spawn one.

## For lane C2 (the client matching window)

- **Expiry.** An entry expires silently after 60 minutes without a register or change (review
  finding 1). The client still holds its number (`this+0x7c0`); a later change or delete of it
  gets `0x2c1c`.

- **The page.**
  - The requester's own entry (or its party leader's) is row 0 **and** appears again in its
    numbered place; skip the second copy, as `c:0x73a770` does.
  - Rows come in entry-number order, 23 to a server page against the window's 12 rows; the
    scroll covers the rest (`party_gui.md` §3).
- **Race** is 0 China / 1 Europe, drawn as text "CHN"/"EUR" (the user's decision). **Count** is
  the party size, 1 without a party; draw `%d/8` or `%d/4` by flag bit 0.
- **A party-less entry's accept** gives the requester `0xb06d [1][1]` twice, and the leader no
  `0xb06d` at all. The leader learns of the join from the formation (`0xb060`, `0x3065`, kind 2).
  An accept into an existing party gives the leader `0xb06d [1][1]` too. The client shows
  `UIIT_MSG_PARTYMATCH_JOIN_COMPLETE_MASTER` for each `[1][1]`, as `c:0x8847d0` does.
- **The popup's answer** must echo the `0x706d`'s job id and requester JID. The server takes an
  answer only from the entry's leader, and only while the job is pending: a late answer after
  the 15 s backstop is dropped.
- **Timers.** The leader's popup answers 2 at 10 s and the requester's bar fills at 10 s; both
  are client-side. With a stock client, "no reply" arrives at about 10 s. The server's 15 s only
  covers a leader client that sends nothing.
- **Register echo.** `0xb069 [1]` carries the assigned entry number: keep it as the player's
  registration (`this+0x7c0`). Change and delete send it back.
- **No server-side search.** Name, purpose and level filtering is the client's, over the held
  rows.
- **Entries that drop.** An entry whose party fills is not removed by the server; the leader's
  client deletes it (`UI_PARTY::FUN_007387c0`). An entry also goes when its party dissolves or its
  party-less owner logs out.
- **Live tests.** Use `partybot -mode bot -name X -register [-accept=false]` as an entry owner,
  or `-request NAME` as a requester.

## Full suite

`go test -count=1 -p 1 ./...` in `server/`: all 65 packages with tests pass (exit 0).

After the review fixes (merged with `int/party`): `go test -count=1 -p 1 ./...` passes all 65
packages again; `go test -race` on `internal/party` and on the session party tests
(`TestMatch|TestParty`) is clean; and on a fresh build of the server, `partybot -mode match`
passes all nine steps and S1's `-mode scenario` all of its steps.
