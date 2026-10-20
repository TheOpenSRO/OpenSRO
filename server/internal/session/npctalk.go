package session

import (
	"context"
	"math"
	"sort"
	"sync"

	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/npcspawn"
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
// flag +0x728 and the per-select set +0x1c78 (PublishAvailableInteractions
// 0x4a95a0), the open sets INTERACTMODE at chardata+6 (GObjPC_HandleShopMsg_046's
// jump table), and the end clears it (GObjPC::EndInteraction 0x5107c0).
// OpenSRO keeps the same per session here.
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
//
// Not modelled, labelled (round 727's review, finding 7):
//   - The select lets INTERACTMODE 1 through when +0x1cc0 (param_1[0x730]) is
//     set (0x50faf0's first test); OpenSRO has no mode 1 and refuses a trading
//     character.
//   - The open refuses 0x1C0B also when the player's slot 0x5a0 answers
//     non-zero (0x5102bc..0x5102e2); what that slot tests is not read.
//   - The open's range check passes the type filter 0x146 (0x510336), whose
//     mismatch is code 3; OpenSRO resolves only NPCs, so it cannot mismatch.
//   - Id 1 at NPC_SD_MERCHANT_CHANGER (0xaf6c04) and
//     NPC_SD_THIEF_AGENT_CHANGER (0xaeedd8) is refused 0x1C26 by the player's
//     job state (0x510431..0x510480); OpenSRO keeps no job record, so the
//     store opens there.
//   - Id 0x23 sends FUN_0051b580's code as the refusal (0x510486..0x51049d);
//     no NPC OpenSRO spawns offers 0x23's open market, and the code is not
//     read, so 0x23 always succeeds here.

// npcInteractRange is IsWithinInteractionRange's radius for an NPC (READ,
// round 701: 300, 3-D).
const npcInteractRange = 300.0

// The open's refusal for id 1 at an NPC with no store: FUN_00619c10 == 0
// (0x5103ba..0x5103c3), code 3.
const codeNoStore = npctalk.CodeNoTarget

type npcInteraction struct {
	entity   uint32
	selected bool   // +0x728
	mode     byte   // INTERACTMODE: 0, 5 or 6
	ids      []byte // the last select's set, +0x1c78
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

// ForgetNPCInteraction drops a session's interaction on its disconnect
// (cmd/server's session cleanup). The engine also ends an interaction on a
// zone change (GObjPC::EndInteraction); OpenSRO's zone change does not call
// this yet (OURS).
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

// selectIDsFor is the set a select by characterID of level sends for npc: its
// own set (+0x130 copied to +0x1c78) and, at the herbalists from level 20, id
// 10 (the quest's event-0xb handler, npcspawn.WithdrawSkill). Without the quest
// runtime id 2 stays as the NPC's static stand-in (npcspawn/questtalk.go); with
// it (round 785) id 2 is the player's own -- offered when the NPC has
// quest business with the character (0x4c9310's per-player filter, now with
// real quests), taken away when it has none and the static stand-in listed it.
func selectIDsFor(ctx context.Context, npc *npcspawn.NPC, level int, characterID int64) []byte {
	ids := append([]byte(nil), npc.Interact...)
	if questRT.Load() != nil && characterID != 0 {
		talk := questTalkAvailable(ctx, characterID, level, npc.Code)
		kept := ids[:0]
		has := false
		for _, b := range ids {
			if b == npctalk.IDTalk {
				if !talk {
					continue
				}
				has = true
			}
			kept = append(kept, b)
		}
		ids = kept
		if talk && !has {
			ids = append(ids, npctalk.IDTalk)
			sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
		}
	}
	if npcspawn.WithdrawSkill(npc.Code, level) {
		has := false
		for _, b := range ids {
			has = has || b == npctalk.IDWithdrawSkill
		}
		if !has {
			ids = append(ids, npctalk.IDWithdrawSkill)
			sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
		}
	}
	return ids
}

// handleNPCSelect is the select (FUN_0050fe50 -> FUN_0050faf0): refused (code
// 3) while the character is busy or the entity does not resolve, refused with
// the range code beyond reach, else {1, entity} and the select's set
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
	ids := selectIDsFor(context.Background(), pl.npc, e.Level, e.CharacterID)
	npcInteractions.mu.Lock()
	st.entity = entity
	st.selected = true
	st.ids = ids
	npcInteractions.mu.Unlock()
	// An NPC of OpenSRO's own (round 783): its store lines and tabs first,
	// so the talk window the reply opens has them (OpNpcShopDef, OURS).
	sendNPCShopDef(sess, entity)
	sendNPCTalk(sess, npctalk.OpSelectResult, npctalk.EncodeSelectNPC(npctalk.SelectNPC{Entity: entity, IDs: ids}))
}

// handleNPCOpen is GObjPC_HandleShopMsg_046 (0x510250): busy 0x1C0B first,
// then the target and the offered-id test (5) on the select's set, then the
// id's own gate, then {1, id} and the mode.
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
	offeredSet := st.ids
	if st.entity != entity {
		offeredSet = nil
	}
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
	// HasAvailableInteraction (0x50cd80) reads the per-select set +0x1c78.
	// An open with no select of this NPC before it tests the set a select
	// would give now (OURS: the engine's +0x1c78 is whatever the last select
	// left).
	if offeredSet == nil {
		offeredSet = selectIDsFor(context.Background(), pl.npc, e.Level, e.CharacterID)
	}
	offered := false
	for _, b := range offeredSet {
		if b == id {
			offered = true
			break
		}
	}
	if !offered {
		sendNPCTalk(sess, npctalk.OpOpenResult, npctalk.EncodeFail(npctalk.CodeNotOffered))
		return
	}
	if id == 1 && !pl.npc.Shop {
		sendNPCTalk(sess, npctalk.OpOpenResult, npctalk.EncodeFail(codeNoStore))
		return
	}
	sendNPCTalk(sess, npctalk.OpOpenResult, npctalk.EncodeOpenSpecialOK(id, specialGoodsSelling()))
	// Id 0xc (round 801): an NPC with a quotation map sends its list
	// (FUN_004c8a60) after the reply, then INTERACTMODE 6.
	specialMode := byte(0)
	if id == npctalk.IDSpecial {
		specialMode = specialtyOpen(context.Background(), sess, e, pl.npc.RefID)
	}
	npcInteractions.mu.Lock()
	st.entity = entity
	switch id {
	case npctalk.IDTalk:
		// INTERACTMODE 5 (0x510584). With no talk menu the NPC gets
		// RaiseEvent(1, 0, player) (0x51059b..0x5105aa), the quest event,
		// and nothing is sent; with one, the player's +0x28c,
		// CGObjPC::ShowFirstTalkMenu (0x4f05d0), sends ShowMenu's 0x30D4
		// (0x4ec930) with the player's enabled talk items, which the client
		// answers with 0x70D4 (GObjPC_HandleTalkMenuSelectMsg_0d4 0x516670:
		// a u8 choice, then EndInteraction). OpenSRO registers no talk item
		// (no quest progress), so it takes the first branch: nothing more.
		// 0x30D4's payload is not read (OPEN).
		st.mode = 5
	case npctalk.IDWithdrawSkill:
		// INTERACTMODE 5 (0x5105f1); the open raises event 0x12 on the NPC
		// (0x5105f1..0x510607), whose subscriber CQSP_ALL_POTION_1 (0x88b7be)
		// runs the withdrawal after testing level 20 again. OpenSRO has no
		// skill withdrawal, so nothing more happens (OURS: the answer and the
		// mode are the original's, the withdrawal is missing).
		st.mode = 5
	case 0x23:
		// Returns without setting a mode (0x510428).
	case npctalk.IDSpecial:
		// 0x5105ca: when the NPC's +0x1cf0 (its quotation map, built by
		// FUN_004c8220 from _ItemQuotation) is empty it returns with no mode
		// (0x5105d1 je 0x510428); otherwise 0x4c8a60, then mode 6 (round
		// 801, specialtyOpen).
		if specialMode != 0 {
			st.mode = specialMode
		}
	default:
		st.mode = 6
	}
	npcInteractions.mu.Unlock()
	// The talk opens the NPC's quest page (round 785, quest.go): the menu
	// ShowFirstTalkMenu sends as 0x30D4 when the player has talk items here.
	if id == npctalk.IDTalk {
		questTalkOpen(context.Background(), sess, e, entity, pl.npc.Code)
	}
}

// handleNPCEnd is GObjPC_HandleEndInteractionMsg_04b -> EndInteraction
// (0x5107c0): an open interaction (5 or 6) or a bare select is ended and
// answered {1}; anything else is refused 0x1C0D. The select's flag is
// cleared only with mode 5 (0x51090d..0x510913) or by a bare select's end
// (mode 0 with the flag, 0x5107f0..0x5107f9): after a mode-6 end a second
// 0x704B still gets {1}.
func handleNPCEnd(sess *gateway.Session, data []byte) {
	if _, err := npctalk.DecodeEntity(data); err != nil {
		return
	}
	npcInteractions.mu.Lock()
	st, ok := npcInteractions.m[sess.ID()]
	open := ok && (st.mode == 5 || st.mode == 6 || st.selected)
	if open {
		if st.mode == 5 || st.mode == 0 {
			st.selected = false
		}
		st.mode = 0
	}
	npcInteractions.mu.Unlock()
	// The quest talk ends with the NPC talk (round 785 review), all but a
	// reward window the client keeps open past it (forgetQuestTalk).
	forgetQuestTalk(sess.ID(), true)
	if !open {
		sendNPCTalk(sess, npctalk.OpEndResult, npctalk.EncodeFail(npctalk.CodeNoInteraction))
		return
	}
	sendNPCTalk(sess, npctalk.OpEndResult, npctalk.EncodeEndOK())
}
