package session

import (
	"context"
	"encoding/binary"
	"fmt"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/durability"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/repair"
	"github.com/TheOpenSRO/OpenSRO/server/internal/trade"
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

// RepairBagSlotBase is where a bag slot starts in a request's Slot and in
// the reply's durability block: the original's own numbering (0x703E's slot
// is the equipment slot as is, or the bag slot + 13 -- READ, the client's
// 0x78fcf0; round 829).
const RepairBagSlotBase = 13

// RepairHandlerWithBag returns a gateway.Handler for OpRepair: it restores a
// worn item, a bag item, or (RepairAllSlots) every one of them, charging the
// gold the cost model asks (repair.Estimate: unit price = itemdata col 27 /
// max, floor 1, times the missing points). Refuses with the engine's own
// codes, including 0x1c0b IM_BUSY for a character a trade holds
// (tradebusy.go); trades and inv may be nil.
//
// Round 829 (the retail server's MsgHandler_703e, gs 0x4c7a10, from its
// decompile): a repair-all asks HandleRepairRequest of every slot, the worn
// ones and then the bag's, and stops at the first 0x1c07 (not enough gold);
// before, ours repaired the worn items only and carried on past a refusal.
// A broken item pays its restore fee (refdata.Item.ReviveCost) first.
func RepairHandlerWithBag(chars character.Store, eq equipment.Store, inv inventory.Store, items ItemLookup, trades *trade.Hub) gateway.Handler {
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

		// What can be mended: the worn items, then the bag's, each with the
		// slot number the request and the reply use.
		type mendable struct {
			slot       int // equipment slot, or RepairBagSlotBase + bag slot
			itemID     int64
			variance   uint64
			durability int
			set        func(d int) error
		}
		var list []mendable
		for _, e := range worn {
			e := e
			list = append(list, mendable{int(e.Slot), e.ItemID, e.Variance, e.Durability,
				func(d int) error { return eq.SetDurability(ctx, characterID, e.Slot, d) }})
		}
		if inv != nil {
			if bag, err := inv.List(ctx, characterID); err == nil {
				for _, b := range bag {
					b := b
					list = append(list, mendable{RepairBagSlotBase + b.Index, b.ItemID, b.Variance, b.Durability,
						func(d int) error { return inv.SetDurability(ctx, characterID, b.Index, d) }})
				}
			}
		}

		var spent int64
		var mended []DurabilitySnapshot
		lastRefusal := int32(repair.ErrNothingToRepair)
		for _, e := range list {
			if req.Slot != RepairAllSlots && int32(e.slot) != req.Slot {
				continue
			}
			if e.durability == durability.Untracked {
				continue
			}
			item, err := items.GetItem(ctx, e.itemID)
			if err != nil || item == nil || item.DurabilityMax <= 0 {
				continue
			}
			max := durability.MaxDurability(item.DurabilityMin, item.DurabilityMax, e.variance)
			// Round 829: a broken item pays its restore fee first, then is
			// mended as from 1 (HandleRepairRequest's item[100] branch:
			// `if (gold < cost) -> 0x1c07; gold -= cost;`, and FUN_00496e60
			// treats 0 as 1 -- docs/protocol/durability.md).
			cur := e.durability
			var fee int64
			if cur == 0 && max > 1 {
				if gold <= 0 || gold < item.ReviveCost {
					lastRefusal = int32(repair.ErrNotEnoughMoney)
					break
				}
				fee = item.ReviveCost
				cur = 1
			}
			q := repair.Estimate(gold-fee, item.RepairCost, max, cur)
			if q.Refusal != 0 {
				lastRefusal = int32(q.Refusal)
				if q.Refusal == repair.ErrNotEnoughMoney {
					break
				}
				continue
			}
			cost := int64(q.Cost)
			if cost < 0 {
				cost = 0
			}
			cost += fee
			if err := chars.DeductGold(ctx, characterID, cost); err != nil {
				lastRefusal = int32(repair.ErrNotEnoughMoney)
				break
			}
			// Estimate can stop short of full when the character cannot afford
			// it all; restore exactly the units paid for.
			if err := e.set(cur + q.Units); err != nil {
				chars.AddGold(ctx, characterID, cost) // put the money back
				return fail(int32(repair.ErrCannotBeRepaired))
			}
			// Round 769: a broken piece mended counts again.
			character.InvalidateBonus(characterID)
			gold -= cost
			spent += cost
			if e.slot >= RepairBagSlotBase {
				mended = append(mended, DurabilitySnapshot{Slot: e.slot, Durability: cur + q.Units, MaxDurability: max})
			} else {
				mended = append(mended, DurabilitySnapshot{Slot: -1})
			}
		}
		if len(mended) == 0 {
			return fail(lastRefusal)
		}
		// The worn slots' durability as it is now, then each bag item mended
		// (slot RepairBagSlotBase + its bag slot), so the client sounds and
		// flashes every item whose durability rose (0x3052's handler).
		durs := equipmentDurabilities(ctx, mustWorn(ctx, eq, characterID), items)
		for _, m := range mended {
			if m.Slot >= RepairBagSlotBase {
				durs = append(durs, m)
			}
		}
		return sess.Send(&proto.Packet{Opcode: OpRepairResult, Data: (&RepairResult{
			Code:         0,
			GoldSpent:    spent,
			Durabilities: durs,
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
