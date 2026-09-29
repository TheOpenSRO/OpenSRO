package buff

import (
	"testing"
	"time"
)

// Round 636: the rest of FUN_0059d870 -- the book's state bit set
// (SkillBook::SetGroupBits 0x59dc00 / FUN_0059db10), the 'dttp' and 'efr'
// kind-2 branches -- and the category end FUN_005a16c0. Rows are the retail
// values MEASURED on the RE box's skilldata (typed here as test data, no
// archive in the repo) unless marked SYNTHETIC:
//
//	SKILL_CH_FIRE_GANGGI_A_01  id 133,  group 280, lv 1, cbuf, Action_Overlap 3, Activity 2
//	SKILL_CH_FIRE_GANGGI_A_02  id 1415, group 280, lv 2, cbuf, Action_Overlap 3
//	SKILL_CH_FIRE_GANGGI_B_01  id 134,  group 281, lv 1, cbuf, Action_Overlap 3
//	SKILL_CH_COLD_GANGGI_A_01  id 93,   group 240, lv 1, cbuf, Action_Overlap 2
//	SKILL_CH_LIGHTNING_GYEONGGONG_E_01 id 8148, group 493, lv 1, hste 93, Action_Overlap 6
//	SKILL_CH_LIGHTNING_GYEONGGONG_C_02 id 1298, group 262, lv 2, hste 57, Action_Overlap 6
//	SKILL_EU_BARD_DANCEA_CASTER_A_01 id 11499, group 756, efr 2, ovl2 57, Action_Overlap 35 (0x23), Activity 2
//	SKILL_EU_BARD_DANCEA_ROG_A_01    id 11518, group 760, efr 2, ovl2 64, Action_Overlap 35 (0x23), Activity 2
//	SKILL_EU_ROG_STEALTHA_HIDING_A_01 id 9374, group 588, hide, skc value[1] 10, Action_Overlap 48, Activity 2
//	SKILL_CH_FIRE_DESCRY_A_01  id 8312, group 513, dttp 5,3, Action_Overlap 46, offensive (dttp)
//
// Fire Protection's 'dura' is -1875767296 as a signed word, so it loads as a
// buff with no duration.

func fireProtA1(c int64) Spec {
	return Spec{SkillID: 133, GroupID: 280, Level: 1, CasterID: c, Cbuf: true, ActionOverlap: 3, BasicGroup: "SKILL_CH_FIRE_GANGGI_A", Activity: 2}
}
func fireProtA2(c int64) Spec {
	s := fireProtA1(c)
	s.SkillID, s.Level = 1415, 2
	return s
}
func fireProtB1(c int64) Spec {
	return Spec{SkillID: 134, GroupID: 281, Level: 1, CasterID: c, Cbuf: true, ActionOverlap: 3, BasicGroup: "SKILL_CH_FIRE_GANGGI_B", Activity: 2}
}
func coldProtA1(c int64) Spec {
	return Spec{SkillID: 93, GroupID: 240, Level: 1, CasterID: c, Cbuf: true, ActionOverlap: 2, BasicGroup: "SKILL_CH_COLD_GANGGI_A", Activity: 2}
}
func grassWalkE1(c int64) Spec {
	return Spec{SkillID: 8148, GroupID: 493, Level: 1, CasterID: c, DuraMs: 829412, HasHste: true, Hste: 93,
		ActionOverlap: 6, BasicGroup: "SKILL_CH_LIGHTNING_GYEONGGONG_E", Activity: 1}
}
func grassWalkC2(c int64) Spec {
	return Spec{SkillID: 1298, GroupID: 262, Level: 2, CasterID: c, DuraMs: 572269, HasHste: true, Hste: 57,
		ActionOverlap: 6, BasicGroup: "SKILL_CH_LIGHTNING_GYEONGGONG_C", Activity: 1}
}
func danceCaster(c int64) Spec {
	return Spec{SkillID: 11499, GroupID: 756, Level: 1, CasterID: c, Efr2: true, Ovl2: 57, ActionOverlap: 35,
		BasicGroup: "SKILL_EU_BARD_DANCEA_CASTER_A", Activity: 2}
}
func danceRog(c int64) Spec {
	return Spec{SkillID: 11518, GroupID: 760, Level: 1, CasterID: c, Efr2: true, Ovl2: 64, ActionOverlap: 35,
		BasicGroup: "SKILL_EU_BARD_DANCEA_ROG_A", Activity: 2}
}

func mustStart(t *testing.T, b *Books, owner int64, s Spec, at time.Time) Record {
	t.Helper()
	rec, _, r, _ := b.Start(owner, s, at)
	if r != NotRefused {
		t.Fatalf("starting skill %d: refused", s.SkillID)
	}
	return rec
}

// The user's first report: Fire Protection cast twice stacked. Its records
// carry 'cbuf', so FUN_0059d870's list passes them over, and the bit test
// refuses the second: byte 3 is set by the first. A higher level and another
// Fire Protection are refused the same way; Cold Protection (byte 2) is not.
// Once the first is cancelled, the bit is clear and the cast goes through.
func TestFireProtectionDoesNotStack(t *testing.T) {
	b := NewBooks(50)
	first := mustStart(t, b, 1, fireProtA1(1), t0)
	for _, s := range []Spec{fireProtA1(1), fireProtA2(1), fireProtB1(1)} {
		if b.CheckOverlap(1, s) != RefusedOverlap {
			t.Errorf("skill %d lv %d with Fire Protection up: not refused at the gate", s.SkillID, s.Level)
		}
		if _, ended, r, _ := b.Start(1, s, t0); r != RefusedOverlap || len(ended) != 0 {
			t.Errorf("skill %d lv %d with Fire Protection up: refused %v, ended %d", s.SkillID, s.Level, r, len(ended))
		}
	}
	if n := len(b.Active(1)); n != 1 {
		t.Fatalf("%d Fire Protection records, want 1", n)
	}
	mustStart(t, b, 1, coldProtA1(1), t0)
	if _, res, _ := b.Cancel(1, first.SkillID, first.Token); res != Cancelled {
		t.Fatalf("cancel: %v", res)
	}
	mustStart(t, b, 1, fireProtA2(1), t0.Add(time.Second))
}

// The user's second report: three Grass Walks at once. A (group 260), C
// (262) and E (493) are different groups, so the GroupID branch never meets
// them; all three carry byte 6, so the bit test refuses whichever comes
// second -- the old one keeps running (retail: 0x300c, no cancel).
func TestGrassWalkVariantsAreRefusedNotStacked(t *testing.T) {
	for _, c := range []struct {
		name        string
		first, next Spec
	}{
		{"A then C", grassWalkA1(1), grassWalkC1(1)},
		{"C then E", grassWalkC1(1), grassWalkE1(1)},
		{"E then A", grassWalkE1(1), grassWalkA1(1)},
		{"A lv2 then C lv1 (a lower level of another variant)", grassWalkA2(1), grassWalkC1(1)},
		{"A lv1 then C lv2 (a higher level of another variant)", grassWalkA1(1), grassWalkC2(1)},
	} {
		b := NewBooks(50)
		first := mustStart(t, b, 1, c.first, t0)
		speed := b.RunSpeed(1)
		if b.CheckOverlap(1, c.next) != RefusedOverlap {
			t.Errorf("%s: the gate let the second through", c.name)
		}
		_, ended, r, _ := b.Start(1, c.next, t0.Add(time.Second))
		if r != RefusedOverlap || len(ended) != 0 {
			t.Errorf("%s: refused %v, ended %d; want refused and nothing ended", c.name, r, len(ended))
		}
		act := b.Active(1)
		if len(act) != 1 || act[0].Token != first.Token || b.RunSpeed(1) != speed {
			t.Errorf("%s: %d active, speed %d; want the first alone at %d", c.name, len(act), b.RunSpeed(1), speed)
		}
		// Its end frees the byte: the next variant then starts.
		b.ExpireOwner(1, first.EndsAt().Add(time.Millisecond))
		if _, _, r, _ := b.Start(1, c.next, first.EndsAt().Add(2*time.Millisecond)); r != NotRefused {
			t.Errorf("%s: after the first ended the second was refused", c.name)
		}
	}
}

// The same variant again: the GroupID branch ends the old record and the
// engage sets the byte again (a lower level is refused, an equal or higher
// one replaces), so the bit set follows the one live record.
func TestGrassWalkSameGroupReplacesAndKeepsTheByte(t *testing.T) {
	b := NewBooks(50)
	a1 := mustStart(t, b, 1, grassWalkA1(1), t0)
	a2, ended, r, sp := b.Start(1, grassWalkA2(1), t0.Add(time.Second))
	if r != NotRefused || len(ended) != 1 || ended[0].Token != a1.Token {
		t.Fatalf("A lv2 over A lv1: refused %v, ended %+v", r, ended)
	}
	if sp.RunSpeed != 62 { // 50 x 1.23 = 61.5, rounded
		t.Fatalf("A lv2's run speed %d, want 62", sp.RunSpeed)
	}
	if _, _, r, _ := b.Start(1, grassWalkA1(1), t0.Add(2*time.Second)); r != RefusedOverlap {
		t.Fatalf("A lv1 under A lv2: %v, want refused", r)
	}
	if _, _, r, _ := b.Start(1, grassWalkC1(1), t0.Add(3*time.Second)); r != RefusedOverlap {
		t.Fatal("after the replacement byte 6 was lost: C started")
	}
	if _, res, _ := b.Cancel(1, a2.SkillID, 0); res != Cancelled {
		t.Fatal("cancel")
	}
	mustStart(t, b, 1, grassWalkC1(1), t0.Add(4*time.Second))
}

// SetGroupBits / FUN_0059db10 on their own: three low bytes only, 0 never,
// 0x1d and 0x23 set but never tested, and a clear is not counted.
func TestGroupBits(t *testing.T) {
	var bk book
	bk.setGroupBits(0x3b000006, false) // the high byte is the cooldown group
	if !bk.bitsHit(6) || bk.bitsHit(0x3b) {
		t.Fatalf("bits %x", bk.bits)
	}
	bk.setGroupBits(0x231d00, false)
	if bk.bitsHit(0x1d) || bk.bitsHit(0x23) || bk.bitsHit(0x1d23) {
		t.Fatal("0x1d / 0x23 were tested")
	}
	bk.setGroupBits(0xc8, false) // 200, the fourth word
	if !bk.bitsHit(0xc800) {
		t.Fatal("byte 200 in the second position not found")
	}
	bk.setGroupBits(6, true)
	if bk.bitsHit(6) {
		t.Fatal("cleared bit still set")
	}
}

// 'ovl2': the bit test refuses a row whose 'ovl2' byte is set, and a record
// sets and clears it. SYNTHETIC rows.
func TestOvl2(t *testing.T) {
	b := NewBooks(50)
	a := Spec{SkillID: 1, GroupID: 10, Level: 1, CasterID: 1, DuraMs: 60000, ActionOverlap: 40, Ovl2: 41}
	rec := mustStart(t, b, 1, a, t0)
	other := Spec{SkillID: 2, GroupID: 20, Level: 1, CasterID: 1, DuraMs: 60000, ActionOverlap: 50, Ovl2: 41}
	if _, _, r, _ := b.Start(1, other, t0); r != RefusedOverlap {
		t.Fatal("ovl2 41 met the active 41: not refused")
	}
	byOverlap := Spec{SkillID: 3, GroupID: 30, Level: 1, CasterID: 1, DuraMs: 60000, ActionOverlap: 41}
	if _, _, r, _ := b.Start(1, byOverlap, t0); r != RefusedOverlap {
		t.Fatal("Action_Overlap 41 met the active ovl2 41: not refused")
	}
	b.Cancel(1, 1, rec.Token)
	mustStart(t, b, 1, other, t0)
}

// The 'dttp' branch (0x59d915..0x59da83): the book's owner casting may
// always stack; another caster is compared by value[1], passing over a
// record its owner cast on itself. SYNTHETIC values on the FIRE_DESCRY shape.
func TestDttpBranch(t *testing.T) {
	descry := func(caster int64, lv uint32) Spec {
		return Spec{SkillID: 8312, GroupID: 513, Level: 1, CasterID: caster, DuraMs: 120000,
			HasDttp: true, Dttp0: 5, Dttp1: lv, ActionOverlap: 46, Offensive: true, TargetRequired: true}
	}
	b := NewBooks(50)
	mustStart(t, b, 1, descry(2, 3), t0)
	if _, _, r, _ := b.Start(1, descry(3, 2), t0); r != RefusedOverlap {
		t.Fatal("a lower dttp value[1] from another caster: not refused")
	}
	_, ended, r, _ := b.Start(1, descry(3, 3), t0)
	if r != NotRefused || len(ended) != 1 {
		t.Fatalf("an equal dttp value[1]: refused %v ended %d, want the old ended", r, len(ended))
	}
	// The owner casting stacks at once, whatever the bits say.
	if _, ended, r, _ := b.Start(1, descry(1, 1), t0); r != NotRefused || len(ended) != 0 {
		t.Fatalf("the owner's own dttp cast: refused %v ended %d", r, len(ended))
	}
}

// The 'efr' kind-2 branch: the caster's own record of the same Basic_Group
// ends on a recast of an equal or higher level; the GroupID branch is never
// tried for such a row. A dance of another group meets the bits of 'ovl2'
// only -- 0x23 is never tested.
func TestEfr2Branch(t *testing.T) {
	b := NewBooks(50)
	first := mustStart(t, b, 1, danceCaster(1), t0)
	_, ended, r, _ := b.Start(1, danceCaster(1), t0)
	if r != NotRefused || len(ended) != 1 || ended[0].Token != first.Token {
		t.Fatalf("recast of the dance: refused %v ended %+v", r, ended)
	}
	// A lower level passes over the record (this branch refuses nothing)
	// and meets the bit test: 'ovl2' 57 is set, so it is refused.
	lower := danceCaster(1)
	lower.Level = 0
	if _, ended, r, _ := b.Start(1, lower, t0); r != RefusedOverlap || len(ended) != 0 {
		t.Fatalf("a lower level: refused %v ended %d, want refused", r, len(ended))
	}
	// Another dance: its ovl2 64 is free and 0x23 is not tested, so it
	// starts beside the first -- until the skill use's category end (below)
	// takes the first away.
	mustStart(t, b, 1, danceRog(1), t0)
	if n := len(b.Active(1)); n != 2 {
		t.Fatalf("%d dances, want 2 (the category end is a separate step)", n)
	}
}

// FUN_005a16c0 with mask 2 at a skill use (FUN_0059b480): the caster's own
// records with a non-zero Activity whose 'skc' value[1] has bit 2, or whose
// Action_Overlap byte pairs with the new row's 0x1d/0x23 (FUN_005a1840).
func TestCategoryEndOnSkillUse(t *testing.T) {
	b := NewBooks(50)
	hiding := Spec{SkillID: 9374, GroupID: 588, Level: 1, CasterID: 1, DuraMs: 60000, ActionOverlap: 48, SkcEnd: 10, Activity: 2}
	mustStart(t, b, 1, hiding, t0)
	mustStart(t, b, 1, danceCaster(1), t0)
	mustStart(t, b, 1, grassWalkA1(1), t0)
	// A Grass Walk cast (byte 6): the stealth ends (skc 10 has bit 2); the
	// dance does not (6 pairs with nothing).
	ended, _ := b.EndCategory(1, CategorySkillUse, 6, true)
	if len(ended) != 1 || ended[0].SkillID != 9374 {
		t.Fatalf("a skill use ended %+v, want the stealth", ended)
	}
	// Another dance (0x23): the first dance (0x23) ends.
	ended, _ = b.EndCategory(1, CategorySkillUse, 35, true)
	if len(ended) != 1 || ended[0].SkillID != 11499 {
		t.Fatalf("a dance's use ended %+v, want the first dance", ended)
	}
	// The move and berserk callers pass no row and masks no retail row's
	// 'skc' carries: nothing ends.
	if ended, _ := b.EndCategory(1, CategoryMove, 0, false); len(ended) != 0 {
		t.Fatal("a move ended a buff")
	}
	// Another caster's record never ends here (ctx+0x20 must be 1).
	b2 := NewBooks(50)
	h := hiding
	h.CasterID = 2
	mustStart(t, b2, 1, h, t0)
	if ended, _ := b2.EndCategory(1, CategorySkillUse, 6, true); len(ended) != 0 {
		t.Fatal("another caster's record ended")
	}
}

// 'msch' value[0] == 1 skips the list and meets the bit test alone.
func TestMsch1SkipsTheList(t *testing.T) {
	b := NewBooks(50)
	high := Spec{SkillID: 1, GroupID: 7, Level: 5, CasterID: 1, DuraMs: 60000}
	mustStart(t, b, 1, high, t0)
	low := Spec{SkillID: 2, GroupID: 7, Level: 1, CasterID: 1, DuraMs: 60000, Msch1: true}
	if _, ended, r, _ := b.Start(1, low, t0); r != NotRefused || len(ended) != 0 {
		t.Fatalf("an msch 1 row: refused %v ended %d, want through with nothing ended", r, len(ended))
	}
}

// An 'lnks' record its owner cast on itself sets no Action_Overlap bits and
// clears none (engageBits / endBits). SYNTHETIC.
func TestLnksSelfCastSetsNoBits(t *testing.T) {
	b := NewBooks(50)
	l := Spec{SkillID: 1, GroupID: 7, Level: 1, CasterID: 1, DuraMs: 60000, Lnks: true, ActionOverlap: 40}
	mustStart(t, b, 1, l, t0)
	plain := Spec{SkillID: 2, GroupID: 8, Level: 1, CasterID: 1, DuraMs: 60000, ActionOverlap: 40}
	mustStart(t, b, 1, plain, t0)
}

// /speed (OURS): a multiplier on top of the buffs, kept past EndAll, and
// cleared by 1.
func TestGMSpeedFactor(t *testing.T) {
	b := NewBooks(50)
	if sp := b.SetGMSpeedFactor(1, 3); sp.RunSpeed != 150 || !sp.Changed {
		t.Fatalf("x3: %+v", sp)
	}
	if _, _, _, sp := b.Start(1, grassWalkA1(1), t0); sp.RunSpeed != 180 {
		t.Fatalf("x3 with Grass Walk: %+v, want 180", sp)
	}
	b.EndAll(1)
	if got := b.RunSpeed(1); got != 150 {
		t.Fatalf("after EndAll %d, want 150", got)
	}
	if sp := b.SetGMSpeedFactor(1, 99); sp.RunSpeed != 500 {
		t.Fatalf("capped at x10: %+v", sp)
	}
	if sp := b.SetGMSpeedFactor(1, 1); sp.RunSpeed != 50 {
		t.Fatalf("off: %+v", sp)
	}
	if _, ok := b.GMSpeedFactor(1); ok {
		t.Fatal("still set")
	}
}
