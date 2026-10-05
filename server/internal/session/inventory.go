package session

import (
	"context"
	"encoding/binary"
	"fmt"

	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
)

// Inventory opcodes, our own protocol. Requires a prior OpLogin. Listing
// lives here; rearranging the bag is OpInventoryMove (inventorymove.go).
// Adding and removing are never exposed directly -- they happen through the
// systems that legitimately do them (shop, loot, storage, trade, use).
const (
	OpInventoryList       uint16 = 0x0030 // client -> server
	OpInventoryListResult uint16 = 0x0031 // server -> client
)

// InventorySlotSnapshot is one occupied slot, as sent over the wire.
type InventorySlotSnapshot struct {
	Slot     int
	ItemID   int64
	Quantity int
}

// inventorySlotSnapshotSize is one encoded slot: u32 slot, i64 item, u32 count.
const inventorySlotSnapshotSize = 4 + 8 + 4

func (s *InventorySlotSnapshot) Encode() []byte {
	out := make([]byte, 4)
	binary.LittleEndian.PutUint32(out, uint32(s.Slot))
	out = append(out, encodeInt64(s.ItemID)...)
	countBuf := make([]byte, 4)
	binary.LittleEndian.PutUint32(countBuf, uint32(s.Quantity))
	return append(out, countBuf...)
}

func decodeInventorySlotSnapshot(data []byte) (*InventorySlotSnapshot, []byte, error) {
	if len(data) < 4 {
		return nil, nil, fmt.Errorf("slot index: truncated")
	}
	slot := int(binary.LittleEndian.Uint32(data))
	rest := data[4:]

	itemID, rest, err := decodeInt64(rest)
	if err != nil {
		return nil, nil, fmt.Errorf("item id: %w", err)
	}

	if len(rest) < 4 {
		return nil, nil, fmt.Errorf("quantity: truncated")
	}
	qty := int(binary.LittleEndian.Uint32(rest))
	rest = rest[4:]

	return &InventorySlotSnapshot{Slot: slot, ItemID: itemID, Quantity: qty}, rest, nil
}

// InventoryListResult is the OpInventoryListResult payload.
type InventoryListResult struct {
	Error string // non-empty on failure; Slots is empty in that case
	Slots []InventorySlotSnapshot
	// Durabilities is the trailing per-slot durability block (see
	// DurabilitySnapshot): additive, so an older client ignores it.
	Durabilities []DurabilitySnapshot
}

func (r *InventoryListResult) Encode() []byte {
	out := encodeStrings(r.Error)
	countBuf := make([]byte, 2)
	binary.LittleEndian.PutUint16(countBuf, uint16(len(r.Slots)))
	out = append(out, countBuf...)
	for _, sl := range r.Slots {
		out = append(out, sl.Encode()...)
	}
	return encodeDurabilityBlock(out, r.Durabilities)
}

func DecodeInventoryListResult(data []byte) (*InventoryListResult, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding InventoryListResult: %w", err)
	}
	if len(rest) < 2 {
		return nil, fmt.Errorf("session: decoding InventoryListResult: truncated slot count")
	}
	count := int(binary.LittleEndian.Uint16(rest))
	rest = rest[2:]

	result := &InventoryListResult{Error: fields[0]}
	for i := 0; i < count; i++ {
		var snap *InventorySlotSnapshot
		snap, rest, err = decodeInventorySlotSnapshot(rest)
		if err != nil {
			return nil, fmt.Errorf("session: decoding InventoryListResult: slot %d: %w", i, err)
		}
		result.Slots = append(result.Slots, *snap)
	}
	result.Durabilities = decodeDurabilityBlock(rest)
	return result, nil
}

// InventoryHandler returns a gateway.Handler implementing OpInventoryList
// against store, scoped to whichever account authenticated on the
// connection. Takes character name via the same "resolve by name against
// the authenticated account" pattern as WorldHandler.
func InventoryHandler(chars character.Store, store inventory.Store, items ItemLookup) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpInventoryList {
			return nil
		}

		accountID, ok := AuthenticatedAccountID(sess)
		if !ok {
			return sess.Send(&proto.Packet{
				Opcode: OpInventoryListResult,
				Data:   (&InventoryListResult{Error: errNotAuthenticated}).Encode(),
			})
		}

		req, err := DecodeCharacterNameRequest(p.Data)
		if err != nil {
			return sess.Send(&proto.Packet{
				Opcode: OpInventoryListResult,
				Data:   (&InventoryListResult{Error: "malformed request"}).Encode(),
			})
		}

		list, err := chars.ListByAccount(ctx, accountID)
		if err != nil {
			return sess.Send(&proto.Packet{
				Opcode: OpInventoryListResult,
				Data:   (&InventoryListResult{Error: "lookup failed"}).Encode(),
			})
		}
		var characterID int64 = -1
		for _, c := range list {
			if c.Name == req.Name {
				characterID = c.ID
				break
			}
		}
		if characterID == -1 {
			return sess.Send(&proto.Packet{
				Opcode: OpInventoryListResult,
				Data:   (&InventoryListResult{Error: "no such character on this account"}).Encode(),
			})
		}

		slots, err := store.List(ctx, characterID)
		if err != nil {
			return sess.Send(&proto.Packet{
				Opcode: OpInventoryListResult,
				Data:   (&InventoryListResult{Error: "list failed"}).Encode(),
			})
		}

		return sess.Send(&proto.Packet{
			Opcode: OpInventoryListResult,
			Data:   bagListResult(ctx, store, characterID, slots, items).Encode(),
		})
	}
}

// bagListResult is the bag as a list reply: its occupied slots, their
// durabilities and -- since round 633 -- the bag's own size as the trailing
// u16 capacity (StorageListResult's shape, which the warehouse list has
// carried since round 498). The client pages its 32-slot lattice by it and
// locks the slots past it, as the original does with the InventorySize the
// character data carries (IFInventory 0x6b6620). An older client stops
// reading after the durability block and never sees it.
func bagListResult(ctx context.Context, store inventory.Store, characterID int64, slots []inventory.Slot, items ItemLookup) *StorageListResult {
	snaps := make([]InventorySlotSnapshot, len(slots))
	for i, sl := range slots {
		snaps[i] = InventorySlotSnapshot{Slot: sl.Index, ItemID: sl.ItemID, Quantity: sl.Quantity}
	}
	return &StorageListResult{
		InventoryListResult: InventoryListResult{Slots: snaps, Durabilities: inventoryDurabilities(ctx, slots, items)},
		Capacity:            inventory.CapacityOf(ctx, store, characterID),
		Infos:               slotItemInfos(ctx, slots, items),
	}
}
