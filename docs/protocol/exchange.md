# Exchange: player-to-player trade (round 834)

Read on 2026-10-26 from `SR_GameServer.exe` (`/var/tmp/decomp_server`, `/var/tmp/gs_dis.txt`) and
`sro_client.exe` (`/var/tmp/decomp_client`, `/var/tmp/sro_client.dis`) on the render box, and from
Media.pk2 (`resinfo\ifexchange.txt`, `resinfo\ginterface.txt`,
`server_dep\silkroad\textdata\textuisystem.txt`). `s:` is a GameServer address and `c:` a client
address. Labels: **READ** (seen in code; the address is given), **INFERRED** (the reason is given),
**OPEN**, **OURS**.

Reused, not re-derived: the request's refusal ladder (`error_codes.md`, "The trade request's codes
(round 500)"), INTERACTMODE (`character_state.md`), the `0x3080` transaction machinery
(`party_protocol.md`, `party_gui.md` §1b), the quantity box (`message_box.md`), the move-request
serializer (`held_icon.md`), the item record (`server/internal/session/iteminfo.go`,
`item_tooltip.md`) and `CanTrade` (`item_capability_flags.md`).

## Corrections from the review (exchange_verify.md, READ)

The second reading (`exchange_verify.md`) found ten claims wrong. Build from these:

- **W1** The request's first check is not silent: `0x4f0a00` (restriction slot 3) sends
  `0x3405 {u8 1, u32 packed time}` and no `0xB081`.
- **W2** Confirm and Approve test only the session's state: Confirm again at state 2 is taken again
  (everything resent), Approve again at 3 answers `{1}` again; Confirm at 3 or Approve at 2 is
  `0x181f`, which closes the session. Only the moves test the caller's own state.
- **W3 / W4** `0x1811` never sends `0x3088`: the session closes abnormally and **both players are
  disconnected** (Establish at the wrong INTERACTMODE, Approve likewise, DealIt's COS check, the
  database job). `0x181b` sends nothing; `0x1825` frees the session silently.
- **W5** For the moves, `0x3088` goes to both first and then `0xB034 {2}`; for Cancel `0x3088
  {0x182c}` comes before `0xB084 {1}`. Confirm and Approve answer `{2}` first, then close.
- **W6** The trust check's addresses: `0x997410` friend list, `0x995ed0` guild members,
  `0x996d60` union (the opponent's guild name against the allied guilds); tested friend, guild,
  union.
- **W7** `UIIT_STT_PARTY_SOMEUSER` heads only kinds 6, 7 and 8.
- **W8** The client keeps a key's first row: the exchange keys' later copies ("CHECK THE NAME!",
  "***READ***...") are not what it shows (OpenSRO: `UiTextTable.EXCHANGE_FIRST_ROW_KEYS`).
- **W9** At completion `UIIT_MSG_EXCHANGE_END` goes to the system line only; window 0xaf is
  notified too.
- **W10** 363x363 is the inner `#else`; the client uses 254x361.

The three boxes (the request popup, the item and the gold box) and where each message is shown
are read in `exchange_boxes.md`.

## 1. The wire (READ)

All little-endian. "id" is the 32-bit world (unique) id of a spawned object. Codes are u16.

### Client to server

| Opcode | Layout | Sent by | Server handler |
|---|---|---|---|
| `0x7081` request | `u32 target id` | `c:SendTradeMsg_081 0x81d790` | `s:GObjPC_HandleTradeMsg_081 0x5154e0` |
| `0x3080` answer | `u8 1, u8 answer`. 1 = accept; 0 = refuse | `c:0x81db80` (`0x81dbf7` writes the 1, `0x81dc0c` the answer) | router `s:CMainProcess::FUN_0046f2d0` reads the first u8. On 1 it calls `trs_wait_response::vslot_002 0x46cb30`, which reads the answer byte. On anything else it reads a u16 code and calls `vslot_003` |
| `0x7034` add item | `u8 4, u8 bag slot` (inventory index, 13 + bag position) | `c:0x7950b0` (0x46→0x1a: `type 4`, `+3 = slot + 13`), serializer `c:0x7923a0` case 4 writes `+3` only | op 4 → `s:CGStorage::TradeOfferItem 0x526910` |
| `0x7034` remove item | `u8 5, u8 exchange index` (0..11) | `c:0x7950b0` (0x1a→0x46: `type 5`) | op 5 → `s:0x526a50` → `s:0x480c70` |
| `0x7034` set gold | `u8 0x0d, u64 gold` | `c:0x825f50` (0x46→0x1a: `local_120 = 0xd`) | op 0xd → `s:0x526e20` → `s:0x480f30` |
| `0x7082` confirm | empty | `c:UI_EXCHANGE::SendTradeMsg_082 0x81d9a0` | `s:GObjPC_HandleTradeMsg_082 0x515820` |
| `0x7083` approve | empty | `c:UI_EXCHANGE::SendTrade_HandleExchange 0x81da40` | `s:Trade_HandleExchange 0x5158f0` |
| `0x7084` cancel | empty | `c:CIFExchange::SendTradeMsg_084 0x81dae0` | `s:GObjPC_HandleTradeMsg_084 0x5159c0` |

How the three move ops were matched to their handlers (READ): `CGObjPC::StorageOperation`
dispatches through a pointer table at `.data 0xcd3b58`. It is 8 bytes per op and is filled at
start-up by `s:0x50ce80`: op 4 = `0x526910`, op 5 = `0x526a50`, op 0xd = `0x526e20`. Op 0xa
(`0x526b00`) is the ground gold drop, and 0xb/0xc (`0x526ce0`) are the warehouse gold ops. The
guard at `s:0x50f7cd` lets **only ops 4, 5 and 0xd** through at INTERACTMODE 2 or 7
(`character_state.md`).

### Server to client

| Opcode | Layout | To | Server writer | Client reader |
|---|---|---|---|---|
| `0x3080` invitation | `u8 1, u32 requester id` (kind 1, no flags byte) | target | `s:trs_wait_response::vslot_004 0x46c8e0` (the wait is created by `GObjPC::FUN_004ea0d0` with type 1, `s:0x47f751`) | `c:0x88aa60` case 1 |
| `0xb081` | `u8 1, u32 target id` when the target accepts. `u8 2, u16 code` when refused | requester | `s:CTradeMgr::EstablishTradeSession 0x47fb41` (success). The handler's `Msg_SendTwoFieldReply` sends the refusal | `c:0x880330` |
| `0x3085` | `u32 requester id` | target, on accept | `s:0x47fb6c` | `c:0x8803f0`. It reads the u32 and does not use it |
| `0x308c` offer list | `u32 owner id, u8 n`, then n × (`u8 bag slot` **only when the receiver is the owner**, `u8 exchange index`, item record) | see §3 | `s:FUN_00480e50` → `s:FUN_0047ef00` | `c:0x8806b0` |
| `0x3089` | `u8 2, u64 gold` | the partner of the player who confirmed | `s:0x47fdb3` (byte 2 at `0x47fded`, 8 bytes at `0x47fdfc`) | `c:0x880590`. Kind 1 (`u8 index` + item record) is parsed, but **nothing in this GameServer sends kind 1**: `0x47fdb3` is the only `push 0x3089` |
| `0x3086` | empty: "the opponent confirmed" | the partner of the player who confirmed | `s:0x47fe1d` | `c:0x87fcb0` |
| `0xb082` / `0xb083` / `0xb084` | `u8 1`, or `u8 2, u16 code` | the player who sent the request | `s:0x515862` / `0x5158f0` / `0x515a19` (one byte, `mov eax,1`) | `c:0x880430` / `Trade_OnExchangeResult 0x8804a0` / `c:0x880520` |
| `0xb034` | `u8 1, u8 4, u8 bag slot, u8 exchange index`; `u8 1, u8 5, u8 exchange index`; `u8 1, u8 0x0d, u64 gold`; or `u8 2, u16 code` | the player who sent the move | `s:0x50f8ee` → `FUN_004f76e0` cases 4/5/0xd (`0x4f7a85`, `0x4f7b4b`, `0x4f7f5f`) | `c:0x87f370` → `0x87ba20` |
| `0x3087` | empty: the exchange is done | both | `s:CTradeMgr::SendItemExchangeResult 0x4807aa` (code 1) | `c:0x88bb50` |
| `0x3088` | `u16 code`: the session is closed | both | `s:0x4807b4` | `c:Storage_OnItemExchangeResult 0x880840` |
| `0x304E` kind 1 | the new gold total | each side whose gold changed | `s:CGObjPC::OffsetGold 0x4e4b60` with the send flag (`party_protocol.md` "0x304E kind 1") | — |

**The item record in `0x308c`** is the retail item record. The writer is the item's vslot 294
(`+0x498`), called with mode 1. `CGItem`'s slot (`s:0x48fb60`) calls the instance's vslot 10
(`+0x28`) with mode 1, which is `CInstanceItem::vslot_010 s:0x42e230`. COS summon items have
their own slot (`s:0x492d40`). The reader is `c:SOItem::FUN_008be4f0`. This is the layout
`AppendItemRecord` already writes (`iteminfo.go`). **The opponent sees each item's full data:**
plus, variance, durability, magic options and binding blocks for equipment, the count for
stackables, and the pet state for summon items (READ).

## 2. The server's session (READ)

`CTradeMgr` (`DAT_00d6a95c`) keeps a map of sessions keyed by a counter. The counter skips 0
(`s:0x47f6f0`). `pc+0x1cc0` holds the session's id.

| Offset | Meaning |
|---|---|
| `+0` | session id |
| `+4` | session state: 1 opened (a request is pending), 2 established, 3 both confirmed, 5 `TRADEP2P_STATE_WAIT_FOR_ASYNC_DBQUERY` (the string is at `s:0x48080d`'s log), 6 the database step is done (`s:0x480530`) |
| `+8`, `+0x48` | participant 0 (the requester) and participant 1 (the target), 0x40 bytes each |
| `p+0` | the participant's id |
| `p+0x20` | CharDBID |
| `p+0x24` | the participant's own state: 2 offering, 3 confirmed, 4 approved |
| `p+0x28` | u64 gold offered. `CTradeMgr::Exchange` overwrites it with the net delta |
| `p+0x30` / `+0x34` / `+0x38` | the bay list, its head and its count. Each entry holds `+8` the bag slot, `+9` the destination slot, and `+0x10` the u64 item DBID |

`CTradeMgr::FUN_0047fc30(expect, next, …)` checks the session state and the caller's own state.
It gives `0x181f` on a mismatch. It sets the caller's state to `next` and reports whether both
participants are now at `next`.

### 2.1 Request (`0x7081`, `s:0x5154e0`)

The ladder is in `error_codes.md` (round 500), checked again here, in this order:

1. `CGObjPC::FUN_004f0a00(1) == 1`: dropped silently.
2. vslot `0x244(0x100)` non-zero: `0x185f` REQUESTED_JOB_BLOCKED_BY_QUEST.
3. The target is yourself, is not found, or is not a PC: `3` (in category 1 the client shows
   UIIT_MSG_STRGERR_INVALID_TARGET, `c:0x7b8c9c`).
4. The requester fails `GObjPC::FUN_004ea050`. That check needs vslot `0x244(0x100) == 0`, life
   state 1, INTERACTMODE 0 and GROUPMODE ≠ 1:
   - not alive, or GROUPMODE 1: `0x181d`;
   - INTERACTMODE 2 or 7: `0x1833`;
   - INTERACTMODE 1 with the same target: dropped silently (`FUN_0047f5b0`);
   - INTERACTMODE 1 with another target: the old session is cancelled through the `084`
     handler, and the old pair gets `0x3088 [0x182c]` (`0xb084` too);
   - any other mode: `0x181d`.
5. 3-D distance not below **320.0** (`.rdata 0xb460dc`): `4`.
6. `CTradeMgr::OpenTradeSession s:0x47f620`:
   - the target fails `FUN_004ea050`: `0x181e` BUSY (so a target that is already pending,
     trading, in an NPC interaction, dead or in party setup is "busy");
   - `FUN_00481730` (a session-number collision): `0x1811`;
   - the wait cannot be made: `2`;
   - otherwise the session is made in state 1, both INTERACTMODEs are set to 1, item event log
     `0x32`/`0x33` is written, the wait is created and `0x3080 [1][requester id]` goes to the
     target.

**The requester is sent nothing on success.** The first answer the requester gets is
`0xb081 [1]` at the accept, or `0x3088` with the code.

### 2.2 Answer, timeout, establish

- The wait lasts **30 s** (`.rdata 0xb45b48`). On timeout, `OnTimeout` type 1 sends
  `0x3088 [0x1826]` TIMEOUT to both.
- Answer `[1][1]` → `EstablishTradeSession s:0x47f970`:
  - the session is gone: `0x181b`;
  - the caller is not a participant: `0x1825`;
  - the state is not 1: `0x181f`;
  - either player is gone: `0x1827` CANNOT_FIND_TARGET;
  - the distance is not below 320.0: `4`;
  - a participant is no longer at INTERACTMODE 1: `0x1811`.

  If all pass, the state becomes 2, both participants become 2 and both INTERACTMODEs become 2.
  The requester gets `0xb081 [1][target id]` and the target gets `0x3085 [requester id]`. Item
  event log `0x34` is written for each. Every failure goes to both as `0x3088 [code]`.
- Answer `[1][other]` → `0x3088 [0x1828]` TRADING_DENIED. If the responder is not alive (vslot
  `0xf8 ≠ 1`): `0x1840`. If the responder has vanished: `0x1820`.

### 2.3 Add an item (op 4)

`TradeOfferItem s:0x526910`, then `TradeMgr::OfferItemToPartner s:0x480a20`. Checks in order:

| # | Check | Code |
|---|---|---|
| 1 | bag slot < 13 (a worn slot) | `0x1806` |
| 2 | no item at the slot | `0x1809` |
| 3 | `CanTrade` (vslot `0xc4`) is 0 | `0x183a` CANNOT_BE_TRADED |
| 4 | the item's DBID is 0 | `3` |
| 5 | a COS summon item (vslot `0x54`) whose pet is summoned (vslot `0x4bc`, flag `+0x38 & 2`) | `0x18b6` COSPETERR_CANT_TRADE |
| 6 | a devil's spirit (vslot `0x470`) in its awakened period (`FUN_00498610`) | `0x18fa` NASRUN_NOT_TRADE |
| 7 | no session (`0x181b`) or the caller is not a participant (`0x1825`) (`FUN_0047f520`); then session state ≠ 2, or the caller's own state ≠ 2 (already confirmed) | `0x181f` |
| 8 | the same item (by DBID) is already in the bay | `0x182d` |
| 9 | slot < 13 again | `0x1806` |
| 10 | the bay already holds **12** | `0x1821` TRADE_BAY_FULL |
| 11 | the partner is gone | `0x1820` |
| 12 | the partner's empty bag slots (`CountEmptySlot(0xd,-1)`) < bay count + 1 | `0x1836` NOT_ENOUGH_OPPONENT_INV_SPACE |
| 13 | item vslot `0x58` non-zero (a trade good) | `0x1850` YOU_CANT_DEAL_SPECIALTY |

On success:

- the item is appended to the bay. Its exchange index is the bay count before the add, so the
  bay is packed from 0;
- `0x308c` is sent **to the owner only**: `FUN_00480e50(id, 1)` sends only to the participant
  whose id matches;
- item event log `0x36` is written;
- the item's vslot `0x508(1)` is called;
- `0xb034 [1][4][slot][index]` is sent.

The whole stack goes. The move carries no count, so a stack cannot be split here (READ: serializer
`c:0x7923a0` case 4; `TradeOfferItem` reads only `+3`).

### 2.4 Remove an item (op 5, `s:0x480c70`)

- Session or own state ≠ 2: `0x181f`.
- The bay is empty: `0x1824`.
- index ≥ count or > 11: `0x1806`.
- The partner is gone: `0x1820`.
- The entry is not found: `0x1809`.

On success the entry is erased, so later items move down one index. `0x308c` goes to the owner
only, item event log `0x37` is written, and `0xb034 [1][5][index]` is sent.

### 2.5 Set gold (op 0xd, `s:0x480f30`)

- 0 or negative: `0x1829` SPECIFY_POSITIVE_NUMBER_ONLY.
- More than **1,000,000,000** (`0x3b9aca00`): `2`.
- Session or own state ≠ 2: `0x181f`.
- The partner is gone: `0x1820`.
- More than the gold carried: `0x180f` NOT_ENOUGH_GOLD.

The value **replaces** the earlier one (`FUN_0047ee70`). Item event log `0x38` is written, and
`0xb034 [1][0xd][gold]` is sent. **Nothing goes to the partner.** The gold is not reserved: it is
checked again at the exchange.

### 2.6 Confirm (`0x7082`, `s:FUN_0047fd20`)

1. `FUN_0047fc30(2, 3)` checks the session is at 2 and sets the caller's own state to 3. When both
   are at 3, the session moves to 3.
2. `0x308c` (the confirmer's list) goes to **both** players. Each gets its own form, with or
   without the bag slots.
3. The partner gets `0x3089 [2][confirmer's gold]` and then `0x3086`.
4. The confirmer gets `0xb082 [1]`.

**This is the only time the partner learns what you offer.** Adds, removes and gold changes before
your confirm are seen only by you. A confirmed player cannot change the offer (`0x181f`). **Nothing
resets a confirmation.** The other player may keep changing an unconfirmed offer after you confirm.
You see that final offer when they confirm in turn.

### 2.7 Approve (`0x7083`, `CTradeMgr::Exchange s:0x47fe40`)

1. `FUN_0047fc30(3, 4)`. Approve is accepted only once **both** have confirmed (session state 3);
   otherwise `0x181f`. If the partner has not approved yet, the reply is `0xb083 [1]` and the
   partner is told nothing.
2. When both are at 4:
   - `trade_p2p__VerifyLoadedItemValidity` fails: `0x1841`;
   - either INTERACTMODE ≠ 2: `0x1811`;
   - nothing to exchange (no items and no gold on either side, `FUN_0043c370`): `0x1823`
     DEAL_FAIL_NON_ITEM;
   - for each side, the empty bag slots are fewer than the items coming in: `0x1841`;
   - for each side, gold + (partner's offer − own offer) < 0: `0x1841`;
   - `FUN_004801b0` gives each incoming item a destination: the **first empty bag slots from 13
     upward, in bay order**. If it fails, the log says "exchange bay corrupted!" and the code is
     `0x1841`;
   - state 5, then `CTradeMgr::DealIt s:0x4802a0`, which works in memory:
     - each side's net gold delta goes through `OffsetGold(delta, reason 0x22, send=1)`, which
       sends `0x304E` kind 1;
     - each item is popped from the giver and set at the receiver's assigned slot;
     - a COS item type (TypeID 3/2/1, TID4 1 or 2) whose receiver fails vslot `0x5dc` aborts with
       `0x1811`. The meaning of that check is OPEN;
   - `AQ_ItemXChanger::ValidateItemExchange s:0x43f3f0` posts the database job. Its strings
     include "can't trade Equiped Item!!", "given Item DBID is 0" and "nothing to exchange". If
     the job cannot be posted, **both players are disconnected** (`FUN_004df050(4)`) and `0x1811`
     is sent;
   - the second approver gets `0xb083 [1]`.
3. When the database job finishes (`s:0x480530`), the state becomes 6 and `0x3087` goes to both.
   A database failure (`AQ_ItemXChanger::vslot_008`) sends `0x1811`.

Any refusal in the list `{2, 3, 5, 0x181b, 0x1825, 0x181f, 0x1820, 0x1823, 0x1841, 0x1811,
0x181c}` (`s:FUN_00515490`), from confirm, approve or a move, **closes the session**. Both players
then get `0x3088 [code]`, after the `0xb08x`/`0xb034` refusal.

### 2.8 What closes a session (READ: the complete caller list of `SendItemExchangeResult`)

`SendItemExchangeResult s:0x4806d0` is the only function that frees a session. It has 16
callers:

| Cause | Code to both | Where |
|---|---|---|
| Cancel button, X, or a new request to someone else | `0x182c` TRADING_CANCELED_BY_USER (and `0xb084 [1]` to the canceller) | `s:0x5159c0`, `s:0x5156a3` |
| Target refuses | `0x1828` TRADING_DENIED | `s:0x46cb30` |
| Timeout (30 s) | `0x1826` TIMEOUT | `s:0x46ce20` |
| Death (INTERACTMODE 1, 2 or 7) | `0x182b` EXCHANGE_CANCEL | `CGObjPC::vslot_306 s:0x529b10`, `vslot_307 s:0x52cdb0` (the death paths, `return_scroll_cast.md`) |
| Warp, logout or disconnect | `0x182b` | `s:FUN_004def00`, from `FUN_004df050` → `FUN_004def90` (`arrival_guard.md` S3) and from `GObjPC::FUN_0050ef70`. That function sets `+0x80b` to 5, 20 or 60; INFERRED to be the logout countdown |
| Any refusal in the list above | that code | the handlers |
| Done | `0x3087` | `s:0x480530` |

- **Walking away does not close it.** No caller measures distance. Distance is checked only at the
  request and at the accept.
- A close while in state 5 (waiting on the database) is logged as "Trading Session Closed
  Abnormally". It ends in `0x182a` and **disconnects both** (`s:0x48084e`, `FUN_004df050(4)`).
- On close, both INTERACTMODEs go back to 0 before `0x3087`/`0x3088` is sent.

### 2.9 Messages that do not exist

- `0x1822` INVENTORY_FULL_DEAL_CANCEL ("Cannot trade because the inventory is full.") is never
  sent: no immediate `0x1822` appears anywhere in the server. A full inventory at approval gives
  `0x1841`, which has no client text.
- UIIT_MSG_STRGERR_EXCHANGE_BEFORE_CANCEL and UIIT_MSG_STGRERR_ITEM_EXCHANGE_FAIL have rows in the
  text table, but **no client code references them** (string-reference scan).

## 3. Flow, both sides (READ unless marked)

| Step | Requester (A) | Target (B) |
|---|---|---|
| A asks | client checks (§4.1); system line UIIT_MSG_DEAL_ASKING "Applying for a trade to [%s]."; `0x7081` | — |
| | refusal: `0xb081 [2][code]` → message in category 1 | `0x3080 [1][A]`: Confirmation popup (§4.2) |
| B accepts | `0xb081 [1][B]` → exchange mode on | `0x3080 [1][1]` → `0x3085 [A]` → exchange mode on |
| B refuses / timeout | `0x3088 [0x1828 / 0x1826]` | the same; B's popup is removed |
| Window opens | both see §4.3's opening: log "You started to exchange with [X].", plus the trust warning when X is not guild, union or friend | |
| Offer | `0x7034` 4/5/0xd → `0xb034` + own `0x308c`; the opponent sees nothing | |
| Confirm | `0x7082` → notice and log "Please check opponet user's ID, Gold, …"; `0xb082 [1]` → own grid blue, own gold greyed, button "Approve" (disabled until the opponent confirms) | `0x308c` (A's list) + `0x3089 [2][A's gold]` + `0x3086` → A's grid filled and blue, A's gold greyed; if B already confirmed, B's Approve is enabled |
| Approve | log "Waiting for other player's approval."; `0x7083` → `0xb083 [1]` → button disabled | nothing until B also approves |
| Done | `0x304E` gold; `0x3087` → inventory updated locally, window closed, log/notice "Exchanging with [X] is completed." / "Exchange of the selected item(s) succeeded." | the same |
| Closed | `0x3088 [code]` → message for the code, window closed | the same |

## 4. The client

### 4.1 Starting a request (READ)

Entry points, all ending in `SendTradeMsg_081`:

- the target menu's Exchange button (button 15, `c:0x60a280`, `trace.md`);
- the action window's Exchange (action 1006, `c:0x793b00`), also from a quick slot;
- the chat commands `UIIT_STT_CHAT_COMMAND_TRADE` "/Exchange" and `…_TRADE2` "/trade", followed by
  a name (`c:0x7adf70`, `0x7af51a`). The name is looked up (`0x9c3640`) and must be a spawned
  player.

Checks in `c:0x81d790`, in order:

1. The alchemy window (0xa8) exists and is shown: category `0x12`, code `0x5419`,
   UIIT_MSG_REINFORCERR_CANNOT_TRADE "Cannot open the alchemy window while trading.". The text is
   retail's own wording.
2. Own player byte `+0x7bc` is set: category 1, `0x1834` STORAGE_OPERATION_BLOCKED. What sets that
   byte is OPEN.
3. Target = the argument, else the selection.
4. GI`+0x508` (already in exchange mode) or GI`+0x7b4` (NPC talk open, set by `c:0x79dbd0`, cleared
   by `0x79e350`): silent.
5. The target is not found, is yourself, or is not a player (class `0xef1bc0`): silent.
6. GI`+0x509` = 1 (a request-pending flag shared with party and academy invites). Then the system
   line UIIT_MSG_DEAL_ASKING with the target's name (`0x778210`, type 5), then `0x7081`.

### 4.2 The request popup (READ, `0x3080` kind 1, `c:0x88aa60`)

- If the game option byte `+2` (`c:0x4f9d00`, CGame+0x545) is 0, the client **auto-refuses**
  with `0x3080 [1][0]` (`c:0x81db80(0)`). INFERRED: that byte is Option › Game's "Exchange Request"
  checkbox (UIIT_STT_REQUEST_EXCHANGE_SIGN), whose list entry sits between INVITE_PARTY (byte `+1`)
  and GET_WHISPER (`c:0x600353..0x6003af`).
- If the requester is not spawned as a player in B's client, the request is dropped silently.
  The server then times out after 30 s.
- Otherwise HUD request **kind 7** is queued (`c:0x6ec5d0`) with the name and id. The exchange
  window's opponent is set at once (`c:0x7b3180`).
- The popup (`c:0x644c90` case 7, `0x64602e..0x646180`):

  | Part | Text |
  |---|---|
  | caption | UIIT_STT_CONFIRM_BOX "Confirmation window" |
  | line 1 | UIIT_STT_PARTY_SOMEUSER formatted with the name |
  | line 2 | UIIT_MSG_DEAL_ASK |
  | buttons | UIIT_STT_ACCEPT / UIIT_STT_REFUSE |

  A button press reaches `c:0x797d90` case 7 → `0x81db80(answer)`.
- **The "sent you  party invite." line is retail's own text, not a private-server bug.**
  UIIT_STT_PARTY_SOMEUSER's Korean is `[%s]님이` ("[%s] has…"), the generic subject of every
  request popup. The retail English row translates it "[%s] sent you  party invite." with the
  double space, and the exchange popup prints it above UIIT_MSG_DEAL_ASK. This Media.pk2's
  textuisystem also has a private overlay block (19 columns, rows ≥ ~7400) that changes several
  of these rows (`…party invite. CHECK THE NAME!`, `Exchange request! HAVE YOU CHECKED THE NAME?`,
  `***READ***…`). The screenshots show the retail rows (first block, 16 columns, English in
  column 8).
- The popup's own timer is OPEN, as for kind 6.

### 4.3 CIFExchange (window id 0x1a / 26)

**ginterface** (READ): `GDR_EXCHANGE:CIFExchange`, frame `interface\frame\mframe_wnd_`, title
UIIT_STT_EXCHANGE "Exchange", Style 64. Rect `200,200,254,361` with both live defines
(`APPLY_EXCHANGE_UPDATE_1TH`, `UI_UPDATE_2009_FIRST`). The `#else` branch is `363×363`.

**Layout** (`resinfo\ifexchange.txt`, both defines; READ):

| ID | Name | Class | Rect | Art / text | Field |
|---|---|---|---|---|---|
| 14 | OTHER_SUBFRAME | CIFSubFrame | 9,38,236,141 | `frame\sframe_wnd_` | `+0x7c4`, opponent header (top) |
| 13 | MY_SUBFRAME | CIFSubFrame | 9,182,236,141 | `frame\sframe_wnd_` | `+0x7c0`, own header (bottom) |
| 100–111 | OTHER_SLOT_1xx | CIFSlotWithHelp | 21+36c, 72/108, 32×32 | — | `+0x7d4[12]`, index 0..11 |
| 200–211 | MY_SLOT_2xx | CIFSlotWithHelp | 21+36c, 215/251, 32×32 | — | `+0x804[12]`, index 0..11 |
| 24 / 25 | LAT_OTHER / LAT_MY | CIFLattice | 21,72 / 21,216, 216×72 | `lattice_window\com_lattice_` | |
| 22 / 23 | STRETCH_OTHER / _MY | CIFStretchWnd | 18,69 / 18,213, 218×74 | `com_lattice_outline_` | |
| 16 | STATIC_MONEYBTNOTHER | CIFStatic | 40,152,20,20 | `com_moneybutton_disable.ddj` | |
| 15 | BUTTON_MONEYBTN | CIFButton | 40,296,20,20 | `com_moneybutton.ddj` | `+0x7d0` |
| 18 / 19 | STATIC_OTHERMONEY / _MYMONEY | CIFStatic | 71,152 / 71,296 (0×0, art size) | `exchange\exc_box.ddj`, right-aligned, CR 5,4,6,4 | `+0x33b8` / `+0x33bc` |
| 13 / 14 | STATIC_OTHERGOLD / _MYGOLD | CIFStatic | 181,156 / 181,300, 24×12 | UIIT_STT_GOLD "Gold" | (IDs collide with the subframes) |
| 20 / 21 | NORMALTILE_OTHER / _MY | CIFNormalTile | 25,143 / 25,287, 204×20 | `com_bg_tile_b.ddj` | |
| 26 / 27 | LINE_OTHER / _MY | CIFStatic | 14,146 / 14,290, 226×4 | `exchange\exc_sub_window_line.ddj` | |
| 28 | NORMALTILE_BG | CIFNormalTile | 40,179,174,3 | `com_bg_tile_a.ddj` | |
| 11 | BUTTON_EXCHANGE | CIFButton | 50,328,76,24 | `com_button.ddj`, UIIT_CTL_CONFIRM | `+0x7c8` |
| 12 | BUTTON_CANCEL | CIFButton | 130,328,76,24 | `com_button.ddj`, UIIT_CTL_CANCEL | `+0x7cc` |
| 153 | USER_NAME | CIFStatic | 21,72,212,68 | `effect\icon\icon_effect1.ddj`, font 4 | `+0x33e0`, opponent name overlay, hidden at Create |
| 150 / 250 | USER_VISUAL / PLAYER_VISUAL | CIFStretchWnd | **9999**,70 / **9999**,214, 100×104 | `com_blacksquare_` | `+0x33dc` / `+0x33d8`, portraits |
| 151 / 251 | USER_NORMAL / PLAYER_NORMAL | CIFNormalTile | 9999,…, 100×104 | `com_bg_tile_e.ddj` | |
| 155 | USER_VISUAL_EFFECT | CIFStatic | 9999,70,128,128 | `exchange\ch_red.ddj`, Style 512, 9 frames in a 4×4 grid of 512×512, Speed 100, loop | `+0x33d0` |
| 156 | USER_VISUAL_TOOLTIP | CIFStatic | 9999,70,100,104 | — | `+0x33d4` |
| 152 / 252 | USER_LINE / PLAYER_LINE | CIFStatic | 9999,61 / 9999,205, 8×116 | `exchange\ch_line.ddj` | |
| 304 | TEXT_BOX | CIFTextBox | 9999,342,337,87 | — | `+0x3730`, the log |
| 303 / 302 | TEXT_BOX_FRAME_BG / _FRAME | | 9999,342 / 9999,339 | `com_bg_tile_e.ddj` / `frame\frame_msg_` | |
| 300 / 301 | TEXT_BOX_BG_1 / _2 | CIFNormalTile | 9999,315 / 9999,426 | `com_bg_tile_a.ddj` | |

`+0x` fields are from `CIFExchange::Create c:0x7b27d0` (`GetChild(id)` → field). In the slot rect
column, `c` is the column, 0..5. Every slot of both grids gets window kind 0x1a and an index of
0..11 (`0x6666f0`, `0x6667d0`).

**Retail 1.188 parks 13 controls at x = 9999:** the portraits, their tiles and lines, the red
effect, the tooltip and the whole log box. Nothing moves them: `CIFExchange` overrides no layout
slot (vtable slots 0, 1, 2, 3, 10, 12, 15, 23, 28, 43 only), and the only `0x270f` compares in
the client are unrelated (round 584 came to the same answer). So **retail shows a compact 254×361
window**: two subframes, two grids, two gold rows and the buttons at y 328. The portraits and the
log box are retail code with no visible place.

**The screenshots** come from a private server whose layout un-parks them.
MEASURED in round 836 (each screenshot is exactly 2× nearest-neighbour; the window's origin was
found by matching our render's top-left corner, score ≥ 0.955 in all four, and every control by
matching our own render of it, or by its edges):

- the window is **365 × 500** (±1 from the 2× phase);
- the subframes are **346** wide (9..355), header and grid as retail;
- the portraits (150 / 250, with 151 / 251 under them) sit at **x 247**, y 70 / 214, 100×104 —
  the file's y and size; the divider lines (152 / 252) at **x 238**, y 61 / 205;
- the log frame (302) at **10,339** 345×95, its background (303) and text box (304) at
  **14,342** 337×87 — the file's y and sizes;
- the buttons at **(96, 450)** and **(194, 450)**, 76×24;
- the red effect (155) fills only the portrait: `ch_red.ddj` (MEASURED from Media.pk2) is a 4×4
  sheet of 128×128 cells whose 9 used frames are red only in their top-left 100×104 — empty,
  empty, then alpha 51, 85, 119, 153, 119, 85, 51 (a pulse at Speed 100, 100 ms a frame). Its
  empty frames are why some screenshots show a stranger's portrait on black.

That placement is an add-on; the content is retail. **Round 836 builds it** as the Extra Settings
option "Show portraits and a log in the exchange window" (on by default, OURS): the layout above
applied as rect overrides to ifexchange.txt's own controls (`HudWindow.with_rects`), the log
strips 300 / 301 placed at x 28 (INFERRED, centred) to fill the body the frame leaves open, the
log as CIFTextBox 304 is set (READ: pitch 14 `0x638c20(0xe)`, lines from the top, no hanging
indent), the trust check showing 155 and giving 156 the warning (READ `c:0x7b399f..0x7b39d4`),
and the busts as below. A screen too small for the window at its UI scale gets the compact one.

**The busts move (READ, round 841).** Each is a `CCObjCharacter` clone (`+0x33e4` own, `+0x3588`
opponent) set up once per exchange (`0x7b3180` -> `0x7b2a20`: dressed from the body, type 0 played
with `(0, 0, 0, 0, 1.0, 1.0)`, stepped 1 ms) and then stepped every frame by the frame's
milliseconds in the window's tick (`vslot_012` `0x7b2210` -> `0xa5ac80`, the int at `0x110f7f8`,
1..3000) and rendered by `vslot_015` (`0x7b21b0` -> `0x4ffc50`): the stand clip loops for as long as
the window is open. Nothing else touches the clones, so the body's own actions and dress changes do
not reach them. OpenSRO: `PlayerPortrait.animate` (round 841's WORLD_ISSUES entry).

**Header** (`c:0x7b2d00`, READ):

- A player in normal state (vslot `0xac == 4`) gets UIIT_STT_SOMEONESITEM_GUILD "[%s - %s]'s item"
  with the name and guild. With no guild, the guild part is UIIT_STT_WITH_OUT_GUILD "Did not join
  any guild".
- Any other state gets UIIT_STT_SOMEONESITEM "[%s]'s items & goods:" with `*` + the name
  (`.rdata 0xd92240` = `*`). INFERRED: this is the job-suit alias state.
- The own header (`+0x7c0`, bottom) is built from the own player and the opponent header
  (`+0x7c4`, top) from the opponent. **The opponent is on top and you are below.**

**Opening** (`0xb081`/`0x3085` → `CIFExchange::FUN_007b2530(1)`, then `c:0x79df10(1)`):

- exchange mode GI`+0x508` = 1;
- the exchange window is shown;
- the main popup (GI`+0x728`, window 0x19) is shown on its **Inventory** tab (`0x6a1f70(0x46)`),
  and both are raised;
- the exchange window is moved to its own stored position;
- GI`+0x509` is cleared;
- `0x7b36b0` resets the window: both golds 0, flags cleared, the button set to UIIT_CTL_CONFIRM
  and enabled, the slots un-tinted.

`vslot_023 c:0x7b3790`, the show, then runs:

1. Log and system line: UIIT_MSG_EXCHANGE_START "You started to exchange with [%s]." in **orange
   `0xffffb541`**. The name comes from `0x7b31a0`, with the `*` rule.
2. `0x7b2d00`: the headers.
3. The trust check `UI_EXCHANGE::FUN_007b2270`. The opponent is trusted if it is a normal-state
   player **in your guild** (`0x997410`), **union** (`0x995ed0`) or **friend list** (`0x996d60`).
   This is **client-side only**: no server message is involved. Each side checks its own lists.
4. If not trusted, then on UIIT_MSG_EXCHANGE_DECEPTION_COMPARE ("Opponent user is not listed in
   your Guild/Union/Friend"), or UIIT_MSG_EXCHANGE_NAME_WARNING ("Opponet user's name is a
   fictitious name.") when the opponent is not in normal state:
   - the big notice is shown (`0x77b580` → `GDR_WARNING_WND` CIFNotify, window 0x23);
   - a system line is written (`0x7781b0`, `GDR_SYSTEM_MESSAGE_VIEW` 0x44);
   - a log line is written in **red `0xffff4a4a`**;
   - the red animated effect (155) is shown behind the opponent's portrait;
   - the tooltip (156) is set to the same text.

   If trusted, the effect and the tooltip are hidden. **The red portrait background in the
   screenshots is this effect.** Black frames in the 9-frame loop explain why it looks absent in
   some shots (INFERRED).
5. An open alchemy window is closed (`0x798e20(0)`).

**Portraits** (READ, `c:0x7b2a20`, drawn by `vslot_015 c:0x7b21b0`):

- each is a live 3-D render of the character's own model, cloned with its equipment
  (`0xa61c30(model+0x124, obj, …)`);
- the camera is aimed at the bone **"Bip01 Head"** (a head-and-shoulders bust);
- it is drawn into controls 250 (own) and 150 (opponent), inset by 2,2,4,4;
- the background is `com_blacksquare_` over `com_bg_tile_e`.
- READ in round 836 (`c:0x7b2a20`): the clone plays animation **0** (ANI_STAND1, `vt+0xc(0, 0,
  0, 0, 1.0, 1.0)`), reads the head bone's matrix and moves the model by (0, −h²/34, −425/h) for
  the head's height h (the doubles 17.0 at `0xda3750`, 0.5 at `0xe1b7d0`, 25.0 at `0xe1b8a0`),
  then renders through the camera object at `+0x33e8`, whose field of view was **not** read. The
  client frames the bust to the screenshots instead (OURS, MEASURED: the head mid-height, about
  39 of 104 pixels from hat to chin): `PlayerPortrait.set_framing` at distance 15, 30°, the
  target 1.0 over the head bone (the player block's READ lift), no yaw; a transparent clear so
  the red effect shows behind the model.

**Slots and the inventory:**

- **Add**, in any of these ways:
  - drop a bag item on the window (`vslot_028 c:0x7b2600`);
  - Alt+click a bag item while exchanging (`c:0x681b7a` → the window's vslot `0x70`);
  - only while you have not confirmed (`+0x7bd == 0`).

  The client checks `CanTrade` (ref `+0xa4`) and the devil's-spirit rule first. Either refusal
  shows `0x183a`/`0x18fa` (`SOItem::FUN_008baf10`). It then opens the inventory's **quantity box,
  purpose 7** (`0x6b1980`): a stack shows its count, anything else shows 1. OK sends
  `0x7034 [4][slot]` (`0x6b4627`: purpose 7 → `0x7950b0(0x46, slot, 0x1a, …)`). The count is
  shown and not sent.
- **Remove**, in either of these ways:
  - pick up an exchange slot and drop it on the inventory (`CIFInventory::vslot_028 c:0x6b5b80`,
    kind 0x1a → `0x7950b0(0x1a, index, 0x46, -1, 1, 0)`);
  - Alt+click an exchange slot. Allowed only while **neither** side has confirmed (`c:0x681de8`).

  Either way the client sends `0x7034 [5][index]`. Slots are pickable until their side confirms:
  `0xb9daf0(0)` clears `+0x64` on confirm. **Quirk:** both grids use kind 0x1a with indexes
  0..11, so dropping a picked-up *opponent* slot also sends `[5][that index]` (INFERRED; the
  server applies it to your own bay).
- **Own list refresh** (`0x308c` with owner = you):
  - every bag slot is re-enabled (`0x6b3f40(1)`);
  - the own grid is cleared (`0x7b3380`);
  - for each entry the bag slot is disabled (`0x6b3f00(slot−13, 0)`, which draws the
    `0x80000000` dim) and the item is placed (`0x7b3ad0`).

  **Offered items stay in the bag, greyed.**
- **Opponent list** (`0x308c`, other owner): the opponent grid is cleared (`0x7b3400`) and filled.
- **Gold:**
  - the gold button (id 15, map entry → `c:0x7b2500`) opens the quantity box with **purpose 8**
    (`0x6b2c30`, `icon\mini_gold_icon.ddj`), only while you have not confirmed;
  - its OK sends `0x7034 [0xd][u64]` (`0x825f50(0x46, 0x1a, gold)`). A zero amount is not sent.
    This settles `message_box.md`'s "purpose 8 = exchange gold, INFERRED" as READ;
  - `0xb034 [1][0xd][gold]` sets `_MYMONEY` (`0x7b23a0`);
  - `0x3089 [2]` sets `_OTHERMONEY` (`0x7b2350`);
  - both are coloured by magnitude (`inventory_window.md`).

**Message map** (READ, entries at `.data 0xebf098`, filled by `c:0xd71c30`):

- control 11 → `0x7b3480`;
- control 12 → `0x7b24d0` (Cancel);
- control 15 → `0x7b2500` (gold).

The X button (vslot 43, `0x7b2660`) also runs `0x7b24d0`. That handler re-enables the bag, clears
the focus and sends `0x7084`. **The window stays until `0xb084 [1]`** (hide, `0x652c00`) **or
`0x3088`**. No sound is played: there is no sound reference in any CIFExchange function.

**Button 11** (`UI_EXCHANGE::FUN_007b3480`):

- **Nothing offered** (`0x7b2480`: all 24 slots empty and the two gold values *equal*; the
  equality, rather than both being 0, is retail's quirk): the client feeds itself a local
  `0xb082 [2][0x1823]` (`0xba8f70`). That shows UIIT_MSG_STRGERR_DEAL_FAIL_NON_ITEM "Trade cannot
  be carried out because there is no item to be traded.", and nothing is sent.
- **Busy flag `+0x7bc` set**: nothing.
- **Not yet confirmed** (`+0x7bd == 0`):
  - set `+0x7bc`;
  - show UIIT_MSG_EXCHANGE_DECEPTION_REAFFIRM as the **big notice**, a system line and an
    **orange** log line;
  - send `0x7082`.
- **Confirmed and the opponent confirmed**:
  - set `+0x7bc`;
  - write an orange log line UIIT_MSG_EXCHANGE_AGREEMENT_WAIT "Waiting for other player's
    approval.";
  - send `0x7083`.

**State changes** (READ):

| Event | Effect |
|---|---|
| `0xb082 [1]` → `CIFExchange::FUN_007b2700(1)` | `+0x7bd` = 1, `+0x7bc` = 0, `_MYMONEY +0x36c = 0x80000000` (grey), own 12 slots `+0x595 = 1` (blue) and not pickable, button text **UIIT_CTL_ACKNOWLEDGMENT "Approve"**, button enabled only if `+0x7be` (`0x655ec0`) |
| `0x3086` → `FUN_007b2670(1)` | `+0x7be` = 1, `_OTHERMONEY` grey, opponent 12 slots blue and not pickable; if `+0x7bd` the button is enabled (`0x7b2310` → `0x655ec0(1)`), otherwise it is **not touched** -- a side that has not confirmed keeps "Confirm" enabled (v0.1.594 disabled it, so the second side could not confirm) |
| `0xb083 [1]` | `+0x7bc` = 1, button disabled (`0x7b22f0`) |
| `0xb08x [2][code]` | category-1 message for the code |

**The blue grid** is the slot drawing texture `+0x61c` =
**`interface\ifcommon\com_item_exchange.ddj`** (loaded in `CIFSlotWithHelp::vslot_010 c:0x66b4a6`,
drawn when `+0x595` is set, `c:0x67cfcc`). **A grid turns blue when its owner's confirm is
accepted.** You see your own grid blue after `0xb082 [1]` and the opponent's after `0x3086`. This
matches the screenshots: toZxgu2 has Pain confirmed, so only Pain's grid is blue and Approve is
grey; JTk2jxi has both confirmed, so both are blue and Approve is enabled.

**Done** (`0x3087`, `c:0x88bb50`):

1. Each item in the opponent grid is copied into your inventory at slot **−1, the first free
   slot**. This mirrors the server's first-empty-from-13 placement in bay order (INFERRED: the
   same order).
2. Each own item is removed from the bag. For stackables it compares counts (`0x8ba460`).
3. Window 0xb2 is told about each item. That window is not in `ginterface.txt` (OPEN).
4. Exchange mode is turned off and the window hidden (`0x79df10(0)`).
5. The log/system line UIIT_MSG_EXCHANGE_END "Exchanging with [%s] is completed." and the notice
   UIIT_MSG_STGRERR_ITEM_EXCHANGE_SUCCEED "Exchange of the selected item(s) succeeded." are shown.

Gold arrives separately as `0x304E`.

**Closed** (`0x3088 [code]`, `c:0x880840`):

1. If still in exchange mode, `0x7084` is sent back. The server has no session by then. INFERRED:
   it answers `0xb084 [2][0x181b]`, and code `0x181b` has no text.
2. The window is hidden and exchange mode turned off.
3. GI`+0x509` is cleared.
4. HUD requests of **kinds 8, 6 and 7** are removed. That covers the pending exchange popup *and*
   party popups.
5. The code's category-1 message is shown.
6. The notice is UIIT_STT_STRGERR_ITEM_EXCHANGE_FAILED. **That key has no row in this
   textuisystem.txt.** What a missing key displays is OPEN; `0x77b580` shows nothing for an empty
   string.

## 5. Text (READ, textuisystem.txt first block, English column)

| Key | English |
|---|---|
| UIIT_STT_EXCHANGE | Exchange |
| UIIT_CTL_CONFIRM / UIIT_CTL_ACKNOWLEDGMENT / UIIT_CTL_CANCEL | Confirm / Approve / Cancel |
| UIIT_STT_GOLD | Gold |
| UIIT_STT_SOMEONESITEM_GUILD | [%s - %s]'s item |
| UIIT_STT_SOMEONESITEM | [%s]'s items & goods: |
| UIIT_STT_WITH_OUT_GUILD | Did not join any guild |
| UIIT_STT_CONFIRM_BOX | Confirmation window |
| UIIT_STT_PARTY_SOMEUSER | [%s] sent you  party invite. |
| UIIT_MSG_DEAL_ASK | Applied for the exchange. Will you accept it? |
| UIIT_STT_ACCEPT / UIIT_STT_REFUSE | Accept / Refuse |
| UIIT_MSG_DEAL_ASKING | Applying for a trade to [%s]. |
| UIIT_MSG_EXCHANGE_START | You started to exchange with [%s]. |
| UIIT_MSG_EXCHANGE_DECEPTION_COMPARE | Opponent user is not listed in your Guild/Union/Friend |
| UIIT_MSG_EXCHANGE_NAME_WARNING | Opponet user's name is a fictitious name. |
| UIIT_MSG_EXCHANGE_DECEPTION_REAFFIRM | Please check opponet user's ID, Gold, and detail information about equipment |
| UIIT_MSG_EXCHANGE_AGREEMENT_WAIT | Waiting for other player's approval. |
| UIIT_MSG_EXCHANGE_END | Exchanging with [%s] is completed. |
| UIIT_MSG_STGRERR_ITEM_EXCHANGE_SUCCEED | Exchange of the selected item(s) succeeded. |
| UIIT_STT_REQUEST_EXCHANGE_SIGN | Exchange Request (Option › Game) |
| UIIT_STT_CHAT_COMMAND_TRADE / _TRADE2 | /Exchange / /trade |
| UIIT_STT_AMOUNT_MONEY | Amount (gold box) |

Codes the client shows in category 1 (`c:0x7b8c82`):

| Code | Key | English |
|---|---|---|
| 3 | STRGERR_INVALID_TARGET | (not quoted) |
| 0x180f | NOT_ENOUGH_GOLD | Not enough gold |
| 0x181e | BUSY | User is busy. |
| 0x181f / 0x1820 | CANNOT_DEAL_NORMALCY | The trade cannot be made normally. |
| 0x1821 | TRADE_BAY_FULL | Cannot add the selected item because the exchange window is full. |
| 0x1823 | DEAL_FAIL_NON_ITEM | Trade cannot be carried out because there is no item to be traded. |
| 0x1826 | TIMEOUT | Trade request is automatically canceled due to no response from the other player. |
| 0x1827 | CANNOT_FIND_TARGET | Cannot find the other player. |
| 0x1828 | TRADING_DENIED | The request for a private trade has been cancelled. |
| 0x1829 | SPECIFY_POSITIVE_NUMBER_ONLY | Invalid numbers |
| 0x182b | EXCHANGE_CANCEL | The exchange has been canceled. |
| 0x182c | TRADING_CANCELED_BY_USER | The trade has been cancelled. |
| 0x1834 | STORAGE_OPERATION_BLOCKED | You are now in the state of being unable to move or trade items. |
| 0x1836 | NOT_ENOUGH_OPPONENT_INV_SPACE | Cannot add the selected item to the exchange window because the other player's inventory i[s full] |
| 0x183a | CANNOT_BE_TRADED | The selected item cannot be traded. |
| 0x1850 | YOU_CANT_DEAL_SPECIALTY | Cannot trade special products at the current shop. |
| 0x185f | REQUESTED_JOB_BLOCKED_BY_QUEST | The requested order cannot be carried out. |
| 0x18b6 | COSPETERR_CANT_TRADE | Summon item cannot be traded because pet is summoned. |
| 0x18fa | NASRUN_NOT_TRADE | You can't trade Devil's Spirit during awaken period. … |

These codes show **nothing** (category-1 default):

- `2`;
- `4`: there is no too-far text in category 1 (`c:0x7b8c93`), so a request made from too far
  away silently fails;
- `0x1806`, `0x1809`, `0x1811`, `0x181b`, `0x181c`, `0x181d`, `0x1824`, `0x1825`, `0x182a`,
  `0x182d`, `0x1833`, `0x1840`, `0x1841`.

## 6. OpenSRO today (OURS)

- **Server:** `server/internal/session/trade.go` and `server/internal/trade/`.
- **Client:** `client/scripts/net/trade.gd`, plus a debug tab in `World3D.gd`
  (`ActionTabs/Trade`: name field, Accept/Decline, gold/slot/quantity fields, Confirm/Cancel).
- **Opcodes:** its own, `0x00D0`–`0x00DE`, with the target named by *name*.

Already the engine's:

- the 320 range, at the request and at the accept;
- the 30 s timeout;
- one request per character, and busy rules on both sides;
- the equip and NPC-service locks while trading;
- `CanTrade`;
- execution once only (the round-743 latch).

Gaps against this spec:

- **Wire:** none of the retail opcodes: `0x7081`/`0xb081`, the `0x3080` kind-1 invitation and
  answer, `0x3085`, `0x7034` ops 4/5/0xd with their `0xb034` replies, `0x308c`,
  `0x3089`/`0x3086`, `0x7082`–`0x7084`, `0xb082`–`0xb084`, `0x3087`/`0x3088`.
- **Offer:** one item stack (with a partial quantity) plus gold per side. Retail has **12 whole
  stacks** plus gold, with partner-space and bay-full checks at add time.
- **Visibility:** OURS pushes every offer change to the partner (`OfferUpdated`) and resets both
  confirmations on any change. Retail reveals an offer **only at that side's Confirm**, locks it,
  and resets nothing.
- **Steps:** OURS has a single Confirm that executes when both confirm. Retail has **Confirm**,
  then **Approve** (only after both confirmed), then execution on the second Approve.
- **Retail codes:** OURS uses free-text reasons; retail's are §2 and §5.
- **Closing:** death, warp and logout cancel with `0x182b` in retail. OURS's disconnect handler
  covers disconnect only, and not death or warp.
- **Client window:** no CIFExchange window, quantity boxes, request popup, portraits, trust
  warning, blue grids, notices or log.
- **Inventory:** OURS has no greying of offered bag items, and no client-side completion
  placement (first free slot).
- **Atomicity:** OURS's `executeTrade` compensates rather than commits atomically. Retail moves
  in memory first (`DealIt`), then commits one async database job, and **disconnects both** if
  that job cannot be posted or fails. Our concern is atomicity, so mirror the order and checks,
  not the kick.

## OPEN

1. Own player byte `+0x7bc` (`c:0x9db000`, refusal `0x1834`): what sets it.
2. `CGObjPC::FUN_004f0a00(1)` (the silent drop at the head of `081`) and vslot `0x244(0x100)`
   (`0x185f`): their meaning.
3. DealIt's COS check (TypeID 3/2/1, TID4 1 or 2, receiver vslot `0x5dc`): what it refuses.
4. The kind-7 popup's own timer, and the exact Accept/Refuse values. Accept = 1 READ for the party
   kinds; Refuse = 0 INFERRED.
5. The option byte `+2` = "Exchange Request" checkbox: INFERRED from the list order, the setter
   was not traced.
6. The display of the missing key UIIT_STT_STRGERR_ITEM_EXCHANGE_FAILED.
7. Window 0xb2's role at completion. Also: the server's `vslot 0x144(0x21, 0, item)` for items
   with vslot `0xb8 ≠ 0` at completion (`s:0x480530`), whether that sends an item update.
8. When the player is in exchange mode, `0x81a620` decides whether USER_NAME (153), the
   opponent-name overlay, is shown (`vslot_012`). INFERRED: on hover. READ (round 834's fix):
   Create hides it (`0x7b29c0..0x7b29dd`, vslot `+0x5c` with 0); `0x7b2210` shows it only while
   `0x81a620` holds for control 14 (`+0x7c4`): its `+0x7b0` set and equal to the global at
   `0x110f608`. The client keeps it hidden; v0.1.594 left it shown, and its
   `icon_effect1.ddj` drew the opponent's grid dark blue from the start.
9. Whether the private layout's exact rects can be recovered (only measured from screenshots).
