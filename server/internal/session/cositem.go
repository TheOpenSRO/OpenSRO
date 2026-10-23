package session

import (
	"context"
	"encoding/binary"
	"errors"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/cos"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
)

// The retail item record's branches past the RefItemID (round 795), READ
// from the client's parser SOItem::FUN_008be4f0 (c:0x8be4f0) by the item's
// packed type word:
//
//	3/1        equipment: OptLevel, Variance, Durability, MagParams, bindings
//	           (AppendItemRecord's own form)
//	3/2/1      a COS summon item: cos.ItemTail (CGItemCOSSummoner::vslot_294
//	           s:0x492d40)
//	3/2/x      any other summoned-object item: nothing more (count 1,
//	           FUN_0056f9e0); 3/2/2 adds a u32 ref (FUN_00666cb0), 3/2/3/1 a
//	           magic cube's own field (FUN_0056fe90; not sent: OURS)
//	3/3/x      an expendable: u16 count (c:0x8be764); then u8 for the
//	           alchemy stones 3/3/11/1 and 3/3/11/2 (FUN_0056fca0 /
//	           FUN_0056fce0: the assimilation byte), u8 n + n x u64 options
//	           for 3/3/14/2 (FUN_00666fc0); 3/3/5/x (x != 1, FUN_00871de0)
//	           and 3/3/8 (FUN_00666d40) carry other fields and are never
//	           sent in these records (OURS)

// cosItemTail is a pet summon item's tail: its pet as the record holds it.
// The instance's Data word (OpenSRO's Durability, as for a devil's spirit:
// avatar.Awake) is the COS record's id, 0 or -1 before the first summon
// (READ item +0x38).
func cosItemTail(ctx context.Context, inst inventory.Instance, now time.Time) []byte {
	t := cos.ItemTail{State: cos.ItemStateNone}
	d := cosWorld.depsNow()
	if inst.Durability > 0 && d.store != nil {
		if rec, err := d.store.Get(ctx, int64(inst.Durability)); err == nil {
			// A live COS's record is the runtime's (its HP, level and name
			// move before they are saved).
			if o := cosWorld.byRecord(rec.ID); o != nil {
				cosWorld.mu.Lock()
				rec = o.rec
				cosWorld.mu.Unlock()
			}
			t.State = cos.ItemState(true, rec.State)
			t.RefID = uint32(rec.RefCharID)
			t.TypeID4 = cosKindOf(t.RefID)
			t.Name = rec.Name
			if t.TypeID4 == cos.KindAbility {
				t.RentSecs = cos.RentSecondsLeft(rec.RentEnd, now)
			}
		}
	}
	return cos.AppendItemTail(nil, t)
}

// retailItemTail is the record's bytes after the RefItemID for a slot that
// is not equipment (nil for equipment: AppendItemRecord's own form).
func retailItemTail(ctx context.Context, it *refdata.Item, sl inventory.Slot, now time.Time) []byte {
	if it == nil || isEquipment(it) {
		return nil
	}
	if cos.IsPetItem(it.TypeID1, it.TypeID2, it.TypeID3, it.TypeID4) {
		return cosItemTail(ctx, sl.Instance(), now)
	}
	if it.TypeID2 == 2 {
		if it.TypeID3 == 2 {
			return binary.LittleEndian.AppendUint32([]byte{}, 0)
		}
		return []byte{}
	}
	out := binary.LittleEndian.AppendUint16(nil, uint16(sl.Quantity))
	if it.TypeID2 == 3 && it.TypeID3 == 8 {
		// A specialty good (round 801, READ c:0x8be6a1..0x8be715, the
		// TID word 0x46c test FUN_00666d40): the u16 count, then the
		// buyer's name as a u16-length string (FUN_004f7a70) -- nothing
		// else.
		out = binary.LittleEndian.AppendUint16(out, uint16(len(sl.Creator)))
		return append(out, sl.Creator...)
	}
	if it.TypeID3 == 11 && (it.TypeID4 == 1 || it.TypeID4 == 2) {
		out = append(out, 0)
	}
	if it.TypeID3 == 14 && it.TypeID4 == 2 {
		out = append(out, 0)
	}
	return out
}

// itemRecordTail reads a non-equipment record's tail when the item table is
// known (SetItemRecordTypes); nil reads every record as equipment's, as
// before round 795.
var itemRecordTail func(ref uint32, b []byte) (tail, rest []byte, ok bool)

// SetItemRecordTypes binds the item types ReadItemRecord dispatches on: a
// RefItemID's TypeID1..4 (ok false: unknown, read as equipment).
func SetItemRecordTypes(typeOf func(ref uint32) (t [4]int, ok bool)) {
	if typeOf == nil {
		itemRecordTail = nil
		return
	}
	itemRecordTail = func(ref uint32, b []byte) ([]byte, []byte, bool) {
		t, ok := typeOf(ref)
		if !ok || (t[0] == 3 && t[1] == 1) {
			return nil, nil, false
		}
		n, err := retailTailLen(t, b)
		if err != nil {
			return nil, nil, false
		}
		return b[:n:n], b[n:], true
	}
}

// retailTailLen is how many bytes a record's tail of type t takes in b.
func retailTailLen(t [4]int, b []byte) (int, error) {
	if cos.IsPetItem(t[0], t[1], t[2], t[3]) {
		_, rest, err := cos.ReadItemTail(b, cosKindOf)
		if err != nil {
			return 0, err
		}
		return len(b) - len(rest), nil
	}
	n := 0
	switch {
	case t[1] == 2 && t[2] == 2:
		n = 4
	case t[1] == 2:
		n = 0
	case t[1] == 3 && t[2] == 8:
		// A good: the count and the buyer's name (round 801).
		if len(b) < 4 {
			return 0, errors.New("item record: short good")
		}
		n = 4 + int(binary.LittleEndian.Uint16(b[2:]))
	default:
		n = 2
		if t[2] == 11 && (t[3] == 1 || t[3] == 2) {
			n++
		}
		if t[2] == 14 && t[3] == 2 {
			if len(b) < 3 {
				return 0, errors.New("item record: short options")
			}
			n += 1 + 8*int(b[2])
		}
	}
	if len(b) < n {
		return 0, errors.New("item record: short tail")
	}
	return n, nil
}

// The out pet's item refusals (round 795, READ: one rule, the item a COS
// summoner whose record says summoned): selling it 0x18b7
// COSPETERR_CANT_SELL_ACTIVATED_COSITEM (s:0x617f70), trading it 0x18b6
// CANT_TRADE (CGStorage::TradeOfferItem 0x526910), storing it 0x18b2
// CANT_MOVETO_CHEST2 (FUN_00523f70).
const (
	cosErrSellOut  = 0x18b7
	cosErrTradeOut = 0x18b6
	cosErrStoreOut = 0x18b2
)

// cosItemOut reports whether characterID's bag slot holds the item of a COS
// that is out.
func cosItemOut(ctx context.Context, characterID int64, slot int) bool {
	d := cosWorld.depsNow()
	if d.inv == nil {
		return false
	}
	slots, err := d.inv.List(ctx, characterID)
	if err != nil {
		return false
	}
	for _, sl := range slots {
		if sl.Index == slot && sl.Durability > 0 {
			o := cosWorld.byRecord(int64(sl.Durability))
			if o == nil {
				return false
			}
			it, err := d.items.GetItem(ctx, sl.ItemID)
			return err == nil && it != nil && cos.IsPetItem(it.TypeID1, it.TypeID2, it.TypeID3, it.TypeID4)
		}
	}
	return false
}

// cosOutText is the line an older client shows beside the code.
const cosOutText = "the pet of this item is summoned"
