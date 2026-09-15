package equipment

import (
	"errors"
	"testing"

	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
)

// Rows shaped like the real table's: type ids 3/1/family/piece, a
// country, a gender and a level requirement by character level.
func cottonSuit() *refdata.Item {
	return &refdata.Item{ID: 4842, TypeID1: TypeItem, TypeID2: TypeEquipment, TypeID3: FamilyChinaGarment, TypeID4: PieceMail,
		Country: CountryChina, ReqGender: ReqGenderMan, ReqLevelType1: ReqLevelTypeCharacter, ReqLevel1: 1}
}

func TestSlotForFollowsTypeID4(t *testing.T) {
	cases := map[int]Slot{PieceHelm: SlotHelm, PieceShoulderGuard: SlotShoulderGuard, PieceMail: SlotMail,
		PiecePants: SlotPants, PieceGauntlet: SlotGauntlet, PieceBoots: SlotBoots}
	for piece, want := range cases {
		it := cottonSuit()
		it.TypeID4 = piece
		got, ok := SlotFor(it)
		if !ok || got != want {
			t.Errorf("piece %d: got slot %v ok=%v, want %v", piece, got, ok, want)
		}
	}
	weapon := &refdata.Item{TypeID1: TypeItem, TypeID2: TypeEquipment, TypeID3: FamilyWeapon, TypeID4: 2}
	if got, ok := SlotFor(weapon); !ok || got != SlotWeapon {
		t.Errorf("a weapon goes in the weapon slot, got %v ok=%v", got, ok)
	}
	shield := &refdata.Item{TypeID1: TypeItem, TypeID2: TypeEquipment, TypeID3: FamilyShield}
	if got, ok := SlotFor(shield); !ok || got != SlotShield {
		t.Errorf("a shield goes in the shield slot, got %v ok=%v", got, ok)
	}
	potion := &refdata.Item{TypeID1: TypeItem, TypeID2: 3, TypeID3: 1}
	if _, ok := SlotFor(potion); ok {
		t.Error("a potion has no slot")
	}
}

func TestRefusal(t *testing.T) {
	man := &character.Character{Gender: character.GenderChinaMan, Level: 1}
	woman := &character.Character{Gender: character.GenderChinaWoman, Level: 1}

	if err := Refusal(man, cottonSuit(), SlotMail); err != nil {
		t.Fatalf("a man at level 1 may wear a Cotton Suit: %v", err)
	}
	// An item with no reference row is REFUSED, not allowed through. The old
	// permissive reading ("unknown" == "fine") is how an HP potion got worn
	// in an armour slot on a server whose refdata lacked the consumables.
	if err := Refusal(man, nil, SlotMail); !errors.Is(err, ErrNotEquippable) {
		t.Errorf("an item with no reference row: got %v, want ErrNotEquippable", err)
	}

	if err := Refusal(man, cottonSuit(), SlotHelm); !errors.Is(err, ErrWrongSlot) {
		t.Errorf("a suit in the helm slot: got %v, want ErrWrongSlot", err)
	}
	if err := Refusal(woman, cottonSuit(), SlotMail); !errors.Is(err, ErrWrongGender) {
		t.Errorf("a man's suit on a woman: got %v, want ErrWrongGender", err)
	}
	unisex := cottonSuit()
	unisex.ReqGender = ReqGenderAny
	if err := Refusal(woman, unisex, SlotMail); err != nil {
		t.Errorf("a unisex item on a woman: %v", err)
	}
	european := cottonSuit()
	european.Country = CountryEurope
	european.TypeID3 = FamilyEuropeHeavy
	if err := Refusal(man, european, SlotMail); !errors.Is(err, ErrWrongRace) {
		t.Errorf("a European item on a China character: got %v, want ErrWrongRace", err)
	}
	high := cottonSuit()
	high.ReqLevel1 = 12
	if err := Refusal(man, high, SlotMail); !errors.Is(err, ErrLevelTooLow) {
		t.Errorf("a level-12 item at level 1: got %v, want ErrLevelTooLow", err)
	}
	// A requirement by mastery level (a mastery id, not 1) is not one this
	// project can check yet, so it does not refuse.
	mastery := cottonSuit()
	mastery.ReqLevelType1 = 513
	mastery.ReqLevel1 = 40
	if err := Refusal(man, mastery, SlotMail); err != nil {
		t.Errorf("a mastery-level requirement is not enforced yet: %v", err)
	}
	potion := &refdata.Item{ID: 1, TypeID1: TypeItem, TypeID2: 3}
	if err := Refusal(man, potion, SlotMail); !errors.Is(err, ErrNotEquippable) {
		t.Errorf("a potion: got %v, want ErrNotEquippable", err)
	}
}

// TestTypeIDsAreWithinRecoveredBounds holds every type-id constant this package
// declares to the widths recovered from the server binary's own asserts (see the
// MaxTID* block in rules.go, and ReferenceData.cpp:2466-2470).
//
// This is a guard, not a discovery: it cannot tell a wrong-but-in-range family
// id from a right one. What it does catch is a constant that could never have
// come out of a real table -- a mistyped family of 30 when TypeID3 is four bits
// wide, say -- which is the failure mode worth a test, because such a constant
// would silently never match any item.
func TestTypeIDsAreWithinRecoveredBounds(t *testing.T) {
	for _, tc := range []struct {
		name  string
		value int
		limit int
	}{
		{"TypeItem", TypeItem, MaxTID1},
		{"TypeEquipment", TypeEquipment, MaxTID2},

		{"FamilyChinaGarment", FamilyChinaGarment, MaxTID3},
		{"FamilyChinaProtector", FamilyChinaProtector, MaxTID3},
		{"FamilyChinaArmor", FamilyChinaArmor, MaxTID3},
		{"FamilyShield", FamilyShield, MaxTID3},
		{"FamilyWeapon", FamilyWeapon, MaxTID3},
		{"FamilyAccessory", FamilyAccessory, MaxTID3},
		{"FamilyEuropeRobe", FamilyEuropeRobe, MaxTID3},
		{"FamilyEuropeLight", FamilyEuropeLight, MaxTID3},
		{"FamilyEuropeHeavy", FamilyEuropeHeavy, MaxTID3},

		{"PieceHelm", PieceHelm, MaxTID4},
		{"PieceShoulderGuard", PieceShoulderGuard, MaxTID4},
		{"PieceMail", PieceMail, MaxTID4},
		{"PiecePants", PiecePants, MaxTID4},
		{"PieceGauntlet", PieceGauntlet, MaxTID4},
		{"PieceBoots", PieceBoots, MaxTID4},
	} {
		if tc.value < 0 || tc.value >= tc.limit {
			t.Errorf("%s = %d, outside the recovered range [0, %d)", tc.name, tc.value, tc.limit)
		}
	}

	// The bounds themselves are powers of two, because each is one past the
	// largest value a fixed-width field can hold. If one of these ever stops
	// being a power of two the constant was transcribed wrong.
	for _, tc := range []struct {
		name  string
		limit int
	}{
		{"MaxCashItemTID", MaxCashItemTID},
		{"MaxTID1", MaxTID1},
		{"MaxTID2", MaxTID2},
		{"MaxTID3", MaxTID3},
		{"MaxTID4", MaxTID4},
	} {
		if tc.limit <= 0 || tc.limit&(tc.limit-1) != 0 {
			t.Errorf("%s = %d, which is not a power of two", tc.name, tc.limit)
		}
	}
}
