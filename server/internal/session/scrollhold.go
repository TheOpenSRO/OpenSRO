package session

import (
	"context"
	"encoding/binary"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/cos"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npctalk"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// The return scroll's hold (round 860, lane S): while a character's scroll
// state is 1 it may not move, turn, attack or cast.
//
// READ (SR_GameServer.exe; round 779 missed it -- it read the handlers, and
// this test runs before any handler):
//
//   - The PC's message pump, GObjPC::FUN_004a8ad0 (from CMainProcess::
//     FUN_00413b30), takes each queued client message, and unless the
//     character is locked (chardata +4 == 1) asks CGObjPC vtable slot 0x610
//     (GObjPC::FUN_004aa310, vtable 0xaf59fc + 0x610 = 0xaf600c) whether it
//     may run. Only then does slot 0x5e0, CGObjPC::DispatchClientMessage
//     (0x50eee0), call the opcode's handler; a refused message goes to slot
//     0x598 (CGObjPC::vslot_358, 0x4ecbc0) instead.
//   - Slot 0x610 is the message filter GObjPC::FUN_004296a0 on the singleton
//     DAT_00d6a8f8 = 0xcc3fe0, built by RegisterValueListFilters (0x427d90):
//     17 groups of 0x1c bytes from 0xcc3fe4, one per character state, each a
//     vector of records by the state's value; a record is an allow list
//     (kind 0, ValueIsInList 0x4279a0) or a deny list (kind 1,
//     ValueIsNotInList 0x427940) of opcodes, built by FUN_00427870(kind in
//     ECX, record, value). No record passes (FUN_00427b20 returns 1). The
//     filter asks every group in turn and refuses on the first that fails.
//   - The scroll state is one of them: `call [edx+0x120]` (GetTeleportState,
//     chardata +0x10) then FUN_00427b20 with EDI = 0xcc3fe0 + 0x138 = group 11
//     (0xcc4118) at 0x429814..0x429834. RegisterValueListFilters sizes group
//     11 to 4 values (0x429337..0x429341) and gives it ONE record, value 1,
//     kind 0 -- an allow list (0x429360: push 1, ECX 0) -- of 0x7025 (chat),
//     0x704C (item use), 0x705B (the scroll's cancel), 0x7005 and 0x34BF
//     (0x429374..0x4293ab). Values 0, 2 and 3 have no record.
//   - So while the state is 1 -- every RESURRECT return scroll, every reverse
//     return scroll, the skin change (FUN_004e0b50(1, ...)) -- every other
//     message is refused: the move 0x7021, the arrow keys' 0x7023 / 0x7024,
//     the action 0x7074 (attacks, skills, pick-ups, the trace), a COS's
//     0x70C5, the NPC, inventory, exchange and stall requests. The thief-den
//     scrolls (state 2) are not held.
//   - The refusal (vslot_358): 0x7074 runs HandleCharacterActionRequest_7074
//     with its refused flag (0x4acc40: param_2 != 0 -> 0xB074 {3, 0x4004},
//     silent on the client, 0x7baf0d); 0x7034 answers 0x181d, 0x7045 0x6006,
//     0x7046 0x1c0b; the rest -- the moves among them -- are dropped with no
//     answer. The retail client walks only on its move's echo, so nothing
//     moves.
//
// OpenSRO (OURS where marked):
//
//   - Held here: the click and heading moves (0x7021, a rider's 0x70C5
//     command 1), the arrow keys' stop and turn (0x7023 / 0x7024, a rider's
//     commands 3 / 4), OpMove's walked positions and stops (OURS' position
//     stream; a relocation -- a placement the server named -- still passes),
//     0x7074, and OpenSRO's own attack and skill requests (OpAttack 0x0060,
//     OpUseSkill 0x0072, which stand for retail's 0x7074).
//   - OURS: a held move is answered with a 0xB023 to the mover alone at the
//     position the server has it, where retail answers nothing: OpenSRO's
//     client walks its click at once (destmove.go), so one that sent a move
//     anyway is put back. Its own client does not send one (World3D
//     _scroll_hold). An attack or a skill gets the silent end
//     (silentRefusal), the 0x4004's equivalent on OpenSRO's own result.
//   - The hold ends with the state: the cast's end (before its warp), the
//     cancel 0x705B, a death -- ScrollCaster removes the cast in each.
//
// Round 862: the rest of the filter (ScrollHoldGate, below).
//
//   - READ, the refusal's answers (CGObjPC::vslot_358, s:0x4ecbc0..0x4ece3e;
//     each Msg_SendTwoFieldReply, s:0x4e7250, is {u8 2, u16 code} on the
//     request's own reply): 0x7034 -> 0xB034 {2, 0x181d}; 0x7045 -> 0xB045
//     {2, 0x6006}; 0x7046 -> 0xB046 {2, 0x1c0b}; 0x7074 -> its handler's
//     refused flag (round 860); 0x70C5 command 2 -> 0xB0C5 {2, 2, u16
//     0x3009, u32 cos} and command 8 -> {2, 8, u16 0x4414, u32 cos, u32
//     item} (s:0x4ecd5b..0x4ece2b), any other command no answer; 0x7155 ->
//     0xB155 {2, 0x5814} unless its byte is 1; 0x7158 runs as if allowed
//     (GObjPC::FUN_00518c20, the client's settings). Every other refused
//     message gets no answer.
//   - READ, what the client shows for them: nothing. 0xB0C5's handler
//     (c:0x872590) sends 0x3009 to the error dispatcher (c:0x7b8b40) under
//     category 4 and 0x4414 under category 0xc, neither of which has a case
//     for it (the default shows nothing).
//   - MEASURED, during a return scroll's cast (30 s and 15 s scrolls, the
//     reverse return scroll's state is the same value 1): a bag move and
//     taking the weapon off (0x7034) are answered {2, 0x181d}, nothing is
//     shown and the item stays; a click on an NPC in reach (0x7045) is
//     answered {2, 0x6006}, nothing is shown and no window opens; a pick-up
//     (0x7074 kind 2) is answered {3, 0, 0x4004}, nothing shown; the sit
//     (0x704F), an emote (0x3091), the stall's open (0x70B1 and its 0x70BA),
//     the party match window (0x706C) and a ground click (0x7021) get no
//     answer and nothing happens; chat (0x7025) and a potion (0x704C) work
//     as usual; another return scroll is refused 0x185d (the warning banner
//     and the system line, "Cannot choose another teleport method because
//     you are now being teleported."). None of them cancels the cast: it
//     ends on time and warps. Only the cancel button (0x705B) ends it early.
//   - OpenSRO: the gate refuses, while scrollHolds, every retail request
//     (0x7000..0x7FFF) outside the allow list with retail's answer above, and
//     the emote 0x3091. The moves, 0x7074 and the rider's 0x70C5 commands 1,
//     3 and 4 still reach their handlers, which hold them (round 860, with
//     its OURS 0xB023 answer). OpenSRO's own requests that stand for a
//     refused retail one get the same silence in their own reply: the bag
//     move OpInventoryMove and the equip / unequip OpEquip / OpUnequip (all
//     retail 0x7034) an error the client shows nowhere, the pick-up OpPickUp
//     (retail 0x7074 kind 2) OpPickUpResult 0x4004, which the client shows
//     nowhere either.
//   - Left alone (unsure; the original refuses them too): the stall
//     network's 0x7461..0x7463 (OpenSRO's own way in, round 840) and
//     OpenSRO's own requests with no retail twin above (the GM console, the
//     guild, party and storage ones, alchemy's OpAlchemy). OPEN.

// ScrollHoldValue is the scroll state's value retail's filter holds (group 11's
// one record, READ above).
const ScrollHoldValue byte = 1

// scrollHolds reports whether sess's character is held by its scroll state:
// a cast made on this session whose value is ScrollHoldValue.
func scrollHolds(sess *gateway.Session) bool {
	s := activeScrolls.Load()
	if s == nil || sess == nil {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, c := range s.casting {
		if c.sess == sess && c.value == ScrollHoldValue {
			return true
		}
	}
	return false
}

// scrollHoldAnswer answers a move the hold refused (OURS, the header): the
// mover hears 0xB023 at the position the server has it. A leg still running
// (none should: the use stopped it) ends there and the window hears it too.
func scrollHoldAnswer(sess *gateway.Session, hub *world.Hub) {
	if hub == nil || sess == nil {
		return
	}
	r, moved, ok := hub.Halt(sess)
	if !ok {
		return
	}
	traceMove("move: held by the scroll", "character_id", r.Entity.CharacterID, "x", r.Entity.Pos.X, "z", r.Entity.Pos.Z)
	if moved {
		motions.walking(r.Entity.CharacterID, time.Now())
		stopRelay(sess, r, true)
		return
	}
	_ = sess.Send(&proto.Packet{Opcode: OpMovementStop, Data: encodeMoveStop(r.Entity)})
}

// The answers ScrollHoldGate gives (READ, the header: CGObjPC::vslot_358).
const (
	scrollHoldItemMoveCode  uint16 = 0x181d // 0x7034 -> 0xB034 {2, 0x181d}
	scrollHoldNPCSelectCode uint16 = 0x6006 // 0x7045 -> 0xB045 {2, 0x6006}
	scrollHoldNPCOpenCode   uint16 = 0x1c0b // 0x7046 -> 0xB046 {2, 0x1c0b}
	scrollHoldCOSAttackCode uint16 = 0x3009 // 0x70C5 command 2
	scrollHoldCOSPickCode   uint16 = 0x4414 // 0x70C5 command 8
)

// scrollHoldAllowed is group 11's allow list (READ, 0x429374..0x4293ab):
// chat, item use, the cancel, 0x7005 and 0x34BF -- and 0x7158, which the
// refusal itself runs (s:0x4ecc79).
var scrollHoldAllowed = map[uint16]bool{
	0x7025: true, 0x704C: true, OpScrollCancel: true, proto.OpLogoutRequest: true, 0x34BF: true,
	OpAutoPotionSave: true,
}

// scrollHoldOwn are the requests whose own handlers hold them (round 860).
var scrollHoldOwn = map[uint16]bool{
	proto.OpMovementRequest: true, OpMovementStopRequest: true, OpMovementTurnRequest: true,
	OpCharacterActionRequest: true,
}

// scrollHoldPassed are left alone (the header: unsure).
var scrollHoldPassed = map[uint16]bool{
	OpStallNetSearch: true, OpStallNetLeave: true, OpStallNetBuy: true,
}

// ScrollHoldGate refuses, while the session's character is held by its
// scroll state, what retail's filter refuses (the header, round 862), and
// hands everything else to next.
func ScrollHoldGate(next gateway.Handler) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if refused, err := scrollHoldRefuses(sess, p); refused {
			return err
		}
		return next(ctx, sess, p)
	}
}

// scrollHoldRefuses answers p as the hold does and reports whether it was
// refused (false: let it through).
func scrollHoldRefuses(sess *gateway.Session, p *proto.Packet) (bool, error) {
	if p == nil || !scrollHolds(sess) {
		return false, nil
	}
	op := p.Opcode
	if scrollHoldAllowed[op] || scrollHoldOwn[op] || scrollHoldPassed[op] {
		return false, nil
	}
	refuse := func(reply uint16, code uint16) (bool, error) {
		return true, sess.Send(&proto.Packet{Opcode: reply, Data: binary.LittleEndian.AppendUint16([]byte{2}, code)})
	}
	switch op {
	case OpItemMove:
		return refuse(OpItemMoveResult, scrollHoldItemMoveCode)
	case npctalk.OpSelect:
		return refuse(npctalk.OpSelectResult, scrollHoldNPCSelectCode)
	case npctalk.OpOpen:
		return refuse(npctalk.OpOpenResult, scrollHoldNPCOpenCode)
	case cos.OpCOSCommand:
		return scrollHoldCOS(sess, p.Data)
	case OpEmote:
		return true, nil
	case OpInventoryMove:
		return true, sess.Send(&proto.Packet{Opcode: OpInventoryMoveResult,
			Data: (&InventoryListResult{Error: scrollHoldBusy}).Encode()})
	case OpEquip, OpUnequip:
		return true, sess.Send(&proto.Packet{Opcode: OpEquipmentResult, Data: (&EquipmentResult{Error: scrollHoldBusy}).Encode()})
	case OpPickUp:
		var ground int64
		if req, err := DecodePickUpRequest(p.Data); err == nil {
			ground = req.GroundItemID
		}
		return true, sess.Send(&proto.Packet{Opcode: OpPickUpResult,
			Data: (&PickUpResult{Code: int32(ActionErrRefused), GroundItemID: ground}).Encode()})
	}
	if op >= 0x7000 && op <= 0x7FFF {
		return true, nil // no answer (vslot_358's default)
	}
	return false, nil
}

// scrollHoldBusy is the wording of OpenSRO's own text replies (OURS; the
// client shows these nowhere, as retail's client shows 0x181d nowhere).
const scrollHoldBusy = "held by a return scroll's cast"

// scrollHoldCOS is 0x70C5 under the hold (READ, the header): the rider's
// move, stop and turn reach their handler (round 860's hold, with its OURS
// answer); the attack and the pick are answered; the rest gets nothing.
func scrollHoldCOS(sess *gateway.Session, data []byte) (bool, error) {
	if len(data) < 5 {
		return true, nil
	}
	uid := binary.LittleEndian.Uint32(data)
	switch data[4] {
	case cos.CommandMove, cos.CommandStop, cos.CommandTurn:
		return false, nil
	case cos.CommandAttack:
		out := binary.LittleEndian.AppendUint16([]byte{2, cos.CommandAttack}, scrollHoldCOSAttackCode)
		return true, sess.Send(&proto.Packet{Opcode: cos.OpCOSCommandAck, Data: binary.LittleEndian.AppendUint32(out, uid)})
	case cos.CommandPick:
		var item uint32
		if len(data) >= 9 {
			item = binary.LittleEndian.Uint32(data[5:])
		}
		return true, sess.Send(&proto.Packet{Opcode: cos.OpCOSCommandAck, Data: pickFail(uid, item, scrollHoldCOSPickCode)})
	}
	return true, nil
}
