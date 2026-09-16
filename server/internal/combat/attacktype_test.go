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

// TestCastRequirementsMatchTheRealRecords walks FUN_0058d480's list branch with
// the (kind, value) shapes that actually occur: kind is a TypeID3 category and
// value a TypeID4 type, 0 meaning any.
func TestCastRequirementsMatchTheRealRecords(t *testing.T) {
	const weapon, shield, euLight, euRobe = 6, 4, 10, 9
	staff := EquippedType{TypeID3: weapon, TypeID4: WeaponEUStaff} // kind 6 value 15, 230 records
	axe := EquippedType{TypeID3: weapon, TypeID4: WeaponEUAxe}     // kind 6 value 9, 146 records
	buckler := EquippedType{TypeID3: shield, TypeID4: 1}           // kind 4 value 1, 141 records
	robe := EquippedType{TypeID3: euRobe, TypeID4: 3}

	for _, tc := range []struct {
		name string
		reqs []CastRequirement
		all  bool
		worn []EquippedType
		want bool
	}{
		{"staff skill with a staff", []CastRequirement{{weapon, WeaponEUStaff}}, false, []EquippedType{staff}, true},
		{"staff skill with an axe", []CastRequirement{{weapon, WeaponEUStaff}}, false, []EquippedType{axe}, false},
		{"staff skill bare-handed", []CastRequirement{{weapon, WeaponEUStaff}}, false, nil, false},

		// value 0 means any item of that category -- kind 9 and 10 only ever
		// carry 0 in the real table.
		{"robe skill wearing a robe", []CastRequirement{{euRobe, 0}}, false, []EquippedType{robe}, true},
		{"robe skill wearing light armour", []CastRequirement{{euRobe, 0}}, false, []EquippedType{{euLight, 3}}, false},

		// ANY-of: 966 real skills. One match is enough.
		{"any-of: second entry matches", []CastRequirement{{weapon, WeaponEUStaff}, {weapon, WeaponEUAxe}}, false, []EquippedType{axe}, true},
		{"any-of: nothing matches", []CastRequirement{{weapon, WeaponEUStaff}, {shield, 1}}, false, []EquippedType{axe}, false},

		// ALL-of ('reqn', field 0x3b4): 128 real skills. Every entry must match.
		{"all-of: both match", []CastRequirement{{weapon, WeaponEUAxe}, {shield, 1}}, true, []EquippedType{axe, buckler}, true},
		{"all-of: only one matches", []CastRequirement{{weapon, WeaponEUAxe}, {shield, 1}}, true, []EquippedType{axe}, false},

		// Kind 14 is a character flag, not equipment; it is deliberately
		// permissive because the flag is not recovered.
		{"flag kind passes bare-handed", []CastRequirement{{CastReqFlagKind, 1}}, false, nil, true},
		{"flag kind passes under all-of too", []CastRequirement{{CastReqFlagKind, 1}, {weapon, WeaponEUAxe}}, true, []EquippedType{axe}, true},

		// An empty list never reaches this branch in the engine.
		{"empty list allows", nil, false, nil, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := SkillAllowsEquipment(tc.reqs, tc.all, tc.worn); got != tc.want {
				t.Errorf("SkillAllowsEquipment(%v, all=%v, %v) = %v, want %v",
					tc.reqs, tc.all, tc.worn, got, tc.want)
			}
		})
	}
}

// TestParseCastRequirements covers the packed export form, including the
// malformed entry that must cost one requirement rather than the whole skill.
func TestParseCastRequirements(t *testing.T) {
	got := ParseCastRequirements("6:15;4:1")
	want := []CastRequirement{{6, 15}, {4, 1}}
	if len(got) != len(want) || got[0] != want[0] || got[1] != want[1] {
		t.Errorf("got %v, want %v", got, want)
	}
	if r := ParseCastRequirements(""); r != nil {
		t.Errorf("empty packs to %v, want nil", r)
	}
	if r := ParseCastRequirements("6:15;garbage;4:1"); len(r) != 2 {
		t.Errorf("a malformed entry must cost one requirement, got %v", r)
	}
}
