package session

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"

	"github.com/OpenSRO/OpenSRO/server/internal/durability"
	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
)

// ItemInfo is one container slot's item instance, as the original's item
// record carries it (round 732; docs/protocol/item_tooltip.md "The item
// instance on the wire").
//
// The RECORD is retail's, READ from both ends: the client's item parser
// SOItem::FUN_008be4f0 (equipment branch, TypeID 3/1) and the GameServer's
// writer CInstanceItem::vslot_010 (gs:0x42e230, modes 1 and 4):
//
//	u32 rent block          c:0x8bb130 / gs:0x845b30 -- 0 when the item has no rent object
//	                        (gs:0x862960); bit 0 adds u16, u32, u32 (the period), bit 1
//	                        adds u16 and u32 (round 732 review F1)
//	u32 RefItemID           c:0x8be549 / gs:0x4958c0
//	u8  OptLevel            c:0x8be647 -> item +0x8c (the plus)
//	u64 Variance            c:0x8be657 -> +0x90 (twelve 5-bit white-stat groups)
//	u32 Durability          c:0x8be667 -> +0x98; for TypeID3 14 (time-limited gear,
//	                        (t & 0x780) == 0x700) the period word active<<31 | seconds
//	                        instead (c:0x8be600, gs:0x42fd30)
//	u8  MagParamNum (<= 12) c:0x8bcdf0 "m_btMagicParamNum <= MAX_MAGPARAM_PER_ITEM"
//	    MagParamNum x u64   low u16 the magicoption.txt id, high u32 the value
//	2 x binding block       gs:0x846280 writes type 1 then type 2; c:0x8bb070 reads two:
//	    u8 type, u8 count, count x entry; the entry (gs:0x825a40) is u8 nSlot, then a
//	    u64 whose low u32 is nOptID | nOptLvl<<16 and whose high u32 is nOptValue
//	    (type 2) or nParam1 (type 1). Type 1 is a socket (+0x74/+0x78); type 2 the
//	    advanced elixir, whose high u32's low byte adds onto the plus (+0x71).
//
// The CONTAINER is OpenSRO's own (OURS): the bag, warehouse and equipment
// lists are OpenSRO's messages, so the records ride in an additive trailing
// block -- u16 count, then per entry a u32 container slot and the record --
// after everything those lists already carried, where an older client has
// stopped reading. The block lists only equipment (TypeID 3/1).
//
// Values that are OURS, the layout being READ: the rent word is 0 (OpenSRO
// has no rentals); a time-limited item's period word is 0, the original's
// "not active" form (OpenSRO has no expiry); the advanced elixir's nSlot,
// nOptID and nOptLvl are 0 (the elixir's option row is not modelled yet);
// no sockets. An untracked durability (-1) is sent as the max its variance
// gives, as the first read would set it.
type ItemInfo struct {
	Slot       int
	RefItemID  uint32
	OptLevel   uint8
	Variance   uint64
	Durability uint32 // the period word for time-limited gear (timeLimited)
	MagParams  []uint64
	AdvElixir  uint8
}

// Binding-option block types (READ, gs:0x846280, c:0x8bb070).
const (
	BindingSocket     = 1
	BindingAdvElixir  = 2
	itemInfoFixedSize = 4 + 1 + 8 + 4 + 1 // RefItemID through MagParamNum
)

// AppendItemRecord appends the retail item record (no container slot).
func AppendItemRecord(out []byte, ii ItemInfo) []byte {
	out = binary.LittleEndian.AppendUint32(out, 0) // rent block: none
	out = binary.LittleEndian.AppendUint32(out, ii.RefItemID)
	out = append(out, ii.OptLevel)
	out = binary.LittleEndian.AppendUint64(out, ii.Variance)
	out = binary.LittleEndian.AppendUint32(out, ii.Durability)
	params := ii.MagParams
	if len(params) > inventory.MaxMagParams {
		params = params[:inventory.MaxMagParams]
	}
	out = append(out, byte(len(params)))
	for _, p := range params {
		out = binary.LittleEndian.AppendUint64(out, p)
	}
	out = append(out, BindingSocket, 0)
	if ii.AdvElixir == 0 {
		return append(out, BindingAdvElixir, 0)
	}
	// nSlot 0; low u32 nOptID 0 | nOptLvl 0 << 16; high u32 nOptValue.
	out = append(out, BindingAdvElixir, 1, 0)
	return binary.LittleEndian.AppendUint64(out, uint64(ii.AdvElixir)<<32)
}

// ReadItemRecord reads one record as the client's parser does, the rent
// block's branches included (c:0x8bb130), returning the rest.
func ReadItemRecord(data []byte) (ItemInfo, []byte, error) {
	var ii ItemInfo
	if len(data) < 4 {
		return ii, nil, errors.New("item record: truncated rent block")
	}
	rent := binary.LittleEndian.Uint32(data)
	data = data[4:]
	if rent&3 != 0 {
		extra := 2
		if rent&1 != 0 {
			extra += 8
		}
		if rent&2 != 0 {
			extra += 6
		}
		if len(data) < extra {
			return ii, nil, errors.New("item record: truncated rent block")
		}
		data = data[extra:]
	}
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
				ii.AdvElixir += uint8(v >> 32) // a u8 add, as c:0x8bb070
			}
		}
		data = data[9*count:]
	}
	return ii, data, nil
}

// itemInfoEntrySize is one block entry's bytes: the u32 slot and the record.
func itemInfoEntrySize(ii ItemInfo) int {
	n := min(len(ii.MagParams), inventory.MaxMagParams)
	size := 4 + 4 + itemInfoFixedSize + 8*n + 2 + 2
	if ii.AdvElixir != 0 {
		size += 9
	}
	return size
}

// fitItemInfos keeps the entries that fit one frame after `used` bytes
// (proto.MaxPayload; the gateway refuses a larger send whole). The worst
// warehouse -- 210 slots, every one equipment with 12 options and an
// advanced elixir -- does not fit: its list carries 199 entries and the
// other 11 follow in OpItemInfoMore (TestWorstCaseStorageListSplits). The
// bag and worn lists always fit, and the guard keeps them from ever losing
// the list itself.
func fitItemInfos(used int, infos []ItemInfo) []ItemInfo {
	used += 2
	for i, ii := range infos {
		used += itemInfoEntrySize(ii)
		if used > proto.MaxPayload {
			return infos[:i]
		}
	}
	return infos
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

// timeLimited is TypeID3 14, whose record word after the variance is the
// period, not durability (c:0x8be5ce `(t & 0x780) == 0x700`, gs:0x42fd30).
func timeLimited(item *refdata.Item) bool {
	return isEquipment(item) && item.TypeID3 == 14
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
	if timeLimited(item) {
		// The period word, active<<31 | seconds: 0, the original's "not
		// active" form -- OpenSRO has no expiry (OURS; gs:0x42fd30).
		dur = 0
	} else if dur == durability.Untracked {
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
