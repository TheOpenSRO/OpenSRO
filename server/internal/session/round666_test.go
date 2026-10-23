package session

import (
	"context"
	"math/rand"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/ai"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/quest"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/skill"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 666: the release review's server items. Synthetic monsters only.

// inWindowOf reports whether a monster at (x, z) of zone stands in the area of
// interest of a player at (px, pz): the AOIRadius square of cells around the
// player's cell.
func inWindowOf(zone string, x, z, px, pz float64) bool {
	c, p := combat.CellOf(zone, x, z), combat.CellOf(zone, px, pz)
	return c.Zone == p.Zone && c.X >= p.X-AOIRadius && c.X <= p.X+AOIRadius && c.Z >= p.Z-AOIRadius && c.Z <= p.Z+AOIRadius
}

// M4: a player walks past forty monsters, each in its own window, and stops
// beside the first. Once every monster left behind has finished what it was
// doing (none is in BATTLE or HOMING), the brains are back to the monsters the
// player's window holds -- one -- and the others' memories are filed. Until
// this round every monster the player had passed kept its whole brain, and
// every pass walked all of them.
func TestSleepingBrainsFallBackToTheAwake(t *testing.T) {
	hub := world.NewHub()
	monsters := newAIHub(66)
	sess := gateway.NewTestSession(66601)
	hub.Enter(sess, 1, "p", 1, "jangan", world.Position{X: cellX(0)})
	const n = 40
	ids := make([]int64, n)
	for k := 0; k < n; k++ {
		ids[k] = spawnAt(t, monsters, "jangan", cellX(4*k), 0) // 4 cells apart: never two in one window
	}
	a := newMonsterAI(hub, monsters, nil, MonsterAIConfig{Sleep: true}, rand.New(rand.NewSource(66)), (&pushRecorder{}).push)
	monsterAIRuntime.Store(a)
	t.Cleanup(func() { monsterAIRuntime.Store(nil) })

	now := aiT0
	run := func(ticks int) {
		for i := 0; i < ticks; i++ {
			a.tick(now)
			now = now.Add(MonsterAITick)
		}
	}
	for k := 0; k < n; k++ { // the walk: ten seconds beside each monster
		hub.Relocate(sess, world.Position{X: cellX(4 * k)}, world.MoveRelocate, 0)
		run(100)
	}
	hub.Relocate(sess, world.Position{X: cellX(0)}, world.MoveRelocate, 0)
	run(900) // 90 s: longer than HOMING's 50 s dwell, so nothing is left insistent

	e, _ := hub.EntityByCharacterID(1)
	awake := 0
	for _, id := range ids {
		m, ok := monsters.Get(id)
		if !ok {
			t.Fatalf("monster %d vanished", id)
		}
		if inWindowOf(m.Zone, m.X, m.Z, e.Pos.X, e.Pos.Z) {
			awake++
		}
	}
	a.mu.Lock()
	brains, filed := len(a.brains), len(a.asleep)
	var insistent []int64
	for id, b := range a.brains {
		if st := b.machine.State(); st == ai.StateBattle || st == ai.StateHoming {
			insistent = append(insistent, id)
		}
	}
	a.mu.Unlock()
	if len(insistent) != 0 {
		t.Fatalf("setup: monsters %v are still in BATTLE or HOMING after 90 s", insistent)
	}
	if brains != awake {
		t.Fatalf("brains after the player walked on: got %d, want %d (the monsters the player's window holds)", brains, awake)
	}
	if filed != n-awake {
		t.Fatalf("%d memories filed, want one per sleeping monster, %d", filed, n-awake)
	}

	// And they wake again: the player walks back past them all.
	for k := 0; k < n; k++ {
		hub.Relocate(sess, world.Position{X: cellX(4 * k)}, world.MoveRelocate, 0)
		run(1)
		a.mu.Lock()
		b := a.brains[ids[k]]
		a.mu.Unlock()
		if b == nil {
			t.Fatalf("monster %d did not wake when the player came back", ids[k])
		}
	}
}

// M4: a woken brain carries on as it slept. Every field brainMemory files is
// set to a literal no fresh brain would hold, the brain is filed and woken,
// and each field of the WOKEN brain is compared with that literal -- not with
// a second trip through memory(), which a field memory() forgot would pass as
// zero on both sides (round 666's review: 8 of 15 mutants survived that).
// The machine resumes in the state it slept in with its dwell, and the wake
// draws nothing from the rng.
func TestWokenBrainKeepsWhatItFiled(t *testing.T) {
	monsters := newAIHub(67)
	m := monsters.SpawnSpecies("jangan", testMangyang, 100, 0, 0, 30, 1, 1, 1)
	src := &countingSource{Source: rand.NewSource(67)}
	a := newMonsterAI(world.NewHub(), monsters, nil, MonsterAIConfig{Sleep: true}, rand.New(src), (&pushRecorder{}).push)
	a.aggro, a.now = true, aiT0
	b := a.newBrain(*m)
	a.dispatch(b, ai.MsgSpawned)
	a.change(b, ai.StateWander)
	if b.machine.State() != ai.StateWander || !b.rolled {
		t.Fatalf("setup: state %v, rolled %v", b.machine.State(), b.rolled)
	}
	// true, not the zero value, so a field memory() forgot shows; a re-roll
	// shows as a draw from the rng (below).
	aggressive := true
	entered := aiT0.Add(-3 * time.Second)
	b.aggressive, b.scanPeriodMs, b.scanDueAt = aggressive, 1234, aiT0.Add(700*time.Millisecond)
	b.enteredAt, b.dwellMs, b.target, b.heading = entered, 5432, 4242, 1.25
	b.homingDestX, b.homingDestZ, b.homingBlackoutMs = 11.5, -22.5, 3333
	b.lastSwing, b.swungReuseMs = aiT0.Add(-time.Second), 3000
	b.giveUpDueAt = aiT0.Add(2 * time.Second)
	b.damageTaken, b.lastHP, b.hpSeen = 1234, 17, true
	b.trigFired, b.trigLast = []bool{true, false}, []time.Time{aiT0, {}}
	mem := b.memory()

	a.now = aiT0.Add(time.Hour)
	draws := src.n
	got := a.wake(*m, mem)
	type field struct {
		name      string
		got, want any
	}
	for _, f := range []field{
		{"state", got.machine.State(), ai.StateWander},
		{"enteredAt", got.enteredAt, entered},
		{"dwellMs", got.dwellMs, 5432},
		{"target", got.target, int64(4242)},
		{"heading", got.heading, 1.25},
		{"homingDestX", got.homingDestX, 11.5},
		{"homingDestZ", got.homingDestZ, -22.5},
		{"homingBlackoutMs", got.homingBlackoutMs, 3333},
		{"lastSwing", got.lastSwing, aiT0.Add(-time.Second)},
		{"swungReuseMs", got.swungReuseMs, 3000},
		{"giveUpDueAt", got.giveUpDueAt, aiT0.Add(2 * time.Second)},
		{"rolled", got.rolled, true},
		{"aggressive", got.aggressive, aggressive},
		{"scanPeriodMs", got.scanPeriodMs, 1234},
		{"scanDueAt", got.scanDueAt, aiT0.Add(700 * time.Millisecond)},
		{"damageTaken", got.damageTaken, int64(1234)},
		{"lastHP", got.lastHP, 17},
		{"hpSeen", got.hpSeen, true},
		{"trigFired", len(got.trigFired) == 2 && got.trigFired[0] && !got.trigFired[1], true},
		{"trigLast", len(got.trigLast) == 2 && got.trigLast[0].Equal(aiT0) && got.trigLast[1].IsZero(), true},
		// rebuilt, not filed: newBrain's arithmetic over the monster
		{"detection", got.detection, b.detection},
		{"giveUp", got.giveUp, b.giveUp},
		{"roamRadius", got.roamRadius, b.roamRadius},
		{"roamRule", got.roamRule, b.roamRule},
	} {
		if f.got != f.want {
			t.Errorf("woken brain's %s = %v, want %v", f.name, f.got, f.want)
		}
	}
	if src.n != draws {
		t.Fatalf("the wake drew %d number(s) from the rng; it must re-roll nothing", src.n-draws)
	}
}

// fileAsleep puts the player far from the monsters so every one of them is
// filed asleep, ticking until they are (or failing).
func fileAsleep(t *testing.T, a *monsterAI, hub *world.Hub, sess *gateway.Session, now *time.Time, ids ...int64) {
	t.Helper()
	hub.Relocate(sess, world.Position{X: cellX(200)}, world.MoveRelocate, 0)
	for i := 0; i < 900; i++ {
		*now = now.Add(MonsterAITick)
		a.tick(*now)
		all := true
		for _, id := range ids {
			if _, filed := a.asleep[id]; !filed || a.brains[id] != nil {
				all = false
			}
		}
		if all {
			return
		}
	}
	t.Fatalf("setup: monsters %v were not all filed asleep in 90 s", ids)
}

// M4: a status hold still wakes a filed monster. A stun lands on a monster
// whose brain is filed asleep; the next pass counts it insistent (addHeld asks
// hasBrain, which counts a filed memory), wakes it and runs it -- as the
// retained brain of rounds 656-665 was kept running.
func TestStatusHoldWakesAFiledMonster(t *testing.T) {
	fx := statusFXForTest(t)
	hub := world.NewHub()
	monsters := newAIHub(69)
	sess := gateway.NewTestSession(66901)
	hub.Enter(sess, 1, "p", 1, "jangan", world.Position{X: cellX(0)})
	id := spawnAt(t, monsters, "jangan", cellX(0)+50, 0)
	a := newMonsterAI(hub, monsters, nil, MonsterAIConfig{Sleep: true}, rand.New(rand.NewSource(69)), (&pushRecorder{}).push)
	monsterAIRuntime.Store(a)
	t.Cleanup(func() { monsterAIRuntime.Store(nil) })
	now := aiT0
	a.tick(now)
	fileAsleep(t, a, hub, sess, &now, id)
	fx.applyToMonster(combatDeps{monsters: monsters}, 1, &refdata.Skill{ReqLearnSP: 1, ID: 9100, StatusParams: "st:60000,100,2"}, id, time.Now())
	now = now.Add(MonsterAITick)
	a.tick(now)
	_, filed := a.asleep[id]
	if b := a.brains[id]; b == nil || b.seenTick != a.tickN || filed {
		t.Fatalf("the stunned filed monster: brain %v, run this pass %v, still filed %v; want it woken and run",
			b != nil, b != nil && b.seenTick == a.tickN, filed)
	}
}

// M4: the memories of monsters that died asleep are swept. Ten monsters are
// filed asleep and killed (no player near: a DoT or a GM's /kill); within a
// pass -- ten is under asleepSweepPerTick -- their memories are gone.
func TestDeadSleepersAreSwept(t *testing.T) {
	hub := world.NewHub()
	monsters := newAIHub(70)
	sess := gateway.NewTestSession(67001)
	hub.Enter(sess, 1, "p", 1, "jangan", world.Position{X: cellX(0)})
	var ids []int64
	for k := 0; k < 10; k++ {
		ids = append(ids, spawnAt(t, monsters, "jangan", cellX(0)+float64(10*k), 0))
	}
	a := newMonsterAI(hub, monsters, nil, MonsterAIConfig{Sleep: true}, rand.New(rand.NewSource(70)), (&pushRecorder{}).push)
	monsterAIRuntime.Store(a)
	t.Cleanup(func() { monsterAIRuntime.Store(nil) })
	now := aiT0
	a.tick(now)
	fileAsleep(t, a, hub, sess, &now, ids...)
	for _, id := range ids {
		if _, died, ok := monsters.ApplyDamage(id, 1<<20); !ok || !died {
			t.Fatalf("setup: monster %d did not die", id)
		}
	}
	now = now.Add(MonsterAITick)
	a.tick(now)
	if n := len(a.asleep); n != 0 {
		t.Fatalf("%d memories of dead monsters left after a pass, want 0", n)
	}
}

// M4's guard: a sleeping monster struck by a damage-over-time tick whose
// caster has walked away still engages the caster, as the retained brain of
// rounds 656-665 did: its filed memory is woken for the blow, it enters
// BATTLE, and from the next pass it is insistent and runs.
func TestFiledMonsterTakesADoTBlow(t *testing.T) {
	hub := world.NewHub()
	monsters := newAIHub(68)
	sess := gateway.NewTestSession(66801)
	hub.Enter(sess, 1, "p", 1, "jangan", world.Position{X: cellX(0)})
	id := spawnAt(t, monsters, "jangan", cellX(0)+50, 0)
	a := newMonsterAI(hub, monsters, nil, MonsterAIConfig{Sleep: true}, rand.New(rand.NewSource(68)), (&pushRecorder{}).push)
	monsterAIRuntime.Store(a)
	t.Cleanup(func() { monsterAIRuntime.Store(nil) })
	now := aiT0
	a.tick(now)
	hub.Relocate(sess, world.Position{X: cellX(40)}, world.MoveRelocate, 0)
	for i := 0; i < 600; i++ { // until it is asleep, filed
		now = now.Add(MonsterAITick)
		a.tick(now)
		if _, filed := a.asleep[id]; filed {
			break
		}
	}
	if _, filed := a.asleep[id]; !filed || a.brains[id] != nil {
		t.Fatalf("setup: the monster left behind is not filed asleep (brain %v)", a.brains[id] != nil)
	}
	noteStruck(monsters, id, 1) // the DoT tick's struck event
	now = now.Add(MonsterAITick)
	a.tick(now)
	if b := a.brains[id]; b == nil || b.machine.State() != ai.StateBattle || b.target != 1 {
		t.Fatalf("the filed monster did not take the blow: brain %v", b != nil)
	}
	now = now.Add(MonsterAITick)
	a.tick(now)
	if a.brains[id] == nil || a.brains[id].seenTick != a.tickN {
		t.Fatal("the struck monster did not run the next pass")
	}
}

// countingSource is a rand.Source that counts its draws.
type countingSource struct {
	rand.Source
	n int
}

func (c *countingSource) Int63() int64 { c.n++; return c.Source.Int63() }

// LOW: a strike worker ends when its monster leaves BATTLE. A Mangyang chases
// Aria and swings; Aria then leaves the world, the monster lets go (0x23,
// target gone), and its worker is gone within a moment. Until this round the
// worker lived as long as the monster did.
func TestStrikeWorkerEndsWithTheFight(t *testing.T) {
	battleForTest(t, true)
	f := startBattleFixture(t, 66, 0, 0)
	m := f.monsters.SpawnSpecies("jangan", chaseMangyang, 8, 0, 0, 1000, 0, 15, 0)
	now := aiT0
	monsterAITick(now)
	now = now.Add(MonsterAITick)
	noteStruck(f.monsters, m.ID, f.aria)
	for i := 0; i < 5; i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
	}
	if !waitFor(t, 2*time.Second, func() bool { return len(f.rec.strikesOf(m.ID)) >= 1 }) {
		t.Fatal("setup: the monster never swung")
	}
	// The count is this runtime's own (monsterAI.workers), so no other
	// test's leftover worker can make this pass (round 666's review, L5).
	if n := f.a.workers.Load(); n != 1 {
		t.Fatalf("setup: %d strike workers running, want 1", n)
	}
	e, _ := f.hub.EntityByCharacterID(f.aria)
	f.hub.Leave(e.Session)
	monsterAITick(now)
	if st := stateOf(t, f.a, m.ID); st == ai.StateBattle {
		t.Fatalf("the monster is still in BATTLE with its target gone")
	}
	if !waitFor(t, 2*time.Second, func() bool { return f.a.workers.Load() == 0 }) {
		t.Fatalf("strike workers after the fight ended: %d, want 0 (the worker should end with the fight)", f.a.workers.Load())
	}
}

// LOW: a monster killed by a damage-over-time tick tells the nests of its
// killer's party, as a killing blow does. Aria (in a party with Bram, both
// beside the monster) bleeds a 100-HP monster to death; the observer is told
// of the kill with 2 members near. Until this round the tick's kill never
// called it, and a DoT kill could not arm a party monster.
func TestStatusTickKillArmsThePartyNest(t *testing.T) {
	fx := statusFXForTest(t)
	ctx := context.Background()
	z := startStrikeZone(t)
	parties := party.NewHub()
	if _, err := parties.Form(party.Member{Session: gateway.NewTestSession(66701), CharacterID: z.ariaChar, Name: "Aria", Level: 50},
		party.Member{Session: gateway.NewTestSession(66702), CharacterID: z.bramChar, Name: "Bram", Level: 50}, party.FlagExpShare); err != nil {
		t.Fatal(err)
	}
	k := z.monsters.SpawnSpecies("jangan", strikeMangyang, z.aria.x, 0, z.aria.z, 100, 0, 0, 1)
	deps := combatDeps{chars: z.chars, eq: z.eq, items: z.items, hub: z.hub, monsters: z.monsters,
		quests: quest.NewMemStore(), inv: z.inv, skills: skill.NewMemStore(), parties: parties}
	var told []int
	var toldID int64
	SetMonsterKillObserver(func(m combat.Monster, members int) { told, toldID = append(told, members), m.ID })
	t.Cleanup(func() { SetMonsterKillObserver(nil) })

	t0 := time.Now()
	fx.applyToMonster(deps, z.ariaChar, &refdata.Skill{ReqLearnSP: 1, ID: 9001, StatusParams: "bl:30000,100,1,200,0"}, k.ID, t0)
	fx.step(ctx, t0.Add(2001*time.Millisecond))
	if _, ok := z.monsters.Get(k.ID); ok {
		t.Fatal("setup: the 200 tick did not kill a 100-HP monster")
	}
	if len(told) != 1 || told[0] != 2 || toldID != k.ID {
		t.Fatalf("the kill observer was told %v (monster %d); want one kill of monster %d with 2 party members near", told, toldID, k.ID)
	}
}
