package session

import (
	"context"
	"math/rand"
	"sync"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

// Round 674: towns. READ (internal/safezone's package note): a monster whose
// region change takes it into a region whose _RefRegion IsBattleField is 0 is
// removed -- CGObjMob::SetCurRegion (0x4c1270) sets life state 3, no death --
// and its first placement is a region change too. Nothing else in the
// engine keeps it from a player in town.
//
// The geometry, in "jangan"'s frame (centred on region 97/168): region 97/168
// spans world z (-960, 960], and 96/168 -- the farmland south of the town --
// z (960, 2880]. The table is the test's own: 97/168 a town, 96/168 a field.

var (
	towns674  = [][2]int{{97, 168}}
	fields674 = [][2]int{{96, 168}}
)

// townFixture674 is Aria in jangan under a runtime that can swing at her, with
// every OpMonsterLeft the pass pushes recorded beside the recorder's moves and
// blows.
type townFixture674 struct {
	*battleFixture
	mu   sync.Mutex
	left []int64
}

func (f *townFixture674) leftIDs() []int64 {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]int64(nil), f.left...)
}

func startTownFixture674(t *testing.T, seed int64, ariaX, ariaZ float64) *townFixture674 {
	t.Helper()
	ctx := context.Background()
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("creating character: %v", err)
	}
	items := stubCombatItems{}
	inv := inventory.NewMemStore(items)
	eq := equipment.NewMemStore(inv)
	hub := world.NewHub()
	hub.Enter(gateway.NewTestSession(uint64(67400+seed)), c.ID, "Aria", 1, "jangan", world.Position{X: ariaX, Z: ariaZ})
	monsters := newAIHub(seed)
	monsters.LogDeaths(true)
	rec := &pushRecorder{}
	f := &townFixture674{}
	push := func(zone string, p *proto.Packet) {
		if p.Opcode == OpMonsterLeft {
			if l, err := DecodeMonsterLeft(p.Data); err == nil {
				f.mu.Lock()
				f.left = append(f.left, l.IDs...)
				f.mu.Unlock()
			}
		}
		rec.push(zone, p)
	}
	potions := NewPotionQueue()
	a := newMonsterAI(hub, monsters, nil, MonsterAIConfig{Chars: chars, Equipment: eq, Items: items, Potions: potions},
		rand.New(rand.NewSource(seed)), push)
	monsterAIRuntime.Store(a)
	t.Cleanup(func() { monsterAIRuntime.Store(nil) })
	f.battleFixture = &battleFixture{a: a, hub: hub, monsters: monsters, chars: chars, aria: c.ID, rec: rec, potions: potions}
	return f
}

func (f *townFixture674) hasBrain(id int64) bool {
	f.a.mu.Lock()
	defer f.a.mu.Unlock()
	_, ok := f.a.brains[id]
	return ok
}

// THE RED: Aria stands in the town, 60 units inside its line (z 900); a
// Mangyang she struck stands in the field at z 1060. It chases her -- the
// band's stop point is 10 units from her, inside the town -- and the pass
// that carries it over z 960 removes it: gone from the hub, no brain, an
// OpMonsterLeft to the players who could see it, the loss on the death log
// the nest scheduler reads, and not one blow on Aria, whose HP is untouched.
// Before this round it walked in and swung at her (the user's report: "I had
// a mob follow me into town and attack me").
func TestMonsterChasingIntoTownIsRemovedAtTheLine(t *testing.T) {
	battleForTest(t, true)
	installTowns674(t, towns674, fields674)
	f := startTownFixture674(t, 1, 0, 900)
	m := f.monsters.SpawnSpecies("jangan", chaseMangyang, 0, 0, 1060, 1000, 0, 15, 0)
	now := aiT0
	monsterAITick(now) // the brain hatches into IDLE: it stands in the field
	now = now.Add(MonsterAITick)
	if !f.monsters.Exists(m.ID) || !f.hasBrain(m.ID) {
		t.Fatal("setup: the monster in the field (z 1060, region 96/168) is gone or has no brain after its first pass")
	}
	noteStruck(f.monsters, m.ID, f.aria)

	crossedAt := -1.0
	for i := 0; i < 200 && f.monsters.Exists(m.ID); i++ {
		if cur, ok := f.monsters.Get(m.ID); ok {
			crossedAt = cur.Z
		}
		monsterAITick(now)
		now = now.Add(MonsterAITick)
	}
	if cur, ok := f.monsters.Get(m.ID); ok {
		t.Errorf("the monster chased Aria into the town and is still there at (%.1f, %.1f), moving %v: the town's line at z 960 removed nothing", cur.X, cur.Z, cur.Moving)
	} else if crossedAt < 960 || crossedAt > 960+2*chaseMangyang.RunSpeed*MonsterAITick.Seconds()+1e-9 {
		t.Errorf("the monster was last seen at z %.2f before it went: want it on the field side, within a tick's step of the line at 960", crossedAt)
	}
	monsterAITick(now) // the pass after: nothing to run
	if f.hasBrain(m.ID) {
		t.Error("the removed monster still has a brain")
	}
	if got := f.leftIDs(); len(got) != 1 || got[0] != m.ID {
		t.Errorf("OpMonsterLeft named %v, want exactly the removed monster %d once", got, m.ID)
	}
	if deaths := f.monsters.DrainDeaths(nil); len(deaths) != 1 || deaths[0] != m.ID {
		t.Errorf("the death log holds %v, want the removed monster %d (the nest scheduler's only signal of a lost hatch)", deaths, m.ID)
	}
	time.Sleep(30 * time.Millisecond) // a strike worker would have pushed by now
	if s := f.rec.strikesOf(m.ID); len(s) != 0 {
		t.Errorf("%d blow(s) on Aria standing in the town: %+v", len(s), s)
	}
	if c, err := f.chars.GetByID(context.Background(), f.aria); err != nil || c.HP != character.StartingMaxHP {
		t.Errorf("Aria's HP %d (err %v), want %d untouched", c.HP, err, character.StartingMaxHP)
	}
}

// A monster placed in a town -- hatched or GM-spawned there -- is removed on
// the first pass that meets it, before it gets a brain: its placement is a
// region change (CGObj::EnterWorld -> MoveTo -> SetCurRegion, READ).
func TestMonsterPlacedInTownIsRemovedOnItsFirstPass(t *testing.T) {
	battleForTest(t, true)
	installTowns674(t, towns674, fields674)
	f := startTownFixture674(t, 2, 300, 300)
	m := f.monsters.SpawnSpecies("jangan", chaseMangyang, 0, 0, 0, 1000, 0, 15, 0)
	monsterAITick(aiT0)
	if f.monsters.Exists(m.ID) {
		t.Fatal("a monster standing in the town (0, 0, region 97/168) is still in the hub after its first pass")
	}
	if f.hasBrain(m.ID) {
		t.Error("the monster placed in the town was given a brain")
	}
	if got := f.leftIDs(); len(got) != 1 || got[0] != m.ID {
		t.Errorf("OpMonsterLeft named %v, want the monster %d", got, m.ID)
	}
	if deaths := f.monsters.DrainDeaths(nil); len(deaths) != 1 || deaths[0] != m.ID {
		t.Errorf("the death log holds %v, want the removed monster %d", deaths, m.ID)
	}
}

// CONTROL: a monster in the field, with the table installed, keeps its place
// and its brain, wandering where it likes on the field side.
func TestMonsterInTheFieldIsLeftAlone(t *testing.T) {
	installTowns674(t, towns674, fields674)
	f := startTownFixture674(t, 3, 0, 900)
	m := f.monsters.SpawnSpecies("jangan", chaseMangyang, 0, 0, 1500, 1000, 0, 15, 0)
	now := aiT0
	for i := 0; i < 100; i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
	}
	if !f.monsters.Exists(m.ID) || !f.hasBrain(m.ID) {
		t.Fatal("a monster in the field (z 1500, region 96/168) was removed")
	}
	if got := f.leftIDs(); len(got) != 0 {
		t.Errorf("OpMonsterLeft named %v for a monster that never left the field", got)
	}
}

// READ, not a protection: nothing in the engine tests the TARGET's region
// (CGObjMob slot 394 0x529110, the AI's 0x540de0 and 0x5464e0). A monster
// that stops on the field side of the line, its band reaching a player who
// stands just inside the town, swings at her and hits.
func TestMonsterAtTheTownEdgeStillReachesAPlayerJustInside(t *testing.T) {
	battleForTest(t, true)
	installTowns674(t, towns674, fields674)
	f := startTownFixture674(t, 4, 0, 955)
	// The band's stop point is 10 from Aria: z 965, on the field side.
	m := f.monsters.SpawnSpecies("jangan", chaseMangyang, 0, 0, 1000, 1000, 0, 15, 0)
	now := aiT0
	monsterAITick(now)
	now = now.Add(MonsterAITick)
	noteStruck(f.monsters, m.ID, f.aria)
	for i := 0; i < 60; i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
	}
	if !f.monsters.Exists(m.ID) {
		t.Fatal("the monster stopping at z 965, on the field side, was removed")
	}
	if !waitFor(t, 2*time.Second, func() bool { return len(f.rec.strikesOf(m.ID)) >= 1 }) {
		t.Fatal("the monster on the field side never hit Aria standing 5 units inside the town: the engine tests no target region")
	}
}
