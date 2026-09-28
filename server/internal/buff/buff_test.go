package buff

import (
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/skillparam"
)

// grassWalkA1 is SKILL_CH_LIGHTNING_GYEONGGONG_A_01's shape (id 113, group
// 260, level 1): action kind 3, 'dura' 355462, 'hste' 20 -- the values the
// spec MEASURED on the retail row, typed here as synthetic test data.
func grassWalkA1(caster int64) Spec {
	return Spec{SkillID: 113, GroupID: 260, Level: 1, CasterID: caster, DuraMs: 355462, HasHste: true, Hste: 20}
}

var t0 = time.Date(2026, 9, 28, 12, 0, 0, 0, time.UTC)

// A buff ends when elapsed is STRICTLY greater than dura -- at BuffEndsAt it
// is still running, one millisecond later it is gone.
func TestBuffExpiresExactlyAtBuffEndsAt(t *testing.T) {
	b := NewBooks()
	rec, _, refused := b.Start(1, grassWalkA1(1), t0)
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
// a factor of 1 + 20/100. Its end takes the contribution with it.
func TestGrassWalkRunSpeedAndContributionsRemovedOnEnd(t *testing.T) {
	b := NewBooks()
	if got := b.RunSpeed(1, 50); got != 50 {
		t.Fatalf("base run speed %d, want 50", got)
	}
	rec, _, _ := b.Start(1, grassWalkA1(1), t0)
	if got := b.RunSpeed(1, 50); got != 60 {
		t.Fatalf("with Grass Walk A lv1 the run speed is %d, want 60", got)
	}
	if !Contributes(rec) {
		t.Fatal("the record carries no run-speed contribution")
	}
	b.Expire(rec.EndsAt().Add(time.Millisecond))
	if got := b.RunSpeed(1, 50); got != 50 {
		t.Fatalf("after the end the run speed is %d, want 50", got)
	}
	if f := b.Factor(1, ParamWalkSpeed); f != 1 {
		t.Fatalf("after the end the walk factor is %v, want 1", f)
	}
}

// The dispel refuses an 'nbuf' buff someone else cast (FUN_0059eff0: 'nbuf'
// and ctx+0x20 != 1), and ends one the owner cast itself.
func TestCancelRefusedForNbufFromAnotherCaster(t *testing.T) {
	b := NewBooks()
	spec := Spec{SkillID: 500, GroupID: 50, Level: 1, CasterID: 2, DuraMs: 60000, Nbuf: true}
	rec, _, _ := b.Start(1, spec, t0)
	if _, res := b.Cancel(1, 500, rec.Token); res != CancelRefusedNbuf {
		t.Fatalf("cancel of another's nbuf buff: %v, want CancelRefusedNbuf", res)
	}
	if n := len(b.Active(1)); n != 1 {
		t.Fatalf("the refused cancel ended it: %d active", n)
	}
	own := spec
	own.SkillID, own.GroupID, own.CasterID = 501, 51, 1
	rec2, _, _ := b.Start(1, own, t0)
	if _, res := b.Cancel(1, 501, 0); res != Cancelled {
		t.Fatalf("cancel of the owner's own nbuf buff: %v, want Cancelled", res)
	}
	if _, res := b.Cancel(1, 501, rec2.Token); res != CancelNotFound {
		t.Fatalf("second cancel: %v, want CancelNotFound", res)
	}
	// Without 'nbuf', another caster's buff is cancellable.
	plain := Spec{SkillID: 502, GroupID: 52, Level: 1, CasterID: 2, DuraMs: 60000}
	b.Start(1, plain, t0)
	if _, res := b.Cancel(1, 502, 0); res != Cancelled {
		t.Fatalf("cancel of a plain buff: %v, want Cancelled", res)
	}
}

// The recast rule (FUN_0059d870): the same GroupID at an equal or higher
// level ends the old record and starts the new; a lower level is refused.
func TestRecastRefreshesAndLowerLevelIsRefused(t *testing.T) {
	b := NewBooks()
	first, _, _ := b.Start(1, grassWalkA1(1), t0)
	second, ended, refused := b.Start(1, grassWalkA1(1), t0.Add(time.Second))
	if refused != NotRefused || len(ended) != 1 || ended[0].Token != first.Token {
		t.Fatalf("recast: refused %v ended %+v, want the first ended", refused, ended)
	}
	if second.Token == first.Token {
		t.Fatal("the recast reused the token")
	}
	if got := b.RunSpeed(1, 50); got != 60 {
		t.Fatalf("after the recast the run speed is %d, want 60 (not 72)", got)
	}
	lv2 := grassWalkA1(1)
	lv2.SkillID, lv2.Level, lv2.Hste = 1130, 2, 23
	if _, _, r := b.Start(1, lv2, t0.Add(2*time.Second)); r != NotRefused {
		t.Fatalf("a higher level was refused")
	}
	if b.CheckOverlap(1, grassWalkA1(1)) != RefusedOverlap {
		t.Fatal("CheckOverlap let a lower level through")
	}
	if _, _, r := b.Start(1, grassWalkA1(1), t0.Add(3*time.Second)); r != RefusedOverlap {
		t.Fatalf("a lower level: %v, want RefusedOverlap", r)
	}
	if n := len(b.Active(1)); n != 1 {
		t.Fatalf("%d active, want 1", n)
	}
}

// The speed holder (pc+0xc24): a second 'hste' record of another group
// writes nothing while the first holds it.
func TestSecondHsteBuffDoesNotStack(t *testing.T) {
	b := NewBooks()
	b.Start(1, grassWalkA1(1), t0)
	other := Spec{SkillID: 130, GroupID: 262, Level: 1, CasterID: 1, DuraMs: 557143, HasHste: true, Hste: 55}
	rec, _, _ := b.Start(1, other, t0)
	if Contributes(rec) {
		t.Fatal("the second hste record wrote a contribution")
	}
	if got := b.RunSpeed(1, 50); got != 60 {
		t.Fatalf("run speed %d, want 60", got)
	}
}

func TestTokensAreUniqueAndNeverZero(t *testing.T) {
	b := NewBooks()
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
	b := NewBooks()
	b.Start(1, grassWalkA1(1), t0)
	if got := b.EndAll(1); len(got) != 1 {
		t.Fatalf("EndAll returned %d", len(got))
	}
	if got := b.RunSpeed(1, 50); got != 50 {
		t.Fatalf("after EndAll run speed %d", got)
	}
}
