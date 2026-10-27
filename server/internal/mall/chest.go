package mall

import (
	"encoding/binary"
	"time"
)

// The item chest's messages (round 837, OURS: retail has no item chest, the
// mall's purchase goes to the bag or is refused 0x1807 -- item_mall_wire.md
// §4; the opcodes are in OpenSRO's own low range, next to the GM console's
// 0x00F1/0x00F2):
//
//	C->S 0x00D0 {}                     list the chest
//	S->C 0x00D1 {u16 n, n x {u32 entryId, u32 refItemId, u32 quantity, str from, u32 unixDate}}
//	C->S 0x00D2 {u32 entryId}          take one; 0 takes all
//	S->C 0x00D3 {u8 result, u16 value} result 1: value = the items taken;
//	                                   result 2: value = the code (0x1807 the
//	                                   bag is full, 0x1809 no such entry,
//	                                   0x1811 the store failed)
//	                                   then a fresh 0x00D1
//	C->S 0x00D4 {}                     the take log (the last TakeLogDays days)
//	S->C 0x00D5 {u16 n, n x {u32 refItemId, u32 quantity, str from, u32 unixDate, u32 takenDate}}
//	S->C 0x00D6 {u32 refItemId, u32 quantity}   something entered the chest
//
// Strings are u16 length + bytes, as everywhere on the wire. Dates are Unix
// seconds. A take-all stops at the first entry the bag has no room for and
// answers {1, taken} when it took any. The items a take makes are the bag's
// own rows; the client re-reads the bag (OpInventoryList, 0x0031), as after
// an exchange.
const (
	OpChestList       uint16 = 0x00D0
	OpChestListResult uint16 = 0x00D1
	OpChestTake       uint16 = 0x00D2
	OpChestTakeResult uint16 = 0x00D3
	OpChestLog        uint16 = 0x00D4
	OpChestLogResult  uint16 = 0x00D5
	OpChestReceived   uint16 = 0x00D6
	TakeAll           uint32 = 0
	chestOK           byte   = 1
	chestFail         byte   = 2
	maxChestRows             = 0xffff
)

func appendStr(out []byte, s string) []byte {
	if len(s) > 0xffff {
		s = s[:0xffff]
	}
	out = binary.LittleEndian.AppendUint16(out, uint16(len(s)))
	return append(out, s...)
}

func unix32(t time.Time) uint32 { return clampU32(t.Unix()) }

// EncodeChestList is 0x00D1.
func EncodeChestList(es []ChestEntry) []byte {
	if len(es) > maxChestRows {
		es = es[:maxChestRows]
	}
	out := binary.LittleEndian.AppendUint16(nil, uint16(len(es)))
	for _, e := range es {
		out = binary.LittleEndian.AppendUint32(out, uint32(e.ID))
		out = binary.LittleEndian.AppendUint32(out, uint32(e.ItemID))
		out = binary.LittleEndian.AppendUint32(out, uint32(e.Quantity))
		out = appendStr(out, e.From)
		out = binary.LittleEndian.AppendUint32(out, unix32(e.At))
	}
	return out
}

// DecodeChestTake reads 0x00D2's entry id.
func DecodeChestTake(b []byte) (uint32, bool) {
	if len(b) < 4 {
		return 0, false
	}
	return binary.LittleEndian.Uint32(b), true
}

// EncodeChestTaken is 0x00D3's success: the items taken.
func EncodeChestTaken(n int) []byte {
	return binary.LittleEndian.AppendUint16([]byte{chestOK}, uint16(min(n, 0xffff)))
}

// EncodeChestTakeFail is 0x00D3's refusal.
func EncodeChestTakeFail(code uint16) []byte {
	return binary.LittleEndian.AppendUint16([]byte{chestFail}, code)
}

// EncodeTakeLog is 0x00D5.
func EncodeTakeLog(ls []TakeLogEntry) []byte {
	if len(ls) > maxChestRows {
		ls = ls[:maxChestRows]
	}
	out := binary.LittleEndian.AppendUint16(nil, uint16(len(ls)))
	for _, l := range ls {
		out = binary.LittleEndian.AppendUint32(out, uint32(l.ItemID))
		out = binary.LittleEndian.AppendUint32(out, uint32(l.Quantity))
		out = appendStr(out, l.From)
		out = binary.LittleEndian.AppendUint32(out, unix32(l.At))
		out = binary.LittleEndian.AppendUint32(out, unix32(l.TakenAt))
	}
	return out
}

// EncodeChestReceived is 0x00D6.
func EncodeChestReceived(itemID int64, quantity int) []byte {
	out := binary.LittleEndian.AppendUint32(nil, uint32(itemID))
	return binary.LittleEndian.AppendUint32(out, uint32(quantity))
}

// The open-mall exchange (item_mall.md §1e, verify "settled"): the client
// sends 0x7121 {u16 shop group word} only when its stock table
// (shopitemstockquantity.txt) has rows for the mall's group, and opens the
// mall on 0xB121 result 1. The reply's pairs set stock counts (c:0x8a1360:
// u16 key, u8 n, n x {u32, u16}; INFERRED counts). OpenSRO keeps no stock
// (the tables are empty in every source, MEASURED), so its answer carries
// none.
const (
	OpOpen       uint16 = 0x7121
	OpOpenResult uint16 = 0xB121
	OpSilk       uint16 = 0x3153
	OpSilkChange uint16 = 0x3154
)

// EncodeOpen is 0xB121 {1, u16 key, u8 0}: the request's group word echoed as
// the key (OURS; what retail's key is was not read), no stock rows.
func EncodeOpen(group uint16) []byte {
	out := binary.LittleEndian.AppendUint16([]byte{1}, group)
	return append(out, 0)
}
