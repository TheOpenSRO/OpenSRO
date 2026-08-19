package combat

import "testing"

func TestSpawnStartsAtFullHP(t *testing.T) {
	h := NewHub()
	m := h.Spawn("jangan", "Stone Golem", 100, 10, 5, 50)
	if m.HP != 100 || m.MaxHP != 100 {
		t.Fatalf("got HP=%d MaxHP=%d, want both 100", m.HP, m.MaxHP)
	}
	if m.ID == 0 {
		t.Fatal("expected a nonzero assigned ID")
	}
}

func TestSpawnAssignsUniqueIDs(t *testing.T) {
	h := NewHub()
	m1 := h.Spawn("jangan", "Stone Golem", 100, 10, 5, 50)
	m2 := h.Spawn("jangan", "Stone Golem", 100, 10, 5, 50)
	if m1.ID == m2.ID {
		t.Fatalf("expected unique IDs, got %d and %d", m1.ID, m2.ID)
	}
}

func TestGetReturnsLiveMonster(t *testing.T) {
	h := NewHub()
	spawned := h.Spawn("jangan", "Stone Golem", 100, 10, 5, 50)

	got, ok := h.Get(spawned.ID)
	if !ok {
		t.Fatal("expected to find the spawned monster")
	}
	if got != *spawned {
		t.Fatalf("got %+v, want %+v", got, *spawned)
	}
}

func TestGetUnknownID(t *testing.T) {
	h := NewHub()
	if _, ok := h.Get(999); ok {
		t.Fatal("expected ok=false for an unknown monster ID")
	}
}

func TestApplyDamageReducesHP(t *testing.T) {
	h := NewHub()
	m := h.Spawn("jangan", "Stone Golem", 100, 10, 5, 50)

	updated, died, ok := h.ApplyDamage(m.ID, 30)
	if !ok {
		t.Fatal("expected ok=true")
	}
	if died {
		t.Fatal("30 damage to 100 HP should not kill it")
	}
	if updated.HP != 70 {
		t.Fatalf("got HP %d, want 70", updated.HP)
	}
}

func TestApplyDamageKillsAndRemoves(t *testing.T) {
	h := NewHub()
	m := h.Spawn("jangan", "Stone Golem", 100, 10, 5, 50)

	updated, died, ok := h.ApplyDamage(m.ID, 150)
	if !ok || !died {
		t.Fatalf("got died=%v ok=%v, want both true", died, ok)
	}
	if updated.HP != 0 {
		t.Fatalf("got HP %d, want 0 (should clamp, not go negative)", updated.HP)
	}

	if _, stillThere := h.Get(m.ID); stillThere {
		t.Fatal("expected the monster to be removed from the hub after dying")
	}
}

func TestApplyDamageUnknownID(t *testing.T) {
	h := NewHub()
	_, died, ok := h.ApplyDamage(999, 10)
	if ok || died {
		t.Fatalf("got died=%v ok=%v, want both false for an unknown monster", died, ok)
	}
}
