# Round 710, lane S1: the party server core on the original's opcodes

The first implementation round of the party epic, built against round 709's three specs
(`docs/protocol/party_protocol.md`, `party_rules.md`, `party_gui.md`). Server only: lane C1
rewrites the client side at the same time, against the same golden fixtures.

## What was done

- **Golden byte fixtures** (milestone 1, commit `fd9da906`):
  - 57 payloads in `client/scripts/net/fixtures/party/`: every S1 message in both directions, the
    member record with each mask (field and dungeon positions), and the S3/C2 party-match records
    (`0x7069`, `0xb069`, `0x706a`-`0x706d`, `0xb06c`, `0x306e`, `0xb06d`);
  - `gen_fixtures.py` builds them straight from the spec tables, independently of either codec.
    The README lists every field value and the id decision below.
- **`internal/party` rebuilt** on the original's rules:
  - the flags byte, with the cap of 8 or 4 by bit 0 alone and `0x2c13`/`0x2c14` for full;
  - leader at index 0, then join order;
  - a party is formed from an accepted invitation with two members at once; there is no party
    of one any more;
  - a party of two dissolves when one leaves, and leadership passes to the longest-standing member
    with the leader's listing;
  - the person-to-person job table `0x2c23` (no job = 4, 0 matches nobody) and the
    person-to-purpose table for S3;
  - the state byte, derived;
  - invitations with the 30 s timeout (`0x2c10`);
  - party ids from a counter that skips 0;
  - formation and join refusals in the ShardManager's order.
- **`party/wire.go`**: every codec. The two HP/MP formulas are both READ and differ:
  - a full record's tenths are `trunc(cur/max x 10)` (GS `0x5baf96`);
  - an update's (GS `FUN_005bb0c0`) are `0` for 0 HP, else `1 - ftol(float32(r) x -10.0)`, i.e.
    `1 + trunc(10 r)`, which is **11 at full HP**. MP is `ftol(float32(r) x 10)`. Re-read in asm
    this round (`fmul QWORD 0xb45f78` = -10.0, `_ftol2` `0x9fbb40` = `cvttsd2si`).
- **`session/party.go` rewritten** on retail opcodes:
  - `0x7060`/`0xb060`: CheckCanCreate (alive, busy plus state, level 5), a self-target dropped
    silently, the 600-unit 3D range, the PC test, CheckTargetAvailable, then `0x3080` kind 2;
  - `0x7062`/`0xb062`: CheckCanJoin, whose first three tests fail silently; the full cap;
    range/PC/availability; and the `0xb060 [2][2]` quirk when posting fails;
  - the `0x3080` answer: a decline gives `0x2c0c`/`0x2c17`, a gone inviter `0x2c0e`, a timeout
    `0x2c10`. Each goes out to both sides, the inviter on `0xb060`/`0xb062` and the invitee on
    `0xb067`;
  - formation and join announced in the GameServer's order. The inviter gets `0xb060 [1][own JID]`,
    then a `0x3065` of itself, then the invitee's kind 2. The invitee gets `0xb067 [1][own JID]`,
    then the `0x3065` of both. A joiner's existing members get kind 2 before the joiner's
    `0x3065`;
  - `0x7061` leave (reason 2) and `0x7063` kick (reason 4, leader only, silent otherwise). Kind 3
    goes to every member, the leaver too; kind 9 goes out when the leader left; kind 1 `0x2c0b`
    when a party of two dissolves;
  - logout: reason 1 to the rest;
  - **kind 6 member updates**: level, HP/MP, position, guild, masteries, name and model, sent to
    every member but the one updated, each only when it changed.
  - OpenSRO's `0x0080`-`0x0089` party messages are retired.
- **Party chat**: delivered to every member, the sender included, and nobody else (GS `0x5bef50`
  excludes no one).
- **`cmd/partybot`**: characters on the real wire against a running server. `-mode scenario` is
  this round's acceptance. `-mode bot` keeps one character online as the other side of a live
  client test.
- **Callers converted** from the removed `Create`/`Join` to `Form`/`Add`: chat, friendlycast,
  round666, nest660, uniquenotice, monsterai and partyexp tests; `uniquenotice.go` (the party id
  is now u32). Test behaviour is unchanged: every converted party is exp-shared, as OpenSRO's
  parties were.

## Choices of ours (OURS), each labelled in the code

| what | choice | why |
|---|---|---|
| **JID and world id** | `uint32(characterID)` for both | It is already the u32 object id OpenSRO sends for a player (`motion.go`'s `0x30BF`). A client maps a party JID to the spawned player whose 64-bit `CharacterID` has those low 32 bits, and learns its own from `OpSelfID` (0x00F9). Monster ids overlap character ids, so a party target is resolved among players only; an NPC uid (>= `0x7f000000`) answers 3; anything else that names no player answers 0. **Consequence:** a monster id sent as a target names the player with that character id, and if that player is in the same zone within 600 units, that player is invited; retail answers 3 there (the `0x26` TypeID filter, `gs:0x4a8eb2`). The client must send player ids only |
| world id in the record | 1 | `_RefGame_World` `INS_DEFAULT` (EXTERNAL); one field world |
| masteries shown | the two highest-levelled above level 0, lower id first on a tie, 0 when empty | The engine's pick `GS 0x5a1890` is OPEN. A new character shows none, as screenshot 08 does |
| member-update cadence | a 1 s sampler (`partyUpdateInterval`) | Retail raises an event at each change (`vslot_323`), and how often position fires is OPEN. Each field still goes out only when it changed. HP/MP is evaluated only when a raw HP/MP/max moved since the last sample, standing in for the HP event. Without that, a full record's HP 10 would turn into the update formula's 11 with nothing having happened |
| logout trigger | the gateway's disconnect, reason 1 | Reason 1 is READ; retail's trigger is the ShardManager's user cleanup (`SM 0x4296f0`) |
| a stale answer | an answer with no invitation pending is dropped | Nothing names its inviter any more |
| accepting a formation | only an answer byte of 1 accepts, for both kinds | This GameServer accepts a formation on any non-zero byte (`test bl,bl`, `gs:0x5be41c`; a join on `cmp bl,1`, `0x5be39f`), which would make the stock client's "no" (`[2][0x2c0c]`) form the party (`party.DecodeAnswer`) |
| "state not 1" on an answer | refused 2 when the invitee got into a party meanwhile | the only way the derived byte leaves 1 with an invitation pending |
| an invitee who leaves the world | its invitation no longer holds it; the timeout still runs and reaches the inviter (`Hub.DetachSession`) | Whether the original's logout cancels the transaction was not read. READ: the transaction finds both sides by id at its answer and its timeout (`gs:0x5be350`, `0x46ce44 -> 0x46cec0`), and the state byte lives in the character object a relog replaces |
| a race past the ladder | a second invitation slipping past `CheckTargetAvailable` is refused `0x2c1f` | what the single-threaded engine's ladder would have said |
| guild and masteries in the sampler | re-read every 10 s (`partySlowRefresh`); a join reads them fresh | the engine announces them on their events (0x10, 0x20); two store reads per member per second saved |
| a zone with no region frame | the record carries no position (mask without `0x20`) | rather than region 0 with world coordinates cut to u16; no zone hits it today |
| refusals that cannot happen here | the slot-0x244 test (`0x2c19`), the character lock (`0x2c06`/`0x2c09`), arena opponents (`0x2c28`) | OpenSRO has none of those states. The exclusive interaction (INTERACTMODE) is `trade.Hub.Busy` |
| state byte | derived, not stored | It agrees with the writers' table for every single invitation |

## Acceptance

**Go:**
- `internal/party`:
  - every encoder against the 57 fixtures, and the decoders reading them back;
  - truncated payloads refused;
  - both HP/MP formulas;
  - the cap per flag combination;
  - formation and join refusals in order;
  - the full job and purpose tables;
  - dissolution at two, succession and the listing following it;
  - the invitation timeout, an answer racing it, and a stale timer not dropping a newer
    invitation;
  - the listed states;
  - party ids skipping 0;
  - concurrency under `-race`.
- `internal/session` (real TCP through the gateway, five characters):
  - formation in the GameServer's order;
  - the create ladder: level 4 `0x2c0a`, self silent, nobody 0, an NPC uid 3, 601 units 4,
    exactly 600 in range, an invited target `0x2c1f`, an inviter with an invitation out `0x2c1f`,
    another party's member `0x2c18`;
  - decline for both kinds;
  - timeout, with a late yes forming nothing;
  - the cap of 4 refusing `0x2c14`, a member's invite dropped without bit 2 and accepted with it;
  - kick, leave, succession and dissolution;
  - logout with reason 1;
  - the answer after the inviter left, `0x2c0e`;
  - kind-6 updates (position only; nothing to the member itself; nothing when unchanged);
  - party chat to members including the sender, not to others.
- `go test -count=1 -p 1 ./...` against local `opensro_test`: green (every package `ok`).

**Live, the real server binary** (in memory, `-chargen-csv`, `-leveldata-csv`, the bots in
`-gm-accounts`), `partybot -mode scenario`: all ten steps passed. The trace, with the login lines
cut:

```
--- step 1: Aria invites Bram to a non-shared party (flags 0x02)
[pbBram] <- 0x3080 kind=2 inviter=1 flags=0x02
--- step 2: Bram accepts: the GameServer's order on both sides
[pbAria] <- 0xb060 [1] jid=1
[pbBram] <- 0xb067 [1] jid=2
[pbAria] <- 0x3065 party=1 leader=1 flags=0x02 members=[pbAria(1)]
[pbAria] <- 0x3864 k2 joined pbBram(2)
[pbBram] <- 0x3065 party=1 leader=1 flags=0x02 members=[pbAria(1) pbBram(2)]
--- step 3: Cato and Dara join (the party fills to 4)
[pbCato] <- 0x3080 kind=3 inviter=1 flags=0x02
[pbBram] <- 0x3864 k2 joined pbCato(3)
[pbAria] <- 0x3864 k2 joined pbCato(3)
[pbCato] <- 0xb067 [1] jid=3
[pbCato] <- 0x3065 party=1 leader=1 flags=0x02 members=[pbAria(1) pbBram(2) pbCato(3)]
[pbDara] <- 0x3080 kind=3 inviter=1 flags=0x02
[pbDara] <- 0xb067 [1] jid=4
[pbDara] <- 0x3065 party=1 leader=1 flags=0x02 members=[pbAria(1) pbBram(2) pbCato(3) pbDara(4)]
(and kind 2 Dara to Aria, Bram, Cato)
--- step 4: Eli is refused by the cap: 0xb062 [2] 0x2c14
[pbAria] <- 0xb062 [2] code=0x2c14
--- step 5: Party chat reaches the four members, the sender included, and not Eli
[pbDara] <- chat type=4 from=pbBram "pull"   (and Bram, Aria, Cato; Eli nothing)
--- step 6: Aria kicks Dara: kind 3 reason 4 to all four
[pbDara] <- 0x3864 k3 left jid=4 reason=4    (and Aria, Cato, Bram)
--- step 7: Aria leaves: kind 3 reason 2, then kind 9 Bram (the longest-standing)
[pbCato] <- 0x3864 k3 left jid=1 reason=2    (and Bram, Aria)
[pbCato] <- 0x3864 k9 leader jid=2           (and Bram)
--- step 8: Cato leaves the party of two: kind 1 dissolved to both
[pbCato] <- 0x3864 k1 dissolved code=0x2c0b  (and Bram)
--- step 9: Dara forms an exp-shared party with Eli and Aria joins; Aria moves; Eli logs out
[pbEli] <- 0x3080 kind=2 inviter=4 flags=0x01
[pbDara] <- 0xb060 [1] jid=4
[pbDara] <- 0x3065 party=4 leader=4 flags=0x01 members=[pbDara(4)]
[pbDara] <- 0x3864 k2 joined pbEli(5)
[pbEli] <- 0x3065 party=4 leader=4 flags=0x01 members=[pbDara(4) pbEli(5)]
[pbAria] <- 0x3065 party=4 leader=4 flags=0x01 members=[pbDara(4) pbEli(5) pbAria(1)]
[pbEli] <- 0x3864 k6 update jid=1 mask=0x20  (and Dara; Aria nothing)
[pbDara] <- 0x3864 k3 left jid=5 reason=1    (and Aria)
--- all steps passed
```

- **Job mismatch** could not be run live: OpenSRO has no job mode, so every character is a 4. The
  unit tests cover the whole table and both refusal paths (Form, Add).
- **No perf gate**: this round is server-only.

## What C1 must know

- **The client's party messages are dead from this round on.** `client/scripts/net/party.gd`'s
  `0x0080`-`0x0089` get no answer, so World3D's debug party panel and `OPENSRO_QA_PARTY` do
  nothing until C1 lands. Merge S1 and C1 together (the plan releases them as a pair).
- **Party chat now echoes to the sender.** The client must drop a type-4 line carrying its own
  name, as retail's `c:Chat_OnChatUpdate 0x877810` case 4 does. Today `World3D._on_chat_update`
  would show it twice.
- **Ids.** The client's own JID is the low 32 bits of `OpSelfID`'s character id. A member or
  inviter is the spawned player whose `CharacterID & 0xffffffff` equals the JID. Send a player's
  id as the `0x7060`/`0x7062` target, not a monster's.
- **HP/MP tenths: two decodes** (READ in the client, round 710's second review).
  - A full record (`0x3065`, kind 2) carries `trunc(10 r)` per nibble. Draw HP n/10 and MP n/10
    (`push 0xa; push 0xa` before `c:0x99a2e0`).
  - A kind-6 update calls `c:0x991f60(jid, hp, 10, mp, 10)`. An HP nibble of 0 means dead (the
    flag at `+0x60`, HP 0). Any other HP nibble n draws as (n-1)/9 (`c:0x991fd1 lea ecx,[ebx-1]`,
    `lea edx,[ebp-1]`), so the server's full-bar 11 is 10/9; whether the gauge clamps that was not
    traced. MP is n/10.
- **Fixtures** are in `client/scripts/net/fixtures/party/`. `README.md` lists every value.

## Second review (independent, `party710_review2.md`) and its fixes

| # | finding | fix |
|---|---|---|
| 1 | the answer tested the decline before the inviter | `handlePartyAnswer` follows `gs:0x5be350`: inviter gone `0x2c0e`, state not 1 → 2, then the decline (`TestPartyAnswerAfterTheInviterLeft` covers yes and no) |
| 2 | "1 accepts" was READ only for kind 3 | labelled OURS with the `test bl,bl` evidence in `wire.go` and `party_protocol.md`; test that `[2][0x2c0c]` declines |
| 3 | a join re-filed every member's record | only the joiner's record is built; the others come from the book (`TestPartyJoinKeepsOthersPendingUpdates`) |
| 4 | pickup rights ignored the item-share bit | `samePartyFunc` requires `Flags.ItemShare()` (`TestPartyFlagGates`) |
| 5 | the gap bonus and nest arming reached free-for-all parties | `inPartyWithOthers` (their only gate) requires `Flags.ExpShare()`; one line, lane S2's rewrite supersedes it |
| 6 | the C1 note on HP/MP was incomplete | the two client decodes above; OPEN 8 closed in `party_protocol.md` |
| 7 | a kind 6 could follow a kind 3/1 | the sampler re-checks membership before each send and sends to the live member list |
| 8 | a race answered 2 | answered `0x2c1f` |
| 9 | no-frame zones sent region 0 | the position bit is left out (`TestPartyPositionWithoutAFrame`) |
| 10 | three store reads per member per second | guild and masteries cached 10 s (OURS) |
| 11 | an invitation outlived its invitee | `Hub.DetachSession` (OURS, `TestPartyInviteeDisconnectFreesIt`) |
| 12 | the monster-id consequence was unwritten | written into the ids row above |
