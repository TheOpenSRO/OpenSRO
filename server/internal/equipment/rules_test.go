package equipment

import (
	"errors"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
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
		{"FamilyJobSuit", FamilyJobSuit, MaxTID3},
		{"FamilyChinaAccessory", FamilyChinaAccessory, MaxTID3},
		{"FamilyEuropeAccessory", FamilyEuropeAccessory, MaxTID3},
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

// TestAccessoriesAreEquippable covers a gap that made 594 real items refuse to
// equip: the accessory families were missing from SlotFor entirely, and the
// constant that looked like it covered them (`FamilyAccessory = 7`) pointed at
// job suits instead.
func TestAccessoriesAreEquippable(t *testing.T) {
	for _, family := range []int{FamilyChinaAccessory, FamilyEuropeAccessory} {
		for _, tc := range []struct {
			piece int
			want  Slot
		}{
			{PieceEarring, SlotEarring},
			{PieceNecklace, SlotNecklace},
			{PieceRing, SlotRingLeft},
		} {
			it := &refdata.Item{TypeID1: TypeItem, TypeID2: TypeEquipment,
				TypeID3: family, TypeID4: tc.piece}
			got, ok := SlotFor(it)
			if !ok {
				t.Errorf("family %d piece %d: not equippable", family, tc.piece)
				continue
			}
			if got != tc.want {
				t.Errorf("family %d piece %d: slot %d, want %d", family, tc.piece, got, tc.want)
			}
		}
	}
}

// TestJobSuitIsNotAnAccessory pins the correction. TypeID3 7 is a job suit --
// every real row there is a TRADE_TRADER, TRADE_THIEF, TRADE_HUNTER or
// FRPVP_VOUCHER -- so it must not resolve to an accessory slot.
//
// This test used to assert job suits resolved to NOTHING, on the grounds that
// "OpenSRO has no job-suit slot". It had one all along: slot 8, carrying the
// invented name SlotExtra. The engine's resolver returns 8 for exactly this
// family, which is what named the slot -- so the assertion is now that every
// piece lands there, and only the family boundary is what it was.
func TestJobSuitIsNotAnAccessory(t *testing.T) {
	if FamilyJobSuit == FamilyChinaAccessory || FamilyJobSuit == FamilyEuropeAccessory {
		t.Fatal("the job-suit family must be distinct from the accessory families")
	}
	for _, piece := range []int{1, 2, 3, 5, 6, 7} {
		it := &refdata.Item{TypeID1: TypeItem, TypeID2: TypeEquipment,
			TypeID3: FamilyJobSuit, TypeID4: piece}
		slot, ok := SlotFor(it)
		if !ok || slot != SlotJobSuit {
			t.Errorf("job suit piece %d resolved to %d,%v; want the job-suit slot %d", piece, slot, ok, SlotJobSuit)
		}
		for _, acc := range AccessorySlots {
			if slot == acc {
				t.Errorf("job suit piece %d resolved to accessory slot %d", piece, acc)
			}
		}
	}
}

// TestAccessorySlotsAppendedNotInserted guards the persistence rule: a Slot is
// stored as its integer, so the pre-existing slots must keep their values.
func TestAccessorySlotsAppendedNotInserted(t *testing.T) {
	for _, tc := range []struct {
		slot Slot
		want int
	}{
		{SlotHelm, 0}, {SlotMail, 1}, {SlotShoulderGuard, 2}, {SlotGauntlet, 3},
		{SlotPants, 4}, {SlotBoots, 5}, {SlotWeapon, 6}, {SlotShield, 7},
		{SlotJobSuit, 8}, {SlotEarring, 9}, {SlotNecklace, 10}, {SlotRingLeft, 11},
		{SlotRingRight, 12},
	} {
		if int(tc.slot) != tc.want {
			t.Errorf("slot %d moved to %d -- every equipped item at that value would change meaning",
				tc.want, int(tc.slot))
		}
	}
}

// TestSlotForMatchesEngineResolver holds SlotFor to GObjPC::FUN_00496c20
// (`0x00496c20`), the engine's own item-to-slot resolver, arm for arm. The
// sample codenames are from a real client's itemdata and are what settles
// each row: the armour mapping is a permutation, so agreeing with it by
// accident is not possible.
func TestSlotForMatchesEngineResolver(t *testing.T) {
	for _, tc := range []struct {
		t2, t3, t4 int
		want       Slot
		ok         bool
		sample     string
	}{
		// Armour: six families, six pieces. TypeID4 -> slot is 1,2,3,4,5,6
		// -> 0,2,1,4,3,5, and the codename suffix says which piece is which.
		{1, FamilyChinaGarment, PieceHelm, SlotHelm, true, "ITEM_CH_W_CLOTHES_06_HA_B_RARE"},
		{1, FamilyChinaGarment, PieceShoulderGuard, SlotShoulderGuard, true, "ITEM_CH_W_CLOTHES_01_SA_A_RARE"},
		{1, FamilyChinaGarment, PieceMail, SlotMail, true, "ITEM_CH_W_CLOTHES_01_BA_A_RARE"},
		{1, FamilyChinaGarment, PiecePants, SlotPants, true, "ITEM_CH_W_CLOTHES_01_LA_A_RARE"},
		{1, FamilyChinaGarment, PieceGauntlet, SlotGauntlet, true, "ITEM_CH_W_CLOTHES_01_AA_A_RARE"},
		{1, FamilyChinaGarment, PieceBoots, SlotBoots, true, "ITEM_CH_W_CLOTHES_02_FA_C_RARE"},
		{1, FamilyEuropeHeavy, PieceMail, SlotMail, true, "ITEM_EU_M_HEAVY_03_BA_B_RARE"},
		{1, FamilyEuropeLight, PieceGauntlet, SlotGauntlet, true, "ITEM_EU_W_LIGHT_06_AA_C_RARE"},

		{1, FamilyShield, 1, SlotShield, true, "ITEM_CH_SHIELD_01_A_DEF"},
		{1, FamilyShield, 2, SlotShield, true, "ITEM_EU_SHIELD_01_A"},
		{1, FamilyWeapon, 2, SlotWeapon, true, "ITEM_CH_SWORD_08_A_RARE_HONOR"},
		{1, FamilyWeapon, 16, SlotWeapon, true, "ITEM_FORT_FORTRESS_HAMMER_06"},

		// TypeID3 == 7 is the job suit -- the slot this project called
		// "extra" until the resolver named it.
		{1, FamilyJobSuit, 1, SlotJobSuit, true, "ITEM_EU_F_TRADE_TRADER_01"},
		{1, FamilyJobSuit, 3, SlotJobSuit, true, "ITEM_EU_F_TRADE_HUNTER_01"},
		{1, FamilyJobSuit, 5, SlotJobSuit, true, "ITEM_CH_F_FRPVP_VOUCHER_D"},

		{1, FamilyChinaAccessory, PieceEarring, SlotEarring, true, "ITEM_CH_EARRING_11_A_RARE"},
		{1, FamilyChinaAccessory, PieceRing, SlotRingLeft, true, "ITEM_CH_RING_01_A_RARE"},
		{1, FamilyEuropeAccessory, PieceNecklace, SlotNecklace, true, "ITEM_EU_NECKLACE_01_A_RARE"},

		// Ammunition: not TypeEquipment, still equipped, in the shield slot.
		{TypeExpendable, FamilyAmmunition, 1, SlotShield, true, "ITEM_EVENT_QUIVER"},
		{TypeExpendable, FamilyAmmunition, 2, SlotShield, true, "ITEM_ETC_AMMO_BOLT_01_DEF"},

		// Avatars (TypeID3 13/14) have no case in the resolver -- it
		// asserts and returns -1. They live in a separate container.
		{1, 13, 2, 0, false, "ITEM_EVENT_AVATAR_W_TURKEY"},
		{1, 14, 1, 0, false, "ITEM_EVENT_AVATAR_M_NASRUN_RED"},
		// An ordinary expendable is not equipment at all.
		{TypeExpendable, 1, 1, 0, false, "ITEM_MALL_HP_SUPERSET_5_BAG"},
	} {
		it := &refdata.Item{TypeID1: TypeItem, TypeID2: tc.t2, TypeID3: tc.t3, TypeID4: tc.t4}
		got, ok := SlotFor(it)
		if ok != tc.ok || (ok && got != tc.want) {
			t.Errorf("SlotFor(%d/%d/%d/%d) = %d,%v; want %d,%v  (%s)",
				TypeItem, tc.t2, tc.t3, tc.t4, got, ok, tc.want, tc.ok, tc.sample)
		}
	}
}

// TestRingTakesEitherSlot is the one place the engine does not demand an
// exact slot match: a ring resolves to slot 11 and it accepts 11 or 12.
func TestRingTakesEitherSlot(t *testing.T) {
	ring := &refdata.Item{ID: 1, TypeID1: TypeItem, TypeID2: TypeEquipment,
		TypeID3: FamilyEuropeAccessory, TypeID4: PieceRing, Country: CountryAny, ReqGender: ReqGenderAny}
	for _, slot := range []Slot{SlotRingLeft, SlotRingRight} {
		if err := Refusal(nil, ring, slot); err != nil {
			t.Errorf("a ring was refused slot %d: %v", slot, err)
		}
	}
	if err := Refusal(nil, ring, SlotNecklace); err == nil {
		t.Error("a ring was allowed into the necklace slot")
	}
	// The pair is rings only: a necklace resolves to 10 and stays there.
	neck := &refdata.Item{ID: 2, TypeID1: TypeItem, TypeID2: TypeEquipment,
		TypeID3: FamilyEuropeAccessory, TypeID4: PieceNecklace, Country: CountryAny, ReqGender: ReqGenderAny}
	if err := Refusal(nil, neck, SlotRingRight); err == nil {
		t.Error("a necklace was allowed into the second ring slot")
	}
}

// TestSlotsFitEngineBound holds the enum inside the engine's own bound: its
// equip check refuses any slot above 12 outright (0x1806), so a Slot this
// project invents beyond that could never be sent to a real client.
func TestSlotsFitEngineBound(t *testing.T) {
	for _, s := range append(append([]Slot{}, WearableSlots...), AccessorySlots...) {
		if int(s) >= MaxEquipSlots {
			t.Errorf("slot %d is outside the engine's %d slots", s, MaxEquipSlots)
		}
	}
	if int(SlotRingRight) != MaxEquipSlots-1 {
		t.Errorf("SlotRingRight = %d, want the last engine slot %d", SlotRingRight, MaxEquipSlots-1)
	}
}

// TestWearableSlotsAreTheVisualRange holds the split the client's appearance
// installer (`0x00a61010`) actually makes: slots 0..EquipVisualCount-1 go to
// the mesh path, and 9..12 go somewhere else and return before any model is
// attached. So WearableSlots must be exactly the first range and
// AccessorySlots exactly the second -- together covering every slot the
// engine has, with none left over.
//
// The job suit is the slot this caught: it is at 8, inside the visual range,
// and WearableSlots did not have it.
func TestWearableSlotsAreTheVisualRange(t *testing.T) {
	seen := map[Slot]string{}
	for _, s := range WearableSlots {
		if int(s) >= EquipVisualCount {
			t.Errorf("slot %d is in WearableSlots but outside the client's %d visual slots", s, EquipVisualCount)
		}
		seen[s] = "wearable"
	}
	for _, s := range AccessorySlots {
		if int(s) < EquipVisualCount {
			t.Errorf("slot %d is in AccessorySlots but inside the visual range -- the client would draw it", s)
		}
		if was, dup := seen[s]; dup {
			t.Errorf("slot %d is both %s and an accessory", s, was)
		}
		seen[s] = "accessory"
	}
	if len(seen) != MaxEquipSlots {
		t.Errorf("the two lists cover %d slots, want all %d", len(seen), MaxEquipSlots)
	}
	for s := Slot(0); int(s) < MaxEquipSlots; s++ {
		if _, ok := seen[s]; !ok {
			t.Errorf("slot %d is in neither list", s)
		}
	}
	if !slotIn(SlotJobSuit, WearableSlots) {
		t.Error("the job suit is at visual slot 8 and the client draws it")
	}
}

func slotIn(s Slot, list []Slot) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}

// TestMaxItemOptLevelIsTheEnginesCeiling pins the bound and, more importantly,
// what kind of bound it is. CheckEquipsetIntegrity refuses an equipped set when
// any item's option level exceeds 0xfa, so 250 is legal and 251 is not.
//
// It is a VALIDATION ceiling, not a balance figure. Real items reach single
// digits. A future change that reads this as "items go up to +250" would be
// making a design decision out of a sanity check, which is the failure this
// test's name is meant to interrupt.
func TestMaxItemOptLevelIsTheEnginesCeiling(t *testing.T) {
	if MaxItemOptLevel != 0xfa {
		t.Fatalf("MaxItemOptLevel = %d; the engine refuses above 0xfa (%d)", MaxItemOptLevel, 0xfa)
	}
	// The guard is `0xfa < value`, so the bound itself is legal.
	for _, tc := range []struct {
		level int
		legal bool
	}{{0, true}, {12, true}, {MaxItemOptLevel, true}, {MaxItemOptLevel + 1, false}} {
		if got := tc.level <= MaxItemOptLevel; got != tc.legal {
			t.Errorf("option level %d: legal=%v, want %v", tc.level, got, tc.legal)
		}
	}
	// It is a byte in the engine, so it cannot exceed 255 whatever else changes.
	if MaxItemOptLevel > 255 {
		t.Errorf("MaxItemOptLevel = %d, but the engine stores it in a byte", MaxItemOptLevel)
	}
}

// TestAmmunitionIsAllowedOnlyInTheShieldSlot holds the exception the engine
// spells out in CheckEquipsetIntegrity: a "Bullet" passes validation at slot 7
// and nowhere else. OpenSRO's SlotFor already sends ammunition there; this
// pins that it sends it NOWHERE else, which is the half a resolver could get
// wrong silently.
func TestAmmunitionIsAllowedOnlyInTheShieldSlot(t *testing.T) {
	for _, t4 := range []int{1, 2} {
		ammo := &refdata.Item{ID: int64(t4), TypeID1: TypeItem,
			TypeID2: TypeExpendable, TypeID3: FamilyAmmunition, TypeID4: t4}
		slot, ok := SlotFor(ammo)
		if !ok || slot != SlotShield {
			t.Fatalf("ammunition TypeID4 %d resolved to %d,%v; want the shield slot %d",
				t4, slot, ok, SlotShield)
		}
		for s := Slot(0); int(s) < MaxEquipSlots; s++ {
			if s == SlotShield {
				continue
			}
			if SlotAccepts(slot, s) {
				t.Errorf("ammunition was accepted in slot %d; the engine allows only slot 7", s)
			}
		}
	}
}

// TestOpenSROSlotsFitTheEnginesCombinedArray holds OpenSRO's two separate
// index spaces to the engine's single one.
//
// The original puts equipment and backpack in one array: slots 0..12 are worn
// (equipment.MaxEquipSlots) and the backpack starts at 13. Its "inventory size"
// cap of 99 therefore covers both, leaving at most 86 usable backpack slots.
// OpenSRO splits them, which is a different design rather than a wrong one --
// but the total still has to be something the engine could represent, or a
// character here could hold more than one there ever could.
//
// This lives in the equipment package because it is the only one that imports
// both. See the note in inventory.go for the two use-sites.
func TestOpenSROSlotsFitTheEnginesCombinedArray(t *testing.T) {
	total := MaxEquipSlots + inventory.SlotsPerCharacter
	if total > inventory.MaxSlotsExpanded {
		t.Errorf("%d equipment slots + %d inventory slots = %d, more than the engine's "+
			"largest single array (%d)", MaxEquipSlots, inventory.SlotsPerCharacter,
			total, inventory.MaxSlotsExpanded)
	}
	// And the backpack alone must leave room for the equipment slots inside the
	// engine's cap -- the mistake this guards is reading 99 as 99 free slots.
	if inventory.SlotsPerCharacter > inventory.MaxSlotsExpanded-MaxEquipSlots {
		t.Errorf("inventory.SlotsPerCharacter is %d; the engine's array leaves only %d "+
			"once the %d equipment slots are counted",
			inventory.SlotsPerCharacter, inventory.MaxSlotsExpanded-MaxEquipSlots, MaxEquipSlots)
	}
}
