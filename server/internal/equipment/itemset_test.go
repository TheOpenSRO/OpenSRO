package equipment

import (
	"testing"

	"github.com/OpenSRO/srrevamp/server/internal/refdata"
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
