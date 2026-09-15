package equipment

import "testing"

// Both hands cannot hold a two-handed weapon and a shield.
//
// Dormant until shields started blocking: with no block a spurious shield was
// only a drawing mistake; now it is free damage avoidance.
func TestTwoHandedConflict(t *testing.T) {
	oneH := &ItemStats{TwoHanded: false}
	twoH := &ItemStats{TwoHanded: true}
	shield := &ItemStats{}

	for _, tc := range []struct {
		name     string
		worn     map[Slot]*ItemStats
		slot     Slot
		incoming *ItemStats
		want     bool
	}{
		{"shield onto a two-handed weapon", map[Slot]*ItemStats{SlotWeapon: twoH}, SlotShield, shield, true},
		{"shield onto a one-handed weapon", map[Slot]*ItemStats{SlotWeapon: oneH}, SlotShield, shield, false},
		{"shield with no weapon at all", map[Slot]*ItemStats{}, SlotShield, shield, false},
		{"two-handed weapon onto a shield", map[Slot]*ItemStats{SlotShield: shield}, SlotWeapon, twoH, true},
		{"one-handed weapon onto a shield", map[Slot]*ItemStats{SlotShield: shield}, SlotWeapon, oneH, false},
		{"two-handed weapon, no shield worn", map[Slot]*ItemStats{}, SlotWeapon, twoH, false},
		{"armour is never a conflict", map[Slot]*ItemStats{SlotWeapon: twoH}, SlotMail, oneH, false},
		{"a nil item is never a conflict", map[Slot]*ItemStats{SlotWeapon: twoH}, SlotShield, nil, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := TwoHandedConflict(tc.worn, tc.slot, tc.incoming); got != tc.want {
				t.Errorf("TwoHandedConflict = %v, want %v", got, tc.want)
			}
		})
	}
}
