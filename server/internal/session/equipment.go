package session

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"

	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
)

// Equipment opcodes, our own protocol. All take a character name (like
// inventory/world) and require a prior OpLogin.
const (
	OpEquipmentList   uint16 = 0x0040 // client -> server
	OpEquipmentResult uint16 = 0x0041 // server -> client (list, or equip/unequip result)
	OpEquip           uint16 = 0x0042 // client -> server
	OpUnequip         uint16 = 0x0043 // client -> server
)

// EquippedSnapshot is one equipped item, as sent over the wire.
type EquippedSnapshot struct {
	Slot   int
	ItemID int64
}

func (e *EquippedSnapshot) Encode() []byte {
	out := make([]byte, 4)
	binary.LittleEndian.PutUint32(out, uint32(e.Slot))
	return append(out, encodeInt64(e.ItemID)...)
}

func decodeEquippedSnapshot(data []byte) (*EquippedSnapshot, []byte, error) {
	if len(data) < 4 {
		return nil, nil, errors.New("slot: truncated")
	}
	slot := int(binary.LittleEndian.Uint32(data))
	itemID, rest, err := decodeInt64(data[4:])
	if err != nil {
		return nil, nil, fmt.Errorf("item id: %w", err)
	}
	return &EquippedSnapshot{Slot: slot, ItemID: itemID}, rest, nil
}

// EquipmentResult is the OpEquipmentResult payload: either a list (from
// OpEquipmentList) or just an error/success marker (from OpEquip/OpUnequip
// -- Items is empty on those).
type EquipmentResult struct {
	Error string
	Items []EquippedSnapshot
}

func (r *EquipmentResult) Encode() []byte {
	out := encodeStrings(r.Error)
	countBuf := make([]byte, 2)
	binary.LittleEndian.PutUint16(countBuf, uint16(len(r.Items)))
	out = append(out, countBuf...)
	for _, it := range r.Items {
		out = append(out, it.Encode()...)
	}
	return out
}

func DecodeEquipmentResult(data []byte) (*EquipmentResult, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding EquipmentResult: %w", err)
	}
	if len(rest) < 2 {
		return nil, errors.New("session: decoding EquipmentResult: truncated count")
	}
	count := int(binary.LittleEndian.Uint16(rest))
	rest = rest[2:]

	result := &EquipmentResult{Error: fields[0]}
	for i := 0; i < count; i++ {
		var snap *EquippedSnapshot
		snap, rest, err = decodeEquippedSnapshot(rest)
		if err != nil {
			return nil, fmt.Errorf("session: decoding EquipmentResult: item %d: %w", i, err)
		}
		result.Items = append(result.Items, *snap)
	}
	return result, nil
}

// EquipRequest is the OpEquip payload: which character, which equipment
// slot, and which inventory slot to equip from.
type EquipRequest struct {
	CharacterName string
	Slot          equipment.Slot
	InventorySlot int
}

func (r *EquipRequest) Encode() []byte {
	out := encodeStrings(r.CharacterName)
	buf := make([]byte, 8)
	binary.LittleEndian.PutUint32(buf[0:4], uint32(r.Slot))
	binary.LittleEndian.PutUint32(buf[4:8], uint32(r.InventorySlot))
	return append(out, buf...)
}

func DecodeEquipRequest(data []byte) (*EquipRequest, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding EquipRequest: %w", err)
	}
	if len(rest) < 8 {
		return nil, errors.New("session: decoding EquipRequest: truncated")
	}
	slot := equipment.Slot(binary.LittleEndian.Uint32(rest[0:4]))
	invSlot := int(binary.LittleEndian.Uint32(rest[4:8]))
	return &EquipRequest{CharacterName: fields[0], Slot: slot, InventorySlot: invSlot}, nil
}

// UnequipRequest is the OpUnequip payload: which character, which slot.
type UnequipRequest struct {
	CharacterName string
	Slot          equipment.Slot
}

func (r *UnequipRequest) Encode() []byte {
	out := encodeStrings(r.CharacterName)
	buf := make([]byte, 4)
	binary.LittleEndian.PutUint32(buf, uint32(r.Slot))
	return append(out, buf...)
}

func DecodeUnequipRequest(data []byte) (*UnequipRequest, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding UnequipRequest: %w", err)
	}
	if len(rest) < 4 {
		return nil, errors.New("session: decoding UnequipRequest: truncated")
	}
	slot := equipment.Slot(binary.LittleEndian.Uint32(rest))
	return &UnequipRequest{CharacterName: fields[0], Slot: slot}, nil
}

// EquipmentHandler returns a gateway.Handler implementing
// OpEquipmentList/OpEquip/OpUnequip against store, resolving character
// names against whichever account authenticated on the connection.
func EquipmentHandler(chars character.Store, store equipment.Store) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		switch p.Opcode {
		case OpEquipmentList:
			return handleEquipmentList(ctx, sess, p, chars, store)
		case OpEquip:
			return handleEquip(ctx, sess, p, chars, store)
		case OpUnequip:
			return handleUnequip(ctx, sess, p, chars, store)
		default:
			return nil
		}
	}
}

func resolveCharacterID(ctx context.Context, sess *gateway.Session, chars character.Store, name string) (int64, string) {
	accountID, ok := AuthenticatedAccountID(sess)
	if !ok {
		return -1, errNotAuthenticated
	}
	list, err := chars.ListByAccount(ctx, accountID)
	if err != nil {
		return -1, "lookup failed"
	}
	for _, c := range list {
		if c.Name == name {
			return c.ID, ""
		}
	}
	return -1, "no such character on this account"
}

func handleEquipmentList(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, store equipment.Store) error {
	req, err := DecodeCharacterNameRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpEquipmentResult, Data: (&EquipmentResult{Error: "malformed request"}).Encode()})
	}
	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.Name)
	if errStr != "" {
		return sess.Send(&proto.Packet{Opcode: OpEquipmentResult, Data: (&EquipmentResult{Error: errStr}).Encode()})
	}

	items, err := store.Get(ctx, characterID)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpEquipmentResult, Data: (&EquipmentResult{Error: "list failed"}).Encode()})
	}
	snaps := make([]EquippedSnapshot, len(items))
	for i, it := range items {
		snaps[i] = EquippedSnapshot{Slot: int(it.Slot), ItemID: it.ItemID}
	}
	return sess.Send(&proto.Packet{Opcode: OpEquipmentResult, Data: (&EquipmentResult{Items: snaps}).Encode()})
}

func handleEquip(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, store equipment.Store) error {
	req, err := DecodeEquipRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpEquipmentResult, Data: (&EquipmentResult{Error: "malformed request"}).Encode()})
	}
	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
	if errStr != "" {
		return sess.Send(&proto.Packet{Opcode: OpEquipmentResult, Data: (&EquipmentResult{Error: errStr}).Encode()})
	}

	if err := store.Equip(ctx, characterID, req.Slot, req.InventorySlot); err != nil {
		return sess.Send(&proto.Packet{Opcode: OpEquipmentResult, Data: (&EquipmentResult{Error: equipErrorMessage(err)}).Encode()})
	}
	return sess.Send(&proto.Packet{Opcode: OpEquipmentResult, Data: (&EquipmentResult{}).Encode()})
}

func handleUnequip(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, store equipment.Store) error {
	req, err := DecodeUnequipRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpEquipmentResult, Data: (&EquipmentResult{Error: "malformed request"}).Encode()})
	}
	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
	if errStr != "" {
		return sess.Send(&proto.Packet{Opcode: OpEquipmentResult, Data: (&EquipmentResult{Error: errStr}).Encode()})
	}

	if err := store.Unequip(ctx, characterID, req.Slot); err != nil {
		return sess.Send(&proto.Packet{Opcode: OpEquipmentResult, Data: (&EquipmentResult{Error: equipErrorMessage(err)}).Encode()})
	}
	return sess.Send(&proto.Packet{Opcode: OpEquipmentResult, Data: (&EquipmentResult{}).Encode()})
}

func equipErrorMessage(err error) string {
	switch {
	case errors.Is(err, equipment.ErrInvalidSlot):
		return "invalid slot"
	case errors.Is(err, equipment.ErrSlotEmpty):
		return "slot is empty"
	case errors.Is(err, equipment.ErrInventorySlotEmpty):
		return "inventory slot is empty"
	default:
		return "operation failed"
	}
}
