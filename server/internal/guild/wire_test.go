package guild

import (
	"bytes"
	"encoding/binary"
	"testing"
)

// Round 821: the block in FUN_009965e0's order, field by field.
func TestEncodeBlock(t *testing.T) {
	g := &Guild{ID: 7, Name: "Verizon", Level: 2, GatheredSP: 1234, NoticeTitle: "Hi", NoticeBody: "Body",
		CrestRev: 3, SoldierFlags: 1, LeaderID: 10,
		Members: []Member{
			{CharacterID: 10, Name: "Tess", Role: RoleLeader, Permission: PermAll, GPDonation: 50, Nickname: "Boss"},
			{CharacterID: 11, Name: "Rook", Role: RoleMember, GPDonation: 5},
		}}
	live := func(id int64) MemberLive {
		if id == 10 {
			return MemberLive{Level: 110, RefObjID: 1907, Online: true}
		}
		return MemberLive{Level: 30, RefObjID: 14875}
	}
	got := EncodeBlock(g, live)
	var w bytes.Buffer
	u32 := func(v uint32) { _ = binary.Write(&w, binary.LittleEndian, v) }
	str := func(s string) { _ = binary.Write(&w, binary.LittleEndian, uint16(len(s))); w.WriteString(s) }
	u32(7)
	str("Verizon")
	w.WriteByte(2)
	u32(1234)
	str("Hi")
	str("Body")
	u32(3)
	w.WriteByte(1)
	w.WriteByte(2)
	// The master: class 0, online (0).
	u32(10)
	str("Tess")
	w.Write([]byte{0, 110})
	u32(50)
	u32(0xffffffff)
	u32(0)
	u32(0)
	u32(0)
	str("Boss")
	u32(1907)
	w.Write([]byte{0, 0})
	// A member: class 10, offline (1).
	u32(11)
	str("Rook")
	w.Write([]byte{10, 30})
	u32(5)
	u32(0)
	u32(0)
	u32(0)
	u32(0)
	str("")
	u32(14875)
	w.Write([]byte{0, 1})
	w.WriteByte(0)
	if !bytes.Equal(got, w.Bytes()) {
		t.Fatalf("block\n got % x\nwant % x", got, w.Bytes())
	}
	if c := BlockChunks(make([]byte, BlockChunkSize*2+5)); len(c) != 3 || len(c[2]) != 5 {
		t.Fatalf("chunks %d", len(c))
	}
}
