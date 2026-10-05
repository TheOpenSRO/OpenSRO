package session

import (
	"context"
	"errors"
	"fmt"

	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
)

// Rearranging the bag: what dragging a stack from one slot onto another
// does. Our own protocol, like the rest of the inventory ops; requires a
// prior OpLogin. The outcome (move, merge or swap) is inventory.Store's
// MoveItem rule -- the server decides, the client only asks.
const (
	OpInventoryMove       uint16 = 0x0032 // client -> server
	OpInventoryMoveResult uint16 = 0x0033 // server -> client
)

// InventoryMoveRequest asks to move whatever is in bag slot From onto To.
type InventoryMoveRequest struct {
	CharacterName string
	From          int32
	To            int32
	// Count is how many of From's stack to move (round 728, the stack split):
	// 0 -- or absent, as an older client sends it -- moves the whole stack, as
	// retail's bag -> bag drop does (quantity -1, docs/protocol/held_icon.md).
	// A count below the stack splits it into To, which must be empty
	// (inventory.Splitter).
	Count int32
}

func (r *InventoryMoveRequest) Encode() []byte {
	out := append(encodeStrings(r.CharacterName), encodeInt64(int64(r.From))...)
	out = append(out, encodeInt64(int64(r.To))...)
	if r.Count > 0 {
		out = append(out, encodeInt64(int64(r.Count))...)
	}
	return out
}

func DecodeInventoryMoveRequest(data []byte) (*InventoryMoveRequest, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding InventoryMoveRequest: %w", err)
	}
	from, rest, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding InventoryMoveRequest: from: %w", err)
	}
	to, rest, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding InventoryMoveRequest: to: %w", err)
	}
	req := &InventoryMoveRequest{CharacterName: fields[0], From: int32(from), To: int32(to)}
	if count, _, err := decodeInt64(rest); err == nil && count > 0 {
		req.Count = int32(count)
	}
	return req, nil
}

// InventoryMoveHandler returns a gateway.Handler implementing OpInventoryMove.
//
// The reply is an InventoryListResult on OpInventoryMoveResult: the error, or
// the whole bag as it stands after the move with the bag's size after it
// (bagListResult) -- so the client redraws from the server's own answer
// instead of assuming the move happened and asking again. A slot at or past
// the character's size is refused as "invalid slot" (the store's capacity,
// inventory.BagCapacity): the client locks it (0x6b6620), and the server
// holds the same line.
func InventoryMoveHandler(chars character.Store, inv inventory.Store, items ItemLookup) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpInventoryMove {
			return nil
		}
		fail := func(reason string) error {
			return sess.Send(&proto.Packet{Opcode: OpInventoryMoveResult, Data: (&InventoryListResult{Error: reason}).Encode()})
		}
		req, err := DecodeInventoryMoveRequest(p.Data)
		if err != nil {
			return fail("malformed request")
		}
		characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
		if errStr != "" {
			return fail(errStr)
		}
		if inv == nil {
			return fail("no inventory")
		}

		var err2 error
		if sp, ok := inv.(inventory.Splitter); ok && req.Count > 0 && splitsStack(ctx, inv, characterID, int(req.From), int(req.Count)) {
			err2 = sp.SplitItem(ctx, characterID, int(req.From), int(req.To), int(req.Count))
		} else {
			err2 = inv.MoveItem(ctx, characterID, int(req.From), int(req.To))
		}
		if err := err2; err != nil {
			switch {
			case errors.Is(err, inventory.ErrSlotTaken):
				return fail("slot is taken")
			case errors.Is(err, inventory.ErrSplitCount):
				return fail("invalid count")
			case errors.Is(err, inventory.ErrInvalidSlot):
				return fail("invalid slot")
			case errors.Is(err, inventory.ErrSlotEmpty):
				return fail("slot is empty")
			default:
				return fail("move failed")
			}
		}

		slots, err := inv.List(ctx, characterID)
		if err != nil {
			return fail("list failed")
		}
		return sess.Send(&proto.Packet{Opcode: OpInventoryMoveResult, Data: bagListResult(ctx, inv, characterID, slots, items).Encode()})
	}
}

// splitsStack says whether moving count out of slot from is a split: less than
// the stack it holds (a count at or past the stack moves the whole stack).
func splitsStack(ctx context.Context, inv inventory.Store, characterID int64, from, count int) bool {
	slots, err := inv.List(ctx, characterID)
	if err != nil {
		return false
	}
	for _, sl := range slots {
		if sl.Index == from {
			return count < sl.Quantity
		}
	}
	return false
}
