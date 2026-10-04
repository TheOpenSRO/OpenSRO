# Round 713 review (S3, party matching)

**Who reviewed.** An independent adversarial reviewer, not the lane. The review covers commit
`6ae2044e` (`int/party..worktree-agent-a608c950056157d6c`). Every claim below was read in the
binaries on the render box, not taken from the specs or the lane's notes:
- ShardManager: `/var/tmp/decomp_shardmgr`, plus a fresh `objdump -d -M intel` of
  `/var/tmp/party709a/SR_ShardManager.exe` (md5 `5f18dae8...`, the same as the `/opt/sro-files`
  copy) into `/var/tmp/r713rev/sm.asm`;
- GameServer: `/var/tmp/decomp_server` and `/var/tmp/srgs.asm`.

No code was changed in this review.

## Findings, most severe first

### 1. DEPARTURE: listings never expire. The ShardManager deletes an entry 60 minutes after it was registered or last changed

- **Where:** `server/internal/party/match.go`, the `Matcher` (l. 94-123). It has no sweep, so an
  entry lives until it is deleted, its party dissolves, or its party-less owner logs out.
- **Evidence (READ):**
  - SM `0x40c703..0x40c729` registers the callback `0x40dd10` on a **60 000 ms** timer
    (`mov DWORD PTR [esp+0x1c],0xea60`). `0x40dd10` calls `0x4504c0` on the party manager.
  - `0x4504c0` walks every entry:
    - it skips an entry whose pending mark `+0x34` is set (`0x450536 cmp [ebx+0x34],0`);
    - otherwise it takes `now - entry+0x30` in seconds. `now` comes from `0x6e3cbc` (time, via
      `GetSystemTimeAsFileTime`), and the subtraction is `0x6c1d40`:
      `mov ecx,[ecx+0x24]; sub ecx,[edx+0x24]`;
    - it divides by 60 (`0x6c1c40`, the magic `0x88888889`, `sar 5`);
    - it expires the entry when the result is **> 60** (`0x45055c cmp eax,0x3c; jle`), so at an
      age of 61 whole minutes or more.
  - For an expired entry it does three things:
    - sends `0x386f [u32 owner JID]` to the owner's GameServer (`0x4505c2..`);
    - deletes the entry through `0x451490`, the same delete `0x706b` uses;
    - rebuilds the pages (`0x451630`).
  - **The GameServer has no `0x386f` case.** Its ShardManager dispatch (`gs:0x414402..`) has a
    table for `0x3809..0x3864` (`sub ecx,0x3809; cmp ecx,0x5b; ja 0x4146e7`), then tests
    `0x38e9`. Nothing else in the GameServer encodes `6f 38` as an immediate.
  - So `0x386f` falls to the default `0x409cd0`, which treats the message's trailing u32 (here
    the JID) as a transaction id. The owner's client is never told. The GameServer's `pc+0x1cd0`,
    and for a party-less owner the state byte 4, are left stale.
- **Fix:**
  - Add the sweep: every 60 s, delete each listing with `!Pending && (now-Time)/60 > 60`. Clear
    the Hub listing too, and send nothing to the client.
  - Decide, and label, what the owner's state does afterwards:
    - **retail:** a party-less owner stays at state 4 until relog. It is refused `0x2c25` on a
      request and `0x2c24` on a register, and its change or delete gets `0x2c1c` from the
      ShardManager;
    - **the Hub-derived state** returns to 0. That is OURS and should say so.

  This is the user's call. Tell lane C2: an expired entry silently drops off the pages, and the
  client still holds its number (`this+0x7c0`).

### 2. DEPARTURE: the requester JID in `0x306e` is never checked; the engine authorizes the answer by it

- **Where:** `server/internal/session/partymatch.go:329`
  (`jobID, _, answer, err := party.DecodeJoinAnswer(data)`). The requester JID is discarded.
- **Evidence (READ):** the path of the answer:
  - The GameServer forwards `0x306e` as `0xbc00`: `[u32 job][u32 requester JID][u16 0xb06d][answer...]`
    (`gs:0x4168f0`, the three `0x404090` appends at `0x416962..0x416984`).
  - SM `0xbc00` -> `0x4107e0` -> `0x421f70` finds the job by its id, then **authorizes** the
    answer in `0x421ec0`. It reads the u32 JID and the u16 message id, and accepts only if:
    - the JID is the job's requester (`0x421f3f cmp [ebx+0x8],esi`, job `+8` = "RegisterJID"),
      or the JID is in the job's target list (`0x420850`). A `0x706d` job's target list is empty:
      in `0x44f850` only the `0x7d1b` branch calls the add, `0x420750`. So for a join request
      the JID must be exactly the requester's; and
    - `job+0xc == (msgid & 0x3fff | 0x4000)` (`0x421f44`).
  - When the check fails the engine logs `"Authorizing Overlapped Job Failed!! ..."` and releases
    the job (vslot `0xc`) with no reply.
  - The engine does not compare the *sender*, so the lane's sentence "does not compare the
    sender" is true. But the echoed requester JID is checked.
- **Live (probe P2):** rvG answered `0x306e [job 7][requester 12345][0]` to rvQ1's request. The
  server accepted it and rvQ1 got `0xb06d [1][0]`. The original would have dropped that answer.
- **Fix:**
  - Keep the OURS leader check, and add `requester == party.JIDOf(job.Requester)`.
  - On a mismatch, ignore the answer. Label what happens to the job: the binary releases it and
    leaves the mark set; ours can leave it pending for the real answer or the backstop.
  - Add a session test with a wrong JID.

### 3. DEPARTURE: change (`0x706a`) edits the caller's own entry and ignores the entry number in the request

- **Where:** `server/internal/party/match.go:209-229`. `Change` takes the number from the Hub's
  listing for the caller (l. 212), so its `0x2c1d` (l. 220-222) can never fire.
- **Evidence (READ):**
  - SM `0x450990` refuses `0x2c1c` when the caller holds no entry (`char+0x24c == 0`), then calls
    `0x4513c0` with the request's entry.
  - `0x4513c0` looks up **the number the client sent**. At `0x4513c7 mov ebx,eax`, `ebx` is the
    request's entry, and the map find `0x49e1a0` keys on `[ebx]` (`0x49e1b0 mov edi,[ebx]`).
  - Not found is `0x2c1c` (`0x451402`). An owner (`+0x2c`) other than the caller is `0x2c1d`.
  - The GameServer echoes the client's entry (`gs:0x5bf870`; kind `0xb` copies `+0x54` to
    `+0x24`).
- **Live (probe P1):** rvG sent `0x706a` naming rvH's entry 5, then entry 9999, which does not
  exist. Both times rvG got `0xb06a [1]` echoing 5 and 9999, and rvG's own entry was the one
  changed. The original refuses `0x2c1d` and `0x2c1c`.
- **Fix:**
  - Keep the "no own entry" `0x2c1c` test.
  - Then look up `m.listings[e.Number]`: missing is `0x2c1c`, an owner that is not the caller is
    `0x2c1d`, and different flags are 5.

### 4. WRONG-LABEL: where the engine leaves the pending mark set is under-counted

- **Where:**
  - `server/internal/party/match.go:496-501`, the `TakeJob` comment;
  - `docs/rounds/party713.md:123`;
  - the brief's "two paths".
- **Evidence (READ, asm of `0x44fbe0`):** there are only three stores to `+0x34`:
  - `0x44ffa8`, a party formed;
  - `0x45029e`, a requester joined;
  - `0x4504a4`, answer 0 or 2 with the requester present.

  The mark is **not** cleared when:
  - an accept's requester is gone (`0x44fc64`);
  - an accept's leader is gone (`0x44fcfc`);
  - the formation fails (`0x44ff05`);
  - the leader's party is missing, `0x2c0d` (`0x4500e6`);
  - the join fails (`0x4501a7`);
  - answer 0 or 2 comes with the requester gone (`0x450413 test`);
  - the answer is outside 0..2 (`0x44fc0e`).

  Outside `0x44fbe0` the mark is also left set when:
  - SM `0x420e50` drops the answer because the leader is offline (it never calls `0x44fbe0`);
  - the authorization in finding 2 fails.

  A stuck mark also exempts the entry from expiry (finding 1).
- **Fix:** keep the OURS choice, which is well justified, but correct the comment and the notes'
  table to the list above. The claim "clears it on every answer that finds the requester" is
  wrong.

### 5. WRONG-LABEL: the second u32 of a list row is READ as Unix seconds, not OURS

- **Where:**
  - `server/internal/party/match.go:64-67`;
  - `docs/rounds/party713.md:120`;
  - `docs/protocol/party_protocol.md:231` ("INFERRED a timestamp ... its use is OPEN").
- **Evidence:** the expiry sweep (finding 1) subtracts `entry+0x30` from the current `time()`
  and divides by 60 to get minutes. `0x6e3cbc` is the CRT `_time32`: it calls
  `GetSystemTimeAsFileTime`, subtracts the 1601-to-1970 offset
  (`add 0x2ac18000` / `adc 0xfe624e21`), and divides by 10 000 000. So the field is `_time32` seconds since the epoch, and the
  ShardManager uses it to expire entries. Only the client's use (`c:+4`) is still OPEN.
- **Fix:** relabel it READ (cite `sm:0x4504c0`, `0x6c1d40`, `0x6c1c40`), and update the spec
  row and spec OPEN 2.

### 6. RACE: a page request can delete a party's entry while its leader is logging out

- **Where:**
  - `server/internal/party/match.go:381-385`: `rowLocked` deletes the listing and calls
    `ClearListing(owner)` when `info` fails;
  - `server/cmd/server/main.go`, the disconnect order: `partyMatchDisconnect`, then
    `worldDisconnect`, then `partyDisconnect`.
- **Evidence:**
  - Between `worldDisconnect` and `partyDisconnect`, a party leader is out of `world.Hub` but
    still in the party, and still holds the listing.
  - A `0x706c` from any other session in that window drops the entry. Then `Hub.Remove` finds no
    listing to pass to the new leader. The entry is lost instead of following the leader.
  - In the original, logout (SM `0x4296f0`) runs the party removal `0x44f580` first, which moves
    the entry (`0x44e1a0`). Only then does it reach the entry (`0x451590`, an owner-JID compare).
    The pages are pre-built, so there is no window.
  - `world.Hub` only loses a character on disconnect (`session/world.go:1138`), so this is
    narrow but real.
- **Fix:** when `info` fails but the owner is still in a Hub party, skip the row without
  deleting it, or run the party removal before `worldDisconnect`.

### 7. DEPARTURE (MINOR): a requester who logs out mid-request comes back still "pending"

- **Where:**
  - `server/internal/session/partymatch.go:443-453`;
  - `server/internal/party/match.go:153-163`.

  `Hub.requests` is only cleared by `TakeJob`.
- **Evidence:** the GameServer's state byte lives on the character object, which is rebuilt on
  login.
- **Live (probe P4):** rvQ4 asked to join rvG's entry, logged out before any answer, and logged
  back in. Asking to join a *different, fresh* entry then gave `0xb06d [2][0x2c1f]`, and
  registering gave `0xb069 [2][0x2c24]`. A level-1 character in the original gets past the
  GameServer on the request, and gets `0x2c0a` on the register. The window lasts until the
  answer or the 15 s backstop (about 10 s with a stock leader client).
- **Fix:** in `PartyMatchDisconnectHandler`, clear the request mark of a disconnecting requester.
  Leave the job, so an accept resolves as "requester gone" (`[2][0x2c0f]` to the leader).

### 8. MINOR: an accept whose leader is gone answers `0x2c1c`, where the engine answers `0x2c0f`

- **Where:** `server/internal/session/partymatch.go:403` (`!ok || !lok || owner != job.Leader`
  -> `0x2c1c`).
- **Evidence:** SM `0x44fcf4..0x44fd5e`. With the requester present and the leader gone, the
  requester gets `[2][0x2c0f]`, before the entry lookup at `0x44fd8e`.
- **Reachability:** almost unreachable here, because the OURS leader-only check means the accept
  comes from the leader's own session. A logout racing the answer can still reach it.
- **Fix:** `if !lok { toRequester(EncodeRefusal(CodeInvalidUser)); return }` before `Get`.

### 9. MINOR: the register correction lists the GameServer's checks out of order

- **Where:**
  - `docs/rounds/party713.md:136`, which says "(level 5, `0x2c24`, `0x2c1d`)";
  - the brief, which says "`0x2c0a` level 5, `0x2c24` state byte, `0x2c1d` not leader".
- **Evidence:** `gs:0x514170` runs, in order:
  1. `0x2c09`;
  2. `0x2c26`;
  3. 5;
  4. **`0x2c24`**;
  5. then `0x2c0a` (no party) or `0x2c1d` (in a party);
  6. `0x2c28`.

  The purpose rule `0x2c23` (`gs:0x5bf2a0` kind `0xa`) comes after. **The code has this right**
  (`partymatch.go:91-108`), and the test `reg("Bram")` -> `0x2c24` checks it.
- **Fix:** when the S3 row is corrected in `party_protocol.md`, write the code's order.

### 10. MINOR (should be labelled OURS): pages are built per request, while the engine serves pre-built pages

- **Where:** `server/internal/party/match.go:314-367`.
- **Evidence:** SM `0x451630` builds the pages only after a change. It is called from register,
  change, delete, the answer, the withdraw and the sweep. `0x450d20` serves those snapshots.
  Two effects:
  - **member counts:** a page between changes shows the snapshot's counts and owners. Ours are
    live;
  - **a trailing empty page:** the builder also closes a page when its remaining-entry counter
    reaches 0, with no rows (`if (bStack_1d == 0x17 || iStack_18 == 0)`). When the last entries
    are dropped as owner-gone, the engine therefore has an empty trailing page, or
    `[1][1][0][0]` when every entry was dropped. Ours computes `ceil(valid/23)` and answers
    `[1][0][0][0]`.

  Neither is visible in normal play.
- **Fix:** label it OURS in the `Page` comment.

### 11. MINOR (cost): every page request reads the database once per listing, inside the Matcher lock

- **Where:**
  - `server/internal/session/partymatch.go:240-254`: `rowInfo` calls `Chars.GetByID` for the
    race;
  - `server/internal/party/match.go:323-330`: `Page` builds a row for **every** listing, not only
    the page's, while holding `m.mu`.
- **Evidence:** every register, request, answer and backstop waits behind N database reads per
  `0x706c`.
- **Fix:** store the race on the `Listing` at register (the owner cannot change race), or read
  it outside the lock. Build rows only for the page.

## The departures the lane chose, judged

| choice | verdict |
|---|---|
| only the entry's leader may answer | **Justified and labelled OURS.** The engine does not compare the sender (GS `0x514900` and SM `0x420e50` read none of it). It does check the echoed requester JID, which we skip: finding 2 |
| the pending mark cleared on every outcome | **Justified.** The engine's stuck mark refuses every later request `0x2c1f` and blocks expiry forever. The label understates how often the engine leaves it set: finding 4 |
| an answer outside 0..2 ends the request silently | **Matches the engine** apart from the mark. `0x44fc0e` asserts and returns. Then `0x421f70` releases the job, with no reply: the target list is empty (`0x420830()==0`), which leads to vslot `0xc`. Correctly described |
| an accept after the entry moved to a new leader is refused `0x2c1c` | **Justified and labelled.** The engine would form a party around the old leader and repoint the entry to it (`0x44ffa0 mov [edi+0x28],esi; mov [edi+4],[esi]`). The entry's owner (`+0x2c`) is then in a different party, a corrupt state that a later delete refuses `0x2c0d` |
| the second u32 is Unix seconds | **The value is right, but it is READ, not OURS:** finding 5 |
| the job-id counter | **Acceptable OURS.** The client only echoes it. The engine's id is the transaction's own (`0x423130`/`0x4207c0`, not read further) |

## Verified correct

- **The claimed spec change (item 3 of the brief) is a correct reading, not a misread register.**
  - In `0x44fbe0`, `ebx` is written once, at `0x44fc3e mov ebx,eax` (the requester, from
    `job+8`), and not again until `0x4500ad`.
  - Both party-less sends load `[ebx+0x78]`, at `0x44ffc6` and `0x45003d`. The first goes to
    `[ebx+0x1c4]`, the second to `[[esp+0x10]+0x1c4]` (`0x450081`, the leader's server; `esp+0x10`
    is stored at `0x44fc5a`).
  - The GameServer's kind `0x11` (`gs:0x5bfac0`) finds the character by the JID in the message
    (`0x485dc0`). With one GameServer the requester therefore gets `[1][1]` twice and the leader
    gets none.
  - With an existing party, `0x450333 mov ebx,[esp+0x10]` reloads the leader for the second copy.
  - A failed accept's second copy goes to the leader (`0x44ff8f mov esi,[esp+0x10]; jmp
    0x44fe3b`, which skips the `0x2c1c` store at `0x44fe33`, so the leader gets the same code).
- **Join ladder, all nine steps in order:**
  - GS `0x514300`:
    - `0x2c06` locked;
    - 3 when the life state is neither 1 nor 2;
    - `0x2c12`;
    - success at state 0 with `+6 == 0`;
    - `0x2c1f` at state 1 or 3;
    - `0x2c25` at state 4;
    - `0x2c06` otherwise.
  - SM `0x44f850`:
    - `0x2c18`, `0x2c25`, `0x2c1c`;
    - `0x2c14 - (flags & 1)`;
    - `0x2c1c` when the leader is gone (`0x44e500`);
    - `0x2c23` (`0x44ed20`), then `0x2c23` again (`0x44f7f0`);
    - `0x2c1e`, with the range inclusive;
    - `0x2c1f` (`+0x34`);
    - `0x2c0e` (owner `+0x2c` not found);
    - then the mark is set, and the job targets `+0x2c` with the 15.0 s float.
- **Register ladder:**
  - SM `0x450680`: `0x2c1b` (`+0x24c`), then in a party `0x2c20` (party `+8` against the entry's
    flags), then `0x451110`: `0x2c0d`, `0x2c1d` (party `+4` against the caller's JID), `0x2c08`
    (`0x44de70`, 4 or 8 by bit 0).
  - Both paths draw numbers from the counter at `manager+0x8c`, which skips 0 (`0x451290`,
    `0x44def0`).
- **Change and delete, the GameServer's half:**
  - `gs:0x514260`: `0x2c09`, then `0x2c1d` in a party but not leader, then `0x2c1c` when
    `pc+0x1cd0 == 0`;
  - `gs:0x5142c0`: `0x2c09`, then `0x2c1c`.
- **Delete, the ShardManager's half:** SM `0x451490` checks the client's number: `0x2c1c`, `0x2c1d`,
  `0x2c0d`. `0x2c0d` really is unreachable here.
- **Echoes:**
  - `0xb069`: the number from `gs:0x46d3a0` kind 10, read into `+0x54` and copied to `+0x24`,
    plus the party id (`0x5bf2a0` case 10 writes `+0x58`). The state becomes 4 when party-less,
    and `pc+0x1cd0` is set (`0x5bf7d0`);
  - `0xb06a`: the client's entry (`0x5bf870`);
  - `0xb06b`: the client's number (`0x5bf900`, request `+0x24`).
- **Pages:**
  - 23 to a page (`0x4517ed`);
  - entry-number order: the store is a std::map keyed by number (`0x49e1a0`);
  - an index at or past the page count becomes 0 (`0x450d20`, `uVar4 <= local_1a`);
  - no entries gives `[1][0][0][0]`;
  - the own entry, or a party member's leader's entry, is written first and the count is +1;
  - `0x2c0d` when that entry is missing.
- **The list row (`0x44f640`):** the count is the entry's party size (`+0x28`), or 1; the race
  byte is the owner's `char+0x250`. Field order as the golden fixture.
- **Timings:**
  - the backstop: `0x79b018` holds the bytes `00 00 70 41` = **15.0**, and the timeout calls
    `0x44fbe0(.., 2)` (`0x420e10`);
  - answer 0 or 2 is `[1][answer]` to the requester, only when the requester is present
    (`0x4503e8..0x450492`).
- **Accept outcomes:**
  - the requester gone gives the leader `[2][0x2c0f]` (`0x44fc64..0x44fcdb`);
  - the entry gone gives `[2][0x2c1c]` to both;
  - formation and join failures give `[2][code]` to both;
  - the formation order is `[1][1]` x2, then kind `0xf`; the join order is `[1][1]` to the
    requester and then the leader, then kind `0x10`.
- **Lifecycle:**
  - **An entry is not removed when its party fills.** `0x451490` has exactly three callers:
    dissolve `0x44eb30`, the delete handler `0x450ba0`, and the expiry sweep `0x4504c0`.
    `0x44e140` (join) has no entry handling. The sweep can still remove a full party's entry
    after 60 minutes (finding 1).
  - The entry follows a new leader: GS kind `0x12` (`0x5bfd80`) writes the new leader's
    `pc+0x1cd0`.
  - It vanishes on dissolve (`0x44eb30` -> `0x451490`).
  - Logout (SM `0x4296f0`) does the party removal, then the entry delete by owner JID
    (`0x451590`). Our `Withdraw`, which skips owners in a party, followed by the Hub's removal,
    has the same outcome.
  - The leader logging out mid-request: the job runs to the backstop, as in the engine (probe
    P3).
- **Lock order:**
  - The Matcher takes `m.mu` and then the Hub's lock, and the Hub never calls the Matcher.
  - The timer callback takes `m.mu` only inside `TakeJob` and calls `resolveJoin` outside it.
  - `rowInfo` takes `world.Hub`'s read lock and does database I/O under `m.mu`. That is not a
    deadlock, but it is a cost (finding 11).
  - No path found that takes `m.mu` while holding the Hub's or the world's lock.

## Runs

- `go test -race -count=1 ./internal/party/` passed (1.0 s).
- `go test -race -count=1 -run 'TestMatch|TestParty' ./internal/session/` passed (194.9 s), with
  the local `opensro_test`.
- `go test -count=1 -p 1 ./...` (`server/`): 64 packages passed. `internal/systems` failed once,
  only because my uncommitted probe directory `cmd/r713probe` was not in `server/README.md`.
  After removing it, `internal/systems` passes. All 65 pass.
- **Live**, on a fresh build of the server (`-in-memory`, `-chargen-csv`, `-leveldata-csv`,
  `-gm-accounts`) and `partybot`:
  - `partybot -mode match`: **all nine steps passed**, with the trace identical to the notes'
    (both `[1][1]` copies to Rex, the formation with flags `0x03`, the count 2, the backstop
    `[1][2]`, the delete).
  - **Own case A** (`-mode bot`): accept into an existing party on the real binary. rvA listed
    and rvB joined (party of two). Then rvC asked: rvC got `0xb06d [1][1]` and then `0xb067`
    and `0x3065` of three, rvA got `0xb06d [1][1]` then kind 2, and rvB got kind 2. As
    `0x450333` reads.
  - **Own case B** (`-mode bot -accept=false`): rvD listed and denied rvE (`[1][0]`). rvF then
    asked the same entry and got the popup and `[1][0]` too, so the pending mark was cleared
    after a deny.
  - **Probes P1-P4** (a scratch client built from `partybot`, not committed):
    - P1: finding 3;
    - P2: finding 2;
    - P3: the leader disconnected mid-request. A third character's page no longer had the entry,
      and the requester got `0xb06d [1][2]` (the backstop);
    - P4: finding 7.
