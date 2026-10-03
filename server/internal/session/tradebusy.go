package session

// THE TRADE HOLDS THE CHARACTER (round 499).
//
// The engine keeps one byte per character saying which exclusive activity owns
// it: INTERACTMODE, at chardata+6 (docs/protocol/character_state.md, "The
// kind-2 field"). A trade sets it on both parties -- 1 the moment the request
// is made (CTradeMgr::OpenTradeSession, `0x0047f620`, called only from the
// trade-request handler GObjPC_HandleTradeMsg_081 `0x005154e0`), 2 once it is
// accepted (CTradeMgr::EstablishTradeSession, `0x0047f970`) -- and two gates
// read it:
//
//   - GObjPC_HandleShopMsg_046 (`0x00510250`), which opens EVERY NPC service
//     (shop, warehouse, smith -- the interaction ids of character_state.md
//     round 455), refuses with 0x1c0b UIIT_MSG_INTERACTION_FAIL_IM_BUSY
//     (docs/protocol/error_codes.md, "The interaction pair") when the byte is
//     not 0, before it reads a field of the request:
//
//     if (*(char *)(param_1[0xc] + 6) != '\0') { ...; uVar9 = 0x1c0b; ... }
//
//   - CGObjPC::StorageOperation (`0x0050f5c0`), which dispatches the item
//     operations by op number, refuses every op but 4, 5 and 0xd with 0x1834
//     when the byte is 2 or 7
//     (`0x50f7cd`-`0x50f7e3`), before it dispatches. Its op 0 is the only
//     route to CGObjPC::AttachEquipItem (`0x00524cd0`) and DetachEquipItem
//     (`0x005255e0`), which test 2 and 7 again and return 0x1811. Together
//     they are the equip lock below.
//
// THE ADAPTATION, disclosed. The engine refuses once, when the NPC interaction
// is OPENED. OpenSRO has no interaction-open message -- its shop, storage and
// repair opcodes are stateless per-operation placeholders
// (docs/protocol/PROTOCOL_DECISION.md) -- so it applies the same test to each
// operation instead: a buy, a sell, a warehouse list/move/gold request or a
// repair made while trade.Hub.Busy is refused. The shop LIST is not refused: it
// only prices goods and changes nothing, standing in for the catalogue the
// client reads from its own tables. The reverse direction is not modelled,
// because OpenSRO has no open-interaction state to hold. In the engine an open
// NPC interaction (INTERACTMODE 5 or 6) also refuses a trade request, through
// GObjPC::FUN_004ea050, which requires the byte to be 0. The request handler
// GObjPC_HandleTradeMsg_081 (`0x005154e0`) runs it on the requester first and
// answers 0x181d itself (0x1833 at mode 2 or 7). CTradeMgr::OpenTradeSession
// then runs it on the target and answers 0x181e (`0x47f6e0`). Neither route
// gives 0x1811 (docs/RE_COMPLETION.md, round 499, "Not modelled").

// interactionBusyCode is 0x1c0b, UIIT_MSG_INTERACTION_FAIL_IM_BUSY
// (docs/protocol/error_codes.md, "The table", row 0x1c0b), the code
// GObjPC_HandleShopMsg_046 (`0x00510250`) refuses an NPC interaction with
// while INTERACTMODE is non-zero. OpRepairResult carries the engine's own
// refusal codes, so a repair refused as busy answers with it -- an
// ADAPTATION, like the rest of this file: the engine sends 0x1c0b in reply to
// the interaction OPEN, 0xb046 (`mov ecx,0xb046` at `0x51041c`, then
// Msg_SendTwoFieldReply `0x4e7250`), not in reply to a repair. OpenSRO has no
// interaction-open message to refuse, so it puts the code on the repair's own
// result instead.
const interactionBusyCode int32 = 0x1c0b

// tradeBusyReason is the text-reply form of the same refusal, for the shop and
// warehouse results, which carry a reason string rather than a code. The
// wording is OpenSRO's own because those results have no code field to carry
// (their layouts are placeholders, docs/protocol/PROTOCOL_DECISION.md). The
// client DOES have a message for 0x1c0b: in the real client's error dispatcher
// the interaction switch (category 0xd, targets at 0x7bbaac) sends it to
// 0x7ba09d, which pushes 0xdc24d0 UIIT_MSG_INTERACTION_FAIL_IM_BUSY
// (docs/protocol/error_codes.md, "The interaction pair", corrected in round
// 515). The repair's result carries the code, and OpenSRO's client shows that
// message for it (client/scripts/net/error_text.gd, round 518).
const tradeBusyReason = "you are busy with a trade"

// tradeEquipLockedReason refuses an equip or unequip during an ACCEPTED trade.
// CGObjPC::AttachEquipItem (`0x00524cd0`) and DetachEquipItem (`0x005255e0`)
// both open with
//
//	if ((*(char *)(param_1[0xc] + 6) == '\x02') || (*(char *)(param_1[0xc] + 6) == '\a'))
//	    ... return 0x1811;
//
// Their only caller is FUN_00523860, op 0's entry in the table that
// CGObjPC::StorageOperation (`0x0050f5c0`) dispatches through. StorageOperation's
// own guard runs first (`0x50f7cd`-`0x50f7e3`) with the same two values, and
// answers 0x1834 UIIT_MSG_STRGERR_STORAGE_OPERATION_BLOCKED. So the engine's
// equip refusal reaches the client as 0x1834, and Attach/Detach's 0x1811 is a
// second line that mode 2 never reaches.
// INTERACTMODE 2 is an established trade. Mode 7 has no known writer (round 457),
// and nothing in OpenSRO can set it. A PENDING request (mode 1) passes both
// tests, so only trade.Hub.Established refuses here. OpEquipmentResult carries
// a text, not a code, so the wording is OpenSRO's own.
const tradeEquipLockedReason = "you cannot change equipment during a trade"
