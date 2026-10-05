package session

import (
	"context"
	"math"
	"sync"

	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/npctalk"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/trade"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// The retail NPC interaction (round 727): select 0x7045 -> 0xB045 with the
// NPC's interaction ids, open 0x7046 -> 0xB046, end 0x704B -> 0xB04B. The
// path is docs/protocol/character_state.md's "An NPC interaction, end to end
// (round 454)", and every byte is npctalk's.
//
// The engine keeps the state on the character: the select sets the requester
// flag +0x728 (PublishAvailableInteractions 0x4a95a0), the open sets
// INTERACTMODE at chardata+6 (5 for ids 2 and 10, nothing for 0x23, else 6;
// GObjPC_HandleShopMsg_046's jump table), and the end clears both
// (GObjPC::EndInteraction 0x5107c0). OpenSRO keeps the same per session here.
//
// OURS:
//   - The store's and warehouse's own messages are not yet keyed to this state
//     (their buy, sell and move requests are OpenSRO's placeholders, lane 728's
//     side); an open interaction is what the client's windows follow, and
//     tradebusy.go's per-operation trade test stays.
//   - The trade side of the engine's mutual exclusion is the trade hub's Busy:
//     a trading character is refused the select (0x50fd41 code 3) and the
//     open (0x1C0B), as INTERACTMODE 1/2 refuses them in the engine.
//   - The range is 3-D from the player to the NPC's spot in the player's
//     frame, against 300 (IsWithinInteractionRange 0x4a8e10's NPC radius,
//     World3D's round-701 note); the NPC's height is its nest or npcpos row's.

// npcInteractRange is IsWithinInteractionRange's radius for an NPC (READ,
// round 701: 300, 3-D).
const npcInteractRange = 300.0

type npcInteraction struct {
	entity   uint32
	selected bool // +0x728
	mode     byte // INTERACTMODE: 0, 5 or 6
}

var npcInteractions = struct {
	mu sync.Mutex
	m  map[uint64]*npcInteraction
}{m: map[uint64]*npcInteraction{}}

func npcInteractionOf(id uint64) *npcInteraction {
	npcInteractions.mu.Lock()
	defer npcInteractions.mu.Unlock()
	st, ok := npcInteractions.m[id]
	if !ok {
		st = &npcInteraction{}
		npcInteractions.m[id] = st
	}
	return st
}

// ForgetNPCInteraction drops a session's interaction (a disconnect or a zone
// change: GObjPC::EndInteraction runs on both in the engine).
func ForgetNPCInteraction(id uint64) {
	npcInteractions.mu.Lock()
	delete(npcInteractions.m, id)
	npcInteractions.mu.Unlock()
}

// NPCInteractionMode is the session's INTERACTMODE (tests, and the store and
// warehouse handlers when they move to it).
func NPCInteractionMode(id uint64) (entity uint32, mode byte) {
	npcInteractions.mu.Lock()
	defer npcInteractions.mu.Unlock()
	if st, ok := npcInteractions.m[id]; ok {
		return st.entity, st.mode
	}
	return 0, 0
}

// NPCTalkHandler answers 0x7045, 0x7046 and 0x704B.
func NPCTalkHandler(hub *world.Hub, trades *trade.Hub) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		switch p.Opcode {
		case npctalk.OpSelect:
			handleNPCSelect(sess, p.Data, hub, trades)
		case npctalk.OpOpen:
			handleNPCOpen(sess, p.Data, hub, trades)
		case npctalk.OpEnd:
			handleNPCEnd(sess, p.Data)
		}
		return nil
	}
}

func sendNPCTalk(sess *gateway.Session, op uint16, data []byte) {
	sess.Send(&proto.Packet{Opcode: op, Data: data})
}

// npcTarget resolves entity in the player's zone and measures the reach:
// npctalk.CodeNoTarget when there is none, CodeTooFar beyond the radius.
func npcTarget(e world.Entity, entity uint32) (npcPlacement, uint16) {
	pl, ok := npcInZone(entity, e.Zone)
	if !ok {
		return pl, npctalk.CodeNoTarget
	}
	dx, dy, dz := pl.x-e.Pos.X, float64(pl.npc.Y)-e.Pos.Y, pl.z-e.Pos.Z
	if math.Sqrt(dx*dx+dy*dy+dz*dz) > npcInteractRange {
		return pl, npctalk.CodeTooFar
	}
	return pl, 0
}

// handleNPCSelect is the select (FUN_0050fe50 -> FUN_0050faf0): refused (code
// 3) while the character is busy or the entity does not resolve, refused with
// the range code beyond reach, else {1, entity} and the NPC's set
// (PublishAvailableInteractions), and the requester flag set.
func handleNPCSelect(sess *gateway.Session, data []byte, hub *world.Hub, trades *trade.Hub) {
	entity, err := npctalk.DecodeEntity(data)
	if err != nil {
		return
	}
	e, ok := hub.EntityBySession(sess.ID())
	if !ok {
		return
	}
	st := npcInteractionOf(sess.ID())
	npcInteractions.mu.Lock()
	busy := st.mode != 0
	npcInteractions.mu.Unlock()
	if busy || (trades != nil && trades.Busy(e.CharacterID)) {
		sendNPCTalk(sess, npctalk.OpSelectResult, npctalk.EncodeFail(npctalk.CodeNoTarget))
		return
	}
	pl, code := npcTarget(e, entity)
	if code != 0 {
		sendNPCTalk(sess, npctalk.OpSelectResult, npctalk.EncodeFail(code))
		return
	}
	npcInteractions.mu.Lock()
	st.entity = entity
	st.selected = true
	npcInteractions.mu.Unlock()
	sendNPCTalk(sess, npctalk.OpSelectResult, npctalk.EncodeSelectNPC(npctalk.SelectNPC{Entity: entity, IDs: pl.npc.Interact}))
}

// handleNPCOpen is GObjPC_HandleShopMsg_046 (0x510250): busy 0x1C0B first,
// then the target and the offered-id test (5), then {1, id} and the mode.
func handleNPCOpen(sess *gateway.Session, data []byte, hub *world.Hub, trades *trade.Hub) {
	entity, id, err := npctalk.DecodeOpen(data)
	if err != nil {
		return
	}
	e, ok := hub.EntityBySession(sess.ID())
	if !ok {
		return
	}
	st := npcInteractionOf(sess.ID())
	npcInteractions.mu.Lock()
	busy := st.mode != 0
	npcInteractions.mu.Unlock()
	if busy || (trades != nil && trades.Busy(e.CharacterID)) {
		sendNPCTalk(sess, npctalk.OpOpenResult, npctalk.EncodeFail(npctalk.CodeBusy))
		return
	}
	pl, code := npcTarget(e, entity)
	if code != 0 {
		sendNPCTalk(sess, npctalk.OpOpenResult, npctalk.EncodeFail(code))
		return
	}
	offered := false
	for _, b := range pl.npc.Interact {
		if b == id {
			offered = true
			break
		}
	}
	if !offered {
		sendNPCTalk(sess, npctalk.OpOpenResult, npctalk.EncodeFail(npctalk.CodeNotOffered))
		return
	}
	sendNPCTalk(sess, npctalk.OpOpenResult, npctalk.EncodeOpenOK(id))
	npcInteractions.mu.Lock()
	st.entity = entity
	switch id {
	case npctalk.IDTalk, npctalk.IDWithdrawSkill:
		// INTERACTMODE 5. Id 2 then runs CGObjPC::ShowFirstTalkMenu (vtable
		// +0x28c), which walks the player's quests for this NPC; its message
		// is not read and OpenSRO's quests are its own, so nothing more is
		// sent (OPEN, docs/protocol/npc_gui.md). Id 10 calls the NPC's slot
		// 0x144 with 0x12 -- the skill withdrawal, which OpenSRO does not
		// offer (no registrar of id 10 is read).
		st.mode = 5
	case 0x23:
		// Returns without setting a mode (0x510428).
	default:
		st.mode = 6
	}
	npcInteractions.mu.Unlock()
}

// handleNPCEnd is GObjPC_HandleEndInteractionMsg_04b -> EndInteraction: an
// open interaction (5 or 6) or a select is ended and answered {1}; anything
// else is refused 0x1C0D.
func handleNPCEnd(sess *gateway.Session, data []byte) {
	if _, err := npctalk.DecodeEntity(data); err != nil {
		return
	}
	npcInteractions.mu.Lock()
	st, ok := npcInteractions.m[sess.ID()]
	open := ok && (st.mode == 5 || st.mode == 6 || st.selected)
	if open {
		st.mode = 0
		st.selected = false
	}
	npcInteractions.mu.Unlock()
	if !open {
		sendNPCTalk(sess, npctalk.OpEndResult, npctalk.EncodeFail(npctalk.CodeNoInteraction))
		return
	}
	sendNPCTalk(sess, npctalk.OpEndResult, npctalk.EncodeEndOK())
}
