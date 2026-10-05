package session

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"

	"github.com/OpenSRO/OpenSRO/server/internal/durability"
	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
)

// ItemInfo is one container slot's item instance, as the original's item
// record carries it (round 732; docs/protocol/item_tooltip.md "The item
// instance on the wire").
//
// The RECORD is retail's, READ from the client's item parser
// SOItem::FUN_008be4f0 (equipment branch, TypeID 3/1) and the two readers it
// calls:
//
//	u32 RefItemID                      0x8be54e   -> item +0x34
//	u8  OptLevel                       0x8be647   -> +0x8c (the plus)
//	u64 Variance                       0x8be657   -> +0x90 (twelve 5-bit white-stat groups)
//	u32 Durability                     0x8be667   -> +0x98
//	u8  MagParamNum (<= 12)            0x8bcdf0   "m_btMagicParamNum <= MAX_MAGPARAM_PER_ITEM"
//	    MagParamNum x u64              0x8bcdf0   low u16 the magicoption.txt id, high u32 the value
//	2 x binding-option block           0x8bb070   (a loop of exactly two)
//	    u8 type, u8 count, count x (u8 slot, u64)
//	    type 1: a socket -- slot's id and value kept at +0x74/+0x78
//	    type 2: the advanced elixir -- the u64's HIGH u32 is added onto the
//	            plus and kept at +0x71
//
// The CONTAINER is OpenSRO's own (OURS): the bag, warehouse and equipment
// lists are OpenSRO's messages, so the records ride in an additive trailing
// block -- u16 count, then per entry a u32 container slot and the record --
// after everything those lists already carried, where an older client has
// stopped reading. The block lists only equipment (TypeID 3/1), the one kind
// the original's record gives an instance worth showing; every other item's
// stack count is already in the list's own records.
//
// Choices labelled OURS: the binding blocks are written type 1 (no sockets,
// OpenSRO has none) then type 2 -- the client takes them in either order;
// a type-2 entry's slot is 0 and its u64's LOW u32 is 0 (what retail puts
// there is OPEN). An untracked durability (-1) is sent as the max its
// variance gives, as the first read would set it (inventory.initLegacy).
type ItemInfo struct {
	Slot       int
	RefItemID  uint32
	OptLevel   uint8
	Variance   uint64
	Durability uint32
	MagParams  []uint64
	AdvElixir  uint8
}

// Binding-option block types (READ, c:0x8bb070's two branches).
const (
	BindingSocket     = 1
	BindingAdvElixir  = 2
	itemInfoFixedSize = 4 + 1 + 8 + 4 + 1 // through MagParamNum
)

// AppendItemRecord appends the retail item record (no container slot).
func AppendItemRecord(out []byte, ii ItemInfo) []byte {
	var b [8]byte
	binary.LittleEndian.PutUint32(b[:4], ii.RefItemID)
	out = append(out, b[:4]...)
	out = append(out, ii.OptLevel)
	binary.LittleEndian.PutUint64(b[:], ii.Variance)
	out = append(out, b[:]...)
	binary.LittleEndian.PutUint32(b[:4], ii.Durability)
	out = append(out, b[:4]...)
	params := ii.MagParams
	if len(params) > inventory.MaxMagParams {
		params = params[:inventory.MaxMagParams]
	}
	out = append(out, byte(len(params)))
	for _, p := range params {
		binary.LittleEndian.PutUint64(b[:], p)
		out = append(out, b[:]...)
	}
	out = append(out, BindingSocket, 0)
	if ii.AdvElixir == 0 {
		return append(out, BindingAdvElixir, 0)
	}
	out = append(out, BindingAdvElixir, 1, 0)
	binary.LittleEndian.PutUint64(b[:], uint64(ii.AdvElixir)<<32)
	return append(out, b[:]...)
}

// ReadItemRecord reads one record AppendItemRecord wrote (the client's
// parser, mirrored for OpenSRO's own tests and tools), returning the rest.
func ReadItemRecord(data []byte) (ItemInfo, []byte, error) {
	var ii ItemInfo
	if len(data) < itemInfoFixedSize {
		return ii, nil, errors.New("item record: truncated")
	}
	ii.RefItemID = binary.LittleEndian.Uint32(data)
	ii.OptLevel = data[4]
	ii.Variance = binary.LittleEndian.Uint64(data[5:])
	ii.Durability = binary.LittleEndian.Uint32(data[13:])
	n := int(data[17])
	data = data[itemInfoFixedSize:]
	if n > inventory.MaxMagParams {
		return ii, nil, fmt.Errorf("item record: MagParamNum %d over %d", n, inventory.MaxMagParams)
	}
	if len(data) < 8*n {
		return ii, nil, errors.New("item record: truncated options")
	}
	for i := 0; i < n; i++ {
		ii.MagParams = append(ii.MagParams, binary.LittleEndian.Uint64(data[8*i:]))
	}
	data = data[8*n:]
	for block := 0; block < 2; block++ {
		if len(data) < 2 {
			return ii, nil, errors.New("item record: truncated binding block")
		}
		kind, count := data[0], int(data[1])
		data = data[2:]
		if len(data) < 9*count {
			return ii, nil, errors.New("item record: truncated binding entries")
		}
		for i := 0; i < count; i++ {
			v := binary.LittleEndian.Uint64(data[9*i+1:])
			if kind == BindingAdvElixir {
				ii.AdvElixir += uint8(v >> 32)
			}
		}
		data = data[9*count:]
	}
	return ii, data, nil
}

// encodeItemInfoBlock appends the trailing block: u16 count, then per entry
// u32 slot and the record.
func encodeItemInfoBlock(out []byte, infos []ItemInfo) []byte {
	out = binary.LittleEndian.AppendUint16(out, uint16(len(infos)))
	for _, ii := range infos {
		out = binary.LittleEndian.AppendUint32(out, uint32(ii.Slot))
		out = AppendItemRecord(out, ii)
	}
	return out
}

// decodeItemInfoBlock reads what encodeItemInfoBlock wrote. An absent tail
// (an older server) yields nothing, not an error.
func decodeItemInfoBlock(rest []byte) ([]ItemInfo, error) {
	if len(rest) < 2 {
		return nil, nil
	}
	n := int(binary.LittleEndian.Uint16(rest))
	rest = rest[2:]
	var out []ItemInfo
	for i := 0; i < n; i++ {
		if len(rest) < 4 {
			return out, errors.New("item info block: truncated slot")
		}
		slot := int(binary.LittleEndian.Uint32(rest))
		ii, r, err := ReadItemRecord(rest[4:])
		if err != nil {
			return out, fmt.Errorf("item info block: entry %d: %w", i, err)
		}
		ii.Slot = slot
		out = append(out, ii)
		rest = r
	}
	return out, nil
}

// isEquipment is TypeID 3/1, the branch of the client's parser that reads
// the instance (c:0x8be5b8: `(t & 0x1c) == 0xc && (t & 0x60) == 0x20`, the
// packed TypeID1 = 3, TypeID2 = 1).
func isEquipment(item *refdata.Item) bool {
	return item != nil && item.TypeID1 == 3 && item.TypeID2 == 1
}

// itemInfoFor builds one entry, or ok false for an item the block does not
// list (not equipment, or not in the item table).
func itemInfoFor(ctx context.Context, items ItemLookup, slot int, itemID int64, inst inventory.Instance) (ItemInfo, bool) {
	if items == nil {
		return ItemInfo{}, false
	}
	item, err := items.GetItem(ctx, itemID)
	if err != nil || !isEquipment(item) {
		return ItemInfo{}, false
	}
	dur := inst.Durability
	if dur == durability.Untracked {
		dur = 0
		if item.DurabilityMax > 0 {
			dur = durability.MaxDurability(item.DurabilityMin, item.DurabilityMax, inst.Variance)
		}
	}
	if dur < 0 {
		dur = 0
	}
	return ItemInfo{Slot: slot, RefItemID: uint32(itemID), OptLevel: inst.OptLevel, Variance: inst.Variance,
		Durability: uint32(dur), MagParams: inst.MagParams, AdvElixir: inst.AdvElixir}, true
}

// slotItemInfos is the block for a bag or a warehouse.
func slotItemInfos(ctx context.Context, slots []inventory.Slot, items ItemLookup) []ItemInfo {
	var out []ItemInfo
	for _, sl := range slots {
		if ii, ok := itemInfoFor(ctx, items, sl.Index, sl.ItemID, sl.Instance()); ok {
			out = append(out, ii)
		}
	}
	return out
}

// wornItemInfos is the block for the worn slots.
func wornItemInfos(ctx context.Context, worn []equipment.Equipped, items ItemLookup) []ItemInfo {
	var out []ItemInfo
	for _, e := range worn {
		if ii, ok := itemInfoFor(ctx, items, int(e.Slot), e.ItemID, e.Instance()); ok {
			out = append(out, ii)
		}
	}
	return out
}
