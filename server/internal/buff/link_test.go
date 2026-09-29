package buff

import "testing"

// The review of round 636: FUN_0059dc80, gate row 16's check for an 'lnks'
// row with an 'efr' of kind 3 (linkLocked). Rows MEASURED on the RE box's
// skilldata (typed here as test data):
//
//	SKILL_EU_WIZARD_FIREA_TRAP_A_01 id 10283, group 659, lv 1, Activity 2, dura 120000, lnks 14 300 1 1, efr 3, trap
//	SKILL_EU_WIZARD_FIREA_TRAP_A_02 id 10284, group 659, lv 2, the same
//	SKILL_EU_WIZARD_FIREA_TRAP_B_01 id 10297, group 660, lv 1, the same
//	SKILL_QNO_EU_IVY_2_01_01        id 7116,  group 395, lv 1, Activity 1, dura 300000, lnks 0 300 1 0, efr 3, qest, trap
//	SKILL_QNO_EU_GENERAL_1_01_01    id 7112,  group 391, the same
func fireTrap(id, group int64, level int) Spec {
	return Spec{SkillID: id, GroupID: group, Level: level, CasterID: 1, DuraMs: 120000,
		Lnks: true, LnksGroup: 14, LnksMax: 1, Efr3: true, Trap: true, Activity: 2}
}

func questTrap(id, group int64) Spec {
	return Spec{SkillID: id, GroupID: group, Level: 1, CasterID: 1, DuraMs: 300000,
		Lnks: true, LnksMax: 1, Efr3: true, Qest: true, Trap: true, Activity: 1, ActionOverlap: 263518 & 0xffffff}
}

func TestLinkCheckFireTrap(t *testing.T) {
	b := NewBooks(50)
	mustStart(t, b, 1, fireTrap(10283, 659, 1), t0)
	// The same skill: counted, and the count reaches lnks value[2] = 1 --
	// 0x3029 (no 'qest').
	if r := b.CheckOverlap(1, fireTrap(10283, 659, 1)); r != RefusedOverlapCount {
		t.Fatalf("the same trap again: %v, want RefusedOverlapCount", r)
	}
	// Another skill with the same non-zero lnks value[0]: 0x300c at once --
	// a higher level of the same trap and the other letter alike.
	for _, s := range []Spec{fireTrap(10284, 659, 2), fireTrap(10297, 660, 1)} {
		if r := b.CheckOverlap(1, s); r != RefusedOverlap {
			t.Fatalf("skill %d over Fire Trap A lv1: %v, want RefusedOverlap", s.SkillID, r)
		}
		if _, _, r, _ := b.Start(1, s, t0); r != RefusedOverlap {
			t.Fatalf("Start of %d: %v, want RefusedOverlap", s.SkillID, r)
		}
	}
	if n := len(b.Active(1)); n != 1 {
		t.Fatalf("%d records, want the first trap alone", n)
	}
	// Once it has ended, the next goes through.
	if ended := b.Expire(t0.Add(121e9)); len(ended[1]) != 1 {
		t.Fatalf("expiry ended %v", ended)
	}
	mustStart(t, b, 1, fireTrap(10297, 660, 1), t0.Add(122e9))
}

func TestLinkCheckQuestTrap(t *testing.T) {
	b := NewBooks(50)
	mustStart(t, b, 1, questTrap(7116, 395), t0)
	// 'qest' and 'trap' both: 0x3037.
	if r := b.CheckOverlap(1, questTrap(7116, 395)); r != RefusedTrapExists {
		t.Fatalf("the same quest trap again: %v, want RefusedTrapExists", r)
	}
	// Another skill whose lnks value[0] is 0: passed over (0x59ddac).
	if r := b.CheckOverlap(1, questTrap(7112, 391)); r != NotRefused {
		t.Fatalf("another quest trap: %v, want through", r)
	}
	// A fire trap has another lnks value[0]: no record compares.
	if r := b.CheckOverlap(1, fireTrap(10283, 659, 1)); r != NotRefused {
		t.Fatalf("a fire trap beside a quest trap: %v, want through", r)
	}
}

// Only a record with the link struct (an 'lnks' + 'efr' kind-3 row cast by
// its owner) and a non-zero Basic_Activity is compared, and a row without
// 'efr' kind 3 never meets the check (0x58e308). SYNTHETIC variations.
func TestLinkCheckFilters(t *testing.T) {
	b := NewBooks(50)
	noAct := fireTrap(10283, 659, 1)
	noAct.Activity = 0
	mustStart(t, b, 1, noAct, t0)
	if r := b.CheckOverlap(1, fireTrap(10283, 659, 1)); r != NotRefused {
		t.Fatalf("over a record with Activity 0: %v, want through", r)
	}
	b = NewBooks(50)
	mustStart(t, b, 1, fireTrap(10283, 659, 1), t0)
	noEfr3 := fireTrap(10283, 659, 1)
	noEfr3.Efr3 = false
	if r := b.CheckOverlap(1, noEfr3); r != NotRefused {
		t.Fatalf("a row without efr 3: %v, want no check", r)
	}
	// 'lks2' on only one of the two: nothing is counted.
	l2 := fireTrap(10283, 659, 1)
	l2.Lks2 = true
	if r := b.CheckOverlap(1, l2); r != NotRefused {
		t.Fatalf("lks2 on the new row only: %v, want through", r)
	}
	// A cast on another owner's book is not a link record.
	other := fireTrap(10283, 659, 1)
	other.CasterID = 2
	if linked(other, 1) {
		t.Fatal("a record cast by another is linked")
	}
}

// Round 636's review follow-up: the target test's FUN_0059dc80
// (0x58d27d..0x58d2a6), on the CASTER's book with the target as the linked
// object. The rows are the retail Warrior guard rows (MEASURED):
//
//	SKILL_EU_WARRIOR_GUARDA_PHYSICAL_A_01 id 9148, group 544, TR 1, Ally/Party, Activity 2, lnks 1 . 2 (value[0] 1, value[2] 2)
//	SKILL_EU_WARRIOR_GUARDA_PHYSICAL_A_02 id 9149, the same group and lnks, lv 2
//
// the ids and durations SYNTHETIC.
func guard(id int64, level int, caster int64) Spec {
	return Spec{SkillID: id, GroupID: 544, Level: level, CasterID: caster, DuraMs: 60000,
		Lnks: true, TargetRequired: true, LnksGroup: 1, LnksMax: 2, Activity: 2, ActionOverlap: 40}
}

func TestLinkTargetTestGuard(t *testing.T) {
	b := NewBooks(50)
	mustStart(t, b, 10, guard(9148, 1, 2), t0)
	// The same target again: its link names it -- 0x300c.
	if r := b.CheckOverlap(10, guard(9148, 1, 2)); r != RefusedOverlap {
		t.Fatalf("the same target again: %v, want RefusedOverlap", r)
	}
	mustStart(t, b, 11, guard(9148, 1, 2), t0)
	// A third target: two links reach lnks value[2] = 2 -- 0x3029.
	if r := b.CheckOverlap(12, guard(9148, 1, 2)); r != RefusedOverlapCount {
		t.Fatalf("a third target: %v, want RefusedOverlapCount", r)
	}
	if _, _, r, _ := b.Start(12, guard(9148, 1, 2), t0); r != RefusedOverlapCount {
		t.Fatalf("Start on a third target: %v", r)
	}
	// Another skill with the same lnks value[0] (the next level): 0x300c.
	if r := b.CheckOverlap(12, guard(9149, 2, 2)); r != RefusedOverlap {
		t.Fatalf("another level of the guard: %v, want RefusedOverlap", r)
	}
	// Another caster links freely: the links are per caster.
	if r := b.CheckOverlap(12, guard(9148, 1, 3)); r != NotRefused {
		t.Fatalf("another caster: %v", r)
	}
	// The link goes with the target's record: a cancel frees a slot.
	rec := b.Active(10)[0]
	if _, res, _ := b.Cancel(10, rec.SkillID, rec.Token); res != CancelRefusedNbuf && res != Cancelled {
		t.Fatalf("cancel: %v", res)
	}
	if r := b.CheckOverlap(12, guard(9148, 1, 2)); r != NotRefused {
		t.Fatalf("after one link ended: %v, want through", r)
	}
	// The caster's teardown drops its links.
	b.EndAll(2)
	if n := len(b.links[2]); n != 0 {
		t.Fatalf("%d links after the caster's EndAll", n)
	}
	// And the target's EndAll drops the link to it.
	b = NewBooks(50)
	mustStart(t, b, 10, guard(9148, 1, 2), t0)
	b.EndAll(10)
	if n := len(b.links[2]); n != 0 {
		t.Fatalf("%d links after the target's EndAll", n)
	}
}

// SkillAction_Buff's sub-state 0 bit test (CheckEngage, 0x583ffb..0x584044):
// on the caster's book, before the costs. The 'dttp' owner shortcut lets a
// second Fire Detect through the gate; with its 'efr' kind 1 and Activity 2
// it goes down the collector path (charged, no test), and the engage then
// does not start it (RefusedEngage). The same row without 'efr' kind 1
// meets the sub-state 0 test: RefusedSilent. Rows MEASURED
// (SKILL_CH_FIRE_DETECT_A_01 id 21209: dttp 6,3, efr 1, Action_Overlap 47,
// Activity 2); the no-efr-1 variant is SYNTHETIC.
func TestEngageTests(t *testing.T) {
	detect := Spec{SkillID: 21209, GroupID: 818, Level: 1, CasterID: 1, DuraMs: 120000,
		HasDttp: true, Dttp0: 6, Dttp1: 3, Efr1: true, ActionOverlap: 47, Offensive: true, Activity: 2}
	b := NewBooks(50)
	mustStart(t, b, 1, detect, t0)
	if r := b.CheckOverlap(1, detect); r != NotRefused {
		t.Fatalf("the gate: %v, want through (the dttp owner shortcut)", r)
	}
	if r := b.CheckEngage(1, 1, detect); r != NotRefused {
		t.Fatalf("sub-state 0 for the collector row: %v, want no test", r)
	}
	if _, _, r, _ := b.Start(1, detect, t0); r != RefusedEngage {
		t.Fatalf("the engage: %v, want RefusedEngage", r)
	}
	noEfr1 := detect
	noEfr1.Efr1 = false
	if r := b.CheckEngage(1, 1, noEfr1); r != RefusedSilent {
		t.Fatalf("sub-state 0 without efr 1: %v, want RefusedSilent", r)
	}
	// 'ovl2' is tested first, on the caster's book -- also for a cast on
	// another character. SYNTHETIC rows.
	b = NewBooks(50)
	mustStart(t, b, 1, Spec{SkillID: 1, GroupID: 7, Level: 1, CasterID: 1, DuraMs: 60000, ActionOverlap: 41}, t0)
	other := Spec{SkillID: 2, GroupID: 8, Level: 1, CasterID: 1, DuraMs: 60000, TargetRequired: true, Ovl2: 41, ActionOverlap: 50}
	if r := b.CheckEngage(1, 5, other); r != RefusedSilent {
		t.Fatalf("a cast on another with the caster's ovl2 byte set: %v, want RefusedSilent", r)
	}
	if r := b.CheckOverlap(5, other); r != NotRefused {
		t.Fatalf("its gate on the target's empty book: %v", r)
	}
	// A recast of the same group on oneself: the gate ends the old record,
	// so sub-state 0 sees its bits gone.
	b = NewBooks(50)
	gw := Spec{SkillID: 113, GroupID: 260, Level: 1, CasterID: 1, DuraMs: 355462, ActionOverlap: 6}
	mustStart(t, b, 1, gw, t0)
	if r := b.CheckEngage(1, 1, gw); r != NotRefused {
		t.Fatalf("a same-group recast: %v, want through", r)
	}
	// An 'efr' kind-3 row (a trap) is not tested here.
	trap := Spec{SkillID: 3, GroupID: 9, Level: 1, CasterID: 1, Efr3: true, ActionOverlap: 6}
	if r := b.CheckEngage(1, 1, trap); r != NotRefused {
		t.Fatalf("an efr 3 row: %v", r)
	}
}
