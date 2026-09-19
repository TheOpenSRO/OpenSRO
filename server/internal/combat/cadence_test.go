package combat

import (
	"testing"
	"time"
)

// TestCounterattackReadyHonoursTheSkillReuseDelay: a monster's blows are its
// attack skill's ReuseDelay apart (Mangyang: 3000 ms), a monster with no known
// delay is always ready, and a monster the hub does not know never is.
func TestCounterattackReadyHonoursTheSkillReuseDelay(t *testing.T) {
	h := NewHub()
	m := h.SpawnSpecies("jangan", Species{Name: "Mangyang", CodeName: "MOB_CH_MANGNYANG", Level: 1, AttackReuseMs: 3000}, 0, 0, 0, 54, 7, 18, 40)
	t0 := time.Date(2026, 9, 19, 16, 0, 0, 0, time.UTC)
	if !h.CounterattackReady(m.ID, t0) {
		t.Fatal("the first blow is always ready")
	}
	if h.CounterattackReady(m.ID, t0.Add(1*time.Second)) || h.CounterattackReady(m.ID, t0.Add(2999*time.Millisecond)) {
		t.Error("a second blow inside the 3000 ms re-use delay must wait")
	}
	if !h.CounterattackReady(m.ID, t0.Add(3*time.Second)) {
		t.Error("the blow at exactly ReuseDelay is ready")
	}
	if h.CounterattackReady(m.ID, t0.Add(4*time.Second)) {
		t.Error("the clock restarts from the blow that landed at 3 s")
	}
	free := h.SpawnSpecies("jangan", Species{Name: "Unknown", CodeName: "MOB_X"}, 0, 0, 0, 10, 1, 1, 1)
	for i := 0; i < 3; i++ {
		if !h.CounterattackReady(free.ID, t0.Add(time.Duration(i)*time.Millisecond)) {
			t.Error("a species with no known delay imposes none")
		}
	}
	if h.CounterattackReady(424242, t0) {
		t.Error("an unknown monster is never ready")
	}
}
