package session

import (
	"bufio"
	"context"
	"errors"
	"math/rand"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/account"
	"github.com/OpenSRO/OpenSRO/server/internal/ai"
	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/mana"
	"github.com/OpenSRO/OpenSRO/server/internal/quest"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
	"github.com/OpenSRO/OpenSRO/server/internal/skill"
	"github.com/OpenSRO/OpenSRO/server/internal/statuseffect"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// Round 659's review follow-up. Every test here was written to FAIL on the
// round's first commit (9007108); each names the review item it pins. The
// skill rows are SYNTHETIC, with chance 100 so the dice never decide.

// ---- H1: a stun on a moving monster puts a stop on the wire ----

func TestStatusStunOnAMovingMonsterSendsAStop(t *testing.T) {
	fx := statusFXForTest(t)
	battleForTest(t, true)
	f := startBattleFixture(t, 25, 0, 0)
	m := f.monsters.SpawnSpecies("jangan", chaseMangyang, 150, 0, 0, 100000, 0, 1, 0)
	now := aiT0
	monsterAITick(now)
	now = now.Add(MonsterAITick)
	noteStruck(f.monsters, m.ID, f.aria)
	for i := 0; i < 5; i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
	}
	if got, _ := f.monsters.Get(m.ID); !got.Moving {
		t.Fatalf("setup: the monster is not chasing: %+v", got)
	}
	f.rec.reset()
	// The fixture's session cannot be written to, so no hub: the mask goes
	// nowhere, the stun lands and the AI does the rest.
	fx.applyToMonster(combatDeps{monsters: f.monsters}, f.aria, &refdata.Skill{ReqLearnSP: 1, ID: 9100, StatusParams: "st:60000,100,2"}, m.ID, time.Now())
	for i := 0; i < 3; i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
	}
	after, _ := f.monsters.Get(m.ID)
	stops := 0
	for _, mv := range f.rec.of(m.ID) {
		if mv.DestX == mv.X && mv.DestZ == mv.Z && float64(mv.X) == float64(float32(after.X)) {
			stops++
		}
	}
	if stops != 1 || after.Moving {
		t.Errorf("a stun on a chasing monster: %d stops on the wire (moves %+v), still moving %v; want one stop where it stands",
			stops, f.rec.of(m.ID), after.Moving)
	}
}

// ---- L3: frostbite slows a leg at once ----

func TestStatusFrostbiteSlowsTheLegAtOnce(t *testing.T) {
	fx := statusFXForTest(t)
	battleForTest(t, true)
	f := startBattleFixture(t, 27, 0, 0)
	m := f.monsters.SpawnSpecies("jangan", chaseMangyang, 150, 0, 0, 100000, 0, 1, 0)
	now := aiT0
	monsterAITick(now)
	now = now.Add(MonsterAITick)
	noteStruck(f.monsters, m.ID, f.aria)
	for i := 0; i < 3; i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
	}
	if got, _ := f.monsters.Get(m.ID); !got.Moving || got.MoveSpeed != chaseMangyang.RunSpeed {
		t.Fatalf("setup: not running at %v: %+v", chaseMangyang.RunSpeed, got)
	}
	f.rec.reset()
	fx.applyToMonster(combatDeps{monsters: f.monsters}, f.aria, &refdata.Skill{ReqLearnSP: 1, ID: 9100, StatusParams: "fb:40,100"}, m.ID, time.Now())
	monsterAITick(now)
	moves := f.rec.of(m.ID)
	if len(moves) != 1 || moves[0].Speed != float32(chaseMangyang.RunSpeed/2) {
		t.Errorf("frostbite on a running monster: %+v; want one leg at half the run speed (%v) on the next tick", moves, chaseMangyang.RunSpeed/2)
	}
}

// ---- M2: a living caster is named on every tick ----

// A non-fatal bleeding tick from a living caster is booked to her on the
// monster's damage list, which is what the unique notice reads.
func TestStatusTickBooksALivingCaster(t *testing.T) {
	fx := statusFXForTest(t)
	ctx := context.Background()
	z := startStrikeZone(t)
	k := z.monsters.SpawnSpecies("jangan", strikeMangyang, z.aria.x, 0, z.aria.z, 1000, 0, 0, 0)
	deps := combatDeps{chars: z.chars, eq: z.eq, items: z.items, hub: z.hub, monsters: z.monsters,
		quests: quest.NewMemStore(), inv: z.inv, skills: skill.NewMemStore()}
	t0 := time.Now()
	fx.applyToMonster(deps, z.ariaChar, &refdata.Skill{ReqLearnSP: 1, ID: 9100, StatusParams: "bl:30000,100,1,200,0"}, k.ID, t0)
	fx.step(ctx, t0.Add(2001*time.Millisecond))
	var booked int
	for _, h := range z.monsters.Hits(k.ID) {
		if h.AttackerID == z.ariaChar {
			booked += h.Damage
		}
	}
	if booked != 200 {
		t.Errorf("Aria's bleeding took 200 off a living monster; the damage list books her %d (hits %+v)", booked, z.monsters.Hits(k.ID))
	}
}

// And the tick is the monster's struck event: a DoT-only debuff draws it
// onto its caster.
func TestStatusTickDrawsTheMonsterOntoItsCaster(t *testing.T) {
	fx := statusFXForTest(t)
	battleForTest(t, true)
	f := startBattleFixture(t, 29, 0, 0)
	m := f.monsters.SpawnSpecies("jangan", chaseMangyang, 60, 0, 0, 100000, 0, 1, 0)
	now := aiT0
	monsterAITick(now)
	now = now.Add(MonsterAITick)
	if st := stateOf(t, f.a, m.ID); st == ai.StateBattle {
		t.Fatal("setup: already in BATTLE")
	}
	rec, _ := statuseffect.Resolve(statuseffect.Run{Code: "bl", Values: []int{30000, 100, 1, 50, 0}}, statuseffect.Target{}, fx.ms(time.Now()), func(int, int) bool { return true })
	rec.SourceID = f.aria
	h := &statuseffect.Holder{}
	h.Put(rec)
	fx.mu.Lock()
	fx.mobs[m.ID] = h
	fx.cdeps = combatDeps{monsters: f.monsters} // no hub: nothing is sent
	fx.sdeps = strikeDeps{hub: f.hub}           // where the caster is looked up
	fx.mu.Unlock()
	fx.step(context.Background(), time.Now().Add(2100*time.Millisecond))
	if got, _ := f.monsters.Get(m.ID); got.HP != got.MaxHP-50 {
		t.Fatalf("the tick did not land: HP %d of %d", got.HP, got.MaxHP)
	}
	monsterAITick(now)
	if st := stateOf(t, f.a, m.ID); st != ai.StateBattle {
		t.Errorf("a bleeding tick from Aria left the monster in %v; want BATTLE (the struck event)", st)
	}
}

// ---- M1: the dice are the caster's ----

func TestStatusDiceAreTheCasters(t *testing.T) {
	fx := statusFXForTest(t)
	z := startStrikeZone(t)
	a := z.monsters.SpawnSpecies("jangan", strikeMangyang, z.aria.x, 0, z.aria.z, 1000, 0, 0, 0)
	for a.ID == z.ariaChar { // monster and character ids share the tracker's key space
		a = z.monsters.SpawnSpecies("jangan", strikeMangyang, z.aria.x, 0, z.aria.z, 1000, 0, 0, 0)
	}
	// The package's tests roll with no generator (main_test.go: the maximum
	// outcome, which touches no accumulator); this one needs a real roll.
	damageRollMu.Lock()
	damageRollNG = rand.New(rand.NewSource(659))
	damageRollMu.Unlock()
	t.Cleanup(func() { damageRollMu.Lock(); damageRollNG = nil; damageRollMu.Unlock() })
	chanceMemory.Forget(z.ariaChar)
	chanceMemory.Forget(a.ID)
	t.Cleanup(func() { chanceMemory.Forget(z.ariaChar) })
	deps := combatDeps{chars: z.chars, hub: z.hub, monsters: z.monsters}
	// A 50 % frostbite (kind 2): a real roll, so the accumulator is touched.
	fx.applyToMonster(deps, z.ariaChar, &refdata.Skill{ReqLearnSP: 1, ID: 9100, StatusParams: "fb:30,50"}, a.ID, time.Now())
	if _, rolled := chanceMemory.Accumulated(z.ariaChar, combat.ChanceStatus(2)); !rolled {
		t.Error("the frostbite roll kept no streak on its caster (0x590680 rolls in [esi+0xa30], ESI the source)")
	}
	if _, rolled := chanceMemory.Accumulated(a.ID, combat.ChanceStatus(2)); rolled {
		t.Error("the frostbite roll kept a streak on its target")
	}
}

// ---- L4: a freeze holds its monster 1.5 s after it ends ----

func TestStatusFreezeThawHoldsTheMonster(t *testing.T) {
	fx := statusFXForTest(t)
	monsters := combat.NewHub()
	m := monsters.SpawnSpecies("jangan", strikeMangyang, 0, 0, 0, 1000, 0, 0, 0)
	now := time.Now()
	rec, _ := statuseffect.Resolve(statuseffect.Run{Code: "fz", Values: []int{10, 100}}, statuseffect.Target{}, fx.ms(now.Add(-2000*time.Millisecond)), func(int, int) bool { return true })
	h := &statuseffect.Holder{}
	h.Put(rec)
	fx.mu.Lock()
	fx.mobs[m.ID] = h
	fx.cdeps = combatDeps{monsters: monsters}
	fx.mu.Unlock()
	fx.step(context.Background(), now) // the 970 ms freeze has ended
	if monsterMayAct(m.ID) {
		t.Error("a freeze that ended this instant let its monster act; retail holds FROZEN 1.5 s more (0xb45c10)")
	}
}

// ---- L2: the pass reads the store outside the runtime's lock ----

// slowChars is a character store whose GetByID blocks while armed.
type slowChars struct {
	character.Store
	mu      sync.Mutex
	armed   bool
	entered chan struct{}
	release chan struct{}
}

func (s *slowChars) GetByID(ctx context.Context, id int64) (*character.Character, error) {
	s.mu.Lock()
	armed := s.armed
	s.armed = false
	s.mu.Unlock()
	if armed {
		close(s.entered)
		<-s.release
	}
	return s.Store.GetByID(ctx, id)
}

func TestStatusPassDoesNotHoldTheLockOnAStoreRead(t *testing.T) {
	fx := statusFXForTest(t)
	ctx := context.Background()
	mem := character.NewMemStore()
	c, err := mem.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatal(err)
	}
	hub := world.NewHub()
	hub.Enter(gateway.NewTestSession(96590), c.ID, "Aria", 1, "jangan", world.Position{})
	slow := &slowChars{Store: mem, armed: true, entered: make(chan struct{}), release: make(chan struct{})}
	rec, _ := statuseffect.Resolve(statuseffect.Run{Code: "ps", Values: []int{60, 100, 5}}, statuseffect.Target{}, fx.ms(time.Now()), func(int, int) bool { return true })
	h := &statuseffect.Holder{}
	h.Put(rec)
	fx.mu.Lock()
	fx.pcs[c.ID] = h
	fx.sdeps = strikeDeps{chars: slow, hub: hub}
	fx.mu.Unlock()
	done := make(chan struct{})
	go func() { fx.step(ctx, time.Now()); close(done) }()
	select {
	case <-slow.entered:
	case <-done:
		t.Fatal("the pass never read the afflicted character")
	case <-time.After(5 * time.Second):
		close(slow.release)
		t.Fatal("the pass never read the afflicted character")
	}
	answered := make(chan struct{})
	go func() { fx.monsterState(12345); close(answered) }()
	select {
	case <-answered:
	case <-time.After(300 * time.Millisecond):
		t.Error("the AI's state read waited on a character store read the pass made under the runtime's lock")
	}
	close(slow.release)
	<-done
	<-answered
}

// ---- H3: a death by a tick is a death ----

func TestStatusTickDeathIsReportedLikeABlowDeath(t *testing.T) {
	fx := statusFXForTest(t)
	deadStateForTest(t, true)
	ctx := context.Background()
	z := startStrikeZone(t)
	k := z.monsters.SpawnSpecies("jangan", strikeMangyang, z.aria.x, 0, z.aria.z, 1000, 0, 0, 0)
	deps := strikeDeps{chars: z.chars, eq: z.eq, items: z.items, hub: z.hub}
	t0 := time.Now()
	fx.applyToCharacter(ctx, deps, *k, combat.MonsterSkill{ID: 9200, Status: "bl:30000,100,1,100000,0"}, z.ariaChar)
	fx.step(ctx, t0.Add(2100*time.Millisecond))
	for _, c := range []*strikeClient{z.aria, z.bram} {
		var died *MonsterAttacked
		var raw []byte
		for _, p := range c.barrier(t) {
			if p.Opcode == OpMonsterAttacked {
				died, _ = DecodeMonsterAttacked(p.Data)
				raw = p.Data
			}
		}
		if died == nil || !died.TargetDied || died.TargetCharacterID != z.ariaChar || died.TargetHP != 0 || died.MonsterID != k.ID {
			t.Errorf("%s was not told of Aria's death by a tick like a blow's death: %+v", c.name, died)
			continue
		}
		if raw[20]&0x08 == 0 {
			t.Errorf("%s: the death carries no status-tick flag (0x08): a client would draw a swing", c.name)
		}
	}
	if e, ok := z.hub.EntityByCharacterID(z.ariaChar); !ok || e.Life != world.LifeDead {
		t.Errorf("Aria's life state after the tick %d, want DEAD", e.Life)
	}
}

// ---- H2 and M3: the cast paths ----

const (
	skStunZero  = 9101 // a zero-damage stun (SKILL_EU_WARRIOR_DUALA_STUN_A's shape)
	skStunZero2 = 9102
	skStunZero3 = 9103
	skStunSmash = 9104 // a damaging skill that stuns (SKILL_CH_SPEAR_STUN_A's shape)
	skStunSmsh2 = 9105
)

type statusSkillRef struct{}

func (statusSkillRef) GetSkill(_ context.Context, id int64) (*refdata.Skill, error) {
	switch id {
	case skStunZero, skStunZero2, skStunZero3:
		return &refdata.Skill{ReqLearnSP: 1, ID: id, GroupID: id, BasicLevel: 1, TargetRequired: true, ZeroDamage: true,
			Range: 20, StatusParams: "st:60000,100,2"}, nil
	case skStunSmash, skStunSmsh2:
		return &refdata.Skill{ReqLearnSP: 1, ID: id, GroupID: id, BasicLevel: 1, TargetRequired: true,
			AttackPercent: 143, DamageMin: 15, DamageMax: 18, AttackType: 5, Range: 20, StatusParams: "st:60000,100,2"}, nil
	}
	return nil, errors.New("no such skill")
}

type statusCastWorld struct {
	*buffWorld
	monsters *combat.Hub
	pos      world.Position
}

func startStatusCastWorld(t *testing.T) *statusCastWorld {
	t.Helper()
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatal(err)
	}
	items := stubCombatItems{100: {ID: 100, PhysAttackMin: 30, PhysAttackMax: 30}}
	inv := inventory.NewMemStore(items)
	inv.AddItem(ctx, c.ID, 100, 1)
	eq := equipment.NewMemStore(inv)
	eq.Equip(ctx, c.ID, equipment.SlotWeapon, 0)
	skills := skill.NewMemStore()
	for _, id := range []int64{skStunZero, skStunZero2, skStunZero3, skStunSmash, skStunSmsh2} {
		if err := skills.Learn(ctx, c.ID, id); err != nil {
			t.Fatal(err)
		}
	}
	hub := world.NewHub()
	monsters := combat.NewHub()
	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		UseSkillHandler(chars, eq, items, skills, hub, monsters, quest.NewMemStore(), inv, statusSkillRef{}, nil, mana.NewTracker(), nil),
	)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	ln.Close()
	srv := &gateway.Server{Addr: addr, Handle: handle, OnDisconnect: WorldDisconnectHandler(hub, nil)}
	sctx, cancel := context.WithCancel(context.Background())
	go srv.ListenAndServe(sctx)
	t.Cleanup(cancel)
	conn := dialTestServer(t, addr)
	t.Cleanup(func() { conn.Close() })
	w := &buffWorld{addr: addr, skills: skills, aria: c.ID, hub: hub, conn: conn, r: bufio.NewReader(conn)}
	t.Cleanup(func() { keepUp.Cancel(c.ID) })
	w.write(t, OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	if lr, err := DecodeLoginResult(w.expect(t, OpLoginResult).Data); err != nil || !lr.OK {
		t.Fatalf("login: %v %+v", err, lr)
	}
	w.write(t, OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	if ewr, err := DecodeEnterWorldResult(w.expect(t, OpEnterWorldResult).Data); err != nil || !ewr.OK {
		t.Fatalf("enter world: %v %+v", err, ewr)
	}
	e, _ := hub.EntityByCharacterID(c.ID)
	return &statusCastWorld{buffWorld: w, monsters: monsters, pos: e.Pos}
}

func held(fx *statusRuntime, id int64) bool {
	fx.mu.Lock()
	defer fx.mu.Unlock()
	h := fx.mobs[id]
	return h != nil && !h.Empty()
}

// H2: a zero-damage stun needs its target in reach and in the caster's zone.
func TestStatusZeroDamageCastNeedsReachAndZone(t *testing.T) {
	fx := statusFXForTest(t)
	w := startStatusCastWorld(t)
	far := w.monsters.SpawnSpecies("jangan", strikeMangyang, w.pos.X+5000, 0, w.pos.Z, 1000, 0, 0, 0)
	away := w.monsters.SpawnSpecies("donwhang", strikeMangyang, w.pos.X, 0, w.pos.Z, 1000, 0, 0, 0)
	near := w.monsters.SpawnSpecies("jangan", strikeMangyang, w.pos.X, 0, w.pos.Z, 1000, 0, 0, 0)

	if ar := w.cast(t, &UseSkillRequest{SkillID: skStunZero, TargetMonsterID: far.ID}); ar.Error != "too far away" || held(fx, far.ID) {
		t.Errorf("a zero-damage stun 5000 away: %q, stunned %v; want refused as too far, no state", ar.Error, held(fx, far.ID))
	}
	if ar := w.cast(t, &UseSkillRequest{SkillID: skStunZero2, TargetMonsterID: away.ID}); ar.Error != "target not found" || held(fx, away.ID) {
		t.Errorf("a zero-damage stun at a monster in another zone: %q, stunned %v; want refused, no state", ar.Error, held(fx, away.ID))
	}
	if ar := w.cast(t, &UseSkillRequest{SkillID: skStunZero3, TargetMonsterID: near.ID}); ar.Error != "" || !held(fx, near.ID) {
		t.Errorf("the control, a zero-damage stun in reach: %q, stunned %v", ar.Error, held(fx, near.ID))
	}
}

// M3: a blocked blow lands no state; an unblocked one does.
func TestStatusBlockedBlowLandsNoState(t *testing.T) {
	fx := statusFXForTest(t)
	w := startStatusCastWorld(t)
	blocker := strikeMangyang
	blocker.Block = 100
	wall := w.monsters.SpawnSpecies("jangan", blocker, w.pos.X, 0, w.pos.Z, 100000, 0, 0, 0)
	open := w.monsters.SpawnSpecies("jangan", strikeMangyang, w.pos.X, 0, w.pos.Z, 100000, 0, 0, 0)
	if ar := w.cast(t, &UseSkillRequest{SkillID: skStunSmash, TargetMonsterID: wall.ID}); ar.Error != "" || held(fx, wall.ID) {
		t.Errorf("a stun whose blow the monster blocked: %q, stunned %v; want no state (0x5906c0 tests the blocked flag)", ar.Error, held(fx, wall.ID))
	}
	if ar := w.cast(t, &UseSkillRequest{SkillID: skStunSmsh2, TargetMonsterID: open.ID}); ar.Error != "" || !held(fx, open.ID) {
		t.Errorf("the control, an unblocked stun: %q, stunned %v", ar.Error, held(fx, open.ID))
	}
}

// ---- The re-review: a death by a tick releases the monsters fighting her ----

// With -player-dead-state off she is back on her feet at once; the monster
// whose bleeding killed her must still let go, as a strike kill makes it.
func TestStatusTickDeathReleasesTheMonster(t *testing.T) {
	fx := statusFXForTest(t)
	battleForTest(t, true)
	deadStateForTest(t, false)
	ctx := context.Background()
	z := startStrikeZone(t)
	rec := &pushRecorder{}
	installMonsterAIForTest(t, z.hub, z.monsters, 659, rec.push)
	k := z.monsters.SpawnSpecies("jangan", chaseMangyang, z.aria.x, 0, z.aria.z, 100000, 0, 1, 0)
	now := aiT0
	monsterAITick(now)
	now = now.Add(MonsterAITick)
	a := monsterAIRuntime.Load()
	noteStruck(z.monsters, k.ID, z.ariaChar)
	monsterAITick(now)
	now = now.Add(MonsterAITick)
	if st := stateOf(t, a, k.ID); st != ai.StateBattle {
		t.Fatalf("setup: the monster is in %v, want BATTLE on Aria", st)
	}
	deps := strikeDeps{chars: z.chars, eq: z.eq, items: z.items, hub: z.hub}
	t0 := time.Now()
	fx.applyToCharacter(ctx, deps, *k, combat.MonsterSkill{ID: 9200, Status: "bl:30000,100,1,100000,0"}, z.ariaChar)
	fx.step(ctx, t0.Add(2100*time.Millisecond))
	if c, _ := z.chars.GetByID(ctx, z.ariaChar); c.HP <= 0 {
		t.Fatalf("setup: with the dead state off she should be back on her feet, HP %d", c.HP)
	}
	monsterAITick(now)
	if st := stateOf(t, a, k.ID); st == ai.StateBattle {
		t.Errorf("the monster whose bleeding killed Aria is still in BATTLE on her; a kill must release it (a.kills)")
	}
}

// ---- The re-review's L3: with the AI off, a stun still ends a leg ----

func TestStatusStunStopsALegWithTheAIOff(t *testing.T) {
	fx := statusFXForTest(t)
	if monsterAIRuntime.Load() != nil {
		t.Fatal("setup: an AI runtime is installed")
	}
	monsters := combat.NewHub()
	m := monsters.SpawnSpecies("jangan", strikeMangyang, 0, 0, 0, 1000, 0, 0, 0)
	if _, ok := monsters.SetMotion(m.ID, 100, 0, 10, 1); !ok {
		t.Fatal("setup: no leg")
	}
	fx.applyToMonster(combatDeps{monsters: monsters}, 1, &refdata.Skill{ReqLearnSP: 1, ID: 9100, StatusParams: "st:60000,100,2"}, m.ID, time.Now())
	if got, _ := monsters.Get(m.ID); got.Moving {
		t.Errorf("with -monster-ai off a stunned monster is still on its leg: %+v", got)
	}
}
