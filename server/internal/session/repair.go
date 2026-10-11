package session

import (
	"context"
	"encoding/binary"
	"fmt"

	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/durability"
	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/repair"
	"github.com/OpenSRO/OpenSRO/server/internal/trade"
)

// Repair opcodes, our own protocol. An NPC's repair buttons; the cost model
// is repair.Estimate (docs/protocol/durability.md).
const (
	OpRepair       uint16 = 0x007a // client -> server
	OpRepairResult uint16 = 0x007b // server -> client
)

// RepairAllSlots in a request's Slot means "repair every worn item".
const RepairAllSlots int32 = -1

// RepairRequest is the OpRepair payload: repair one worn slot, or all.
type RepairRequest struct {
	CharacterName string
	Slot          int32 // an equipment.Slot, or RepairAllSlots
}

func (r *RepairRequest) Encode() []byte {
	out := encodeStrings(r.CharacterName)
	buf := make([]byte, 4)
	binary.LittleEndian.PutUint32(buf, uint32(r.Slot))
	return append(out, buf...)
}

func DecodeRepairRequest(data []byte) (*RepairRequest, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding RepairRequest: %w", err)
	}
	if len(rest) < 4 {
		return nil, fmt.Errorf("session: decoding RepairRequest: truncated")
	}
	return &RepairRequest{CharacterName: fields[0], Slot: int32(binary.LittleEndian.Uint32(rest))}, nil
}

// RepairResult is the OpRepairResult payload: a refusal code (0 = repaired),
// the gold spent, and the worn slots' durability afterwards so the window
// refreshes.
type RepairResult struct {
	Code         int32
	GoldSpent    int64
	Durabilities []DurabilitySnapshot
}

func (r *RepairResult) Encode() []byte {
	out := make([]byte, 12)
	binary.LittleEndian.PutUint32(out[0:4], uint32(r.Code))
	binary.LittleEndian.PutUint64(out[4:12], uint64(r.GoldSpent))
	return encodeDurabilityBlock(out, r.Durabilities)
}

func DecodeRepairResult(data []byte) (*RepairResult, error) {
	if len(data) < 12 {
		return nil, fmt.Errorf("session: decoding RepairResult: truncated")
	}
	r := &RepairResult{
		Code:      int32(binary.LittleEndian.Uint32(data[0:4])),
		GoldSpent: int64(binary.LittleEndian.Uint64(data[4:12])),
	}
	r.Durabilities = decodeDurabilityBlock(data[12:])
	return r, nil
}

// RepairHandler returns a gateway.Handler for OpRepair: it restores a worn
// item (or all worn items) to full durability, charging the gold the cost
// model asks (repair.Estimate: unit price = itemdata col 28 / max, floor 1,
// times the missing points). Refuses with the engine's own codes, including
// 0x1c0b IM_BUSY for a character a trade holds (tradebusy.go); trades may be
// nil.
func RepairHandler(chars character.Store, eq equipment.Store, items ItemLookup, trades *trade.Hub) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpRepair {
			return nil
		}
		fail := func(code int32) error {
			return sess.Send(&proto.Packet{Opcode: OpRepairResult, Data: (&RepairResult{Code: code}).Encode()})
		}
		req, err := DecodeRepairRequest(p.Data)
		if err != nil {
			return fail(int32(repair.ErrCannotBeRepaired))
		}
		characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
		if errStr != "" {
			return fail(int32(repair.ErrCannotBeRepaired))
		}
		if trades.Busy(characterID) {
			return fail(interactionBusyCode)
		}
		if items == nil {
			return fail(int32(repair.ErrCannotBeRepaired))
		}
		worn, err := eq.Get(ctx, characterID)
		if err != nil {
			return fail(int32(repair.ErrCannotBeRepaired))
		}
		c, err := chars.GetByID(ctx, characterID)
		if err != nil || c == nil {
			return fail(int32(repair.ErrCannotBeRepaired))
		}
		gold := c.Gold

		var spent int64
		repairedAny := false
		lastRefusal := int32(repair.ErrNothingToRepair)
		for _, e := range worn {
			if req.Slot != RepairAllSlots && int32(e.Slot) != req.Slot {
				continue
			}
			if e.Durability == durability.Untracked {
				continue
			}
			item, err := items.GetItem(ctx, e.ItemID)
			if err != nil || item == nil || item.DurabilityMax <= 0 {
				continue
			}
			max := durability.MaxDurability(item.DurabilityMin, item.DurabilityMax, e.Variance)
			q := repair.Estimate(gold, item.RepairCost, max, e.Durability)
			if q.Refusal != 0 {
				lastRefusal = int32(q.Refusal)
				continue
			}
			cost := int64(q.Cost)
			if cost < 0 {
				cost = 0
			}
			if err := chars.DeductGold(ctx, characterID, cost); err != nil {
				lastRefusal = int32(repair.ErrNotEnoughMoney)
				continue
			}
			// Estimate can stop short of full when the character cannot afford
			// it all; restore exactly the units paid for.
			if err := eq.SetDurability(ctx, characterID, e.Slot, e.Durability+q.Units); err != nil {
				chars.AddGold(ctx, characterID, cost) // put the money back
				return fail(int32(repair.ErrCannotBeRepaired))
			}
			// Round 769: a broken piece mended counts again.
			character.InvalidateBonus(characterID)
			gold -= cost
			spent += cost
			repairedAny = true
		}
		if !repairedAny {
			return fail(lastRefusal)
		}
		return sess.Send(&proto.Packet{Opcode: OpRepairResult, Data: (&RepairResult{
			Code:         0,
			GoldSpent:    spent,
			Durabilities: equipmentDurabilities(ctx, mustWorn(ctx, eq, characterID), items),
		}).Encode()})
	}
}

// mustWorn re-reads the worn list after a repair, empty on error.
func mustWorn(ctx context.Context, eq equipment.Store, characterID int64) []equipment.Equipped {
	worn, err := eq.Get(ctx, characterID)
	if err != nil {
		return nil
	}
	return worn
}
