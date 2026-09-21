# `SetCharacterState`, and the interaction state at `chardata + 6`

Round 360 named `chardata + 4` (the character lock, `docs/protocol/char_lock.md`)
and left the byte beside it unread. This is that byte, plus the dispatcher that
owns it.

Recovered 2026-09-21 (round 361). Everything below is from the server dump.

## The dispatcher

`CGObjPC::SetCharacterState` (`0x004f0ad0`) is **vtable slot 171**, named in an
earlier pass from the base class's own assert (`IGObj::SetCharacterState`). It is
not a setter for one field — it is a switch on a **state-kind code**, and the
kind selects which field of the character record gets written:

| kind | what it writes |
|---|---|
| 2 | `chardata + 6` — the interaction state, below |
| 3 | `chardata + 7` — the pending-invitation byte (`docs/protocol/party.md`) |
| 6 | `chardata + 8`, as an `int` |
| 7 | `GObjPC::FUN_004e2940(value)` |
| 8 | `GObjPC::SetBattleState()` |
| 9 | `chardata + 0xe` |
| 10 | `FUN_004e0b20()` |
| 0xb | `FUN_004e0b50(value, 0xff, 0, 0)` |
| 0xc | `chardata + 0x11` |
| 0xd | `FUN_004e0c20()` |
| 0xf | falls through to the tail |
| anything else | `Assert_BreakIfDebugger` |

The tail, reached only by kind `0xf`, refreshes a float through vtable `0x4b0`
when the value is 1 or 2 and then calls `FUN_004e0db0`.

**Kind 3 is independent corroboration of rounds 356–359**: this dispatcher, read
without reference to the party work, writes the same `chardata + 7` that the
invitation state machine turned on.

## The kind-2 field: an exclusive-interaction state

`chardata + 6` is an enum, not a flag. Values 0, 1, 2, 4, 5, 6, 7 and 9 all
appear, and roughly forty sites read it — trade, stall, open market, storage,
shop, siege, guild summon, party, academy and item use all gate on it. It says
which mutually-exclusive activity currently owns the character.

| value | meaning | what settles it |
|---|---|---|
| 0 | idle — nothing has the character | `GObjPC_HandleShopMsg_046` refuses to open a shop unless it is 0; `TrainingCamp_CheckCanEnter` likewise |
| 1 | trade session **opened** | `CTradeMgr::OpenTradeSession` writes 1 to **both** parties; `CTradeMgr::EstablishTradeSession` requires 1 |
| 2 | trade **established** | `EstablishTradeSession` writes 2; `CTradeMgr::Exchange` requires **both** parties at 2; equip attach/detach refuse |
| 9 | open market / consignment | all six `COpenMarketMgr::On*Req` handlers require 9 |

Values **4, 5, 6 and 7 are read but NOT named.** What is known about each:

- **7** — refused alongside 2 by `GObjPC_StorageManipulator::AttachEquipItem` and
  `DetachEquipItem` (`== 2 || == 7`), and `CGItemEquip::vslot_301`/`vslot_302`
  gate on it. So it is a second state in which the character's items are
  committed elsewhere, like an open trade. Which one is unread.
- **5 and 6** — both written by `GObjPC_HandleShopMsg_046` from a switch on an
  NPC type byte: cases 2 and 10 give 5, case 12 and the default give 6, and case
  0x23 sets nothing. **That NPC type vocabulary is not grounded in this repo** —
  the `TypeID4` tables in `ITEM_FORMAT.md` are for items, not NPCs — so naming 5
  and 6 from it would be a guess. Readers requiring 5: `FUN_00510660`,
  `FUN_005107c0`, `FUN_0051b370`. Requiring 6: `FUN_00511f40`, `FUN_005243d0`,
  `FUN_00526ce0`.
- **4** — written by `FUN_00515e90` beside 2 and 0; `CGObjPC::vslot_293` refuses
  when it is not 4.

## The writers of 7 and 9 are not in the direct-write set

Stated because it is a gap and not an oversight. Every direct assignment to
`chardata + 6` in the dump writes 0, 1, 2, 4, 5 or 6 — **nothing writes 7 or 9**,
yet six open-market handlers require 9 and four gates test 7.

The candidate path is `AJStateChanger::vslot_002` (`0x00405f70`), which writes
the byte from a *job* field rather than a literal:

	*(undefined1 *)(*(int *)(*(int *)(param_1 + 8) + 0x30) + 6)
	  = *(undefined1 *)(param_1 + 0xd);

So 7 and 9 most likely arrive through that asynchronous state-change job, whose
`+0xd` is filled by whoever queues it. **This is a lead, not a finding** — the
queuing sites were not traced.

## Also seen, not pursued

The slot-171 call sites are dominated by a large **`QNO_*` family** — scripted
quest objects with `OnEnterWorld`, `OnLeaveWorld`, `OnDead` and `OnUpdate`
handlers, already carrying the binary's own names (`QNO_CA_GORIA_7`,
`QNO_EU_IVY_3`, `QNO_TQ_BAEKRYOUNG_17`, …). They call kinds `0xd` and `0xf`, not
kind 2. That family belongs to the quest epic
(`docs/protocol/quest_*`), and is recorded here only so the next round does not
rediscover it.

## For srrevamp

**Nothing to wire yet.** srrevamp has no player-to-player trade, no stall and no
open market, so it has no second activity that could own a character. The value
of this round is that ~40 gates which read an unexplained byte now read a named
one, and that when trade is built, this is the state machine it has to match:
`OpenTradeSession` writes 1 to both sides, `EstablishTradeSession` moves both to
2, and equipment changes are refused from 2 onward.
