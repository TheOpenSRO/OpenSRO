# Round 709, lane party709a: the party wire protocol (spec, docs only)

The first spec round of the party epic. This lane owned the wire protocol: every party and
party-match message in both directions, with exact byte layouts, read from the client, the
GameServer and, new this round, the ShardManager. The result is `docs/protocol/party_protocol.md`.

## What was done

- **Full decompile of `SR_ShardManager.exe`**: 16,634 functions in `/var/tmp/decomp_shardmgr` on
  the render box (DecompAll; project `/var/tmp/party709a/gh_sm`). Round 271 found that the party is
  not created in the GameServer. It lives in the ShardManager: `CPartyManager`, the `0x7866` job
  request (`sm:0x44ec50`) and `0x3864` events (`sm:0x44f3f0`), with relays to other GameServers
  through `0x7c00`.
- **The member record**, the mask-driven structure shared by `0x3065`, `0x3864` and the
  join-request popup. Exact on both sides: JID, name, RefObjID, level, HP/MP tenths (truncated),
  region and position (u32 in dungeons, u16 elsewhere), world id, guild name, job state, two
  masteries.
- **26 messages** with layouts. 0x7060-0x7063, 0x7069-0x706d, 0x306e, the 0x3080 answer and
  party chat 0x7025 are client to server. 0xb060, 0xb062, 0xb067, 0xb069-0xb06d, 0x3065, 0x3864
  (kinds 1, 2, 3, 6, 9), the 0x3080 invitation, the relayed 0x706d, 0x3068 and party chat 0x3026
  are server to client. Almost every layout is
  cross-binary exact.
- **Rules that choose the reply on the wire**, read from the ShardManager:
  - a party of two dissolves when one member leaves;
  - leadership passes to the oldest remaining member;
  - flags are fixed for the party's life: no change-type or change-leader message exists in any of
    the three binaries;
  - party-match pages hold 23 entries, with the requester's own entry prepended;
  - a join request is checked for job, level range, party full and a busy entry, and waits 15 s
    for the leader;
  - the job rules: trader and hunter together, thief only with thief, no-job only with no-job, and
    match purpose 2 = trader, 3 = thief;
  - the invitation timeout code is `0x2c10`.
- **Settled from round 359**: state byte values 3 and 4 (4 = listed in party matching without a
  party). Removal reasons 1-4 are now named (LOGOUT, SECEDE, SERVER_MIGRATION, BOOTED).
- **Corrected**: `0x7061` is leave, not a teleport. `0x06e` is the party-match leader's answer, not
  the invite answer; invitations are answered on `0x3080`. Full table in the doc.

## Gap

**None of OpenSRO's party messages is retail.** `session/party.go` and `net/party.gd` use OURS
opcodes `0x0080`-`0x0089` with name strings and 64-bit ids, have no invitation, no party types, no
member updates and no party matching. Party chat already reaches only party members; it rides
OpenSRO's own chat opcodes.

## OPEN items that block implementation

1. **The `0x3068` gold branch**: the client reads 8 bytes, this package's GameServer writes 4.
   Recommendation: follow the client.
2. **Purpose values 0 and 1.**
3. **Client-side search filtering.** The list request carries only a page byte.
4. **What the client draws from the list entry's second u32 and race byte.**
5. **How the client links a member JID to a world object.**
6. **Position update cadence.**
7. **The two timeout floats** (30.0 invite, 15.0 join request) are INFERRED seconds.

Items 2-5 belong to lane party709c.

No code changed; no perf gate (docs-only round).
