# Round 710 review (S1, the party server core)

**Who reviewed.** The lane's brief asked for a separate general-purpose review agent. This lane
ran as a forked worker, which cannot spawn agents, so this pass was done by the lane itself,
adversarially and against the binaries rather than the specs. **The coordinator should treat it
as a self-review** and run an independent one before release if one is wanted.

## Bytes against the binaries (11 messages)

Each was read in the asm or decompile of `SR_GameServer.exe` / `sro_client.exe` on the render box,
not taken from the spec:

| message | where read | result |
|---|---|---|
| member record, all masks | client reader `c:0x883620`: JID (`0x10`), name + RefObjID (`0x01`), level (`0x02`), HP/MP (`0x04`), region + 3 coords (u16, or u32 when `region & 0x8000`) + world id (`0x20`), guild (`0x40`), job (`0x80`), masteries (`0x08`), in that order | matches `party.AppendRecord`/`ReadRecord` and the fixtures |
| full-record HP/MP byte | `gs:0x5baf96..0x5bb029`: `fild cur; fidiv max; fmul [0xb45c60]` (10.0), FPU set to chop, low nibble HP, high nibble MP | matches `HPMPFull` |
| update HP/MP byte | `gs:FUN_005bb0c0`, `0x5bb0ea..0x5bb1c8`: HP is 0 when 0, else `1 - ftol(float32(r) x [0xb45f78])` with -10.0 (raw bytes `00 00 00 00 00 00 24 c0`), `_ftol2` `0x9fbb40` = `cvttsd2si`; MP is `ftol(float32(r) x 10.0)`; written only when a nibble changed | matches `HPMPUpdate`. A full bar is **11** in an update and 10 in a full record; both READ |
| `0x3065` | `gs:0x5bc650`: mask `0xff`, party id `+8`, leader `+0xc`, flags `+0x10`, count, records with mask `0xff` | matches |
| `0x3864` kind 3 and kind 9 | `gs:0x5bc390`: kind 3 (u8 3, u32 JID, u8 reason) broadcast to every local member before the removal (the leaver hears it); kind 9 only when the leader left and members remain | matches `removeMember` |
| `0x3864` kind 1 | `gs:0x5bb670`: u8 1 and the code, broadcast to every member | matches |
| `0x3864` kind 2 + `0x3065` on join | `gs:FUN_005bc210`: kind 2 (mask `0xff`) to the members already there, then add, then `FUN_005bb930` sends `0x3065` to the joiner | matches `announceJoined`/`announceFormed` |
| formation order | `gs:trs_sm_partyjob::FUN_005be710`: `0xb060 [1][inviter JID]`; add the inviter (a `0x3065` of one); `0xb067 [1][invitee JID]`; add the invitee (kind 2 to the inviter, `0x3065` of two) | matches |
| `0xb062` refusals of `0x7062` | `gs:0x514560`: full is `0xb062` `0x2c13`/`0x2c14` by bit 0 (`sete` on `count == cap`); range/type/availability go out on `0xb062`; a failed post goes out on **`0xb060`** (`0x5146bb`) | matches |
| `0x3080` answer outcomes | `gs:0x5be350`: kind 2 decline `0x2c0c`, kind 3 decline `0x2c17`, inviter gone `0x2c0e`, invitee gone 3, a failed post 2 (codes are register arguments, read in asm). Kind 2 replies on `0xb060` + `0xb067` (`0x5be9b0`); kind 3 on `0xb062` (only if the inviter is found) + `0xb067` (`0x5bea20`) | matches |
| party chat delivery | spec READ (`gs:0x5bef50`, exclusion 0) | matches `chat.go` |

## Ladder order against the binaries

- **CheckCanCreate** (`gs:0x513f90`, read in asm this round): slot-0x244 test `0x2c19`; lock
  `0x2c09`; life state not 1 `0x2c09`; a state byte other than 0/4 **and** an exclusive
  interaction `0x2c09`; level < 5 `0x2c0a`. A party pointer at that point only asserts. Matches
  `checkCanCreate`, minus the states OpenSRO lacks (documented).
- **0x7060 handler** (`gs:0x5143b0`): CheckCanCreate, then the self-target (`cmp eax,[edi+8]`)
  dropped with no reply, then range/PC, CheckTargetAvailable, post. Matches.
- **CheckCanJoin** (`gs:0x514560`): in a party; leader or bit 2; not self (all three silent); full;
  range/PC; CheckTargetAvailable; post. Matches.
- **CheckTargetAvailable** (`gs:0x514010`, read in asm): lock `0x2c06`; life not 1/2 → 3; in a party
  → `0x2c12` when it is the caller's party, else `0x2c18`; `pc+0x1cd0` (a listing) → `0x2c25`; state
  byte or interaction non-zero → 1/3 `0x2c1f`, 4 `0x2c25`, else `0x2c06`; arena `0x2c28`. Matches
  `checkTargetAvailable`.

## Races

| race | outcome |
|---|---|
| answer against timeout | `TakeInvite` and the timer callback both take the hub's lock. The timer checks the invitation's sequence number, so exactly one wins, and a stale timer never drops a newer invitation to the same target (`TestAnAnswerBeforeTheTimeoutStopsIt`). |
| two invitations to one target | the second is refused `0x2c1f` by the ladder (`TestPartyCreateLadder`). One that slips past the ladder in a race is refused by `Invite` (`ErrInvitePending`) and sent as the post failure 2. |
| leave during an invitation | a formation accepted after the inviter joined another party is refused `0x2c09` (the ShardManager's order). A join accepted after the inviter left its party adds to the party, as the ShardManager does, since it checks the party and its leader, not the inviter. |
| inviter disconnects | the invitation stays until it is answered or times out; a yes then gets `0x2c0e` (`TestPartyAnswerAfterTheInviterLeft`), the engine's code. |
| invitee disconnects | the invitation times out; the inviter gets `0x2c10`. |
| sampler against a leave | **Found and fixed:** a sample taken just before a member left could file its record again. `partyRecordBook.replace` now stores only while the member is still filed. |

## Findings

1. **Fixed: the sampler re-filed a record for a member who had just left.** See Races above.
2. **Recorded, no code change: the spec's "an invitee no longer pending gives 3" is imprecise.** In
   `gs:0x5be350` an invitee **not found** gives 3, and an invitee found **with a state byte other
   than 1** gives 2 (`edx = 2` at `0x5be370`, reaching `0x5be3fc`/`0x5be474`). OpenSRO drops an
   answer with no invitation pending (OURS, `handlePartyAnswer`), so neither code is sent. The
   coordinator may correct `party_protocol.md` step 4.
3. **Recorded: `gs:0x5bea90` resets each answered side's state byte**, 3 → 4 and anything else
   → 0. The derived state agrees, because a listed character with an invitation out goes back to
   listed.
4. **Earlier, during the build** (in the round notes): a sampler that evaluated HP/MP on every
   tick sent a spurious update right after a join, because the full record's HP 10 is the update
   formula's 11. HP/MP is now evaluated only when a raw value moved
   (`TestPartyMemberUpdates`, `TestPartyUpdateRules`).

No byte disagreement was found between the code, the fixtures and the binaries.
