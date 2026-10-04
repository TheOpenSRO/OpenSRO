# Round 716: every receiver of a share is told what it gained -- retail 0x3056, 0x304E's gold total, and the client's 0x3068 line

The party epic's follow-up to round 712, which left two gaps on the wire: a party member who never
hit a monster gained its share of EXP and skill EXP in silence (its client's gauge did not move
until the next character load), and the client could not read the Item Auto Share notice `0x3068`
the server already sent. The user's standing instruction: as close to the original as possible.
Labels: READ, INFERRED, OPEN, OURS.

## What the original does (READ, both binaries)

Full tables in `docs/protocol/party_protocol.md`, "Rewards: 0x3056 and 0x304E".

- **0x3056** is written at the end of `GObjPC_GainExpAndLevel` (CGObjPC slot 92, `gs:0x4e5250`,
  appends `0x4e583c..0x4e58fa`) and read by `Client_ApplyExpAndLevelUp` (`c:0x8a97c0`) with the
  same widths: u32 source object id, u64 EXP (signed), u64 skill EXP, u8 flags, then two optional
  training-camp blocks keyed on the flags, then a **u16 RemainStatPoint only when the call raised
  the level** (`0x4e58df`). The kill reward calls slot 92 once per receiver with the victim's unique
  id as the source (`0x4eabd2..0x4eabd5`), so **every member a kill pays gets its own 0x3056**.
  Nothing is sent when both amounts are zero (`0x4e5393..0x4e53a1`). At level 110 the EXP in the
  message is clamped to what fits (`0x4e5365..0x4e5390`).
- The client prints, type 1: `UIIT_MSG_STATE_GAIN_EXP` / `_LOSE_EXP` / `_GET_SKILL_EXP`; it floats
  the gain from the source object if it can find it (`+0x759`/`+0x75a` counters).
- **A party gold share** is told with **0x304E kind 1**, not 0x3068: the split `gs:0x5bc7f0` calls
  `CGObjPC::OffsetGold` (slot 91, `0x4e4b60`) with `(amount, 0, 0x17, 1, 1)` for every share,
  which sends `FUN_004e3fb0` kind 1: u8 1, u64 the new total, u8 show. The client (`c:0x8a70d0`)
  prints `UIIT_MSG_STATE_GAIN_GOLD` "[%d]gold gained." with the rise when shown.
- **0x3068 on the client** (`c:0x873990`): the recipient's name from the party list, the item's
  from its name key; `UIIT_MSG_PARTYGET_ITEM_EXPENDABLE` "Item [%s %d pieces]is distributed to
  [%s]." type 4 for another member (every non-gold class), `UIIT_MSG_STATE_GET_ITEM_EXPENDABLE`
  type 1 for the player's own JID, `UIIT_MSG_PARTYGET_GOLD` type 4 for gold.

## What changed

**Server**
- New `server/internal/charmsg`: the 0x3056 and 0x304E kind-1 codecs (flags always 0: OpenSRO has
  no training camp).
- `session/rewardnotice.go` + `killshare.go`: `distributeKill` sends 0x3056 to **every receiver,
  the killer included**, with the EXP its row actually rose by (`expAdded`, the level-cap clamp),
  its skill EXP, and its stat points after a level-up. OpAttackResult's own EXP tail (round 639)
  stays on the wire, so an older client still prints its line; this client no longer reads it for
  that.
- `session/grounditem.go`: gold-share members other than the picker are sent 0x304E kind 1, shown.
  **OURS:** the picker is told by OpenSRO's own pick-up reply, which already prints its line; the
  original sends the picker 0x304E too. The old comment there ("the client prints
  UIIT_MSG_PARTYGET_GOLD") was wrong: that line belongs to 0x3068's gold form, which this server
  never sends.
- `cmd/partybot`: `-mode share` now checks the 0x3056 each bot receives; bot mode gains `-kill
  SPECIES -kill-after D` (once in a party, kill one monster with a real blow).

**Client**
- New `net/reward_notice.gd` (`RewardNoticeNet`): decoders for 0x3056 and 0x304E kind 1, and the
  original's lines as static functions. `PartyNet.decode_item_notice` + `PartyState.item_notice`
  for 0x3068. `NetClient` signals `exp_gained` and `gold_total`.
- `World3D`: prints the gain lines from 0x3056 (not from the attack result any more, so the killer
  is not told twice), the gold line from 0x304E, the 0x3068 line, and refreshes the EXP gauge and
  purse from the server's stats.
- **OURS:** 0x3056's stat-point u16 and 0x3068's item class are taken from the bytes left, where
  the original runs its level arithmetic and item table (equal for every message this server
  writes); the gauge and purse are refreshed from the server rather than advanced locally.

**Fixtures** (`gen_fixtures.py`, the other 60 byte-identical): `3056_kill`, `3056_levelup`,
`3056_lose`, `304e_gold`.

## Tests

- **Go:** `charmsg` round trips; `party` wire test encodes the four new fixtures byte for byte;
  `session`: every share receiver (killer and the member who never hit) gets 0x3056 with its
  payout, a level-up carries the row's stat points, an outsider gets none, a zero award sends
  nothing, a gold-share member gets its total. `go test -count=1 -p 1 ./...`: all packages pass
  (after `DecodeGold` was explained in the orphans gate).
- **GD** (`net/reward_notice_test.gd`, 24 checks): every fixture decoded and re-encoded, the lines,
  the gold clamp, the short-packet drops, PartyState naming the 0x3068 recipient. On the box:
  `check` ALL LOAD (602 scripts), full suite 230 suites, 0 failing.
- **Live, server** (the real binary on the box, in memory, retail leveldata, the round-712
  monsters.csv with ExpToGive, `partybot -mode share -level 18`):

```
--- 2: an Exp Auto Share party of two; one member kills
[psMate] <- 0x3056 source 26 EXP 29 skill EXP 133 level-up false
[psKill] <- 0x3056 source 26 EXP 29 skill EXP 133 level-up false
    killer +29 EXP, mate +29 EXP; want both trunc(54 x 0.55) = 29
--- 3: an Exp Free-For-All party of two; one member kills
[psFfa] <- 0x3056 source 27 EXP 55 skill EXP 249 level-up false
    killer +55 EXP, idle member +0 EXP; want trunc(54 x 1.03) = 55 and 0
--- all share steps passed
```

  (The idle free-for-all member received no 0x3056, which the scenario now checks.) The scenario's
  ×0.55 check holds only for a monster fewer than 5 levels above the bots (round 712's note); at
  the default `-level 10` against level-20 chakji the party gap bonus applies and the check fails
  by design, so the run uses `-level 18`.

- **Live, client** (`/var/tmp/r716/live.sh` on the box; the stock `qa_shot.sh --server` on the shared
  lock, CLIENT_DIR `/opt/opensro-client-r716`): Bram is the rendered client, levelled to 5 so it may
  create a party, and teleported beside the partybot Killa (level 1). Bram invites Killa (the
  settings' READ defaults give type 0x05, EXP share), Killa accepts and, 8 s later, kills a
  mangnyang with a real blow. Bram never hits. Killa's log:

```
[Killa] <- 0x3080 kind=2 inviter=1 flags=0x05
[Killa] <- 0xb067 [1] jid=2
[Killa] <- 0x3056 source 25 EXP 4 skill EXP 21 level-up false
[Killa] killed MOB_CH_MANGNYANG #25 (HP 54): EXP +4, SP +21
```

  Bram's client log (`/var/tmp/r716/live/godot.log`):

```
SYSLOG [1] [9]Experience Points gained.
SYSLOG [1] [24]skill experience point gained.
World3D: 0x3056 from 25: EXP 9, skill EXP 24
```

  The member who never hit got its own share and its client printed the original's two type-1
  lines. (Bram, level 5, out-levels the level-1 killer by 4 against the same monster, so its share
  is larger.) Getting there took five attempts, each a set-up fault, none the code: the bot
  invited before Bram's `/tp` landed (refused 4, too far), the bot's `/spawn` read its own stale
  `/tp` reply (fixed: queued GM replies are drained before `-kill`), chakji is not in the hand
  roster without a monster table, a level-18 kill of a mangnyang pays 0 (so, as the original does,
  nothing is sent), and a level-1 creator is refused by the level-5 rule. Server log: no errors.
  The frames were deleted; the logs stay on the box.

## Left open

- The gain floated from the source object (`+0x759`/`+0x75a`, a log-scale bucket): not built.
- The death penalty still refreshes from stats instead of sending its negative 0x3056.
- 0x304E's other kinds (2 skill points, 3 stat points, 4 the berserk count, 0x10) are not spoken;
  the client still learns those from OpenSRO's stats reply.
- The picker of a split pick-up is told by OpenSRO's pick-up reply, not 0x304E (OURS, above).

No perf gate: a message handler and system lines, no per-frame code.
