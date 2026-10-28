package session

// Round 838, OURS: the special reverse return scroll's two add-on options --
// "4. Move to a party member" and "5. Move to a previously saved location"
// (ITEM_MALL_REVERSE_RETURN_SCROLL_SPECIAL's description). The archive's
// client and server add-ons (vsroplus) that drew and ran them are packed, so
// what is built here follows their texts (MEASURED, textuisystem's
// VPLUS_UI_REVERSE_*): a "Movement of Party Members" list (Character Name,
// Position, Move), and a "User Setting Window" whose "Setting Location"
// registers the current position into a numbered slot ("Empty Slot", "Do you
// confirm updating this slot?", "Saved location has got updated.") and whose
// "Movement" moves to one. Choices left open by the texts, conservatively:
// character.SavedLocationSlots slots; registering needs the special scroll in
// the bag and does not spend it; moving spends it, casts as the other options
// do and resolves the destination when the cast runs out.

import (
	"context"
	"encoding/binary"
	"fmt"
	"math"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/teleport"
)

// The saved locations' messages (OURS, lane 5's block; 0x00FC/0x00FD are the
// ping's).
const (
	OpReverseSaved       uint16 = 0x00FE // client -> server: list or register
	OpReverseSavedResult uint16 = 0x00FF // server -> client: the slots
)

// The OpReverseSaved actions.
const (
	ReverseSavedList     byte = 0
	ReverseSavedRegister byte = 1
)

// ReverseSavedRequest is OpReverseSaved: the action, the slot to register
// into, and the bag slot holding the special scroll.
type ReverseSavedRequest struct {
	Action  byte
	Slot    byte
	BagSlot int32
}

func (r *ReverseSavedRequest) Encode() []byte {
	return append([]byte{r.Action, r.Slot}, encodeInt64(int64(r.BagSlot))...)
}

func DecodeReverseSavedRequest(data []byte) (*ReverseSavedRequest, error) {
	if len(data) != 10 {
		return nil, fmt.Errorf("session: decoding ReverseSavedRequest: %d bytes, want 10", len(data))
	}
	bag, _, err := decodeInt64(data[2:])
	if err != nil {
		return nil, fmt.Errorf("session: decoding ReverseSavedRequest: %w", err)
	}
	return &ReverseSavedRequest{Action: data[0], Slot: data[1], BagSlot: int32(bag)}, nil
}

// ReverseSavedResult is OpReverseSavedResult: OK and, for a refusal, the
// words; then every slot's point (Region 0 an empty slot), region-local as
// the stores keep them. Registered is true on an accepted registration, which
// the client says "Saved location has got updated." for.
type ReverseSavedResult struct {
	OK         bool
	Registered bool
	Reason     string
	Slots      []character.SavedPoint
}

func (r *ReverseSavedResult) Encode() []byte {
	out := []byte{boolByte(r.OK), boolByte(r.Registered)}
	out = append(out, encodeStrings(r.Reason)...)
	out = append(out, byte(len(r.Slots)))
	for _, p := range r.Slots {
		out = binary.LittleEndian.AppendUint32(out, uint32(int32(p.Region)))
		out = binary.LittleEndian.AppendUint32(out, math.Float32bits(float32(p.X)))
		out = binary.LittleEndian.AppendUint32(out, math.Float32bits(float32(p.Y)))
		out = binary.LittleEndian.AppendUint32(out, math.Float32bits(float32(p.Z)))
	}
	return out
}

func DecodeReverseSavedResult(data []byte) (*ReverseSavedResult, error) {
	if len(data) < 2 {
		return nil, fmt.Errorf("session: decoding ReverseSavedResult: short")
	}
	fields, rest, err := decodeStringsPrefix(data[2:], 1)
	if err != nil || len(rest) < 1 {
		return nil, fmt.Errorf("session: decoding ReverseSavedResult: %v", err)
	}
	r := &ReverseSavedResult{OK: data[0] != 0, Registered: data[1] != 0, Reason: fields[0]}
	n := int(rest[0])
	rest = rest[1:]
	if len(rest) != n*16 {
		return nil, fmt.Errorf("session: decoding ReverseSavedResult: %d slot bytes for %d slots", len(rest), n)
	}
	for i := 0; i < n; i++ {
		b := rest[i*16:]
		r.Slots = append(r.Slots, character.SavedPoint{
			Region: int(int32(binary.LittleEndian.Uint32(b))),
			X:      float64(math.Float32frombits(binary.LittleEndian.Uint32(b[4:]))),
			Y:      float64(math.Float32frombits(binary.LittleEndian.Uint32(b[8:]))),
			Z:      float64(math.Float32frombits(binary.LittleEndian.Uint32(b[12:]))),
		})
	}
	return r, nil
}

// addOnPoint is where option 4 or 5 sends characterID now: the party member
// whose JID is target, where it stands, or saved slot target. ok false with
// the reason the use is refused for.
func (s *ScrollCaster) addOnPoint(ctx context.Context, characterID int64, option byte, target uint32) (character.SavedPoint, bool, string) {
	var p character.SavedPoint
	switch option {
	case ReverseOptionParty:
		if s.parties == nil || s.hub == nil {
			return p, false, reverseNoPartyMember
		}
		pt, ok := s.parties.Get(characterID)
		if !ok {
			return p, false, reverseNoPartyMember
		}
		var memberID int64 = -1
		for _, m := range pt.Members {
			if m.JID() == target && m.CharacterID != characterID {
				memberID = m.CharacterID
			}
		}
		if memberID < 0 {
			return p, false, reverseNoPartyMember
		}
		e, ok := s.hub.EntityByCharacterID(memberID)
		if !ok {
			return p, false, reverseInvalidTargetArea
		}
		place, ok := placeOfEntity(e)
		if !ok || place.Region == 0 {
			return p, false, reverseInvalidTargetArea
		}
		p = character.SavedPoint{Region: place.Region, X: place.X, Y: place.Y, Z: place.Z, WorldID: teleport.MainWorld}
	case ReverseOptionSaved:
		store, ok := s.chars.(character.SavedLocationStore)
		if !ok || int(target) >= character.SavedLocationSlots {
			return p, false, reverseEmptySlot
		}
		slots, err := store.SavedLocations(ctx, characterID)
		if err != nil || !slots[target].Set() {
			return p, false, reverseEmptySlot
		}
		p = slots[target]
	default:
		return p, false, scrollReason(ScrollErrUnknownOption)
	}
	if _, _, _, _, ok := placeArrival(p.Region, p.X, p.Y, p.Z, p.WorldID); !ok {
		return p, false, reverseInvalidTargetArea
	}
	return p, true, ""
}

// savedRequest answers OpReverseSaved: the list, or a registration of where
// the character stands into req.Slot, which needs the special scroll in
// req.BagSlot (not spent).
func (s *ScrollCaster) savedRequest(ctx context.Context, sess *gateway.Session, inv inventory.Store, items ItemLookup, p *proto.Packet) error {
	reply := func(r *ReverseSavedResult) error {
		return sess.Send(&proto.Packet{Opcode: OpReverseSavedResult, Data: r.Encode()})
	}
	req, err := DecodeReverseSavedRequest(p.Data)
	if err != nil {
		return reply(&ReverseSavedResult{Reason: "malformed request"})
	}
	store, ok := s.chars.(character.SavedLocationStore)
	if !ok || s.hub == nil {
		return reply(&ReverseSavedResult{Reason: "saved locations are not kept here"})
	}
	e, ok := s.hub.EntityBySession(sess.ID())
	if !ok {
		return reply(&ReverseSavedResult{Reason: "not in the world"})
	}
	characterID := e.CharacterID
	list := func(registered bool) error {
		slots, err := store.SavedLocations(ctx, characterID)
		if err != nil {
			return reply(&ReverseSavedResult{Reason: "lookup failed"})
		}
		return reply(&ReverseSavedResult{OK: true, Registered: registered, Slots: slots})
	}
	if req.Action == ReverseSavedList {
		return list(false)
	}
	if req.Action != ReverseSavedRegister || int(req.Slot) >= character.SavedLocationSlots {
		return reply(&ReverseSavedResult{Reason: "malformed request"})
	}
	// The special scroll must be in the named bag slot.
	held := false
	if inv != nil && items != nil {
		if slots, err := inv.List(ctx, characterID); err == nil {
			for _, sl := range slots {
				if sl.Index == int(req.BagSlot) && sl.Quantity > 0 {
					it, err := items.GetItem(ctx, sl.ItemID)
					held = err == nil && IsSpecialReverseReturnScroll(it)
				}
			}
		}
	}
	if !held {
		return reply(&ReverseSavedResult{Reason: "the special reverse return scroll is not there"})
	}
	place, ok := placeOfEntity(e)
	if !ok || place.Region == 0 {
		return reply(&ReverseSavedResult{Reason: reverseInvalidTargetArea})
	}
	pt := character.SavedPoint{Region: place.Region, X: place.X, Y: place.Y, Z: place.Z, WorldID: teleport.MainWorld}
	if _, _, _, _, ok := placeArrival(pt.Region, pt.X, pt.Y, pt.Z, pt.WorldID); !ok {
		return reply(&ReverseSavedResult{Reason: reverseInvalidTargetArea})
	}
	if err := store.SetSavedLocation(ctx, characterID, int(req.Slot), pt); err != nil {
		return reply(&ReverseSavedResult{Reason: "saving failed"})
	}
	if s.logger != nil {
		s.logger.Info("reverse return: location saved", "character_id", characterID, "slot", req.Slot,
			"region", pt.Region, "x", pt.X, "z", pt.Z)
	}
	return list(true)
}
