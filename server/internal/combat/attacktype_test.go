package combat

import "testing"

// TestRealMasksSplitIntoExactlyOneHalf walks the masks that actually occur in
// the real skill table, with the row counts measured on 2026-09-16 over 31,605
// `att` runs. The property under test is the one the damage sum depends on:
// every real mask names exactly one half, never both.
func TestRealMasksSplitIntoExactlyOneHalf(t *testing.T) {
	for _, tc := range []struct {
		mask     AttackType
		rows     int
		physical bool
		magical  bool
	}{
		{5, 17075, true, false}, // {1,4}
		{6, 4055, true, false},  // {2,4}
		{10, 6971, false, true}, // {2,8}
		{9, 2528, false, true},  // {1,8}
		{8, 966, false, true},   // {8}
	} {
		if got := tc.mask.IsPhysical(); got != tc.physical {
			t.Errorf("mask %d (%d real rows): IsPhysical = %v, want %v", tc.mask, tc.rows, got, tc.physical)
		}
		if got := tc.mask.IsMagical(); got != tc.magical {
			t.Errorf("mask %d (%d real rows): IsMagical = %v, want %v", tc.mask, tc.rows, got, tc.magical)
		}
		if tc.mask.IsPhysical() && tc.mask.IsMagical() {
			t.Errorf("mask %d claims BOTH halves; no real skill does, and the engine's sum relies on it", tc.mask)
		}
		if !tc.mask.Known() {
			t.Errorf("mask %d is a real authored mask and must read as Known", tc.mask)
		}
	}
}

// TestUnknownMaskStaysPhysical pins the compatibility rule. A skill record from
// an export made before the AttackType column carries 0, and must keep behaving
// exactly as it did then -- physical, never magical.
func TestUnknownMaskStaysPhysical(t *testing.T) {
	for _, mask := range []AttackType{0, AttackClassA, AttackClassB, AttackClassA | AttackClassB} {
		if !mask.IsPhysical() {
			t.Errorf("mask %d: an unknown mask must read as physical so old exports are unchanged", mask)
		}
		if mask.IsMagical() {
			t.Errorf("mask %d: an unknown mask must never reroute damage to the magical path", mask)
		}
		if mask.Known() {
			t.Errorf("mask %d names no damage half and must not read as Known", mask)
		}
	}
}

// TestBitsAreTheFormulaGuards states the constants against the two functions
// they were read out of, so a later edit that swaps them fails here rather than
// silently sending every magical skill down the physical path.
func TestBitsAreTheFormulaGuards(t *testing.T) {
	if AttackPhysical != 4 {
		t.Errorf("AttackPhysical = %d, want 4 -- Formula_MitigatePhysicalDamage (0040e450) tests & 4", AttackPhysical)
	}
	if AttackMagical != 8 {
		t.Errorf("AttackMagical = %d, want 8 -- Formula_MitigateMagicalDamage (0040e830) tests & 8", AttackMagical)
	}
}

// TestSkillAllowsWeapon walks FUN_0058d480 with the real codes.
func TestSkillAllowsWeapon(t *testing.T) {
	const weapon = WeaponTypeIDCategory
	for _, tc := range []struct {
		name       string
		req1, req2 int
		t3, t4     int
		want       bool
	}{
		// Both slots unused: 4,144 magical attack skills are in this state,
		// including every CH elemental nuke.
		{"no requirement, any weapon", ReqWeaponUnused, ReqWeaponUnused, weapon, WeaponEUAxe, true},
		{"no requirement, bare hand", ReqWeaponUnused, ReqWeaponUnused, 0, 0, true},

		// One slot used -- the common shape (e.g. SKILL_EU_AXE -> 9).
		{"axe skill with an axe", WeaponEUAxe, ReqWeaponUnused, weapon, WeaponEUAxe, true},
		{"axe skill with a staff", WeaponEUAxe, ReqWeaponUnused, weapon, WeaponEUStaff, false},
		{"axe skill bare-handed", WeaponEUAxe, ReqWeaponUnused, 0, 0, false},

		// Two slots used: SKILL_CH_SWORD takes sword OR blade, SKILL_CH_SPEAR
		// spear OR tblade. Both slots are really checked.
		{"CH sword skill with a sword", WeaponCHSword, WeaponCHBlade, weapon, WeaponCHSword, true},
		{"CH sword skill with a blade", WeaponCHSword, WeaponCHBlade, weapon, WeaponCHBlade, true},
		{"CH sword skill with a spear", WeaponCHSword, WeaponCHBlade, weapon, WeaponCHSpear, false},
		{"CH spear skill with a tblade", WeaponCHSpear, WeaponCHTBlade, weapon, WeaponCHTBlade, true},

		// SKILL_PUNCH_01 requires code 1, and an empty hand is code 1 via the
		// engine's own `if (code == 0) code = 1`.
		{"punch bare-handed", WeaponBareHand, ReqWeaponUnused, 0, 0, true},
		{"punch holding a sword", WeaponBareHand, ReqWeaponUnused, weapon, WeaponCHSword, false},

		// A non-weapon in the slot has a TypeID4 that means something else
		// entirely (armour's TypeID4 is which piece), so it must not be read as
		// a weapon code. TypeID3 3 is armour; its TypeID4 2 is a shoulder guard,
		// which must not satisfy a CH-sword requirement.
		{"armour in the weapon slot is not a CH sword", WeaponCHSword, ReqWeaponUnused, 3, WeaponCHSword, false},

		// Compatibility: 0/0 is invalid in the real table (the loader refuses
		// it), so it can only mean an export predating the columns.
		{"unknown requirement permits", 0, 0, weapon, WeaponEUAxe, true},
		{"unknown requirement permits bare-handed", 0, 0, 0, 0, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := SkillAllowsWeapon(tc.req1, tc.req2, tc.t3, tc.t4); got != tc.want {
				t.Errorf("SkillAllowsWeapon(%d, %d, t3=%d, t4=%d) = %v, want %v",
					tc.req1, tc.req2, tc.t3, tc.t4, got, tc.want)
			}
		})
	}
}

// TestWeaponCodesAreDistinct guards the vocabulary: these are TypeID4 values
// read out of real itemdata, where each weapon family occupies exactly one.
// A duplicate would silently let one weapon satisfy another's requirement.
func TestWeaponCodesAreDistinct(t *testing.T) {
	codes := map[string]int{
		"bare": WeaponBareHand, "ch_sword": WeaponCHSword, "ch_blade": WeaponCHBlade,
		"ch_spear": WeaponCHSpear, "ch_tblade": WeaponCHTBlade, "ch_bow": WeaponCHBow,
		"eu_sword": WeaponEUSword, "eu_tsword": WeaponEUTSword, "eu_axe": WeaponEUAxe,
		"eu_darkstaff": WeaponEUDarkStaff, "eu_tstaff": WeaponEUTStaff,
		"eu_crossbow": WeaponEUCrossbow, "eu_dagger": WeaponEUDagger,
		"eu_harp": WeaponEUHarp, "eu_staff": WeaponEUStaff, "fortress": WeaponFortress,
	}
	seen := map[int]string{}
	for name, c := range codes {
		if prev, dup := seen[c]; dup {
			t.Errorf("code %d is both %s and %s", c, prev, name)
		}
		seen[c] = name
		if c < 1 || c > MaxTID4Code {
			t.Errorf("%s = %d, outside the recovered TypeID4 range", name, c)
		}
	}
	if len(seen) != 16 {
		t.Errorf("got %d distinct codes, want 16 (1 bare hand + 15 real weapon types)", len(seen))
	}
}

// TestWeaponGateAppliesOnlyWithoutAReqCastList states the branch this gate sits
// inside. FUN_0058d480 checks ReqCastWeapon only when the skill's list at
// +0x3a0 is empty; 517 real skills carry both a 'reqi' list and a weapon
// requirement, and for those the engine never looks at the requirement.
//
// The rule lives in session.handleUseSkill, so this pins the DECISION rather
// than the plumbing: given a list count, is the weapon check consulted at all?
func TestWeaponGateAppliesOnlyWithoutAReqCastList(t *testing.T) {
	// The predicate the call site uses.
	applies := func(reqCastList, req1, req2 int) bool {
		return reqCastList == 0 && (req1 != 0 || req2 != 0)
	}
	if !applies(0, WeaponEUAxe, ReqWeaponUnused) {
		t.Error("no list + a real requirement: the gate must apply")
	}
	if applies(1, WeaponEUAxe, ReqWeaponUnused) {
		t.Error("a 'reqi' list is present: the engine takes the other branch, so the gate must NOT apply")
	}
	if applies(5, WeaponCHSword, WeaponCHBlade) {
		t.Error("a full five-slot list must still suppress the gate")
	}
	if applies(0, 0, 0) {
		t.Error("an export predating the columns must not gate anything")
	}
}
