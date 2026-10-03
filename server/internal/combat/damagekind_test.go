package combat

import "testing"

// The selector's ORDER is part of the rule, because the engine's tests are an
// if/else chain: transform, then structure, then fortress weapon, then the
// event list. Each case here is one the chain decides differently from the
// naive reading.
func TestSelectDamageKindFollowsTheEnginesOrder(t *testing.T) {
	structure := KindInput{AttackerIsPC: true, TargetTypeID1: 1, TargetTypeID2: 2, TargetTypeID3: 5, TargetTypeID4: 3}
	for _, c := range []struct {
		name string
		in   KindInput
		want DamageKind
	}{
		{"a plain PC blow", KindInput{AttackerIsPC: true}, KindOrdinary},
		{"a monster's blow is always ordinary, whatever it hits",
			KindInput{AttackerIsPC: false, TargetCodeName: "MOB_EV_WINTER_SNOWMAN", WeaponTypeID4: 16}, KindOrdinary},
		{"a structure", structure, KindStructure},
		{"a flag is a structure too",
			KindInput{AttackerIsPC: true, TargetTypeID1: 1, TargetTypeID2: 2, TargetTypeID3: 4, TargetTypeID4: 2}, KindStructure},
		{"a fortress weapon on a monster", KindInput{AttackerIsPC: true, WeaponTypeID4: 16}, KindFortressWeapon},
		{"a fortress weapon on a STRUCTURE is the structure kind, not 4",
			func() KindInput { in := structure; in.WeaponTypeID4 = 16; return in }(), KindStructure},
		{"the event monster", KindInput{AttackerIsPC: true, TargetCodeName: "MOB_EV_WINTER_SNOWMAN"}, KindEventMob},
		{"a fortress weapon on the event monster is kind 4 -- the weapon test comes first",
			KindInput{AttackerIsPC: true, TargetCodeName: "MOB_EV_WINTER_SNOWMAN", WeaponTypeID4: 16}, KindFortressWeapon},
		{"a transformed attacker is kind 1 even against a structure",
			func() KindInput { in := structure; in.AttackerTransformed = true; return in }(), KindTransformed},
	} {
		if got := SelectDamageKind(c.in); got != c.want {
			t.Errorf("%s: kind %d, want %d", c.name, got, c.want)
		}
	}
}

// The two TID patterns, against the classes real characterdata holds beside
// them. (1,2,4,*) is mostly fortress GUARDS -- only TypeID4 2 is the flags --
// which is exactly why slot 244 tests TypeID4 and slot 248 does not.
func TestFortressPredicatesMatchOnlyTheirOwnClasses(t *testing.T) {
	if !IsFortressFlag(1, 2, 4, 2) {
		t.Error("(1,2,4,2) is STRUCTURE_*_FLAG in real data and must be a flag")
	}
	for _, t4 := range []int{1, 3, 4} {
		if IsFortressFlag(1, 2, 4, t4) {
			t.Errorf("(1,2,4,%d) is COS_GUARD_/MOB_FW_ in real data -- a guard, not a flag", t4)
		}
	}
	for t4 := 1; t4 <= 6; t4++ {
		if !IsFortressStructure(1, 2, 5) {
			t.Errorf("(1,2,5,%d) is STRUCTURE_* in real data and must be a structure", t4)
		}
	}
	if IsFortressStructure(1, 2, 1) || IsFortressStructure(1, 2, 3) {
		t.Error("monsters (1,2,1) and COS (1,2,3) are not structures")
	}
	if IsFortressStructure(0, 0, 0) || IsFortressFlag(0, 0, 0, 0) {
		t.Error("an unknown TypeID must never be taken for a structure")
	}
}

func TestFixedDamagePerHit(t *testing.T) {
	if d, ok := FixedDamagePerHit(KindFortressWeapon, "MOB_CH_MANGNYANG"); !ok || d != 1 {
		t.Errorf("fortress weapon = (%d, %v), want (1, true)", d, ok)
	}
	if d, ok := FixedDamagePerHit(KindEventMob, "MOB_EV_WINTER_SNOWMAN"); !ok || d != 1 {
		t.Errorf("winter snowman = (%d, %v), want (1, true)", d, ok)
	}
	// The kinds that compute their damage, or that OpenSRO does not model,
	// must leave the blow alone rather than invent a constant for it.
	for _, k := range []DamageKind{KindOrdinary, KindTransformed, KindStructure} {
		if _, ok := FixedDamagePerHit(k, "MOB_CH_MANGNYANG"); ok {
			t.Errorf("kind %d claimed a fixed damage", k)
		}
	}
	if FortressWeaponTypeID4 != 16 {
		t.Errorf("FortressWeaponTypeID4 = %d; the engine tests (TID & 0xf800) == 0x8000, which is 16", FortressWeaponTypeID4)
	}
	if 0x8000>>11 != FortressWeaponTypeID4 {
		t.Error("0x8000 >> 11 must equal FortressWeaponTypeID4")
	}
}
