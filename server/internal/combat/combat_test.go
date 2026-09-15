package combat

import (
	"math/rand"
	"testing"
)

func TestSpawnStartsAtFullHP(t *testing.T) {
	h := NewHub()
	m := h.Spawn("jangan", "Mangyang", 0, 0, 0, 100, 10, 5, 50)
	if m.HP != 100 || m.MaxHP != 100 {
		t.Fatalf("got HP=%d MaxHP=%d, want both 100", m.HP, m.MaxHP)
	}
	if m.ID == 0 {
		t.Fatal("expected a nonzero assigned ID")
	}
}

func TestSpawnAssignsUniqueIDs(t *testing.T) {
	h := NewHub()
	m1 := h.Spawn("jangan", "Mangyang", 0, 0, 0, 100, 10, 5, 50)
	m2 := h.Spawn("jangan", "Mangyang", 0, 0, 0, 100, 10, 5, 50)
	if m1.ID == m2.ID {
		t.Fatalf("expected unique IDs, got %d and %d", m1.ID, m2.ID)
	}
}

func TestGetReturnsLiveMonster(t *testing.T) {
	h := NewHub()
	spawned := h.Spawn("jangan", "Mangyang", 0, 0, 0, 100, 10, 5, 50)

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
	m := h.Spawn("jangan", "Mangyang", 0, 0, 0, 100, 10, 5, 50)

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
	m := h.Spawn("jangan", "Mangyang", 0, 0, 0, 100, 10, 5, 50)

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
	a := h.Spawn("jangan", "Mangyang", 0, 0, 0, 100, 10, 5, 50)
	b := h.Spawn("jangan", "Weasel", 0, 0, 0, 80, 3, 4, 15)
	h.Spawn("donwhang", "Earth Ghost", 0, 0, 0, 350, 18, 14, 120)

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
	h.Spawn("jangan", "Mangyang", 0, 0, 0, 100, 10, 5, 50)
	if got := h.InZone("nowhere"); len(got) != 0 {
		t.Fatalf("got %d monsters, want 0", len(got))
	}
}

func TestInZoneExcludesDeadMonsters(t *testing.T) {
	h := NewHub()
	m := h.Spawn("jangan", "Mangyang", 0, 0, 0, 10, 0, 0, 50)
	if _, died, ok := h.ApplyDamage(m.ID, 10); !ok || !died {
		t.Fatalf("setup: got died=%v ok=%v, want both true", died, ok)
	}
	if got := h.InZone("jangan"); len(got) != 0 {
		t.Fatalf("got %d monsters, want 0 (dead monster should be gone)", len(got))
	}
}

// TestMitigateDamage pins the game's own mitigation SHAPE -- a percentage
// reduction plus a flat term -- against the flat subtraction it replaced.
//
// Recovered from Formula_MitigatePhysicalDamage (0040e450) and its magical twin
// (0040e830): damage = raw / (1 + pct/100) - flat. See MitigateDamage.
func TestMitigateDamage(t *testing.T) {
	// A level-10 monster mitigates 10% (characterdata col 73 = its level).
	// 100 / 1.10 = 90.909... -> 91, minus a flat 5 = 86.
	if got := MitigateDamage(100, 10, 5); got != 86 {
		t.Fatalf("MitigateDamage(100, 10, 5) = %d, want 86", got)
	}
	// No percentage is the old flat behaviour exactly.
	if got := MitigateDamage(100, 0, 30); got != 70 {
		t.Fatalf("MitigateDamage(100, 0, 30) = %d, want 70", got)
	}
	// The percentage is a DIVISOR, not a subtraction of a fraction: 100% halves
	// rather than zeroing, which is the whole point of the shape.
	if got := MitigateDamage(100, 100, 0); got != 50 {
		t.Fatalf("MitigateDamage(100, 100, 0) = %d, want 50 (divide, not subtract)", got)
	}
	// Mitigation is monotonic in the percentage -- the property that settled
	// which side of the fight owns it.
	prev := MitigateDamage(1000, 0, 0)
	for pct := 1; pct <= 120; pct++ {
		got := MitigateDamage(1000, pct, 0)
		if got > prev {
			t.Fatalf("mitigation not monotonic: pct %d gave %d, up from %d", pct, got, prev)
		}
		prev = got
	}
	// Floor is 1, not the game's 0: srrevamp has no hit/evade roll, so a
	// zero-damage hit would read as a bug rather than a miss. Disclosed.
	if got := MitigateDamage(5, 90, 500); got != 1 {
		t.Fatalf("over-mitigated hit = %d, want the floor 1", got)
	}
	// A negative percentage cannot amplify damage.
	if got := MitigateDamage(100, -50, 0); got != 100 {
		t.Fatalf("MitigateDamage(100, -50, 0) = %d, want 100", got)
	}
}

// TestRollDamage pins the recovered damage roll: uniform in [min, max],
// inclusive at both ends, with a non-positive span yielding the max.
//
// Recovered from Formula_RollWeaponDamage (0040f8d0) and its twin (0040f930):
//
//	min = GetParam(191); max = GetParam(190)
//	if max - min < 1 { return 0 }
//	return rand() % (max - min + 1) + min
func TestRollDamage(t *testing.T) {
	r := rand.New(rand.NewSource(1))

	// Both ends are reachable, and nothing outside the range ever is.
	seen := map[int]bool{}
	for i := 0; i < 2000; i++ {
		v := RollDamage(10, 14, r)
		if v < 10 || v > 14 {
			t.Fatalf("roll %d outside [10, 14]", v)
		}
		seen[v] = true
	}
	for want := 10; want <= 14; want++ {
		if !seen[want] {
			t.Errorf("value %d never rolled in 2000 tries -- range is not inclusive", want)
		}
	}

	// A zero-width range is the value itself, not a panic.
	if got := RollDamage(7, 7, r); got != 7 {
		t.Fatalf("RollDamage(7, 7) = %d, want 7", got)
	}
	// Reversed bounds are tolerated rather than producing nonsense.
	if got := RollDamage(9, 3, r); got < 3 || got > 9 {
		t.Fatalf("RollDamage(9, 3) = %d, want something in [3, 9]", got)
	}
	// A nil source rolls the maximum, so a caller that wants a fixed blow
	// does not need a separate code path.
	if got := RollDamage(4, 11, nil); got != 11 {
		t.Fatalf("RollDamage(4, 11, nil) = %d, want the max 11", got)
	}
}

// TestRollGold pins the per-level gold roll and its fallback.
//
// The range is real client data (levelgold.txt: level 1 = 28-59, level 10 =
// 60-125) and the binary's gold table is the one a gold item is spawned from;
// the join between file and table is inferred, and RollGold's doc comment says
// so. What this test guards is the mechanics: in range, inclusive, and a clean
// fall back to the flat disclosed reward when a monster has no range.
func TestRollGold(t *testing.T) {
	r := rand.New(rand.NewSource(7))

	seen := map[int64]bool{}
	for i := 0; i < 4000; i++ {
		v := RollGold(28, 59, 999, r)
		if v < 28 || v > 59 {
			t.Fatalf("gold %d outside the level-1 range [28, 59]", v)
		}
		seen[v] = true
	}
	if !seen[28] || !seen[59] {
		t.Error("the level-1 gold range is not inclusive at both ends")
	}

	// No range means the flat disclosed reward, not zero -- a monster whose
	// level the table does not cover must still pay something.
	if got := RollGold(0, 0, 42, r); got != 42 {
		t.Fatalf("RollGold with no range = %d, want the flat fallback 42", got)
	}
	// An inverted range is treated as absent rather than panicking.
	if got := RollGold(90, 10, 42, r); got != 42 {
		t.Fatalf("RollGold with an inverted range = %d, want the fallback 42", got)
	}
	// A zero-width range is that value.
	if got := RollGold(70, 70, 42, r); got != 70 {
		t.Fatalf("RollGold(70, 70) = %d, want 70", got)
	}
	// A nil generator takes the maximum, keeping callers deterministic.
	if got := RollGold(28, 59, 0, nil); got != 59 {
		t.Fatalf("RollGold with a nil source = %d, want the max 59", got)
	}
}
