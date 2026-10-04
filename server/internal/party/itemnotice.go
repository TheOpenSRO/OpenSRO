package party

import (
	"encoding/binary"
	"fmt"
)

// OpItemNotice is the Item Auto Share party's distribution notice, S->C
// (round 712, party lane S2): sent to the party's members when a pick-up hands
// an item to a member by the round robin. READ, GS FUN_005bdc80 (`push 0x3068`
// at 0x5bdcdd), sent only when the party's flags have bit 1 (0x5bdc87) and
// broadcast to the party (0x5bb770); client handler c:0x873990. The client's
// line is UIIT_MSG_PARTYGET_ITEM_EXPENDABLE "Item [%s %d pieces]is distributed
// to [%s]." (party_rules.md "Item Auto Share").
const OpItemNotice uint16 = 0x3068

// ItemNoticeClass selects the notice's third field by the item's TypeIDs
// (READ: GS 0x42fe10 / 0x42fe80 at 0x5bdd13 / 0x5bdd28; client
// c:0x873a2b..0x873aed tests the same TID bits).
type ItemNoticeClass uint8

const (
	// ItemNoticeOther is everything else: a u8 1 (the constant, `mov eax,1;
	// mov [esp+0x18],al` at 0x5bdd44).
	ItemNoticeOther ItemNoticeClass = iota
	// ItemNoticeExpendable is TypeID1 3, TypeID2 3: a u16 count.
	ItemNoticeExpendable
	// ItemNoticeGold is TypeID 3/3/5 with TypeID4 not 1: the amount. The
	// client reads 8 bytes (`mov ebp,8` at c:0x873a75), this GameServer writes
	// 4 (0x5bdd1c). OURS: 8, as the client reads (party_protocol.md OPEN 1).
	ItemNoticeGold
)

// ItemNotice is 0x3068's payload.
type ItemNotice struct {
	// RecipientJID is the member the item went to: the object at the
	// transaction's +0x28, written through its slot 2 (0x5bdcce..0x5bdcd5)
	// -- the name the client's "distributed to [%s]" shows.
	RecipientJID uint32
	RefItemID    uint32
	Class        ItemNoticeClass
	// Amount is the gold amount (ItemNoticeGold) or the stack count
	// (ItemNoticeExpendable); unused for ItemNoticeOther.
	Amount uint64
}

// Encode lays the notice out: u32 recipient, u32 RefItemID, then u64 gold /
// u16 count / u8 1.
func (n ItemNotice) Encode() []byte {
	out := make([]byte, 8, 16)
	binary.LittleEndian.PutUint32(out, n.RecipientJID)
	binary.LittleEndian.PutUint32(out[4:], n.RefItemID)
	switch n.Class {
	case ItemNoticeGold:
		out = binary.LittleEndian.AppendUint64(out, n.Amount)
	case ItemNoticeExpendable:
		out = binary.LittleEndian.AppendUint16(out, uint16(n.Amount))
	default:
		out = append(out, 1)
	}
	return out
}

// DecodeItemNotice parses a notice; the class is the caller's, as on the
// client, which decides it from the RefItemID's TypeIDs.
func DecodeItemNotice(data []byte, class ItemNoticeClass) (ItemNotice, error) {
	want := map[ItemNoticeClass]int{ItemNoticeGold: 16, ItemNoticeExpendable: 10, ItemNoticeOther: 9}[class]
	if len(data) != want {
		return ItemNotice{}, fmt.Errorf("party: 0x3068 is %d bytes, want %d for class %d", len(data), want, class)
	}
	n := ItemNotice{RecipientJID: binary.LittleEndian.Uint32(data), RefItemID: binary.LittleEndian.Uint32(data[4:]), Class: class}
	switch class {
	case ItemNoticeGold:
		n.Amount = binary.LittleEndian.Uint64(data[8:])
	case ItemNoticeExpendable:
		n.Amount = uint64(binary.LittleEndian.Uint16(data[8:]))
	default:
		n.Amount = uint64(data[8])
	}
	return n, nil
}
