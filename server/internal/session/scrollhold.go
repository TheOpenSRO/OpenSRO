package session

import (
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
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
//   - OPEN: the rest of retail's allow list (the NPC, inventory, exchange,
//     stall, pick-up and pet requests are not held yet).
//   - The hold ends with the state: the cast's end (before its warp), the
//     cancel 0x705B, a death -- ScrollCaster removes the cast in each.

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
