package session

import (
	"bytes"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/cos"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npctalk"
)

// Round 862: the rest of retail's filter during a return scroll's cast
// (scrollhold.go, ScrollHoldGate; READ s:0x4ecbc0, MEASURED).

// quiet reads for a moment and fails on anything but the opcodes in ok.
func (rig *scrollRig) quiet(what string, ok ...uint16) {
	rig.t.Helper()
	for {
		p := rig.read(300 * time.Millisecond)
		if p == nil {
			return
		}
		fine := false
		for _, op := range ok {
			fine = fine || p.Opcode == op
		}
		if !fine {
			rig.t.Fatalf("%s while held: got 0x%04x % x; want no answer", what, p.Opcode, p.Data)
		}
	}
}

// answer sends op and wants reply with exactly the body want.
func (rig *scrollRig) answer(what string, op uint16, data []byte, reply uint16, want []byte) {
	rig.t.Helper()
	rig.send(op, data)
	p, _ := rig.readUntil(reply, 2*time.Second)
	if p == nil {
		rig.t.Fatalf("%s while held: no 0x%04x", what, reply)
	}
	if want != nil && !bytes.Equal(p.Data, want) {
		rig.t.Fatalf("%s while held: 0x%04x % x; want % x", what, reply, p.Data, want)
	}
}

func (rig *scrollRig) reachedOp(op uint16) bool {
	rig.mu.Lock()
	defer rig.mu.Unlock()
	for _, o := range rig.reached {
		if o == op {
			return true
		}
	}
	return false
}

// Every refused request gets retail's answer (or none), reaches no handler,
// and leaves the cast running; the allowed ones pass; the cancel ends it.
func TestRound862ScrollHoldRefusesTheRest(t *testing.T) {
	rig := newScrollRig(t, 60)
	scrollSlot, _ := rig.slot(fixtureReturnScroll)
	if res := rig.use(fixtureReturnScroll, 0, 0); res.Error != "" {
		t.Fatalf("use refused: %+v", res)
	}
	rig.readUntil(0xffff, 300*time.Millisecond) // the use's effect and state lines

	// 0x7034 (a bag move, an unequip): 0xB034 {2, 0x181d}.
	rig.answer("a bag move", OpItemMove, []byte{0, byte(scrollSlot), 0x1b, 1, 0}, OpItemMoveResult, []byte{2, 0x1d, 0x18})
	// 0x7045 (an NPC's select): 0xB045 {2, 0x6006}; 0x7046: 0xB046 {2, 0x1c0b}.
	rig.answer("an NPC select", npctalk.OpSelect, u32le(0x3f), 0xB045, []byte{2, 0x06, 0x60})
	rig.answer("an NPC open", npctalk.OpOpen, append(u32le(0x3f), 1), 0xB046, []byte{2, 0x0b, 0x1c})
	// 0x70C5: the attack {2, 2, 0x3009, cos}, the pick {2, 8, 0x4414, cos,
	// item}, the follow nothing.
	rig.answer("a pet attack", cos.OpCOSCommand, append(append(u32le(77), cos.CommandAttack), u32le(5)...),
		cos.OpCOSCommandAck, append([]byte{2, cos.CommandAttack, 0x09, 0x30}, u32le(77)...))
	rig.answer("a pet pick", cos.OpCOSCommand, append(append(u32le(77), cos.CommandPick), u32le(9)...),
		cos.OpCOSCommandAck, append(append([]byte{2, cos.CommandPick, 0x14, 0x44}, u32le(77)...), u32le(9)...))
	rig.send(cos.OpCOSCommand, append(u32le(77), cos.CommandFollow))
	rig.quiet("a pet follow")

	// No answer: the sit, an emote, the stall, an exchange, the party match.
	rig.send(OpMotionRequest, []byte{4})
	rig.quiet("the sit")
	rig.send(OpEmote, []byte{0})
	rig.quiet("an emote")
	rig.send(0x70B1, append([]byte{3, 0}, "abc"...))
	rig.quiet("a stall's open")
	rig.send(0x7081, u32le(5))
	rig.quiet("an exchange request")
	rig.send(0x706C, []byte{0})
	rig.quiet("the party match")

	// OpenSRO's own twins: the bag move and the equip get their error (shown
	// nowhere), the pick-up 0x4004.
	before, _ := rig.slot(fixtureReturnScroll)
	rig.send(OpInventoryMove, (&InventoryMoveRequest{CharacterName: "Aria", From: int32(before), To: 30}).Encode())
	p, _ := rig.readUntil(OpInventoryMoveResult, 2*time.Second)
	if r, err := DecodeInventoryListResult(p.Data); p == nil || err != nil || r.Error == "" {
		t.Fatalf("a held bag move: %+v %v; want an error", r, err)
	}
	if after, _ := rig.slot(fixtureReturnScroll); after != before {
		t.Fatalf("a held bag move moved the scroll %d -> %d", before, after)
	}
	rig.send(OpEquip, (&EquipRequest{CharacterName: "Aria", Slot: 6, InventorySlot: before}).Encode())
	p, _ = rig.readUntil(OpEquipmentResult, 2*time.Second)
	if r, err := DecodeEquipmentResult(p.Data); p == nil || err != nil || r.Error == "" {
		t.Fatalf("a held equip: %+v %v; want an error", r, err)
	}
	rig.send(OpPickUp, (&PickUpRequest{CharacterName: "Aria", GroundItemID: 41}).Encode())
	p, _ = rig.readUntil(OpPickUpResult, 2*time.Second)
	if r, err := DecodePickUpResult(p.Data); p == nil || err != nil || r.Code != int32(ActionErrRefused) || r.GroundItemID != 41 {
		t.Fatalf("a held pick-up: %+v %v; want 0x4004 for 41", r, err)
	}

	for _, op := range []uint16{OpItemMove, npctalk.OpSelect, npctalk.OpOpen, cos.OpCOSCommand, OpMotionRequest, OpEmote,
		0x70B1, 0x7081, 0x706C, OpInventoryMove, OpEquip, OpPickUp} {
		if rig.reachedOp(op) {
			t.Fatalf("0x%04x reached a handler while held", op)
		}
	}

	// Let through: the client's settings 0x7158, chat, OpenSRO's own others.
	rig.send(OpAutoPotionSave, []byte{2, 0, 0, 0, 0, 0, 0, 0})
	rig.send(0x7025, []byte{1, 0, 0})
	rig.send(OpChatSend, nil)
	rig.quiet("the passed requests")
	for _, op := range []uint16{OpAutoPotionSave, 0x7025, OpChatSend} {
		if !rig.reachedOp(op) {
			t.Fatalf("0x%04x did not pass the hold", op)
		}
	}
	// None of it cancelled the cast (MEASURED: it ends on time).
	if !rig.caster.Casting(rig.charID) {
		t.Fatal("a held request ended the cast")
	}

	// The cancel releases: the sit and the emote answer again.
	rig.send(OpScrollCancel, nil)
	rig.readUntil(0xffff, 300*time.Millisecond)
	rig.send(OpEmote, []byte{0})
	if echo, _ := rig.readUntil(OpEmote, 2*time.Second); echo == nil {
		t.Fatal("no emote echo after the cancel")
	}
	rig.send(OpMotionRequest, []byte{4})
	if st, _ := rig.readUntil(OpStateChange, 2*time.Second); st == nil {
		t.Fatal("no sit after the cancel")
	}
}

// The thief-den scrolls' state 2 is not held: an emote echoes.
func TestRound862StateTwoIsNotHeld(t *testing.T) {
	rig := newScrollRig(t, 60)
	e, _ := rig.hub.EntityByCharacterID(rig.charID)
	rig.caster.mu.Lock()
	rig.caster.casting[rig.charID] = &scrollCast{sess: e.Session, value: 2}
	rig.caster.mu.Unlock()
	t.Cleanup(func() {
		rig.caster.mu.Lock()
		delete(rig.caster.casting, rig.charID)
		rig.caster.mu.Unlock()
	})
	rig.send(OpEmote, []byte{0})
	if echo, _ := rig.readUntil(OpEmote, 2*time.Second); echo == nil {
		t.Fatal("state 2 held an emote")
	}
}
