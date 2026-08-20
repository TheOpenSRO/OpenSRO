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

func TestInZoneOnlyReturnsMatchingZone(t *testing.T) {
	h := NewHub()
	a := h.Spawn("jangan", "Stone Golem", 100, 10, 5, 50)
	b := h.Spawn("jangan", "Wild Boar", 80, 3, 4, 15)
	h.Spawn("donwhang", "Sand Scorpion", 350, 18, 14, 120)

	got := h.InZone("jangan")
	if len(got) != 2 {
		t.Fatalf("got %d monsters, want 2", len(got))
	}
	ids := map[int64]bool{got[0].ID: true, got[1].ID: true}
	if !ids[a.ID] || !ids[b.ID] {
		t.Fatalf("got IDs %v, want %d and %d", ids, a.ID, b.ID)
	}
}

func TestInZoneEmptyForUnknownZone(t *testing.T) {
	h := NewHub()
	h.Spawn("jangan", "Stone Golem", 100, 10, 5, 50)
	if got := h.InZone("nowhere"); len(got) != 0 {
		t.Fatalf("got %d monsters, want 0", len(got))
	}
}

func TestInZoneExcludesDeadMonsters(t *testing.T) {
	h := NewHub()
	m := h.Spawn("jangan", "Stone Golem", 10, 0, 0, 50)
	if _, died, ok := h.ApplyDamage(m.ID, 10); !ok || !died {
		t.Fatalf("setup: got died=%v ok=%v, want both true", died, ok)
	}
	if got := h.InZone("jangan"); len(got) != 0 {
		t.Fatalf("got %d monsters, want 0 (dead monster should be gone)", len(got))
	}
}
