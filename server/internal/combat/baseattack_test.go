package combat

import "testing"

func TestBaseAttackSkillForEveryWeaponType(t *testing.T) {
	want := map[int]int64{1: 1, 2: 2, 3: 2, 4: 40, 5: 40, 6: 70, 7: 8419, 8: 8420, 9: 8421, 10: 10625, 11: 9944, 12: 9354, 13: 9355, 14: 11162, 15: 11526}
	for tid, id := range want {
		if got := BaseAttackSkillFor(tid); got != id {
			t.Errorf("TypeID4 %d: got %d, want %d", tid, got, id)
		}
	}
	if BaseAttackSkillFor(16) != 0 || BaseAttackSkillFor(0) != 0 {
		t.Error("a type with no base attack must report 0")
	}
}
