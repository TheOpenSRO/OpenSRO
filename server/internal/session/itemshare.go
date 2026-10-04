package session

import (
	"math"

	"github.com/OpenSRO/OpenSRO/server/internal/party"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// The Item Auto Share party's pick-ups (round 712, party lane S2). READ, GS;
// docs/protocol/party_rules.md "Items and gold".

// ErrPartyInventoryFull is 0x18da UIIT_MSG_STRGERR_PARTY_INVENTORY_FULL,
// "Inventory slot of the target to be distributed to is full, thus item
// distribution has failed." -- the picker's refusal when the round robin's
// choice has no room (READ, GS FUN_00526090 0x52633d-0x5263a8).
const ErrPartyInventoryFull = 0x18da

// itemShareRange is the 1000.0 both the round robin and the gold split measure
// in 3D (`fcomp QWORD 0xb45c68`; FUN_00430ba0 keeps y).
const itemShareRange = 1000.0

// itemSharePartyOf is the picker's party when it shares items (flags bit 1),
// else nil -- the gate both FUN_00525dc0 and GObjPC::FUN_004eaca0 test.
func itemSharePartyOf(parties *party.Hub, characterID int64) *party.Party {
	if parties == nil {
		return nil
	}
	p, in := parties.Get(characterID)
	if !in || p == nil || !p.Flags.ItemShare() {
		return nil
	}
	return p
}

func dist3(a, b world.Position) float64 {
	dx, dy, dz := a.X-b.X, a.Y-b.Y, a.Z-b.Z
	return math.Sqrt(dx*dx + dy*dy + dz*dz)
}

// roundRobinRecipient is FUN_00525dc0's choice of who gets an item a member
// of an Item Auto Share party picks up (READ, asm 0x525f00-0x52608d):
//
//   - up to memberCount times, take the next member of the party's rotation
//     (party.Hub.NextInRotation, GObjPC::FUN_004d4840) and accept the first
//     who is found, alive, in the picker's world and within 1000 of the picker
//     in 3D;
//   - otherwise the item goes to the LAST candidate the loop kept: the
//     pointer survives a failed alive test (0x525fae) or world test
//     (0x525fd7), and only a distance failure clears it (0x526055 xor
//     ebx,ebx), so the picker gets it only when the last member tried was too
//     far (0x526069), or could not be found -- the lookup's null result is
//     what the pointer then holds (READ: `0x525f90 call 0x485dc0; mov
//     ebx,eax; test ebx,ebx; je 0x526057`).
//
// "The same world" is the same zone bucket (OURS, as for the party share).
func roundRobinRecipient(hub *world.Hub, parties *party.Hub, p *party.Party, picker world.Entity) int64 {
	var kept int64 // EBX
	for i := 0; i < len(p.Members); i++ {
		id, ok := parties.NextInRotation(p.ID)
		if !ok {
			break
		}
		e, found := hub.EntityByCharacterID(id)
		if !found {
			kept = 0
			continue
		}
		kept = id
		if e.Life == world.LifeDead || e.Zone != picker.Zone {
			continue
		}
		if dist3(e.Pos, picker.Pos) > itemShareRange {
			kept = 0
			continue
		}
		return id
	}
	if kept == 0 {
		return picker.CharacterID
	}
	return kept
}

// goldShare is one member's part of a split pick-up.
type goldShare struct {
	characterID int64
	amount      int64
}

// splitGold is GObjPC::FUN_005bc7f0 (READ, party_rules.md "Gold"): the picker
// and every member found, in the picker's world and within 1000 of the pick
// position in 3D -- alive or not -- share the amount; each gets amount / n,
// the picker the remainder on top; when amount / n is 0 the picker takes it
// all. The picker is first in the result.
func splitGold(hub *world.Hub, p *party.Party, picker world.Entity, amount int64) []goldShare {
	ids := []int64{picker.CharacterID}
	for _, m := range p.Members {
		if m.CharacterID == picker.CharacterID {
			continue
		}
		e, ok := hub.EntityByCharacterID(m.CharacterID)
		if !ok || e.Zone != picker.Zone || dist3(e.Pos, picker.Pos) > itemShareRange {
			continue
		}
		ids = append(ids, m.CharacterID)
	}
	n := int64(len(ids))
	each, rest := amount/n, amount%n
	if each == 0 {
		return []goldShare{{picker.CharacterID, amount}}
	}
	out := make([]goldShare, len(ids))
	for i, id := range ids {
		out[i] = goldShare{id, each}
	}
	out[0].amount += rest
	return out
}

// sendItemNotice sends 0x3068 to every member of p in the world EXCEPT the
// recipient (READ: FUN_005bdc80 passes the recipient's id, the notice's first
// u32, as the second argument of CParty::BroadcastToLocalMember 0x5bb770 --
// `0x5bdd59 push edx` -- which skips the member with that id when it is
// non-zero, 0x5bb811-0x5bb81d; chat passes 0, which is why chat echoes).
func sendItemNotice(hub *world.Hub, p *party.Party, recipient int64, n party.ItemNotice) {
	pkt := &proto.Packet{Opcode: party.OpItemNotice, Data: n.Encode()}
	for _, m := range p.Members {
		if m.CharacterID == recipient {
			continue
		}
		if e, ok := hub.EntityByCharacterID(m.CharacterID); ok && e.Session != nil {
			e.Session.Send(pkt)
		}
	}
}
