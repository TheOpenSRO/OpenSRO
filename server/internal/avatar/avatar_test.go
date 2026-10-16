package avatar

import (
	"context"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
)

// OURS test fixtures: invented ids; the kinds and columns are the shapes the
// research names, not any real row.
func av(t4, gender int) *refdata.Item {
	return &refdata.Item{ID: int64(100 + t4), TypeID1: 3, TypeID2: 1, TypeID3: TypeAvatar, TypeID4: t4,
		ReqGender: gender, Country: 3, ReqLevelType1: -1, MaxStack: 1}
}

func man(t *testing.T) *character.Character {
	t.Helper()
	c := &character.Character{ID: 1, Name: "Aria", Gender: character.GenderChinaMan, Level: 10, Str: 20, Int: 20}
	if character.SexOf(c.Gender) != character.SexMan || character.RaceOf(c.Gender) != character.RaceChina {
		t.Fatal("the fixture is not a Chinese man")
	}
	return c
}

// CanBeEquipedAt keeps s:0x497070's order: the position, the gender, the
// level, Str, Int, then the country.
func TestCanBeEquipedAtOrder(t *testing.T) {
	c := man(t)
	hat := av(KindHat, 1)
	if code := CanBeEquipedAt(c, hat, 0); code != 0 {
		t.Fatalf("a man's hat: 0x%x", code)
	}
	if code := CanBeEquipedAt(c, hat, 13); code != CodeWrongPosition {
		t.Fatalf("position 13: 0x%x", code)
	}
	if code := CanBeEquipedAt(c, hat, 12); code != 0 {
		t.Fatalf("position 12 passes CanBeEquipedAt (the move refuses it later): 0x%x", code)
	}
	all := *hat
	all.ReqGender, all.ReqLevelType1, all.ReqLevel1, all.ReqStr, all.ReqInt, all.Country = 0, 1, 99, 999, 999, 1
	if code := CanBeEquipedAt(c, &all, 0); code != CodeGender {
		t.Fatalf("everything wrong: 0x%x, want the gender first", code)
	}
	all.ReqGender = 2
	if code := CanBeEquipedAt(c, &all, 0); code != CodeLevel {
		t.Fatalf("then the level: 0x%x", code)
	}
	all.ReqLevel1 = 1
	if code := CanBeEquipedAt(c, &all, 0); code != CodeStr {
		t.Fatalf("then Str: 0x%x", code)
	}
	all.ReqStr = 0
	if code := CanBeEquipedAt(c, &all, 0); code != CodeInt {
		t.Fatalf("then Int: 0x%x", code)
	}
	all.ReqInt = 0
	if code := CanBeEquipedAt(c, &all, 0); code != CodeCountry {
		t.Fatalf("then the country: 0x%x", code)
	}
	all.Country = 0
	if code := CanBeEquipedAt(c, &all, 0); code != 0 {
		t.Fatalf("China's on a Chinese: 0x%x", code)
	}
}

// The devil's spirit's Data word: 0/-1 never awakened, else the expiry.
func TestSpiritExpiry(t *testing.T) {
	now := time.Unix(1_000_000, 0)
	if Awake(0, now) || Awake(-1, now) || Awake(999_999, now) || !Awake(1_000_001, now) {
		t.Fatal("Awake")
	}
	if w := PeriodWord(0, now); w != 0 {
		t.Fatalf("never awakened: %#x", w)
	}
	if w := PeriodWord(1_000_000+3600, now); w != 1<<31|3600 {
		t.Fatalf("an hour left: %#x", w)
	}
	if w := PeriodWord(999_000, now); w != 1<<31 {
		t.Fatalf("expired: %#x", w)
	}
	data, ok := Awaken(-1, 2419200, now)
	if !ok || data != 1_000_000+2419200 {
		t.Fatalf("Awaken = %d %v", data, ok)
	}
	if _, ok := Awaken(data, 2419200, now); ok {
		t.Fatal("an awake spirit awakened twice")
	}
	if _, ok := Extend(0, 2419200, now); ok {
		t.Fatal("extended a spirit never awakened")
	}
	if got, _ := Extend(1_000_100, 100, now); got != 1_000_200 {
		t.Fatalf("extended from the old expiry: %d", got)
	}
	if got, _ := Extend(900_000, 100, now); got != 1_000_100 {
		t.Fatalf("extended an expired one from now: %d", got)
	}
}

// CheckAvatarsetIntegrity's failures, in its order.
func TestIntegrity(t *testing.T) {
	c := man(t)
	armour := &refdata.Item{ID: 9, TypeID1: 3, TypeID2: 1, TypeID3: 1, TypeID4: 1, ReqGender: 1}
	h := func(it *refdata.Item, opt uint8) Held {
		return Held{Slot: inventory.Slot{ItemID: it.ID, OptLevel: opt}, Item: it}
	}
	if why := IntegrityFailure(c, h(armour, 0), nil); why == "" {
		t.Fatal("an armour piece passed")
	}
	if why := IntegrityFailure(c, h(av(KindHat, 0), 0), nil); why == "" {
		t.Fatal("a woman's hat on a man passed")
	}
	if why := IntegrityFailure(c, h(av(KindHat, 1), 0), []Held{h(av(KindHat, 1), 0)}); why == "" {
		t.Fatal("a second hat passed")
	}
	if why := IntegrityFailure(c, h(av(KindHat, 1), 251), nil); why == "" {
		t.Fatal("+251 passed")
	}
	if why := IntegrityFailure(c, h(av(KindHat, 1), 250), []Held{h(av(KindDress, 1), 0)}); why != "" {
		t.Fatalf("a +250 hat beside a dress: %s", why)
	}
	eu := *av(KindHat, 1)
	eu.Country = 1
	if why := IntegrityFailure(c, h(&eu, 0), nil); why != "" {
		t.Fatalf("a country mismatch does not fail integrity: %s", why)
	}
}

// The stores keep five slots, the bag's columns and placement.
func TestStores(t *testing.T) {
	m := NewMem(nil)
	if m.Capacity() != Slots {
		t.Fatalf("capacity %d", m.Capacity())
	}
	ctx := context.Background()
	if err := m.PlaceItemInstance(ctx, 1, 4, 101, 1, inventory.Instance{OptLevel: 3, Durability: 77}); err != nil {
		t.Fatal(err)
	}
	if err := m.PlaceItemInstance(ctx, 1, 5, 102, 1, inventory.Instance{}); err == nil {
		t.Fatal("placed in slot 5")
	}
	held, err := List(ctx, m, nil, 1)
	if err != nil || len(held) != 1 || held[0].Slot.Index != 4 || held[0].Slot.OptLevel != 3 || held[0].Slot.Durability != 77 {
		t.Fatalf("List = %+v, %v", held, err)
	}
}
