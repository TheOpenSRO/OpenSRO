package world

import (
	"math"
	"testing"
)

// Round 637's review follow-up: the character's heading, FUN_009ed130's rule
// in OpenSRO's frame (+z is heading 0, +x is pi/2), kept by a walk, left by
// a relocation, carried through a zone change.
func TestHeadingTowardIsTheClientsRule(t *testing.T) {
	cases := []struct {
		dx, dz, want float64
	}{
		{0, 1, 0}, {1, 0, math.Pi / 2}, {0, -1, math.Pi}, {-1, 0, 1.5 * math.Pi},
		{3, 3, math.Pi / 4}, {-2, 2, 1.75 * math.Pi},
	}
	for _, c := range cases {
		if got := HeadingToward(9, c.dx, c.dz); math.Abs(got-c.want) > 1e-9 {
			t.Errorf("HeadingToward(%v, %v) = %v, want %v", c.dx, c.dz, got, c.want)
		}
	}
	if got := HeadingToward(1.25, 5e-7, 5e-7); got != 1.25 {
		t.Errorf("a step of 1e-6 or less keeps the heading (FUN_009ed130's early return), got %v", got)
	}
}

func TestWireAngleIsTheHeadingLessAQuarterTurn(t *testing.T) {
	for _, c := range []struct{ h, want float64 }{
		{math.Pi / 2, 0}, {math.Pi, math.Pi / 2}, {0, 1.5 * math.Pi}, {1.5 * math.Pi, math.Pi},
	} {
		if got := WireAngle(c.h); math.Abs(got-c.want) > 1e-9 {
			t.Errorf("WireAngle(%v) = %v, want %v", c.h, got, c.want)
		}
	}
}

func TestMoveFacingTurnsAndMoveAndChangeZoneKeep(t *testing.T) {
	h := NewHub()
	s := fakeSession(1)
	h.Enter(s, 100, "Aria", 1, "jangan", Position{X: 10, Z: 10})
	e, _, _ := h.MoveFacing(s, Position{X: 20, Z: 10})
	if math.Abs(e.Heading-math.Pi/2) > 1e-9 {
		t.Fatalf("a walk toward +x faces pi/2, got %v", e.Heading)
	}
	e, _, _ = h.MoveFacing(s, Position{X: 20, Y: 5, Z: 10})
	if math.Abs(e.Heading-math.Pi/2) > 1e-9 {
		t.Fatalf("a step straight up has no ground heading and keeps pi/2, got %v", e.Heading)
	}
	e, _, _ = h.Move(s, Position{X: 20, Z: -500})
	if math.Abs(e.Heading-math.Pi/2) > 1e-9 {
		t.Fatalf("a relocation (Move) keeps the heading, got %v", e.Heading)
	}
	old, _, _, _ := h.ChangeZone(s, "donwhang", Position{})
	now, _ := h.EntityBySession(s.ID())
	if old.Heading != now.Heading || math.Abs(now.Heading-math.Pi/2) > 1e-9 {
		t.Fatalf("a zone change carries the heading, got %v -> %v", old.Heading, now.Heading)
	}
}
