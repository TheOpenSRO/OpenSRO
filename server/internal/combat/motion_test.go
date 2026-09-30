package combat

import (
	"math"
	"testing"
)

// FUN_0048bff0 clamps a step to 160.0f (0xb45ea8): 300 u/s for a whole
// second moves 160, not 300, and the leg is not over.
func TestMoverStepCapsAt160(t *testing.T) {
	x, z, arrived := MoverStep(0, 0, 1000, 0, 300, 1)
	if x != 160 || z != 0 || arrived {
		t.Fatalf("300 u/s x 1 s from (0,0) toward (1000,0): (%v, %v) arrived=%v; want (160, 0), still walking", x, z, arrived)
	}
	// The cap is on |speed x dt|, so a negative dt or speed steps the same.
	if x, _, _ := MoverStep(0, 0, 1000, 0, -300, 1); x != 160 {
		t.Errorf("|speed x dt| is the step: -300 u/s gave x = %v", x)
	}
	// Under the cap the step is speed x dt, along the line to the destination.
	x, z, arrived = MoverStep(0, 0, 30, 40, 22, 0.5) // 11 units toward (0.6, 0.8)
	if math.Abs(x-6.6) > 1e-9 || math.Abs(z-8.8) > 1e-9 || arrived {
		t.Errorf("22 u/s x 0.5 s toward (30,40): (%v, %v) arrived=%v; want (6.6, 8.8)", x, z, arrived)
	}
}

// NEGATIVE 1. A monster 3 units short of its destination, at Mangyang's 22 u/s
// run over a 0.2 s tick (a 4.4-unit step), must end ON the destination with
// Moving cleared. FUN_0048bff0 alone -- the step with only its 160 cap -- puts
// it 1.4 units beyond; the no-overshoot clamp in CGObjMoverByDest::vslot_003
// (0x48c4e0, fcompp at 0x48c622) is what stops it there.
func TestStepAllNeverOvershoots(t *testing.T) {
	h := NewHub()
	m := h.SpawnSpecies("jangan", Species{Name: "Mangyang", CodeName: "MOB_CH_MANGNYANG", WalkSpeed: 8, RunSpeed: 22}, 100, 0, -200, 54, 7, 18, 40)
	if _, ok := h.SetMotion(m.ID, 103, -200, 22, 1); !ok {
		t.Fatal("SetMotion refused a live monster")
	}
	h.StepCells(0.2, nil, nil)
	got, _ := h.Get(m.ID)
	if got.X != 103 || got.Z != -200 {
		t.Errorf("after a 4.4-unit step with 3 left: at (%v, %v); want exactly (103, -200) -- %.1f past it",
			got.X, got.Z, got.X-103)
	}
	if got.Moving {
		t.Error("a monster on its destination is still Moving")
	}
	// Arrived is final: another tick does not move it.
	h.StepCells(0.2, nil, nil)
	if again, _ := h.Get(m.ID); again.X != got.X || again.Z != got.Z {
		t.Errorf("an arrived monster moved on the next tick from (%v, %v) to (%v, %v)", got.X, got.Z, again.X, again.Z)
	}
}

// SetMotion returns the leg's origin and records the leg; StopMotion puts the
// destination on the monster and clears Moving, keeping speed and mode; both
// refuse an id the hub does not hold. SpawnSpecies seeds home and destination
// from the spawn point and carries the species' speeds.
func TestHubMotionAPI(t *testing.T) {
	h := NewHub()
	m := h.SpawnSpecies("jangan", Species{Name: "Mangyang", WalkSpeed: 8, RunSpeed: 22}, 100, 0, -200, 54, 7, 18, 40)
	if m.WalkSpeed != 8 || m.RunSpeed != 22 {
		t.Errorf("spawned speeds %v/%v; want 8/22", m.WalkSpeed, m.RunSpeed)
	}
	if m.HomeX != 100 || m.HomeZ != -200 || m.DestX != 100 || m.DestZ != -200 || m.Moving {
		t.Errorf("a fresh spawn: home (%v,%v) dest (%v,%v) moving=%v; want home and dest on (100,-200), standing",
			m.HomeX, m.HomeZ, m.DestX, m.DestZ, m.Moving)
	}

	if _, ok := h.SetMotion(424242, 0, 0, 8, 0); ok {
		t.Error("SetMotion on an unknown id must return false")
	}
	if _, ok := h.StopMotion(424242); ok {
		t.Error("StopMotion on an unknown id must return false")
	}

	origin, ok := h.SetMotion(m.ID, 140, -200, 8, 0)
	if !ok || origin.X != 100 || origin.Z != -200 || origin.DestX != 140 || origin.MoveSpeed != 8 || origin.MoveMode != 0 || !origin.Moving {
		t.Fatalf("SetMotion's copy: %+v ok=%v; want the leg from (100,-200) to (140,-200) at 8, mode 0", origin, ok)
	}
	h.StepCells(1, nil, nil) // 8 units along +x
	stopped, ok := h.StopMotion(m.ID)
	if !ok || stopped.X != 108 || stopped.DestX != 108 || stopped.DestZ != -200 || stopped.Moving {
		t.Errorf("StopMotion after one 8-unit step: %+v; want standing with dest on (108,-200)", stopped)
	}
	if stopped.MoveSpeed != 8 || stopped.MoveMode != 0 {
		t.Errorf("StopMotion changed the leg's speed/mode to %v/%v", stopped.MoveSpeed, stopped.MoveMode)
	}
	h.StepCells(1, nil, nil)
	if still, _ := h.Get(m.ID); still.X != 108 {
		t.Errorf("a stopped monster moved to x = %v", still.X)
	}
	if all := h.AppendAll(nil); len(all) != 1 || all[0].ID != m.ID {
		t.Errorf("All: %d monsters; want the one", len(all))
	}
}

// StepAll after ApplyDamage killed a moving monster neither panics nor brings
// it back: both hold h.mu, and the kill deletes it from the hub first.
func TestStepAllSkipsAMonsterKilledMidLeg(t *testing.T) {
	h := NewHub()
	m := h.SpawnSpecies("jangan", Species{Name: "Mangyang", RunSpeed: 22}, 0, 0, 0, 54, 7, 18, 40)
	other := h.SpawnSpecies("jangan", Species{Name: "Mangyang", RunSpeed: 22}, 50, 0, 0, 54, 7, 18, 40)
	h.SetMotion(m.ID, 100, 0, 22, 1)
	h.SetMotion(other.ID, 150, 0, 22, 1)
	if _, died, _ := h.ApplyDamage(m.ID, 1000); !died {
		t.Fatal("the blow should kill")
	}
	h.StepCells(0.5, nil, nil)
	if _, alive := h.Get(m.ID); alive {
		t.Error("StepAll brought a killed monster back")
	}
	if len(h.AppendAll(nil)) != 1 {
		t.Errorf("All lists %d monsters after the kill; want 1", len(h.AppendAll(nil)))
	}
	if o, _ := h.Get(other.ID); o.X != 61 {
		t.Errorf("the living monster should still step 11 units: x = %v", o.X)
	}
	if _, ok := h.SetMotion(m.ID, 0, 0, 8, 0); ok {
		t.Error("SetMotion on a killed monster must return false")
	}
}
