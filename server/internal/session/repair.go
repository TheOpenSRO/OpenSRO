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
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
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

// The repair hammer (round 838): ITEM_MALL_REPAIR_HAMMER and its event and
// quest twins, TypeID 3/3/13/7. READ in SR_GameServer,
// CGItemExpendable::UseByKind (0x0049c2b0) case 7 (0x49c448..0x49c4db): for
// every slot of the character's storage -- the worn 0..12 and the bag -- an
// item that IsEquip (vslot 0x84) and CanRepair (vslot 0xd8) whose current
// durability is not its max gets CGObjPC::ChangeItemDurability(slot, max -
// cur), which clamps, puts a broken worn item's stats back and sends 0x3052;
// no gold is read. None mended answers 0x1888
// UIIT_MSG_STRGERR_THERE_IS_NO_ITEM_TO_REPAIR and keeps the hammer; else the
// use answers 1 and DoJob spends one. Param1 (2 on every row, "1=?, 2=?") is
// never read by the case.
//
// Not modelled (as in the NPC repair above): the 'rep' option's decrement
// (FUN_00491890) and UseByKind's logout refusal 0x186b. OURS: an item counts
// as CanRepair when it has a durability range (the CanRepair column is not
// exported; MEASURED, every 3/1 row with a range has CanRepair 1 -- the
// accessories, job suits and avatars that have 0 carry no range).
const (
	repairHammerKind = 7 // UseByKind case 7
	// ErrNoItemToRepair is 0x1888, UIIT_MSG_STRGERR_THERE_IS_NO_ITEM_TO_REPAIR.
	ErrNoItemToRepair uint16 = 0x1888
)

// useItemEquipment is the worn-item store the repair hammer mends (round
// 838). UseItemHandler takes none, so cmd/server sets it once at start-up
// (SetUseItemEquipment), before any session is served; nil refuses the
// hammer.
var useItemEquipment equipment.Store

// SetUseItemEquipment wires the worn-item store into the item uses.
func SetUseItemEquipment(eq equipment.Store) { useItemEquipment = eq }

// isRepairHammer reports a 3/3/13/7 row.
func isRepairHammer(it *refdata.Item) bool {
	return it != nil && it.TypeID1 == equipment.TypeItem && it.TypeID2 == equipment.TypeExpendable &&
		it.TypeID3 == 13 && it.TypeID4 == repairHammerKind
}

// useRepairHammer runs UseByKind case 7 for characterID's hammer in held.
func useRepairHammer(ctx context.Context, sess *gateway.Session, eq equipment.Store, inv inventory.Store, items ItemLookup,
	characterID int64, it *refdata.Item, held inventory.Slot, have int) error {
	refuse := func(code uint16, reason string) error {
		return sess.Send(&proto.Packet{Opcode: OpUseItemResult, Data: (&UseItemResult{Error: reason, Code: code}).Encode()})
	}
	if eq == nil || inv == nil || items == nil {
		return refuse(0, "cannot use items")
	}
	type mendable struct {
		slot       int // the equipment slot, or RepairBagSlotBase + the bag slot
		itemID     int64
		variance   uint64
		durability int
		set        func(d int) error
	}
	var list []mendable
	worn, err := eq.Get(ctx, characterID)
	if err != nil {
		return refuse(0, "lookup failed")
	}
	for _, e := range worn {
		e := e
		list = append(list, mendable{int(e.Slot), e.ItemID, e.Variance, e.Durability,
			func(d int) error { return eq.SetDurability(ctx, characterID, e.Slot, d) }})
	}
	bag, err := inv.List(ctx, characterID)
	if err != nil {
		return refuse(0, "lookup failed")
	}
	for _, b := range bag {
		b := b
		list = append(list, mendable{RepairBagSlotBase + b.Index, b.ItemID, b.Variance, b.Durability,
			func(d int) error { return inv.SetDurability(ctx, characterID, b.Index, d) }})
	}
	type mendedItem struct{ slot, durability int }
	var mended []mendedItem
	for _, e := range list {
		if e.durability == durability.Untracked {
			continue
		}
		ref, err := items.GetItem(ctx, e.itemID)
		if err != nil || ref == nil || ref.TypeID2 != equipment.TypeEquipment || ref.DurabilityMax <= 0 {
			continue
		}
		max := durability.MaxDurability(ref.DurabilityMin, ref.DurabilityMax, e.variance)
		if e.durability == max {
			continue
		}
		if err := e.set(max); err != nil {
			continue
		}
		mended = append(mended, mendedItem{e.slot, max})
	}
	if len(mended) == 0 {
		return refuse(ErrNoItemToRepair, "no item needs repairing")
	}
	if err := inv.RemoveItem(ctx, characterID, held.Index, 1); err != nil {
		// The items stay mended: the engine's job ran before DoJob's count
		// (OURS: a removal that fails is a store error the engine has none of).
		return refuse(0, "using failed")
	}
	// A broken piece mended counts again (round 769).
	character.InvalidateBonus(characterID)
	if err := sess.Send(&proto.Packet{Opcode: OpUseItemResult, Data: (&UseItemResult{
		Remaining: int32(have - 1), ItemID: uint32(it.ID),
	}).Encode()}); err != nil {
		return err
	}
	// ChangeItemDurability's 0x3052, one per item, after the use's answer
	// (OURS order: the engine's go out inside the job, before DoJob answers).
	for _, m := range mended {
		if err := sess.Send(&proto.Packet{Opcode: OpDurabilityChanged, Data: EncodeDurabilityChanged(m.slot, m.durability)}); err != nil {
			return err
		}
	}
	return nil
}

// mustWorn re-reads the worn list after a repair, empty on error.
func mustWorn(ctx context.Context, eq equipment.Store, characterID int64) []equipment.Equipped {
	worn, err := eq.Get(ctx, characterID)
	if err != nil {
		return nil
	}
	return worn
}
