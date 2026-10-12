package gm

import (
	"errors"
	"strings"
	"testing"
)

// Round 786's test tools (OURS): /hurt takes HP and MP off the GM and never
// kills; /afflict hands its run to the Afflict hook.
func TestRound786HurtNeverKills(t *testing.T) {
	f := newFixture(t)
	c, _ := f.chars.GetByID(f.ctx, f.actor.CharacterID)
	res := f.run(t, "/hurt 10 5")
	if res.Refused || !res.RefreshStats {
		t.Fatalf("/hurt: %+v", res)
	}
	after, _ := f.chars.GetByID(f.ctx, f.actor.CharacterID)
	if after.HP != c.HP-10 {
		t.Fatalf("HP %d after /hurt 10, want %d", after.HP, c.HP-10)
	}
	if mp := f.deps.Mana.Current(f.actor.CharacterID, c.MaxMP()); mp != c.MaxMP()-5 {
		t.Fatalf("MP %d after /hurt 10 5, want %d", mp, c.MaxMP()-5)
	}
	f.run(t, "/hurt 999999")
	if after, _ := f.chars.GetByID(f.ctx, f.actor.CharacterID); after.HP != 1 {
		t.Fatalf("HP %d after a huge /hurt, want 1", after.HP)
	}
	if res := f.deps.Run(f.ctx, f.actor, "/hurt x"); !res.Refused {
		t.Fatalf("/hurt x: %+v", res)
	}
}

type fakeAfflict struct {
	code   string
	values []int
}

func (a *fakeAfflict) Afflict(_ int64, code string, values []int) (uint32, error) {
	if code == "zz" {
		return 0, errors.New("no such state")
	}
	a.code, a.values = code, values
	return 0x10, nil
}

func TestRound786Afflict(t *testing.T) {
	f := newFixture(t)
	if res := f.deps.Run(f.ctx, f.actor, "/afflict ps 34 100 16"); !res.Refused {
		t.Fatalf("without a hook: %+v", res)
	}
	a := &fakeAfflict{}
	f.deps.Afflict = a
	res := f.run(t, "/afflict PS 34 100 16")
	if res.Refused || a.code != "ps" || len(a.values) != 3 || a.values[2] != 16 || !strings.Contains(res.Text, "0x10") {
		t.Fatalf("/afflict: %+v, hook saw %q %v", res, a.code, a.values)
	}
	if res := f.deps.Run(f.ctx, f.actor, "/afflict zz 1"); !res.Refused {
		t.Fatalf("a refused state: %+v", res)
	}
}
