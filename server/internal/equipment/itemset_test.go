package equipment

import (
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
)

func setPiece(id int64, setID, family, piece int) *refdata.Item {
	return &refdata.Item{ID: id, TypeID1: TypeItem, TypeID2: TypeEquipment,
		TypeID3: family, TypeID4: piece, SetID: setID}
}

// TestSetsWornCountsSlotsNotItems is the distinction the client's own guard
// makes -- `if ((1 << slot) & mask) == 0` before it counts -- and the reason
// it matters: 30 of the 42 sets in a real itemdata list more than one item for
// some slot, so counting items would never complete them.
func TestSetsWornCountsSlotsNotItems(t *testing.T) {
	const armourSet = 13
	worn := map[Slot]*refdata.Item{
		SlotHelm:          setPiece(1, armourSet, FamilyChinaArmor, PieceHelm),
		SlotMail:          setPiece(2, armourSet, FamilyChinaArmor, PieceMail),
		SlotShoulderGuard: setPiece(3, armourSet, FamilyChinaArmor, PieceShoulderGuard),
		SlotGauntlet:      setPiece(4, armourSet, FamilyChinaArmor, PieceGauntlet),
		SlotPants:         setPiece(5, armourSet, FamilyChinaArmor, PiecePants),
		SlotBoots:         setPiece(6, armourSet, FamilyChinaArmor, PieceBoots),
		// Not part of the set, and must not be counted toward it.
		SlotWeapon: setPiece(7, 0, FamilyWeapon, 2),
	}
	sets := SetsWorn(worn)
	if len(sets) != 1 {
		t.Fatalf("got %d sets, want 1: %+v", len(sets), sets)
	}
	p := sets[armourSet]
	if p.Count() != 6 {
		t.Errorf("got %d slots, want the six armour slots: %+v", p.Count(), p.Slots)
	}
	// The six-slot shape is what 36 of 42 real sets have.
	if !p.Complete(6) {
		t.Error("six of six slots is a complete six-slot set")
	}
	if p.Complete(7) {
		t.Error("six of seven slots is not complete")
	}
	// An unknown set size is not an excuse to call it complete.
	if p.Complete(0) {
		t.Error("a set of no slots must never report complete")
	}
}

// TestSetsWornIgnoresUnsetAndMissing keeps the two "not in a set" cases from
// creating a phantom set 0.
func TestSetsWornIgnoresUnsetAndMissing(t *testing.T) {
	worn := map[Slot]*refdata.Item{
		SlotMail:   setPiece(1, 0, FamilyChinaGarment, PieceMail),
		SlotPants:  nil,
		SlotWeapon: setPiece(3, 0, FamilyWeapon, 2),
	}
	if sets := SetsWorn(worn); len(sets) != 0 {
		t.Errorf("items in no set produced %+v", sets)
	}
}

// TestSetsWornTracksTheRingsSeparately covers the one slot pair. A set with
// two rings has them in slots 11 and 12, and both must count -- which is why
// SetsWorn keys on the slot the item is IN rather than on SlotFor's answer,
// since SlotFor maps every ring to SlotRingLeft.
func TestSetsWornTracksTheRingsSeparately(t *testing.T) {
	const accessorySet = 7
	worn := map[Slot]*refdata.Item{
		SlotEarring:   setPiece(1, accessorySet, FamilyChinaAccessory, PieceEarring),
		SlotNecklace:  setPiece(2, accessorySet, FamilyChinaAccessory, PieceNecklace),
		SlotRingLeft:  setPiece(3, accessorySet, FamilyChinaAccessory, PieceRing),
		SlotRingRight: setPiece(4, accessorySet, FamilyChinaAccessory, PieceRing),
	}
	p := SetsWorn(worn)[accessorySet]
	if p.Count() != 4 {
		t.Fatalf("got %d slots, want 4: %+v", p.Count(), p.Slots)
	}
	if !p.Slots[SlotRingLeft] || !p.Slots[SlotRingRight] {
		t.Errorf("both ring slots must count separately: %+v", p.Slots)
	}
	// Two rings in one slot is impossible, so the same item id in both slots
	// is still two slots -- which is the client's model exactly.
	if p.Complete(3) {
		t.Error("four filled slots is not a three-slot set")
	}
}

// TestSetPiecesAllResolveToASlot holds the property measured over the real
// table: every piece of every set resolves through SlotFor, none left over.
// The shapes are the four a real itemdata produces.
func TestSetPiecesAllResolveToASlot(t *testing.T) {
	for _, tc := range []struct {
		name   string
		family int
		pieces []int
		want   []Slot
	}{
		{"armour", FamilyEuropeHeavy,
			[]int{PieceHelm, PieceMail, PieceShoulderGuard, PieceGauntlet, PiecePants, PieceBoots},
			[]Slot{SlotHelm, SlotMail, SlotShoulderGuard, SlotGauntlet, SlotPants, SlotBoots}},
		{"accessories", FamilyEuropeAccessory,
			[]int{PieceEarring, PieceNecklace, PieceRing},
			[]Slot{SlotEarring, SlotNecklace, SlotRingLeft}},
		{"weapon", FamilyWeapon, []int{2}, []Slot{SlotWeapon}},
		{"shield", FamilyShield, []int{1}, []Slot{SlotShield}},
	} {
		for i, piece := range tc.pieces {
			it := setPiece(int64(i), 1, tc.family, piece)
			got, ok := SlotFor(it)
			if !ok {
				t.Errorf("%s piece %d resolves to no slot", tc.name, piece)
				continue
			}
			if got != tc.want[i] {
				t.Errorf("%s piece %d: slot %d, want %d", tc.name, piece, got, tc.want[i])
			}
		}
	}
}

// TestBonusTierPicksHighestNotExceeding holds the rule the engine's own search
// implements: FUN_006a7320 shifts its tier bit right until something matches,
// and each shift is one fewer piece. So a partial set earns the best tier it
// has reached, not nothing and not the next one up.
//
// The tier table is the real one for ITEM_11_SET_A's armour: groups 2, 3 and 4
// -- MAGIC_11_SET_A_DEFENSE_2, _DEFENSE_4 and _DEFENSE_6 -- at two, four and
// six pieces.
func TestBonusTierPicksHighestNotExceeding(t *testing.T) {
	tiers := map[int]int{2: 2, 4: 3, 6: 4}
	for _, tc := range []struct {
		worn      int
		wantGroup int
		wantOK    bool
	}{
		{0, 0, false},
		{1, 0, false}, // below MinSetPiecesForBonus
		{2, 2, true},
		{3, 2, true}, // no three-piece tier: the two-piece one still applies
		{4, 3, true},
		{5, 3, true},
		{6, 4, true},
	} {
		p := SetProgress{SetID: 13, Slots: map[Slot]bool{}}
		for i := 0; i < tc.worn; i++ {
			p.Slots[Slot(i)] = true
		}
		got, ok := p.BonusTier(tiers)
		if ok != tc.wantOK || got != tc.wantGroup {
			t.Errorf("%d pieces: got group %d,%v; want %d,%v", tc.worn, got, ok, tc.wantGroup, tc.wantOK)
		}
	}
}

// TestAccessorySetHasNoSixPieceTier is the prediction that decoded the table,
// kept as a test because it is what makes the position-is-piece-count reading
// falsifiable: three slots cannot reach six pieces, so a three-slot set that
// somehow carried a six-piece tier could never award it.
func TestAccessorySetHasNoSixPieceTier(t *testing.T) {
	// ITEM_11_SET_A_ACCESSORY: _ACCESSORY_2 at two pieces, _ACCESSORY_4 at four.
	tiers := map[int]int{2: 5, 4: 6}
	full := SetProgress{SetID: 25, Slots: map[Slot]bool{
		SlotEarring: true, SlotNecklace: true, SlotRingLeft: true,
	}}
	if full.Count() != 3 {
		t.Fatalf("an accessory set fills 3 slots, got %d", full.Count())
	}
	got, ok := full.BonusTier(tiers)
	if !ok || got != 5 {
		t.Errorf("a full three-slot accessory set earns the two-piece tier (group 5), got %d,%v", got, ok)
	}
	// And it can never reach the four-piece tier with three slots -- unless the
	// character also wears the second ring, which is why there are four
	// accessory slots and only three accessory pieces per set.
	if _, ok := (SetProgress{Slots: map[Slot]bool{SlotEarring: true}}).BonusTier(tiers); ok {
		t.Error("one piece earns nothing")
	}
}

// TestMinSetPiecesForBonus pins the constant against the engine's own guard.
func TestMinSetPiecesForBonus(t *testing.T) {
	if MinSetPiecesForBonus != 2 {
		t.Fatalf("MinSetPiecesForBonus = %d; FUN_0066c3d0 returns 0 below 2", MinSetPiecesForBonus)
	}
	// The engine's key is 1 << (count-2); that it is a shift is why the search
	// can walk down one piece at a time.
	for count := MinSetPiecesForBonus; count < 12; count++ {
		if got, want := 1<<(count-MinSetPiecesForBonus), 1<<(count-2); got != want {
			t.Errorf("count %d: key %d, want %d", count, got, want)
		}
	}
}
