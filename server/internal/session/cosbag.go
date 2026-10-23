package session

import (
	"context"
	"encoding/binary"

	"github.com/TheOpenSRO/OpenSRO/server/internal/cos"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
)

// The ability pet's bag moves (round 795; 0x7034, READ the request parser
// GObjPC::FUN_004d8bf0 and the handlers s:0x523860 / 0x523aa0 with
// FUN_00523960, docs/protocol/pets.md "The pet's bag"). Pet slots are 0..n-1
// on the wire, bag slots the bag index + 13.
//
//	0x10  pet -> pet   u32 cos, u8 src, u8 dst, u16 count
//	0x1a  pet -> bag   u32 cos, u8 src, u8 dst (bag + 13)
//	0x1b  bag -> pet   u32 cos, u8 src (bag + 13), u8 dst
//
// The success reply is 0xB034 {1, type, u32 cos, u8 src, u8 dst[, u16
// count]}; a failure {2, u16 code}.
const (
	ItemMoveCOSToCOS byte = 0x10
	ItemMoveCOSToBag byte = 0x1a
	ItemMoveBagToCOS byte = 0x1b
	itemErrSumItem        = 0x18b1 // CANT_MOVETO_SUMITEM
	itemErrBadTarget      = 0x1843 // INVALID_TARGET_STORAGE
)

// isCOSBagMove reports a 0x7034 type this file takes.
func isCOSBagMove(t byte) bool {
	return t == ItemMoveCOSToCOS || t == ItemMoveCOSToBag || t == ItemMoveBagToCOS
}

// handleCOSBagMove is one of them.
func handleCOSBagMove(ctx context.Context, sess *gateway.Session, owner int64, data []byte, inv inventory.Store) error {
	fail := func(code uint16) error {
		return sess.Send(&proto.Packet{Opcode: OpItemMoveResult, Data: EncodeItemFail(code)})
	}
	if len(data) < 7 {
		return fail(ItemErrDB)
	}
	t := data[0]
	uid := binary.LittleEndian.Uint32(data[1:])
	src, dst := int(data[5]), int(data[6])
	o := cosWorld.ownedOf(owner, uid)
	if o == nil {
		return fail(3)
	}
	cosWorld.mu.Lock()
	kind, recID, size := o.kind, o.rec.ID, o.rec.InvSize
	cosWorld.mu.Unlock()
	if kind != cos.KindAbility {
		return fail(3)
	}
	d := cosWorld.depsNow()
	bags := d.bags
	if bags == nil || inv == nil {
		return fail(ItemErrDB)
	}
	slotOf := func(st inventory.Store, id int64, idx int) (inventory.Slot, bool) {
		slots, _ := st.List(ctx, id)
		for _, s := range slots {
			if s.Index == idx {
				return s, true
			}
		}
		return inventory.Slot{}, false
	}
	firstFree := func(st inventory.Store, id int64, n int) int {
		slots, _ := st.List(ctx, id)
		used := map[int]bool{}
		for _, s := range slots {
			used[s.Index] = true
		}
		for i := 0; i < n; i++ {
			if !used[i] {
				return i
			}
		}
		return -1
	}
	move := func(from inventory.Store, fromID int64, fromSlot int, to inventory.Store, toID int64, toSlot int) error {
		sl, ok := slotOf(from, fromID, fromSlot)
		if !ok {
			return fail(ItemErrDB)
		}
		inst, err := inventory.Take(ctx, from, fromID, fromSlot, sl.Quantity, sl.ItemID, sl.Instance())
		if err != nil {
			return fail(ItemErrDB)
		}
		p, ok := to.(inventory.Placer)
		if !ok {
			return fail(ItemErrDB)
		}
		if err := p.PlaceItemInstance(ctx, toID, toSlot, sl.ItemID, sl.Quantity, inst); err != nil {
			if back, ok := from.(inventory.Placer); ok {
				_ = back.PlaceItemInstance(ctx, fromID, fromSlot, sl.ItemID, sl.Quantity, inst)
			}
			return fail(ItemErrDB)
		}
		return nil
	}
	switch t {
	case ItemMoveCOSToBag:
		bagSlot := dst - ItemWireBagOffset
		capacity := inventory.CapacityOf(ctx, inv, owner)
		if bagSlot < 0 || bagSlot >= capacity {
			return fail(2)
		}
		if _, taken := slotOf(inv, owner, bagSlot); taken {
			if bagSlot = firstFree(inv, owner, capacity); bagSlot < 0 {
				return fail(ItemErrBagFull)
			}
		}
		sl, ok := slotOf(bags, recID, src)
		if !ok {
			return fail(ItemErrDB)
		}
		if it, err := d.items.GetItem(ctx, sl.ItemID); err == nil && it != nil && it.TypeID3 == 9 && it.TypeID2 == 3 {
			return fail(itemErrBadTarget)
		}
		if err := move(bags, recID, src, inv, owner, bagSlot); err != nil {
			return err
		}
		dst = bagSlot + ItemWireBagOffset
	case ItemMoveBagToCOS:
		bagSlot := src - ItemWireBagOffset
		if dst < 0 || dst >= size {
			return fail(2)
		}
		if _, taken := slotOf(bags, recID, dst); taken {
			if dst = firstFree(bags, recID, size); dst < 0 {
				return fail(ItemErrBagFull)
			}
		}
		sl, ok := slotOf(inv, owner, bagSlot)
		if !ok {
			return fail(ItemErrDB)
		}
		// CANT_MOVETO_SUMITEM: a summon item, a quest item, anything that
		// cannot be traded, a devil's spirit (s:FUN_00523960, READ).
		it, err := d.items.GetItem(ctx, sl.ItemID)
		if err != nil || it == nil || cos.IsPetItem(it.TypeID1, it.TypeID2, it.TypeID3, it.TypeID4) ||
			(it.TypeID2 == 3 && it.TypeID3 == 9) || !it.CanTrade || (it.TypeID2 == 1 && it.TypeID3 == 14) {
			return fail(itemErrSumItem)
		}
		if err := move(inv, owner, bagSlot, bags, recID, dst); err != nil {
			return err
		}
	case ItemMoveCOSToCOS:
		if dst < 0 || dst >= size || src < 0 || src >= size {
			return fail(2)
		}
		if err := bags.MoveItem(ctx, recID, src, dst); err != nil {
			return fail(ItemErrDB)
		}
	}
	out := []byte{itemOpOK, t}
	out = binary.LittleEndian.AppendUint32(out, uid)
	out = append(out, byte(src), byte(dst))
	if t == ItemMoveCOSToCOS && len(data) >= 9 {
		out = append(out, data[7], data[8])
	}
	return sess.Send(&proto.Packet{Opcode: OpItemMoveResult, Data: out})
}
