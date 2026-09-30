package session

import (
	"bytes"
	"context"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/quest"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
	"github.com/OpenSRO/srrevamp/server/internal/skill"
	"github.com/OpenSRO/srrevamp/server/internal/statuseffect"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

// Round 659: monsters give and receive status effects. The skill rows here
// are SYNTHETIC, shaped like the real ones the round measured (a bleeding is
// bl:duration,chance,level,damage,defence; a poison ps:strength,chance,damage),
// each with a chance of 100 so the dice never decide a test.

// statusFXForTest gives the test a runtime of its own and puts the process's
// back when it ends, so no state leaks into another test's monster list.
func statusFXForTest(t *testing.T) *statusRuntime {
	t.Helper()
	statusFX.resetForTest()
	t.Cleanup(statusFX.resetForTest)
	return statusFX
}

// resetForTest empties the runtime in place (the pointer is read by other
// goroutines, so it is never swapped).
func (s *statusRuntime) resetForTest() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.mobs = map[int64]*statuseffect.Holder{}
	s.pcs = map[int64]*statuseffect.Holder{}
	s.cdeps, s.sdeps, s.stats = combatDeps{}, strikeDeps{}, RegenDeps{}
}

// statusesIn decodes the OpObjectStatus packets among pkts.
func statusesIn(t *testing.T, pkts []*proto.Packet) []*ObjectStatus {
	t.Helper()
	var out []*ObjectStatus
	for _, p := range pkts {
		if p.Opcode != OpObjectStatus {
			continue
		}
		m, err := DecodeObjectStatus(p.Data)
		if err != nil {
			t.Fatalf("DecodeObjectStatus: %v", err)
		}
		out = append(out, m)
	}
	return out
}

func opcodeCount(pkts []*proto.Packet, op uint16) int {
	n := 0
	for _, p := range pkts {
		if p.Opcode == op {
			n++
		}
	}
	return n
}

// The wire, byte for byte, as the client's fixture has it
// (client/scripts/net/status_net_test.gd): monster 7 stunned at level 3 and
// poisoned. The poison bit (0x10) carries no level byte; stun (0x4000) does.
var objectStatusFixture = []byte{0x01, 0x07, 0, 0, 0, 0, 0, 0, 0, 0x00, 0x00, 0x04, 0x10, 0x40, 0x00, 0x00, 0x03}

func TestObjectStatusMatchesTheClientFixture(t *testing.T) {
	m := &ObjectStatus{OwnerKind: OwnerMonster, OwnerID: 7, Mask: 0x4010, Levels: []byte{3}}
	if got := m.Encode(); !bytes.Equal(got, objectStatusFixture) {
		t.Fatalf("ObjectStatus.Encode:\n got % x\nwant % x", got, objectStatusFixture)
	}
	back, err := DecodeObjectStatus(objectStatusFixture)
	if err != nil || back.OwnerID != 7 || back.Mask != 0x4010 || len(back.Levels) != 1 || back.Levels[0] != 3 {
		t.Fatalf("round trip %+v, %v", back, err)
	}
	if OpObjectStatus != 0x3057 {
		t.Errorf("OpObjectStatus = %#04x, want retail's 0x3057", OpObjectStatus)
	}
}

// RECEIVE, and a kill by a tick. Aria's bleeding lands on a 300-HP monster
// and ticks 200 once MORE than 2000 ms have passed: the first tick leaves 100
// and tells the zone; the second kills it -- credited to Aria, who is paid
// the kill's gold ONCE and is told of the death with everyone else -- and the
// states end with the monster. A third pass pays nothing more.
func TestStatusDoTKillPaysTheKillerOnce(t *testing.T) {
	fx := statusFXForTest(t)
	ctx := context.Background()
	z := startStrikeZone(t)
	const gold = 77
	k := z.monsters.SpawnSpecies("jangan", strikeMangyang, z.aria.x, 0, z.aria.z, 300, 0, 0, gold)
	deps := combatDeps{chars: z.chars, eq: z.eq, items: z.items, hub: z.hub, monsters: z.monsters,
		quests: quest.NewMemStore(), inv: z.inv, skills: skill.NewMemStore()}
	bleed := &refdata.Skill{ID: 9001, StatusParams: "bl:30000,100,1,200,0"}

	t0 := time.Now()
	fx.applyToMonster(deps, z.ariaChar, bleed, k.ID, t0)
	for _, c := range []*strikeClient{z.aria, z.bram} {
		got := statusesIn(t, c.barrier(t))
		if len(got) != 1 || got[0].OwnerKind != OwnerMonster || got[0].OwnerID != k.ID || got[0].Mask != 0x800 ||
			len(got[0].Levels) != 1 || got[0].Levels[0] != 1 {
			t.Fatalf("%s was told %+v; want monster %d's mask 0x800 (bleeding) with level 1", c.name, got, k.ID)
		}
		c.readUntil(t, OpObjectStatus, time.Second) // the list's own copy of the mask
	}
	before, _ := z.chars.GetByID(ctx, z.ariaChar)

	fx.step(ctx, t0.Add(2000*time.Millisecond))
	if m, _ := z.monsters.Get(k.ID); m.HP != 300 {
		t.Fatalf("a bleeding ticked at exactly its interval (HP %d)", m.HP)
	}
	fx.step(ctx, t0.Add(2001*time.Millisecond))
	if m, ok := z.monsters.Get(k.ID); !ok || m.HP != 100 {
		t.Fatalf("after the first tick: HP %d (alive %v), want 100", m.HP, ok)
	}
	fx.step(ctx, t0.Add(4002*time.Millisecond))
	if _, ok := z.monsters.Get(k.ID); ok {
		t.Fatal("the second 200 did not kill a 100-HP monster")
	}
	fx.step(ctx, t0.Add(6003*time.Millisecond))

	after, _ := z.chars.GetByID(ctx, z.ariaChar)
	if after.Gold-before.Gold != gold {
		t.Errorf("Aria's gold rose by %d, want the kill's %d exactly once", after.Gold-before.Gold, gold)
	}
	for _, c := range []*strikeClient{z.aria, z.bram} {
		pkts := c.barrier(t)
		if n := opcodeCount(pkts, OpMonsterDamaged); n != 1 {
			t.Errorf("%s was sent %d OpMonsterDamaged, want the first tick's one", c.name, n)
		}
		if n := opcodeCount(pkts, OpMonsterDied); n != 1 {
			t.Errorf("%s was sent %d OpMonsterDied, want one -- the killer too: no attack result tells her", c.name, n)
		}
	}
	fx.mu.Lock()
	_, held := fx.mobs[k.ID]
	fx.mu.Unlock()
	if held {
		t.Error("the dead monster's states outlived it")
	}
}

// A stunned monster does not strike back: the synchronous counter (the
// -monster-battle off path) is skipped while the stun holds, and lands again
// once it has gone.
func TestStatusStunnedMonsterDoesNotCounter(t *testing.T) {
	fx := statusFXForTest(t)
	z := startStrikeZone(t)
	k := z.monsters.SpawnSpecies("jangan", strikeMangyang, z.aria.x, 0, z.aria.z, 100000, 0, 15, 0)
	stun, ok := statuseffect.Resolve(statuseffect.Run{Code: "st", Values: []int{60000, 100, 2}}, statuseffect.Target{Level: 1}, fx.ms(time.Now()), func(int, int) bool { return true })
	if !ok {
		t.Fatal("the stun did not resolve")
	}
	h := &statuseffect.Holder{}
	h.Put(stun)
	fx.mu.Lock()
	fx.mobs[k.ID] = h
	fx.mu.Unlock()

	res, _ := z.aria.attack(t, k.ID)
	z.aria.readUntil(t, OpObjectStatus, time.Second) // the barrier's list names the stunned monster
	if res.PlayerDamageTaken != 0 || res.MonsterCritical {
		t.Errorf("a stunned monster countered: %+v", res)
	}
	fx.forgetMonster(k.ID)
	time.Sleep(time.Duration(strikeMangyang.AttackReuseMs+50) * time.Millisecond)
	if res, _ := z.aria.attack(t, k.ID); res.PlayerDamageTaken != 15 {
		t.Errorf("the stun gone, the counter %+v; want its 15", res)
	}
}

// A stunned monster in BATTLE, in reach of its target, neither swings nor
// walks under the AI; the stun gone, it swings. (-monster-battle on.)
func TestStatusStunnedMonsterNeitherMovesNorStrikes(t *testing.T) {
	fx := statusFXForTest(t)
	battleForTest(t, true)
	f := startBattleFixture(t, 25, 0, 0)
	m := f.monsters.SpawnSpecies("jangan", chaseMangyang, 8, 0, 0, 100000, 0, 100000, 0)
	stun, _ := statuseffect.Resolve(statuseffect.Run{Code: "st", Values: []int{60000, 100, 2}}, statuseffect.Target{Level: 1}, fx.ms(time.Now()), func(int, int) bool { return true })
	h := &statuseffect.Holder{}
	h.Put(stun)
	fx.mu.Lock()
	fx.mobs[m.ID] = h
	fx.mu.Unlock()

	now := aiT0
	monsterAITick(now)
	now = now.Add(MonsterAITick)
	noteStruck(f.monsters, m.ID, f.aria)
	f.rec.reset()
	for i := 0; i < 40; i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
	}
	time.Sleep(100 * time.Millisecond)
	if n := len(f.rec.strikesOf(m.ID)); n != 0 {
		t.Errorf("a stunned monster swung %d times", n)
	}
	for _, mv := range f.rec.of(m.ID) {
		if mv.DestX != mv.X || mv.DestZ != mv.Z {
			t.Errorf("a stunned monster started a leg %+v", mv)
		}
	}
	if got, _ := f.monsters.Get(m.ID); got.X != 8 || got.Z != 0 {
		t.Errorf("a stunned monster moved to (%.1f, %.1f)", got.X, got.Z)
	}

	fx.forgetMonster(m.ID)
	monsterAITick(now)
	if !waitFor(t, 2*time.Second, func() bool { return len(f.rec.strikesOf(m.ID)) >= 1 }) {
		t.Error("the stun gone, the monster in reach did not swing")
	}
}

// GIVE. A monster's zero-damage skill carrying a poison lands it on the
// player (MSKILL_CH_WATERGHOST_ATTACK02's shape): the zone is told her mask,
// the poison takes its 16 a tick, stops at 1 HP, and a dead player takes
// nothing.
func TestMonsterSkillPoisonsThePlayer(t *testing.T) {
	fx := statusFXForTest(t)
	ctx := context.Background()
	z := startStrikeZone(t)
	k := z.monsters.SpawnSpecies("jangan", strikeMangyang, z.aria.x, 0, z.aria.z, 1000, 0, 0, 0)
	bite := combat.MonsterSkill{ID: 169, AttMin: 0, AttMax: 0, Status: "ps:34,100,16"}
	deps := strikeDeps{chars: z.chars, eq: z.eq, items: z.items, hub: z.hub}

	t0 := time.Now()
	if _, err := monsterStrike(ctx, deps, *k, bite, z.ariaChar, 1); err != nil {
		t.Fatal(err)
	}
	got := statusesIn(t, z.bram.barrier(t))
	if len(got) != 1 || got[0].OwnerKind != OwnerCharacter || got[0].OwnerID != z.ariaChar || got[0].Mask != 0x10 || len(got[0].Levels) != 0 {
		t.Fatalf("Bram was told %+v; want Aria's mask 0x10 (poison), no level byte", got)
	}
	z.bram.readUntil(t, OpObjectStatus, time.Second) // the list's copy of Aria's mask
	start, _ := z.chars.GetByID(ctx, z.ariaChar)

	fx.step(ctx, t0.Add(2100*time.Millisecond))
	c, _ := z.chars.GetByID(ctx, z.ariaChar)
	if start.HP-c.HP != 16 {
		t.Fatalf("one poison tick took %d, want 16", start.HP-c.HP)
	}
	if _, pkt := z.aria.readUntil(t, OpCharacterStatsResult, time.Second); pkt == nil {
		t.Error("Aria's bar was not told of the tick (no stats push)")
	}
	// Down to 10: the next tick leaves 1, the one after nothing.
	z.chars.ApplyDamage(ctx, z.ariaChar, c.HP-10)
	fx.step(ctx, t0.Add(4200*time.Millisecond))
	fx.step(ctx, t0.Add(6300*time.Millisecond))
	if c, _ = z.chars.GetByID(ctx, z.ariaChar); c.HP != 1 {
		t.Errorf("poison left Aria on %d HP, want 1 -- it never kills", c.HP)
	}

	// A dead character is never afflicted.
	fx.forgetCharacterForTest(z.bramChar)
	z.hub.SetLifeState(z.bramChar, world.LifeAlive, world.LifeDead, time.Now())
	fx.applyToCharacter(ctx, deps, *k, bite, z.bramChar)
	fx.mu.Lock()
	_, held := fx.pcs[z.bramChar]
	fx.mu.Unlock()
	if held {
		t.Error("a dead character was poisoned")
	}
}

// forgetCharacterForTest drops a character's states without a push.
func (s *statusRuntime) forgetCharacterForTest(id int64) {
	s.mu.Lock()
	delete(s.pcs, id)
	s.mu.Unlock()
}
