package session

import (
	"math/rand"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
)

// Round 880: a swing blocks the monster's AI for D + rand % D ms, D the swung
// skill's action time (swingHold; READ s:0x5a1a40, s:0x558f70, s:0x53d600).
// MEASURED: monsters whose skills have an action time of 2000 ms and a
// ReuseDelay of 2500 ms swung 2.11 .. 4.03 s apart, 3.15 s on average.
func TestSwingHoldIsTheActionTimeAndAsMuchAgainAtRandom(t *testing.T) {
	sk := combat.MonsterSkill{ID: 880301, ReuseMs: 2500, ActionMs: 2000, HoldMs: 2000}
	// The randomness off (a test's default): the hold's lower end.
	if got := swingHold(sk); got != 2000 {
		t.Fatalf("hold with the randomness off = %d, want 2000", got)
	}
	// A hand-typed row without a hold base holds for its ReuseDelay.
	if got := swingHold(combat.MonsterSkill{ID: 160, ReuseMs: 3000}); got != 3000 {
		t.Fatalf("hold of a row with no hold base = %d, want its ReuseDelay 3000", got)
	}
	damageRollMu.Lock()
	damageRollNG = rand.New(rand.NewSource(880))
	damageRollMu.Unlock()
	t.Cleanup(func() { damageRollMu.Lock(); damageRollNG = nil; damageRollMu.Unlock() })
	lo, hi, sum := 1<<30, 0, 0
	const n = 20000
	for i := 0; i < n; i++ {
		h := swingHold(sk)
		lo, hi, sum = min(lo, h), max(hi, h), sum+h
	}
	if lo < 2000 || hi > 3999 || lo > 2010 || hi < 3990 {
		t.Errorf("holds ran %d..%d, want the whole of 2000..3999", lo, hi)
	}
	if mean := float64(sum) / n; mean < 2970 || mean > 3030 {
		t.Errorf("mean hold %.0f ms, want about 3000", mean)
	}
}

// The battle tick swings again only once the hold has run: with the randomness
// off, D after the swing -- the action time, not the ReuseDelay.
func TestMonsterSwingsAgainWhenItsHoldEnds(t *testing.T) {
	battleForTest(t, true)
	f := startBattleFixture(t, 880, 0, 0)
	sp := chaseMangyang
	sp.Skills = []combat.MonsterSkill{{ID: 880302, ReuseMs: 2500, Range: 10, AttMin: 15, AttMax: 15, Chance: 100, ActionMs: 2000, HoldMs: 2000}}
	m := f.monsters.SpawnSpecies("jangan", sp, 10, 0, 0, 1000, 0, 15, 0)
	now := aiT0
	monsterAITick(now)
	now = now.Add(MonsterAITick)
	noteStruck(f.monsters, m.ID, f.aria)
	f.rec.reset()
	monsterAITick(now) // BATTLE, in reach: the first swing at once
	if !waitFor(t, 2*time.Second, func() bool { return len(f.rec.strikesOf(m.ID)) == 1 }) {
		t.Fatalf("no first swing (%d)", len(f.rec.strikesOf(m.ID)))
	}
	// 1.9 s later: still held.
	for i := 0; i < 19; i++ {
		now = now.Add(MonsterAITick)
		monsterAITick(now)
	}
	time.Sleep(50 * time.Millisecond)
	if n := len(f.rec.strikesOf(m.ID)); n != 1 {
		t.Fatalf("%d swings 1.9 s after the first, want it held for its 2000 ms", n)
	}
	// The 20th pass, 2000 ms after the swing: the next one, 500 ms before the
	// ReuseDelay would have allowed it.
	now = now.Add(MonsterAITick)
	monsterAITick(now)
	if !waitFor(t, 2*time.Second, func() bool { return len(f.rec.strikesOf(m.ID)) == 2 }) {
		t.Fatalf("no second swing 2000 ms after the first (%d pushed)", len(f.rec.strikesOf(m.ID)))
	}
}
