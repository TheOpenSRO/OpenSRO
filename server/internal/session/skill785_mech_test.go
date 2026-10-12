package session

import (
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
	"github.com/OpenSRO/OpenSRO/server/internal/statuseffect"
)

// TestChainTiming pins the skill tick's budget rule (READ 0x4aec2d..
// 0x4aed02): 500 ms are spent on the first durations, the rest carried to
// the last link's hand-off.
func TestChainTiming(t *testing.T) {
	rows := []*refdata.Skill{{ActionDurationMs: 300}, {ActionDurationMs: 400}, {ActionDurationMs: 900}}
	posts, handOff := chainTiming(rows)
	// head 300 <= 500: wait 0, budget 200; link1 400 > 200: wait 200, carry 200.
	if len(posts) != 2 || posts[0] != 0 || posts[1] != 200 || handOff != 200+900+200 {
		t.Fatalf("posts %v handOff %d", posts, handOff)
	}
	// A CastingTime longer than the wait holds the next link.
	rows = []*refdata.Skill{{CastingTimeMs: 700, ActionDurationMs: 100}, {ActionDurationMs: 100}}
	if posts, _ := chainTiming(rows); posts[0] != 700 {
		t.Fatalf("posts %v", posts)
	}
}

// TestKnockdownChance is FUN_0040fcb0 (READ): ko [19 50] is 50 % on a
// level-19 target, capped at 75.
func TestKnockdownChance(t *testing.T) {
	if c := knockdownChance(19, 50, 19); c != 50 {
		t.Fatalf("got %d", c)
	}
	if c := knockdownChance(19, 200, 1); c != 75 {
		t.Fatalf("cap: %d", c)
	}
	if c := knockdownChance(19, 50, 100); c != 16 {
		t.Fatalf("high level: %d", c)
	}
}

// TestKnockFlagsFallback: data without the column takes 3 / 3000; a
// Knockdown with KO_RecoverTime 0 is 3000 (the loader's rule, READ).
func TestKnockFlagsFallback(t *testing.T) {
	if f, r := knockFlags(combat.Monster{}); f != 3 || r != 3000 {
		t.Fatalf("%d %d", f, r)
	}
	if f, r := knockFlags(combat.Monster{HasKnockdown: true, Knockdown: 2}); f != 2 || r != 3000 {
		t.Fatalf("%d %d", f, r)
	}
	if f, _ := knockFlags(combat.Monster{HasKnockdown: true}); f != 0 {
		t.Fatalf("immune: %d", f)
	}
}

// TestCureRule: curl ends a state at its chance; a level above curl[2]
// divides it; curt winds an elemental state's clock back.
func TestCureRule(t *testing.T) {
	var h statuseffect.Holder
	h.Put(statuseffect.Record{Code: "st", Slot: 20, Level: 5, StartMs: 1000, DurationMs: 60000})
	h.Put(statuseffect.Record{Code: "bu", Slot: statuseffect.SlotBurn, StartMs: 1000, DurationMs: 3000})
	seen := 0
	roll := func(chance int) bool { seen = chance; return chance >= 50 }
	h.Cure(statuseffect.CureRule{HasCurl: true, CurlMask: statuseffect.MaskForSlot(20), CurlChance: 100, CurlLevel: 1}, 2000, roll, nil)
	if seen != 25 || !h.Holds(20) {
		t.Fatalf("level 5 over curl level 1: chance %d (want 100/4), held %v", seen, h.Holds(20))
	}
	h.Cure(statuseffect.CureRule{HasCurt: true, CurtMask: statuseffect.MaskForSlot(statuseffect.SlotBurn), CurtStrength: 4}, 2000, roll, nil)
	if h.Holds(statuseffect.SlotBurn) {
		t.Fatal("4 x 750 ms back past a 3 s burn should end it")
	}
}

// TestLfstDamage: the drain's level penalty and its cap at the HP left.
func TestLfstDamage(t *testing.T) {
	c := &castContext{level: 10, row: &refdata.Skill{ParamWords: words(0, run("lfst", 200))}}
	if d, ok := c.lfstDamage(combat.Monster{Level: 10, HP: 1000}, 0, 100); !ok || d != 200 {
		t.Fatalf("%d %v", d, ok)
	}
	if d, _ := c.lfstDamage(combat.Monster{Level: 14, HP: 1000}, 0, 100); d != 180 {
		t.Fatalf("4 levels over: %d", d)
	}
	if d, _ := c.lfstDamage(combat.Monster{Level: 10, HP: 150}, 0, 100); d != 150 {
		t.Fatalf("capped: %d", d)
	}
}
