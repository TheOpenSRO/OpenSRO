package session

import (
	"context"
	"strings"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/leveldata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// shareRig is a world with level-50 characters, a level table whose level-50
// EXP unit is 1000, and a party hub.
type shareRig struct {
	ctx     context.Context
	chars   *character.MemStore
	hub     *world.Hub
	parties *party.Hub
	ids     []int64
	sess    map[int64]*gateway.Session
}

func newShareRig(t *testing.T, xs ...float64) *shareRig {
	t.Helper()
	tbl, err := leveldata.ParseCSV(strings.NewReader("level,exp,mastery_sp,exp_unit\n50,100000000,1,1000\n51,100000000,1,1100\n"))
	if err != nil {
		t.Fatal(err)
	}
	prev := levelTable
	SetLevelTable(tbl)
	t.Cleanup(func() { SetLevelTable(prev) })
	r := &shareRig{ctx: context.Background(), chars: character.NewMemStore(), hub: world.NewHub(),
		parties: party.NewHub(), sess: map[int64]*gateway.Session{}}
	for i, x := range xs {
		c, err := r.chars.Create(r.ctx, int64(100+i), "share"+string(rune('a'+i)))
		if err != nil {
			t.Fatal(err)
		}
		if err := r.chars.SetLeveling(r.ctx, c.ID, 50, 0, 0, c.Str, c.Int); err != nil {
			t.Fatal(err)
		}
		s := gateway.NewTestSession(uint64(77000 + i))
		r.hub.Enter(s, c.ID, c.Name, 50, "jangan", world.Position{X: x})
		r.ids = append(r.ids, c.ID)
		r.sess[c.ID] = s
	}
	return r
}

func (r *shareRig) member(id int64) party.Member {
	return party.Member{Session: r.sess[id], CharacterID: id, Name: "m", Level: 50}
}

func (r *shareRig) deps() combatDeps {
	return combatDeps{chars: r.chars, hub: r.hub, parties: r.parties}
}

func (r *shareRig) exp(t *testing.T, id int64) int64 {
	t.Helper()
	c, err := r.chars.GetByID(r.ctx, id)
	if err != nil {
		t.Fatal(err)
	}
	return c.Exp
}

// A level-50 kill of a level-50 monster with 100 HP: base 1000, share 1,
// window 1, Diff 1.09 -> 1090 EXP and 109 SP before the multiplier.
var shareMonster = combat.Monster{ID: 1, Zone: "jangan", Level: 50, MaxHP: 100}

// An exp-share party of two, one member dealing all the damage: both get
// 0.5 x 1.1 = 0.55 of the kill -- trunc(1090 x 0.55) = 599 EXP, trunc(109 x
// 0.55) = 59 SP -- and the arming count is 2.
func TestKillShareExpSharePartyOfTwo(t *testing.T) {
	r := newShareRig(t, 0, 500)
	a, b := r.ids[0], r.ids[1]
	if _, err := r.parties.Form(r.member(a), r.member(b), party.FlagExpShare); err != nil {
		t.Fatal(err)
	}
	hits := []combat.Hit{{AttackerID: a, Damage: 100}}
	plan := planKill(r.hub, r.parties, shareMonster, hits, nil)
	if plan.credit != a || plan.armCount != 2 || len(plan.awards) != 2 {
		t.Fatalf("plan %+v, want credit %d, 2 awards, count 2", plan, a)
	}
	paid, err := payKill(r.ctx, r.deps(), shareMonster, plan)
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []int64{a, b} {
		if p := paid[id]; p.exp != 599 || p.sp != 59 {
			t.Errorf("member %d paid %d EXP %d SP, want 599 and 59", id, p.exp, p.sp)
		}
		if got := r.exp(t, id); got != 599 {
			t.Errorf("member %d's row holds %d EXP, want 599", id, got)
		}
	}
}

// Out of range, dead or in another zone: no share. A member 1001 from the kill
// credit is out; exactly 1000 is in.
func TestKillShareEligibility(t *testing.T) {
	r := newShareRig(t, 0, 1000, 1001)
	a, b, c := r.ids[0], r.ids[1], r.ids[2]
	p, err := r.parties.Form(r.member(a), r.member(b), party.FlagExpShare)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := r.parties.Add(p.ID, r.member(c)); err != nil {
		t.Fatal(err)
	}
	plan := planKill(r.hub, r.parties, shareMonster, []combat.Hit{{AttackerID: a, Damage: 100}}, nil)
	if plan.armCount != 2 {
		t.Fatalf("eligible %d, want 2 (1000 in, 1001 out)", plan.armCount)
	}
	for _, aw := range plan.awards {
		if aw.characterID == c {
			t.Fatalf("the member 1001 away was paid")
		}
	}
}

// The kill credit can sit outside a sharing party: a solo player out-damages
// the party, and the party's radius is measured from him.
func TestKillShareCreditOutsideTheParty(t *testing.T) {
	r := newShareRig(t, 0, 10, 5000)
	a, b, solo := r.ids[0], r.ids[1], r.ids[2]
	if _, err := r.parties.Form(r.member(a), r.member(b), party.FlagExpShare); err != nil {
		t.Fatal(err)
	}
	hits := []combat.Hit{{AttackerID: a, Damage: 20}, {AttackerID: b, Damage: 20}, {AttackerID: solo, Damage: 60}}
	plan := planKill(r.hub, r.parties, shareMonster, hits, nil)
	if plan.credit != solo {
		t.Fatalf("credit %d, want the solo player %d", plan.credit, solo)
	}
	if plan.armCount != 0 {
		t.Fatalf("the party 5000 from the credit counted %d, want 0", plan.armCount)
	}
	if len(plan.awards) != 1 || plan.awards[0].characterID != solo || plan.awards[0].damage != 60 {
		t.Fatalf("awards %+v, want the solo player's alone", plan.awards)
	}
}

// An Exp Free-For-All party: each contributor is his own group, paid for his
// own damage x (1 + 0.03); a member who did no damage gets nothing.
func TestKillShareFreeForAll(t *testing.T) {
	r := newShareRig(t, 0, 10, 20)
	a, b, c := r.ids[0], r.ids[1], r.ids[2]
	p, err := r.parties.Form(r.member(a), r.member(b), party.FlagItemShare)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := r.parties.Add(p.ID, r.member(c)); err != nil {
		t.Fatal(err)
	}
	hits := []combat.Hit{{AttackerID: a, Damage: 50}, {AttackerID: b, Damage: 50}}
	plan := planKill(r.hub, r.parties, shareMonster, hits, nil)
	if plan.armCount != 0 || len(plan.awards) != 2 {
		t.Fatalf("plan %+v, want two individual awards and no count", plan)
	}
	paid, err := payKill(r.ctx, r.deps(), shareMonster, plan)
	if err != nil {
		t.Fatal(err)
	}
	// 1000 x 0.5 x 1.09 = 545 EXP, 54 SP; x 1.06 (three members) = 577 and 57.
	for _, id := range []int64{a, b} {
		if p := paid[id]; p.exp != 577 || p.sp != 57 {
			t.Errorf("contributor %d paid %d EXP %d SP, want 577 and 57", id, p.exp, p.sp)
		}
	}
	if _, ok := paid[c]; ok {
		t.Errorf("the member who dealt nothing was paid")
	}
}

// A lone killer is paid exactly the old full award: share 1, multiplier 1.
func TestKillShareSolo(t *testing.T) {
	r := newShareRig(t, 0)
	paid, err := payKill(r.ctx, r.deps(), shareMonster, planKill(r.hub, r.parties, shareMonster,
		[]combat.Hit{{AttackerID: r.ids[0], Damage: 300}}, nil))
	if err != nil {
		t.Fatal(err)
	}
	if p := paid[r.ids[0]]; p.exp != 1090 || p.sp != 109 {
		t.Fatalf("solo paid %d EXP %d SP, want 1090 and 109", p.exp, p.sp)
	}
}

// A party monster: x7.5 on the base.
func TestKillSharePartyMonster(t *testing.T) {
	r := newShareRig(t, 0)
	m := shareMonster
	m.Party = true
	paid, err := payKill(r.ctx, r.deps(), m, planKill(r.hub, r.parties, m, []combat.Hit{{AttackerID: r.ids[0], Damage: 100}}, nil))
	if err != nil {
		t.Fatal(err)
	}
	// 1000 x 7.5 x 1.09 = 8175.
	if p := paid[r.ids[0]]; p.exp != 8175 {
		t.Fatalf("party monster paid %d EXP, want 8175", p.exp)
	}
}
