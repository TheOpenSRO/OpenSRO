# Party golden fixtures (round 710)

The party and party-match messages, byte for byte. One file per case: the
**payload only**, without the packet header, as whitespace-separated hex. An empty
payload (`7061_leave.hex`) is an empty line.

The layouts are `docs/protocol/party_protocol.md`'s (round 709), READ in the client's
parsers and senders and in the GameServer and ShardManager. `gen_fixtures.py` builds
every file from those tables, written independently of either codec. Two test suites
check against these files:
- Go: `server/internal/party/wire_test.go`, for `server/internal/party/wire.go`;
- GDScript: lane C1's tests, for `client/scripts/net/party.gd`.

So the server and the client cannot drift apart, and neither can drift from the spec
unnoticed. Change a layout here (in `gen_fixtures.py`) only when the spec changes.
Then rerun `python3 gen_fixtures.py`, which also rewrites the table below.

## Ids (OURS, round 710)

- **JID.** A member's id in every party message is its JID: vtable slot 2 `GetJID` in
  retail. **OpenSRO's JID is the low 32 bits of the character id**,
  `party.JIDOf(characterID) = uint32(characterID)`.
- **The world id a client selects a player by** is the same u32. OpenSRO already puts
  it on the wire for players: the retail `0x30BF` state change carries
  `uint32(CharacterID)` as the object id (`server/internal/session/motion.go`).
- **Party targets.** The `0x7060`/`0x7062` target and the `0x3080` inviter are that
  same u32.
- **Mapping a party JID to a spawned player.** OpenSRO still spawns players with its
  own `OpEntityEntered` (0x0023), which carries a 64-bit `CharacterID`. A client finds
  the player for a party JID (or an inviter id) as the spawned player whose
  `CharacterID & 0xffffffff == JID`. That is the same as `CharacterID == JID` for every
  character id the database hands out (positive, below 2^31).
- **Not unique across kinds.** OpenSRO's monster ids (`combat.Hub`, counting from 1)
  and ground-item ids overlap the character ids. The server therefore resolves a
  `0x7060`/`0x7062` target **among players only**. The client must send a player's id:
  the selected character itself, or the owner of a selected pet, as retail's sender
  substitutes. NPC uids start at `0x7f000000` (`npcspawn.UIDBase`), above every
  character id.
- **World id in the member record** (bit `0x20`'s last u32; retail vtable slot 5
  `GetWorldID`). OpenSRO sends **1** for the one field world (OURS).
  `_RefGame_World`'s first row, `INS_DEFAULT`, is id 1 in the user's shard export
  (EXTERNAL).

## Field values used

The characters every case uses:

| field | Aria | Bram |
|---|---|---|
| JID | 101 | 201 |
| name | `Aria` | `Bram` |
| RefObjID | 1907 | 1908 |
| level | 10 | 7 |
| HP/MP byte | `0x5a` (HP 10, MP 5) | `0xaa` |
| region | `0x61a8` (97/168) | `0x61a8` |
| x, y, z | 1002, 30, 1020 | 990, 31, 1011 |
| world id | 1 | 1 |
| guild | (empty) | `Wolves` |
| job state | 4 (no job) | 4 |
| masteries | 257, 258 | 0, 0 |

- **The dungeon variant** is Aria in region `0x8001` at 70000, -5, 12, written as u32 each.
- **The third character** in the invite cases is 301.
- **Party fields:** party id 7; match entries 12 and 15; job id `0x41`.

Strings are a u16 length and the bytes. All integers are little-endian.

<!-- cases -->
| file | opcode | dir | bytes | case |
|---|---|---|---|---|
| `7060_create_exp_item.hex` | 0x7060 | C->S | 5 | create + invite target 201, flags 0x03 (exp share, item share) |
| `7060_create_all.hex` | 0x7060 | C->S | 5 | target 201, flags 0x07 (exp, item, anyone may invite) |
| `7060_create_ffa.hex` | 0x7060 | C->S | 5 | target 201, flags 0x00 (both free-for-all: a 4-member party) |
| `b060_ok.hex` | 0xb060 | S->C | 5 | inviter's ack: [1][own JID 101] |
| `b060_err_too_far.hex` | 0xb060 | S->C | 3 | refused: target out of range, bare code 4 |
| `b060_err_low_level.hex` | 0xb060 | S->C | 3 | refused 0x2c0a, creator below level 5 |
| `b060_err_post_failed.hex` | 0xb060 | S->C | 3 | the 0x7062 quirk: posting failed, [2][2] on 0xb060 |
| `b060_err_timeout.hex` | 0xb060 | S->C | 3 | invitation timed out, 0x2c10 |
| `7062_invite.hex` | 0x7062 | C->S | 4 | invite target 301 into my party |
| `b062_err_full_exp.hex` | 0xb062 | S->C | 3 | refused 0x2c13, exp-shared party full |
| `b062_err_full_ffa.hex` | 0xb062 | S->C | 3 | refused 0x2c14, non-shared party full |
| `b062_err_declined.hex` | 0xb062 | S->C | 3 | the invitee declined a join invitation, 0x2c17 |
| `3080_invite_new.hex` | 0x3080 | S->C | 6 | invitation kind 2 (form a party) from 101, flags 0x03 |
| `3080_invite_existing.hex` | 0x3080 | S->C | 6 | invitation kind 3 (join my party) from 101, flags 0x07 |
| `3080_answer_yes.hex` | 0x3080 | C->S | 2 | yes: [1][1] |
| `3080_answer_no_form.hex` | 0x3080 | C->S | 3 | no to a kind-2: [2][0x2c0c] |
| `3080_answer_no_join.hex` | 0x3080 | C->S | 3 | no to a kind-3: [2][0x2c17] |
| `b067_ok.hex` | 0xb067 | S->C | 5 | invitee's ack: [1][own JID 201] |
| `b067_err_timeout.hex` | 0xb067 | S->C | 3 | invitation timed out, 0x2c10 |
| `b067_err_mismatch.hex` | 0xb067 | S->C | 3 | formation refused, job mismatch 0x2c23 |
| `7061_leave.hex` | 0x7061 | C->S | 0 | leave: no payload |
| `7063_kick.hex` | 0x7063 | C->S | 4 | kick member JID 201 |
| `record_full_aria.hex` | (record) | both | 40 | Aria's full record, mask 0xff |
| `record_full_bram.hex` | (record) | both | 46 | Bram's full record, mask 0xff (guild Wolves, no masteries) |
| `record_full_dungeon.hex` | (record) | both | 46 | Aria in dungeon region 0x8001: x, y, z as u32 (y = -5) |
| `3065_two_members.hex` | 0x3065 | S->C | 97 | party 7, leader 101, flags 0x03, Aria then Bram (full records) |
| `3065_one_member.hex` | 0x3065 | S->C | 51 | party 7 as the inviter first sees it: leader 101, flags 0x03, Aria alone |
| `3864_k1_dissolved.hex` | 0x3864 | S->C | 3 | kind 1, party dissolved, code 0x2c0b |
| `3864_k2_joined.hex` | 0x3864 | S->C | 47 | kind 2, Bram joined (full record) |
| `3864_k3_logout.hex` | 0x3864 | S->C | 6 | kind 3, 201 left, reason 1 logout |
| `3864_k3_left.hex` | 0x3864 | S->C | 6 | kind 3, 201 left, reason 2 secede |
| `3864_k3_kicked.hex` | 0x3864 | S->C | 6 | kind 3, 201 left, reason 4 booted |
| `3864_k6_hpmp.hex` | 0x3864 | S->C | 7 | kind 6, 101's HP/MP: mask 0x04, byte 0x5b (HP step 11, MP 5) |
| `3864_k6_level.hex` | 0x3864 | S->C | 7 | kind 6, 101 reached level 11: mask 0x02 |
| `3864_k6_position.hex` | 0x3864 | S->C | 18 | kind 6, 101 moved: mask 0x20, region 0x61a8, 1100, 30, 900, world 1 |
| `3864_k6_position_dungeon.hex` | 0x3864 | S->C | 24 | kind 6, 101 in dungeon region 0x8001: u32 coordinates |
| `3864_k6_guild.hex` | 0x3864 | S->C | 14 | kind 6, 101 joined guild Wolves: mask 0x40 |
| `3864_k6_masteries.hex` | 0x3864 | S->C | 14 | kind 6, 101's masteries 257 and 259: mask 0x08 |
| `3864_k6_name_model.hex` | 0x3864 | S->C | 16 | kind 6, 101's name and model: mask 0x01, Aria, 1910 |
| `3864_k6_hpmp_level.hex` | 0x3864 | S->C | 8 | kind 6, two fields at once: mask 0x06, level 11 then HP/MP 0xab |
| `3864_k9_leader.hex` | 0x3864 | S->C | 5 | kind 9, the new leader is 201 |
| `7069_register.hex` | 0x7069 | C->S | 30 | register: entry 0, party 0, flags 0x03, purpose 0 hunting, levels 1..110, title 'For open hunting' |
| `b069_ok.hex` | 0xb069 | S->C | 31 | registered: [1] entry 12, party 7, flags 0x03, purpose 0, 1..110, title |
| `706a_change.hex` | 0x706a | C->S | 20 | change entry 12: purpose 1 quest, levels 5..20, title 'Quests' |
| `706b_delete.hex` | 0x706b | C->S | 4 | delete entry 12 |
| `b06b_ok.hex` | 0xb06b | S->C | 5 | deleted: [1][12] |
| `706c_page.hex` | 0x706c | C->S | 1 | list page 0 |
| `b06c_page.hex` | 0xb06c | S->C | 71 | page: [1] 3 pages, index 0, 2 rows: entry 12 Aria race 0 2 members flags 0x03 purpose 0 1..110; entry 15 Bram race 1 1 member flags 0x00 purpose 2 20..40 |
| `b06c_empty.hex` | 0xb06c | S->C | 4 | no entries: [1][0][0][0] |
| `706d_request.hex` | 0x706d | C->S | 4 | join request for entry 12 |
| `706d_to_leader.hex` | 0x706d | S->C | 67 | request shown to the leader: job 0x41, requester 201, entry 12, masteries 257/258, job 4, Bram's full record |
| `306e_confirm.hex` | 0x306e | C->S | 9 | leader confirms: job 0x41, requester 201, answer 1 |
| `306e_closed.hex` | 0x306e | C->S | 9 | the popup's 10 s timer: answer 2 |
| `b06d_joined.hex` | 0xb06d | S->C | 3 | [1][1] joined |
| `b06d_refused.hex` | 0xb06d | S->C | 3 | [1][0] refused by the leader |
| `b06d_noreply.hex` | 0xb06d | S->C | 3 | [1][2] no reply |
| `b06d_err_level.hex` | 0xb06d | S->C | 3 | [2][0x2c1e] level outside the entry's range |
| `3068_expendable.hex` | 0x3068 | S->C | 10 | Bram got 5 of item 62 (an expendable) |
| `3068_other.hex` | 0x3068 | S->C | 9 | Aria got item 3617 (equipment): u8 1 |
| `3068_gold.hex` | 0x3068 | S->C | 16 | Bram got 1234 gold (item 1, 8-byte amount, OURS) |
<!-- /cases -->
