package buff

import (
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/skillparam"
)

// The rows below carry the retail values MEASURED on the RE box's skilldata
// (typed here as test data, no archive in the repo) unless marked SYNTHETIC:
//
//	SKILL_CH_LIGHTNING_GYEONGGONG_A_01  id 113,  group 260, lv 1, kind 3, dura 355462, hste 20
//	SKILL_CH_LIGHTNING_GYEONGGONG_A_02  id 1276, group 260, lv 2, kind 3, dura 370588, hste 23
//	SKILL_CH_LIGHTNING_GYEONGGONG_C_01  id 115,  group 262, lv 1, kind 3, dura 557143, hste 55
//	SKILL_EU_ROG_DAGGERA_SPEED_A_01     id 9834, group 628, lv 1, kind 3, dura 15000,  hst2 48
func grassWalkA1(caster int64) Spec {
	return Spec{SkillID: 113, GroupID: 260, Level: 1, CasterID: caster, DuraMs: 355462, HasHste: true, Hste: 20}
}

func grassWalkA2(caster int64) Spec {
	return Spec{SkillID: 1276, GroupID: 260, Level: 2, CasterID: caster, DuraMs: 370588, HasHste: true, Hste: 23}
}

func grassWalkC1(caster int64) Spec {
	return Spec{SkillID: 115, GroupID: 262, Level: 1, CasterID: caster, DuraMs: 557143, HasHste: true, Hste: 55}
}

func daggerSpeedA1(caster int64) Spec {
	return Spec{SkillID: 9834, GroupID: 628, Level: 1, CasterID: caster, DuraMs: 15000, HasHst2: true, Hst2: 48}
}

var t0 = time.Date(2026, 9, 28, 12, 0, 0, 0, time.UTC)

// A buff ends when elapsed is STRICTLY greater than dura -- at BuffEndsAt it
// is still running, one millisecond later it is gone.
func TestBuffExpiresExactlyAtBuffEndsAt(t *testing.T) {
	b := NewBooks(50)
	rec, _, refused, _ := b.Start(1, grassWalkA1(1), t0)
	if refused != NotRefused {
		t.Fatalf("refused %v", refused)
	}
	endsAt := time.UnixMilli(skillparam.BuffEndsAt(t0.UnixMilli(), 355462, 0))
	if !rec.EndsAt().Equal(endsAt) {
		t.Fatalf("EndsAt %v, want %v", rec.EndsAt(), endsAt)
	}
	if got := b.Expire(endsAt); len(got) != 0 {
		t.Fatalf("at BuffEndsAt the buff ended: %+v", got)
	}
	if n := len(b.Active(1)); n != 1 {
		t.Fatalf("%d active at BuffEndsAt, want 1", n)
	}
	got := b.Expire(endsAt.Add(time.Millisecond))
	if len(got[1]) != 1 || got[1][0].Token != rec.Token {
		t.Fatalf("1 ms past BuffEndsAt ended %+v, want token %d", got, rec.Token)
	}
	if n := len(b.Active(1)); n != 0 {
		t.Fatalf("%d active after the end, want 0", n)
	}
}

// Grass Walk A lv1 moves the run speed from 50 to 60: 'hste' 20 in slot 2 is
// a factor of 1 + 20/100. Its end takes the contribution with it, and each
// operation reports the speed it left.
func TestGrassWalkRunSpeedAndContributionsRemovedOnEnd(t *testing.T) {
	b := NewBooks(50)
	if got := b.RunSpeed(1); got != 50 {
		t.Fatalf("base run speed %d, want 50", got)
	}
	rec, _, _, sp := b.Start(1, grassWalkA1(1), t0)
	if got := b.RunSpeed(1); got != 60 || sp != (Speed{RunSpeed: 60, Changed: true}) {
		t.Fatalf("with Grass Walk A lv1 the run speed is %d (reported %+v), want 60", got, sp)
	}
	if !Contributes(rec) {
		t.Fatal("the record carries no run-speed contribution")
	}
	ended, sp := b.ExpireOwner(1, rec.EndsAt().Add(time.Millisecond))
	if len(ended) != 1 || sp != (Speed{RunSpeed: 50, Changed: true}) {
		t.Fatalf("the end reported %d records, %+v", len(ended), sp)
	}
	if got := b.RunSpeed(1); got != 50 {
		t.Fatalf("after the end the run speed is %d, want 50", got)
	}
	if n := len(b.Active(1)); n != 0 {
		t.Fatalf("%d records after the end, want none (and with them their contributions)", n)
	}
}

// The dispel refuses an 'nbuf' buff someone else cast (FUN_0059eff0: 'nbuf'
// and ctx+0x20 != 1), and ends one the owner cast itself. SYNTHETIC rows.
func TestCancelRefusedForNbufFromAnotherCaster(t *testing.T) {
	b := NewBooks(50)
	spec := Spec{SkillID: 500, GroupID: 50, Level: 1, CasterID: 2, DuraMs: 60000, Nbuf: true}
	rec, _, _, _ := b.Start(1, spec, t0)
	if _, res, _ := b.Cancel(1, 500, rec.Token); res != CancelRefusedNbuf {
		t.Fatalf("cancel of another's nbuf buff: %v, want CancelRefusedNbuf", res)
	}
	if n := len(b.Active(1)); n != 1 {
		t.Fatalf("the refused cancel ended it: %d active", n)
	}
	own := spec
	own.SkillID, own.GroupID, own.CasterID = 501, 51, 1
	rec2, _, _, _ := b.Start(1, own, t0)
	if _, res, _ := b.Cancel(1, 501, 0); res != Cancelled {
		t.Fatalf("cancel of the owner's own nbuf buff: %v, want Cancelled", res)
	}
	if _, res, _ := b.Cancel(1, 501, rec2.Token); res != CancelNotFound {
		t.Fatalf("second cancel: %v, want CancelNotFound", res)
	}
	plain := Spec{SkillID: 502, GroupID: 52, Level: 1, CasterID: 2, DuraMs: 60000}
	b.Start(1, plain, t0)
	if _, res, _ := b.Cancel(1, 502, 0); res != Cancelled {
		t.Fatalf("cancel of a plain buff: %v, want Cancelled", res)
	}
}

// The recast rule (FUN_0059d870): the same GroupID at an equal or higher
// level ends the old record and starts the new; a lower level is refused.
func TestRecastRefreshesAndLowerLevelIsRefused(t *testing.T) {
	b := NewBooks(50)
	first, _, _, _ := b.Start(1, grassWalkA1(1), t0)
	second, ended, refused, _ := b.Start(1, grassWalkA1(1), t0.Add(time.Second))
	if refused != NotRefused || len(ended) != 1 || ended[0].Token != first.Token {
		t.Fatalf("recast: refused %v ended %+v, want the first ended", refused, ended)
	}
	if second.Token == first.Token {
		t.Fatal("the recast reused the token")
	}
	if got := b.RunSpeed(1); got != 60 {
		t.Fatalf("after the recast the run speed is %d, want 60 (not 72)", got)
	}
	if _, _, r, _ := b.Start(1, grassWalkA2(1), t0.Add(2*time.Second)); r != NotRefused {
		t.Fatalf("a higher level was refused")
	}
	if b.CheckOverlap(1, grassWalkA1(1)) != RefusedOverlap {
		t.Fatal("CheckOverlap let a lower level through")
	}
	if _, _, r, _ := b.Start(1, grassWalkA1(1), t0.Add(3*time.Second)); r != RefusedOverlap {
		t.Fatalf("a lower level: %v, want RefusedOverlap", r)
	}
	if n := len(b.Active(1)); n != 1 {
		t.Fatalf("%d active, want 1", n)
	}
}

// The gate's conditions around the GroupID branch (0x58e2fd, FUN_0059d870):
// no check at all for a row with 'lnks' or Target_Required 1; none for a new
// row with 'lks2'; an active 'lnks' record the owner cast on itself is
// skipped; GroupID 0 never matches; a 'cbuf' record is skipped. SYNTHETIC
// rows, each a lower level of an active group, which the rule would refuse.
func TestRecastRuleConditions(t *testing.T) {
	high := Spec{SkillID: 700, GroupID: 70, Level: 5, CasterID: 1, DuraMs: 60000}
	low := Spec{SkillID: 701, GroupID: 70, Level: 1, CasterID: 1, DuraMs: 60000}
	for _, c := range []struct {
		name       string
		active     func(Spec) Spec
		cast       func(Spec) Spec
		wantRefuse bool
	}{
		{"the plain rule refuses", func(s Spec) Spec { return s }, func(s Spec) Spec { return s }, true},
		{"a Target_Required 1 row is not checked", func(s Spec) Spec { return s }, func(s Spec) Spec { s.TargetRequired = true; return s }, false},
		{"an 'lnks' row is not checked", func(s Spec) Spec { return s }, func(s Spec) Spec { s.Lnks = true; return s }, false},
		{"an 'lks2' row skips the GroupID branch", func(s Spec) Spec { return s }, func(s Spec) Spec { s.Lks2 = true; return s }, false},
		{"a self-cast 'lnks' record is skipped", func(s Spec) Spec { s.Lnks = true; return s }, func(s Spec) Spec { return s }, false},
		{"another caster's 'lnks' record is not", func(s Spec) Spec { s.Lnks = true; s.CasterID = 2; return s }, func(s Spec) Spec { return s }, true},
		{"GroupID 0 never matches", func(s Spec) Spec { s.GroupID = 0; return s }, func(s Spec) Spec { s.GroupID = 0; return s }, false},
		{"a 'cbuf' record is skipped", func(s Spec) Spec { s.Cbuf = true; return s }, func(s Spec) Spec { return s }, false},
	} {
		b := NewBooks(50)
		b.Start(1, c.active(high), t0)
		_, ended, r, _ := b.Start(1, c.cast(low), t0)
		if (r == RefusedOverlap) != c.wantRefuse || len(ended) != 0 {
			t.Errorf("%s: refused %v, ended %d; want refused %v and nothing ended", c.name, r, len(ended), c.wantRefuse)
		}
	}
	// Unchecked, a Target_Required 1 recast stacks: both records stay.
	b := NewBooks(50)
	tr := high
	tr.TargetRequired = true
	b.Start(1, tr, t0)
	b.Start(1, tr, t0)
	if n := len(b.Active(1)); n != 2 {
		t.Fatalf("a Target_Required 1 recast left %d records, want 2", n)
	}
}

// The speed holder (pc+0xc24): a second 'hste' record of another group
// writes nothing while the first holds it.
func TestSecondHsteBuffDoesNotStack(t *testing.T) {
	b := NewBooks(50)
	b.Start(1, grassWalkA1(1), t0)
	rec, _, _, sp := b.Start(1, grassWalkC1(1), t0)
	if Contributes(rec) || sp.Changed {
		t.Fatalf("the second hste record wrote a contribution (%+v)", sp)
	}
	if got := b.RunSpeed(1); got != 60 {
		t.Fatalf("run speed %d, want 60", got)
	}
}

// 'hst2' (0x594ac0): it removes the holder's speed writes, writes its own,
// and holds only when none held; at its end (0x5829d0) a holder that is not
// it gets its 'hste' written back. Grass Walk A lv1 (hste 20) then the EU
// dagger speed A lv1 (hst2 48).
func TestHst2OverridesTheHolderAndRestoresItAtItsEnd(t *testing.T) {
	b := NewBooks(50)
	grass, _, _, _ := b.Start(1, grassWalkA1(1), t0)
	dagger, _, _, sp := b.Start(1, daggerSpeedA1(1), t0)
	if sp != (Speed{RunSpeed: 74, Changed: true}) {
		t.Fatalf("with the dagger speed over Grass Walk: %+v, want 74 (50 x 1.48, Grass Walk's 20 removed)", sp)
	}
	ended, sp := b.ExpireOwner(1, dagger.EndsAt().Add(time.Millisecond))
	if len(ended) != 1 || sp != (Speed{RunSpeed: 60, Changed: true}) {
		t.Fatalf("the dagger speed's end: %d ended, %+v; want Grass Walk's 60 back", len(ended), sp)
	}
	if !Contributes(b.Active(1)[0]) || b.Active(1)[0].Token != grass.Token {
		t.Fatal("Grass Walk's contribution was not written back")
	}

	// Alone, the dagger speed holds, and its end empties the holder: a later
	// Grass Walk writes.
	b = NewBooks(50)
	d, _, _, sp := b.Start(1, daggerSpeedA1(1), t0)
	if sp.RunSpeed != 74 {
		t.Fatalf("the dagger speed alone: %+v", sp)
	}
	b.ExpireOwner(1, d.EndsAt().Add(time.Millisecond))
	if _, _, _, sp := b.Start(1, grassWalkA1(1), t0.Add(time.Minute)); sp.RunSpeed != 60 {
		t.Fatalf("Grass Walk after the dagger speed: %+v, want 60 (the holder was emptied)", sp)
	}
}

func TestTokensAreUniqueAndNeverZero(t *testing.T) {
	b := NewBooks(50)
	b.next.Store(^uint32(0) - 1)
	seen := map[uint32]bool{}
	for i := 0; i < 4; i++ {
		tok := b.NextToken()
		if tok == 0 || seen[tok] {
			t.Fatalf("token %d (seen %v)", tok, seen)
		}
		seen[tok] = true
	}
}

func TestEndAllEndsEverything(t *testing.T) {
	b := NewBooks(50)
	b.Start(1, grassWalkA1(1), t0)
	got, sp := b.EndAll(1)
	if len(got) != 1 || sp != (Speed{RunSpeed: 50, Changed: true}) {
		t.Fatalf("EndAll returned %d, %+v", len(got), sp)
	}
	if got := b.RunSpeed(1); got != 50 {
		t.Fatalf("after EndAll run speed %d", got)
	}
}
