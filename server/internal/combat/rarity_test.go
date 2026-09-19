package combat

import "testing"

// TestRarityHPPercentIsTheEngineSwitch pins the percentages read off
// CGObjMob::PublishStats: the rank multipliers and the two ranks (uniques)
// the engine declines to scale.
func TestRarityHPPercentIsTheEngineSwitch(t *testing.T) {
	cases := map[int]int{0: 100, 1: 200, 6: 400, 4: 2000, 7: 3000, 5: 10000, 3: 100, 8: 100, 2: 100, 42: 100}
	for rarity, want := range cases {
		if got := RarityHPPercent(rarity); got != want {
			t.Errorf("RarityHPPercent(%d) = %d, want %d", rarity, got, want)
		}
	}
}

// TestSpawnScalesHPByRarity: a giant Mangyang carries twenty times the row's
// 54, a champion twice, a unique exactly its row; a general is untouched.
func TestSpawnScalesHPByRarity(t *testing.T) {
	for _, tc := range []struct{ rarity, want int }{{0, 54}, {1, 108}, {4, 1080}, {5, 5400}, {3, 54}} {
		if got := ScaleHPForRarity(54, tc.rarity); got != tc.want {
			t.Errorf("rarity %d: HP %d, want %d", tc.rarity, got, tc.want)
		}
	}
	h := NewHub()
	m := h.SpawnSpecies("jangan", Species{Name: "Mangyang", Rarity: 4}, 0, 0, 0, 54, 7, 18, 40)
	if m.MaxHP != 1080 || m.HP != 1080 {
		t.Fatalf("giant spawn: MaxHP/HP = %d/%d, want 1080/1080", m.MaxHP, m.HP)
	}
}
