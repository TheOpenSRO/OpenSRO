package cos

import (
	"bytes"
	"context"
	"encoding/binary"
	"testing"
	"time"
)

// The ride row by the owner's level (READ s:0x49bbc1..0x49bc98): the
// largest bracket at or below the level, the engine's 1 and 255 added.
func TestRideRow(t *testing.T) {
	brackets := "5,10,20,30,45,60,75,90,105,120"
	for _, c := range []struct {
		level int
		want  string
		ok    bool
	}{
		{4, "", false}, // _1: no such row (the engine's code 5)
		{5, "COS_C_OSTRICH_5", true},
		{9, "COS_C_OSTRICH_5", true},
		{47, "COS_C_OSTRICH_45", true},
		{120, "COS_C_OSTRICH_120", true},
		{140, "COS_C_OSTRICH_120", true},
	} {
		got, ok := RideRow("COS_C_OSTRICH", brackets, c.level)
		if c.level == 4 {
			// The set holds 1, so the code is _1 -- ok is true and the row
			// lookup is what fails.
			if !ok || got != "COS_C_OSTRICH_1" {
				t.Errorf("level 4: %q %v, want COS_C_OSTRICH_1 (no such row)", got, ok)
			}
			continue
		}
		if got != c.want || ok != c.ok {
			t.Errorf("level %d: %q %v, want %q %v", c.level, got, ok, c.want, c.ok)
		}
	}
	if got, ok := RideRow("COS_C_HORSE1", "xxx", 50); !ok || got != "COS_C_HORSE1" {
		t.Errorf("a fixed row: %q %v", got, ok)
	}
	if _, ok := RideRow("xxx", "", 50); ok {
		t.Error("an item naming no COS was accepted")
	}
}

func TestItemState(t *testing.T) {
	for _, c := range []struct {
		has   bool
		flags uint8
		want  uint8
	}{
		{false, 0, ItemStateNone},
		{true, StateAlive | StateSummoned, ItemStateSummoned},
		{true, StateAlive, ItemStateStored},
		{true, StateSummoned, ItemStateDead},
		{true, 0, ItemStateDead},
	} {
		if got := ItemState(c.has, c.flags); got != c.want {
			t.Errorf("ItemState(%v, %d) = %d, want %d", c.has, c.flags, got, c.want)
		}
	}
}

func TestHunger(t *testing.T) {
	// 1 % every 5 minutes: 10,000 HGP in 30,000 s.
	if got := HungerPerSecond() * 30000; got < 9999.9 || got > 10000.1 {
		t.Errorf("a full gauge empties in %.1f s of HGP, want 10000", got)
	}
	if !HungerCrossedTen(10000, 9999) || HungerCrossedTen(9999, 9998) || !HungerCrossedTen(3000, 2999) {
		t.Error("the 10 % marks")
	}
	if FeedAmount(9500, 10) != HGPFull || FeedAmount(2000, 10) != 3000 {
		t.Error("an HGP potion is Param1 x 100, clamped to 10000")
	}
}

func TestDeathExpLoss(t *testing.T) {
	// A monster's kill, no murderer: min(unit*100, floor(next*0.02)/2).
	if got := DeathExpLoss(100000, 10, false, false); got != 1000 {
		t.Errorf("unit-bound loss %d, want 1000", got)
	}
	if got := DeathExpLoss(10000, 1000, false, false); got != 100 {
		t.Errorf("threshold-bound loss %d, want 100", got)
	}
	if got := DeathExpLoss(40, 10, false, false); got != 0 {
		t.Errorf("a loss under 1 is none, got %d", got)
	}
}

func TestValidPetName(t *testing.T) {
	if !ValidPetName("Rex") || ValidPetName("") || ValidPetName("two words") || ValidPetName("abcdefghijklm") {
		t.Error("a pet name is 1..12 bytes with no space")
	}
}

// The spawn record's tail by kind, as CICCos slot 25 reads it (READ
// c:0x9c60b0): a ride stops at the flags; a growth pet carries its name,
// the owner's name, job and PvP, and the owner's uid; an ability pet no PvP.
func TestSpawnRecordTails(t *testing.T) {
	base := SpawnRecord{RefID: 7, UID: 9, Region: 25000, Name: "Rex", OwnerName: "Aria", OwnerJob: 4, OwnerUID: 42}
	head := len(AppendSpawnRecord(nil, SpawnRecord{TypeID4: KindRide}))
	// u32 ref, u32 uid, u16 region, 3 f32, u16 angle, u8 0 u8 run u8 0 u16
	// angle, 4 stance bytes, 3 f32, buffs, flags.
	if head != 4+4+2+12+2+5+4+12+1+1 {
		t.Fatalf("the common part is %d bytes", head)
	}
	tail := func(kind int) []byte {
		r := base
		r.TypeID4 = kind
		return AppendSpawnRecord(nil, r)[head:]
	}
	str := func(s string) []byte { return append(binary.LittleEndian.AppendUint16(nil, uint16(len(s))), s...) }
	u32 := func(v uint32) []byte { return binary.LittleEndian.AppendUint32(nil, v) }
	cat := func(parts ...[]byte) []byte { return bytes.Join(parts, nil) }
	for _, c := range []struct {
		kind int
		want []byte
	}{
		{KindRide, nil},
		{KindTransport, cat(str("Aria"), []byte{4, 0}, u32(42))},
		{KindGrowth, cat(str("Rex"), str("Aria"), []byte{4, 0}, u32(42))},
		{KindAbility, cat(str("Rex"), str("Aria"), []byte{4}, u32(42))},
	} {
		if got := tail(c.kind); !bytes.Equal(got, c.want) {
			t.Errorf("kind %d: tail % x, want % x", c.kind, got, c.want)
		}
	}
}

// 0x30C8 per kind (c:COSDataMgr::FUN_009a1900).
func TestDataLayouts(t *testing.T) {
	d := Data{UID: 1, RefID: 2, HP: 3, MP: 0, Exp: 5, Level: 6, HGP: 7, PetOption: 1, Name: "Rex", InvSize: 0, OwnerUID: 42, ItemSlot: 13}
	size := func(kind int) int {
		d.TypeID4 = kind
		return len(AppendData(nil, d))
	}
	if got := size(KindRide); got != 4*4+1 {
		t.Errorf("a ride's 0x30C8 is %d bytes, want 17", got)
	}
	if got := size(KindTransport); got != 4*4+1+4 {
		t.Errorf("a transport's is %d bytes, want 21", got)
	}
	if got := size(KindGrowth); got != 4*4+8+1+2+4+2+3+1+4+1 {
		t.Errorf("a growth pet's is %d bytes", got)
	}
	if got := size(KindAbility); got != 4*4+4+2+3+1+4+1 {
		t.Errorf("an ability pet's is %d bytes", got)
	}
}

func TestItemTailRoundTrip(t *testing.T) {
	kinds := map[uint32]int{100: KindGrowth, 200: KindAbility}
	kindOf := func(r uint32) int { return kinds[r] }
	for _, tt := range []ItemTail{
		{State: ItemStateNone},
		{State: ItemStateSummoned, RefID: 100, TypeID4: KindGrowth, Name: "Rex"},
		{State: ItemStateStored, RefID: 200, TypeID4: KindAbility, Name: "", RentSecs: 3600},
	} {
		b := append(AppendItemTail(nil, tt), 0xAA)
		got, rest, err := ReadItemTail(b, kindOf)
		if err != nil || len(rest) != 1 || got.State != tt.State || got.Name != tt.Name || got.RentSecs != tt.RentSecs {
			t.Errorf("%+v read back as %+v (rest %d, %v)", tt, got, len(rest), err)
		}
	}
}

func TestMemStore(t *testing.T) {
	ctx := context.Background()
	s := NewMemStore()
	a, _ := s.Create(ctx, Record{RefCharID: 1, State: StateAlive | StateSummoned, OwnerCharID: 7})
	b, _ := s.Create(ctx, Record{RefCharID: 2, State: StateAlive})
	if err := s.SetName(ctx, a, "Rex"); err != nil {
		t.Fatal(err)
	}
	if err := s.SetName(ctx, b, "rex"); err != ErrNameTaken {
		t.Errorf("a second pet took the name: %v", err)
	}
	rides, _ := s.SummonedRides(ctx, 7)
	if len(rides) != 1 || rides[0].ID != a {
		t.Errorf("summoned rides %+v", rides)
	}
	r, _ := s.Get(ctx, a)
	r.Name = "lost"
	r.HP = 5
	_ = s.Save(ctx, r)
	if r2, _ := s.Get(ctx, a); r2.Name != "Rex" || r2.HP != 5 {
		t.Errorf("Save changed the name or lost the HP: %+v", r2)
	}
	if left := RentSecondsLeft(time.Unix(100, 0), time.Unix(40, 0)); left != 60 {
		t.Errorf("rent left %d", left)
	}
}
