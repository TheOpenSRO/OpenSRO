package berserk

import "testing"

func TestFillCapsAndActivates(t *testing.T) {
	tr := NewTracker()
	const id = int64(1)

	// Fills by FillPerHit, capped at Max.
	got := 0
	for i := 0; i < 100; i++ {
		got = tr.Fill(id)
	}
	if got != Max {
		t.Fatalf("gauge capped at %d, got %d", Max, got)
	}

	// Not active until activated; activation needs a full gauge.
	if tr.Active(id) {
		t.Fatal("should not be active before activation")
	}
	if !tr.Activate(id) {
		t.Fatal("a full gauge should activate")
	}
	if tr.Gauge(id) != 0 {
		t.Fatalf("gauge should empty on activation, got %d", tr.Gauge(id))
	}
	if !tr.Active(id) {
		t.Fatal("should be active after activation")
	}
}

func TestActivateNeedsFullGauge(t *testing.T) {
	tr := NewTracker()
	const id = int64(1)
	tr.Fill(id) // one hit, nowhere near full
	if tr.Activate(id) {
		t.Fatal("a partial gauge must not activate")
	}
	if tr.Gauge(id) != FillPerHit {
		t.Fatalf("a failed activation must not empty the gauge, got %d", tr.Gauge(id))
	}
}

func TestBoostOnlyWhenActive(t *testing.T) {
	tr := NewTracker()
	const id = int64(1)
	if tr.Boost(id, 100) != 100 {
		t.Fatal("no boost when inactive")
	}
	for i := 0; i < 100; i++ {
		tr.Fill(id)
	}
	tr.Activate(id)
	if got := tr.Boost(id, 100); got != 100+100*DamageBonusPct/100 {
		t.Fatalf("boosted damage = %d, want %d", got, 100+100*DamageBonusPct/100)
	}
}
