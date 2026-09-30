package session

import (
	"context"
	"math/rand"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/ai"
	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/party"
	"github.com/OpenSRO/srrevamp/server/internal/quest"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
	"github.com/OpenSRO/srrevamp/server/internal/skill"
	"github.com/OpenSRO/srrevamp/server/internal/world"
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
		hub.Move(sess, world.Position{X: cellX(4 * k)})
		run(100)
	}
	hub.Move(sess, world.Position{X: cellX(0)})
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
		hub.Move(sess, world.Position{X: cellX(4 * k)})
		run(1)
		a.mu.Lock()
		b := a.brains[ids[k]]
		a.mu.Unlock()
		if b == nil {
			t.Fatalf("monster %d did not wake when the player came back", ids[k])
		}
	}
}

// M4: a woken brain carries on as it slept. Every field brainMemory files
// comes back, the machine resumes in the state it slept in without a new
// dwell, and nothing is re-rolled: the rng draws nothing on the wake.
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
	b.aggressive = !b.aggressive // a value the roll did not give, so a re-roll would show
	b.scanDueAt = aiT0.Add(700 * time.Millisecond)
	b.lastSwing, b.swungReuseMs = aiT0.Add(-time.Second), 3000
	b.giveUpDueAt = aiT0.Add(2 * time.Second)
	b.damageTaken, b.lastHP, b.hpSeen = 1234, 17, true
	b.trigFired, b.trigLast = []bool{true, false}, []time.Time{aiT0, {}}
	want := b.memory()

	a.now = aiT0.Add(time.Hour)
	draws := src.n
	got := a.wake(*m, want)
	if got.machine.State() != want.state || got.enteredAt != want.enteredAt || got.dwellMs != want.dwellMs {
		t.Fatalf("woke in %v entered %v dwell %d; want %v entered %v dwell %d (resumed, not re-entered)",
			got.machine.State(), got.enteredAt, got.dwellMs, want.state, want.enteredAt, want.dwellMs)
	}
	back := got.memory()
	if back.heading != want.heading || back.target != want.target || back.aggressive != want.aggressive ||
		back.scanPeriodMs != want.scanPeriodMs || back.scanDueAt != want.scanDueAt || back.rolled != want.rolled ||
		back.lastSwing != want.lastSwing || back.swungReuseMs != want.swungReuseMs || back.giveUpDueAt != want.giveUpDueAt ||
		back.damageTaken != want.damageTaken || back.lastHP != want.lastHP || back.hpSeen != want.hpSeen ||
		len(back.trigFired) != 2 || !back.trigFired[0] || back.trigLast[0] != aiT0 ||
		back.homingDestX != want.homingDestX || back.homingDestZ != want.homingDestZ || back.homingBlackoutMs != want.homingBlackoutMs {
		t.Fatalf("woken brain %+v\nfiled         %+v", back, want)
	}
	if got.detection != b.detection || got.giveUp != b.giveUp || got.roamRadius != b.roamRadius || got.roamRule != b.roamRule {
		t.Fatalf("the rebuilt tactics differ: detection %v/%v give-up %v/%v roam %v/%v rule %d/%d",
			got.detection, b.detection, got.giveUp, b.giveUp, got.roamRadius, b.roamRadius, got.roamRule, b.roamRule)
	}
	if src.n != draws {
		t.Fatalf("the wake drew %d number(s) from the rng; it must re-roll nothing", src.n-draws)
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
	hub.Move(sess, world.Position{X: cellX(40)})
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

// strikeWorkers counts the live strike-worker goroutines.
func strikeWorkers() int {
	buf := make([]byte, 1<<20)
	for {
		n := runtime.Stack(buf, true)
		if n < len(buf) {
			return strings.Count(string(buf[:n]), "session.(*monsterAI).strikeWorker(")
		}
		buf = make([]byte, 2*len(buf))
	}
}

// LOW: a strike worker ends when its monster leaves BATTLE. A Mangyang chases
// Aria and swings; Aria then leaves the world, the monster lets go (0x23,
// target gone), and its worker is gone within a moment. Until this round the
// worker lived as long as the monster did.
func TestStrikeWorkerEndsWithTheFight(t *testing.T) {
	battleForTest(t, true)
	before := strikeWorkers()
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
	if n := strikeWorkers() - before; n < 1 {
		t.Fatalf("setup: %d strike workers running beyond the %d before the test, want 1", n, before)
	}
	e, _ := f.hub.EntityByCharacterID(f.aria)
	f.hub.Leave(e.Session)
	monsterAITick(now)
	if st := stateOf(t, f.a, m.ID); st == ai.StateBattle {
		t.Fatalf("the monster is still in BATTLE with its target gone")
	}
	if !waitFor(t, 2*time.Second, func() bool { return strikeWorkers() <= before }) {
		t.Fatalf("strike workers after the fight ended: %d, want %d (the worker should end with the fight)", strikeWorkers(), before)
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
	p, err := parties.Create(party.Member{Session: gateway.NewTestSession(66701), CharacterID: z.ariaChar, Name: "Aria", Level: 50})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := parties.Join(p.ID, party.Member{Session: gateway.NewTestSession(66702), CharacterID: z.bramChar, Name: "Bram", Level: 50}); err != nil {
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
	fx.applyToMonster(deps, z.ariaChar, &refdata.Skill{ID: 9001, StatusParams: "bl:30000,100,1,200,0"}, k.ID, t0)
	fx.step(ctx, t0.Add(2001*time.Millisecond))
	if _, ok := z.monsters.Get(k.ID); ok {
		t.Fatal("setup: the 200 tick did not kill a 100-HP monster")
	}
	if len(told) != 1 || told[0] != 2 || toldID != k.ID {
		t.Fatalf("the kill observer was told %v (monster %d); want one kill of monster %d with 2 party members near", told, toldID, k.ID)
	}
}
