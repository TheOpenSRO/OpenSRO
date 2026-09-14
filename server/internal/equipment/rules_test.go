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
