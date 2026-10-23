package session

import (
	"context"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/mana"
	"github.com/TheOpenSRO/OpenSRO/server/internal/skill"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// engineRegen restates CGObjPC::vslot_362's per-tick amount from the read
// constants, independently of mana.RegenPerTick, so the tests below check the
// tick against the reading rather than against the code under test:
// trunc(float32(max) x rate / 100), floored at 1, capped at trunc(max x 0.5).
func engineRegen(max int, rate float32) int {
	pool := float64(float32(max))
	n := int(pool * float64(rate) / 100.0)
	if n < 1 {
		n = 1
	}
	if c := int(pool * 0.5); n > c {
		n = c
	}
	return n
}

// A tick with nobody online must not panic or touch anything.
func TestRegenTickWithNoPlayers(t *testing.T) {
	regenPass(context.Background(), nil, nil, RegenDeps{}, nil, time.Now(), true)
}

// A standing, damaged character regains 0.8% of its MAXIMUM HP and MP a tick
// (round 607): the slot the tick multiplies is ftol(EvaluateParam(3)), and
// SetMotionState(STAND) writes 0.8 to 'hprg' and 'mprg'. The fixture's pools
// are chosen so 4% of the current pool -- the rule this replaced -- gives a
// different number, and so MP moves too, which the old tick never did.
func TestRegenStandingIsPointEightPercentOfTheMaximum(t *testing.T) {
	f := startDeadWorldFixture(t)
	ctx := context.Background()
	c, err := f.chars.GetByID(ctx, f.aria)
	if err != nil {
		t.Fatal(err)
	}
	maxHP, maxMP := c.MaxHP(), c.MaxMP()
	if _, _, err := f.chars.ApplyDamage(ctx, f.aria, maxHP/2); err != nil {
		t.Fatal(err)
	}
	before, _ := f.chars.GetByID(ctx, f.aria)
	mp := mana.NewTracker()
	if _, ok := mp.Spend(f.aria, maxMP, maxMP/2); !ok {
		t.Fatalf("could not spend half of %d MP", maxMP)
	}
	mpBefore := mp.Current(f.aria, maxMP)

	regenPass(ctx, f.hub, f.chars, RegenDeps{Mana: mp}, nil, time.Now(), true)

	after, _ := f.chars.GetByID(ctx, f.aria)
	wantHP := engineRegen(maxHP, 0.8)
	if got := after.HP - before.HP; got != wantHP {
		t.Errorf("standing tick healed %d HP at %d/%d, want %d (0.8%% of the maximum, floored at 1)",
			got, before.HP, maxHP, wantHP)
	}
	wantMP := engineRegen(maxMP, 0.8)
	if got := mp.Current(f.aria, maxMP) - mpBefore; got != wantMP {
		t.Errorf("standing tick restored %d MP at %d/%d, want %d", got, mpBefore, maxMP, wantMP)
	}
}

// Sitting is 8%, ten times standing, and walking, running and the 1.5 s
// transition regenerate nothing -- CGObjPC::vslot_362 returns unless the
// motion state is STAND or SIT.
func TestRegenFollowsTheMotionState(t *testing.T) {
	ctx := context.Background()
	store := character.NewMemStore()
	c, err := store.Create(ctx, 1, "Restful")
	if err != nil {
		t.Fatal(err)
	}
	maxHP := c.MaxHP()
	if _, _, err := store.ApplyDamage(ctx, c.ID, maxHP-2); err != nil { // HP 2
		t.Fatal(err)
	}
	hub := world.NewHub()
	hub.Enter(gateway.NewTestSession(605), c.ID, "Restful", 1, "jangan", world.Position{})
	e, _ := hub.EntityByCharacterID(c.ID)
	e.Session = nil // no client: nothing to send the stats to
	t0 := time.Now()
	motions.enter(c.ID, t0)
	t.Cleanup(func() { motions.clear(c.ID) })
	hp := func() int {
		got, _ := store.GetByID(ctx, c.ID)
		return got.HP
	}

	// Walking: a move 100 ms ago.
	motions.moved(c.ID, t0)
	was := hp()
	regenOne(ctx, hub, e, store, RegenDeps{}, nil, t0.Add(100*time.Millisecond))
	if hp() != was {
		t.Errorf("a walking character regenerated %d HP", hp()-was)
	}
	// Standing still again.
	was = hp()
	regenOne(ctx, hub, e, store, RegenDeps{}, nil, t0.Add(time.Second))
	if got, want := hp()-was, engineRegen(maxHP, 0.8); got != want {
		t.Errorf("standing: +%d HP, want %d", got, want)
	}
	// Sitting down: 1.5 s of CHANGEMOTION, nothing.
	sitAt := t0.Add(2 * time.Second)
	if v, ok := motions.request(c.ID, MotionSit, sitAt); !ok || v != MotionSit {
		t.Fatalf("sit request: value %d ok %v", v, ok)
	}
	was = hp()
	regenOne(ctx, hub, e, store, RegenDeps{}, nil, sitAt.Add(1400*time.Millisecond))
	if hp() != was {
		t.Errorf("a character sitting down regenerated %d HP in the transition", hp()-was)
	}
	// Seated: 8%.
	was = hp()
	regenOne(ctx, hub, e, store, RegenDeps{}, nil, sitAt.Add(MotionChangeDuration))
	if got, want := hp()-was, engineRegen(maxHP, 8.0); got != want {
		t.Errorf("sitting: +%d HP, want %d (8%% of %d)", got, want, maxHP)
	}
	if engineRegen(maxHP, 8.0) <= engineRegen(maxHP, 0.8) {
		t.Fatalf("the fixture's max HP %d cannot tell the two rates apart", maxHP)
	}
}

// The timer is the character's own: first due 4 s after it enters, then every
// 4 s, and sitting does not re-arm it.
func TestRegenTimerIsPerCharacterFromEntry(t *testing.T) {
	const id = 605001
	t.Cleanup(func() { motions.clear(id) })
	t0 := time.Now()
	motions.enter(id, t0)
	if motions.regenDue(id, t0.Add(mana.RegenInterval-time.Millisecond)) {
		t.Error("the first tick fired before 4 s")
	}
	if !motions.regenDue(id, t0.Add(mana.RegenInterval)) {
		t.Error("the first tick did not fire at 4 s")
	}
	motions.request(id, MotionSit, t0.Add(5*time.Second))
	if motions.regenDue(id, t0.Add(8*time.Second-time.Millisecond)) {
		t.Error("sitting re-armed the timer: a tick fired before 8 s")
	}
	if !motions.regenDue(id, t0.Add(8*time.Second)) {
		t.Error("the second tick did not fire at 8 s")
	}
}

// The dead stay dead through regen (round 549): the tick's first test is the
// life state, so a character on 0 HP in life state 2 regains nothing -- now
// that the amount comes from the maximum, the life test is what holds it.
func TestRegenTickLeavesTheDeadAtZero(t *testing.T) {
	ctx := context.Background()
	store := character.NewMemStore()
	c, err := store.Create(ctx, 1, "Fallen")
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.ApplyDamage(ctx, c.ID, 1<<30); err != nil {
		t.Fatal(err)
	}
	hub := world.NewHub()
	hub.Enter(gateway.NewTestSession(549), c.ID, "Fallen", 1, "jangan", world.Position{})
	hub.SetLifeState(c.ID, world.LifeAlive, world.LifeDead, time.Now())
	for i := 0; i < 5; i++ {
		regenPass(ctx, hub, store, RegenDeps{}, nil, time.Now(), true)
	}
	if after, _ := store.GetByID(ctx, c.ID); after.HP != 0 {
		t.Errorf("regen raised a dead character from 0 to %d", after.HP)
	}
}

// A tick in the gap between a lethal blow's write and its kill decision must
// not lift the pool off 0 (round 607's review): the blow's fallen() would then
// find her alive above 0 and drop the kill. Alive at HP 0 -- the state that gap
// leaves -- regenerates no HP, standing or sitting; her MP still comes back
// (an HP-cost caster left at 0 is the other character in that state).
func TestRegenLeavesAnAliveCharacterAtZero(t *testing.T) {
	ctx := context.Background()
	store := character.NewMemStore()
	c, err := store.Create(ctx, 1, "Brink")
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.ApplyDamage(ctx, c.ID, 1<<30); err != nil {
		t.Fatal(err)
	}
	hub := world.NewHub()
	hub.Enter(gateway.NewTestSession(605002), c.ID, "Brink", 1, "jangan", world.Position{})
	t.Cleanup(func() { motions.clear(c.ID) })
	e, _ := hub.EntityByCharacterID(c.ID)
	e.Session = nil
	t0 := time.Now()
	motions.enter(c.ID, t0)
	regenOne(ctx, hub, e, store, RegenDeps{}, nil, t0)
	motions.request(c.ID, MotionSit, t0.Add(-2*MotionChangeDuration))
	regenOne(ctx, hub, e, store, RegenDeps{}, nil, t0)
	if after, _ := store.GetByID(ctx, c.ID); after.HP != 0 {
		t.Errorf("a character alive at HP 0 regenerated to %d; the kill that is deciding her would be dropped", after.HP)
	}
	mp := mana.NewTracker()
	mp.Spend(c.ID, c.MaxMP(), c.MaxMP()/2)
	before := mp.Current(c.ID, c.MaxMP())
	regenOne(ctx, hub, e, store, RegenDeps{Mana: mp}, nil, t0)
	if got := mp.Current(c.ID, c.MaxMP()); got <= before {
		t.Errorf("MP stayed at %d for a character alive at HP 0; only HP is held back", got)
	}
}

// The life state is read afresh under the kill lock, not from the pass's
// snapshot: a kill that lands after the snapshot was taken must win.
func TestRegenReadsTheLifeStateAfresh(t *testing.T) {
	ctx := context.Background()
	store := character.NewMemStore()
	c, err := store.Create(ctx, 1, "Stale")
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.ApplyDamage(ctx, c.ID, c.MaxHP()/2); err != nil {
		t.Fatal(err)
	}
	hub := world.NewHub()
	hub.Enter(gateway.NewTestSession(605003), c.ID, "Stale", 1, "jangan", world.Position{})
	t.Cleanup(func() { motions.clear(c.ID) })
	e, _ := hub.EntityByCharacterID(c.ID) // alive in the snapshot
	e.Session = nil
	motions.enter(c.ID, time.Now())
	hub.SetLifeState(c.ID, world.LifeAlive, world.LifeDead, time.Now())
	before, _ := store.GetByID(ctx, c.ID)
	regenOne(ctx, hub, e, store, RegenDeps{}, nil, time.Now())
	if after, _ := store.GetByID(ctx, c.ID); after.HP != before.HP {
		t.Errorf("a stale 'alive' snapshot healed a dead character %d -> %d", before.HP, after.HP)
	}
}

// blockingSkills is a skill.Store whose SkillPoints -- read while a stats reply
// is built -- waits until released, so a test can land a blow in that gap.
type blockingSkills struct {
	skill.Store
	entered chan struct{}
	release chan struct{}
}

func (b *blockingSkills) SkillPoints(_ context.Context, _ int64) (int, error) {
	b.entered <- struct{}{}
	<-b.release
	return 0, nil
}

// A regen push must not land after the death (round 607's third review): the
// stats reply is built outside the kill lock, a lethal blow can take the lock,
// kill her and push HP 0 meanwhile, and a regen packet arriving after it drew a
// live bar on a dead character. The push is dropped when she is no longer
// alive, or no longer at the HP it carries.
func TestRegenPushIsDroppedAfterADeath(t *testing.T) {
	f := startDeadWorldFixture(t)
	ctx := context.Background()
	t.Cleanup(func() { motions.clear(f.aria) })
	c, _ := f.chars.GetByID(ctx, f.aria)
	if _, _, err := f.chars.ApplyDamage(ctx, f.aria, c.MaxHP()/2); err != nil {
		t.Fatal(err)
	}
	e, _ := f.hub.EntityByCharacterID(f.aria)
	bs := &blockingSkills{entered: make(chan struct{}), release: make(chan struct{})}
	done := make(chan struct{})
	go func() {
		regenOne(ctx, f.hub, e, f.chars, RegenDeps{Skills: bs}, nil, time.Now())
		close(done)
	}()
	<-bs.entered // the pools are written and the reply is being built
	f.kill(t, f.aria, time.Now())
	close(bs.release)
	<-done
	if !f.nothing(t, f.connA, f.rA) {
		t.Error("a regen stats push was delivered after Aria was killed")
	}
}

// The control: with nobody killing her, the same push goes out.
func TestRegenPushGoesOutWhenNothingChanged(t *testing.T) {
	f := startDeadWorldFixture(t)
	ctx := context.Background()
	t.Cleanup(func() { motions.clear(f.aria) })
	c, _ := f.chars.GetByID(ctx, f.aria)
	if _, _, err := f.chars.ApplyDamage(ctx, f.aria, c.MaxHP()/2); err != nil {
		t.Fatal(err)
	}
	e, _ := f.hub.EntityByCharacterID(f.aria)
	regenOne(ctx, f.hub, e, f.chars, RegenDeps{}, nil, time.Now())
	p := f.read(t, f.connA, f.rA)
	if p.Opcode != OpCharacterStatsResult {
		t.Fatalf("got %#04x, want the regen stats push", p.Opcode)
	}
}
