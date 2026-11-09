package equipment

import (
	"errors"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
)

// Round 877: the mastery requirements are enforced at equip time, and the
// body armour may not mix cloth with armour. The item rows are synthetic,
// shaped as the real table's (a European robe asks for Wizard, Warlock, Bard
// or Cleric at the item's degree level; heavy armour for Warrior; light for
// Warrior, Rogue or Cleric).

func robe877(id int64, piece int) *refdata.Item {
	return &refdata.Item{ID: id, TypeID1: TypeItem, TypeID2: TypeEquipment, TypeID3: FamilyEuropeRobe, TypeID4: piece,
		Country: CountryEurope, ReqGender: ReqGenderAny,
		ReqLevelType1: 514, ReqLevel1: 101, ReqLevelType2: 516, ReqLevel2: 101,
		ReqLevelType3: 517, ReqLevel3: 101, ReqLevelType4: 518, ReqLevel4: 101}
}

func heavy877(id int64, piece int) *refdata.Item {
	return &refdata.Item{ID: id, TypeID1: TypeItem, TypeID2: TypeEquipment, TypeID3: FamilyEuropeHeavy, TypeID4: piece,
		Country: CountryEurope, ReqGender: ReqGenderAny,
		ReqLevelType1: 513, ReqLevel1: 101, ReqLevelType2: -1, ReqLevelType3: -1, ReqLevelType4: -1}
}

func light877(id int64, piece int) *refdata.Item {
	return &refdata.Item{ID: id, TypeID1: TypeItem, TypeID2: TypeEquipment, TypeID3: FamilyEuropeLight, TypeID4: piece,
		Country: CountryEurope, ReqGender: ReqGenderAny,
		ReqLevelType1: 513, ReqLevel1: 1, ReqLevelType2: 515, ReqLevel2: 1, ReqLevelType3: 518, ReqLevel3: 1, ReqLevelType4: -1}
}

func masteries877(levels map[int]int) func(int) (int, bool) {
	return func(id int) (int, bool) { return levels[id], true }
}

func TestRobeNeedsACasterMastery(t *testing.T) {
	warrior := &character.Character{Level: 110, Gender: character.GenderEuropeMan}
	robe := robe877(1, PieceMail)
	// MEASURED: Warrior 110 and Cleric 100 -- refused (0x186c).
	if err := Refusal(warrior, robe, SlotMail, masteries877(map[int]int{513: 110, 518: 100})); !errors.Is(err, ErrRequirementNotMet) {
		t.Errorf("Warrior 110 / Cleric 100: %v, want ErrRequirementNotMet", err)
	}
	// A pure Warrior: refused.
	if err := Refusal(warrior, robe, SlotMail, masteries877(map[int]int{513: 110})); !errors.Is(err, ErrRequirementNotMet) {
		t.Errorf("pure Warrior: %v, want ErrRequirementNotMet", err)
	}
	// MEASURED: Cleric 101 -- allowed. Any one of the four does.
	for _, m := range []int{514, 516, 517, 518} {
		if err := Refusal(warrior, robe, SlotMail, masteries877(map[int]int{513: 110, m: 101})); err != nil {
			t.Errorf("mastery %d at 101: %v", m, err)
		}
	}
	// No lookup: carried, not enforced (every caller before round 877).
	if err := Refusal(warrior, robe, SlotMail, nil); err != nil {
		t.Errorf("nil lookup: %v", err)
	}
	// Heavy armour wants the Warrior.
	if err := Refusal(warrior, heavy877(2, PieceMail), SlotMail, masteries877(map[int]int{518: 110})); !errors.Is(err, ErrRequirementNotMet) {
		t.Errorf("heavy without Warrior: %v", err)
	}
	if !Qualifies(robe, 110, masteries877(map[int]int{518: 101})) || Qualifies(robe, 110, masteries877(map[int]int{513: 110})) {
		t.Error("Qualifies disagrees with the equip test")
	}
}

func TestArmourMix(t *testing.T) {
	robeChest, robeLegs := robe877(1, PieceMail), robe877(2, PiecePants)
	lightChest, lightLegs, lightFeet := light877(3, PieceMail), light877(4, PiecePants), light877(5, PieceBoots)
	heavyLegs := heavy877(6, PiecePants)
	cases := []struct {
		name string
		it   *refdata.Item
		slot Slot
		worn map[Slot]*refdata.Item
		want bool // refused
	}{
		// MEASURED: light chest, legs and boots worn, a robe chest put on.
		{"robe over light", robeChest, SlotMail, map[Slot]*refdata.Item{SlotMail: lightChest, SlotPants: lightLegs, SlotBoots: lightFeet}, true},
		{"robe with robe", robeLegs, SlotPants, map[Slot]*refdata.Item{SlotMail: robeChest}, false},
		{"heavy with light", heavyLegs, SlotPants, map[Slot]*refdata.Item{SlotMail: lightChest}, false},
		{"light with robe", lightLegs, SlotPants, map[Slot]*refdata.Item{SlotMail: robeChest}, true},
		// The only armour piece worn, in the slot asked: the two swap.
		{"swap the only piece", robeChest, SlotMail, map[Slot]*refdata.Item{SlotMail: lightChest}, false},
		{"only piece elsewhere", robeChest, SlotMail, map[Slot]*refdata.Item{SlotPants: lightLegs}, true},
		{"nothing worn", robeChest, SlotMail, nil, false},
	}
	for _, tc := range cases {
		err := ArmourMixRefusal(tc.it, tc.slot, tc.worn)
		if got := errors.Is(err, ErrArmourMix); got != tc.want {
			t.Errorf("%s: %v, want refused %v", tc.name, err, tc.want)
		}
	}
	// A weapon is not body armour.
	weapon := &refdata.Item{ID: 9, TypeID1: TypeItem, TypeID2: TypeEquipment, TypeID3: FamilyWeapon}
	if err := ArmourMixRefusal(weapon, SlotWeapon, map[Slot]*refdata.Item{SlotMail: robeChest}); err != nil {
		t.Errorf("weapon: %v", err)
	}
}
