package session

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/durability"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
	"github.com/OpenSRO/srrevamp/server/internal/skill"
)

// itemsAndSkills is a reference store that answers both item and skill
// lookups, the way the production refdata store does.
type itemsAndSkills struct {
	items  map[int64]*refdata.Item
	skills map[int64]*refdata.Skill
}

func (s itemsAndSkills) GetItem(_ context.Context, id int64) (*refdata.Item, error) {
	if it, ok := s.items[id]; ok {
		return it, nil
	}
	return nil, refdata.ErrItemNotFound
}
func (s itemsAndSkills) GetMaxStack(_ context.Context, id int64) (int, error) { return 1, nil }
func (s itemsAndSkills) GetSkill(_ context.Context, id int64) (*refdata.Skill, error) {
	if sk, ok := s.skills[id]; ok {
		return sk, nil
	}
	return nil, errors.New("no such skill")
}

// TestSwingReadyIsTheBaseSkillsReuseDelay: a sword swings every 1200 ms
// (SKILL_CH_SWORD_BASE_01's ReuseDelay), a bare hand every 1500 (SKILL_PUNCH_01),
// a click inside the delay is dropped, and a store that cannot look skills up
// imposes no gate.
func TestSwingReadyIsTheBaseSkillsReuseDelay(t *testing.T) {
	ctx := context.Background()
	ref := itemsAndSkills{
		items:  map[int64]*refdata.Item{100: {ID: 100, TypeID4: 2}},
		skills: map[int64]*refdata.Skill{2: {ID: 2, ReuseDelayMs: 1200}, 1: {ID: 1, ReuseDelayMs: 1500}},
	}
	skills := skill.NewMemStore()
	t0 := time.Date(2026, 9, 19, 16, 0, 0, 0, time.UTC)

	sword := fixedEquipment{worn: []equipment.Equipped{{Slot: equipment.SlotWeapon, ItemID: 100, Durability: 50}}}
	if !swingReady(ctx, 1, sword, ref, skills, t0) {
		t.Fatal("the first swing is ready")
	}
	if swingReady(ctx, 1, sword, ref, skills, t0.Add(1199*time.Millisecond)) {
		t.Error("a second swing inside the sword's 1200 ms is dropped")
	}
	if !swingReady(ctx, 1, sword, ref, skills, t0.Add(1200*time.Millisecond)) {
		t.Error("the swing at ReuseDelay is ready")
	}

	bare := fixedEquipment{}
	if !swingReady(ctx, 2, bare, ref, skills, t0) || swingReady(ctx, 2, bare, ref, skills, t0.Add(1499*time.Millisecond)) || !swingReady(ctx, 2, bare, ref, skills, t0.Add(1500*time.Millisecond)) {
		t.Error("bare-handed: SKILL_PUNCH_01's 1500 ms")
	}

	// A broken sword swings bare-handed, on the punch's delay.
	broken := fixedEquipment{worn: []equipment.Equipped{{Slot: equipment.SlotWeapon, ItemID: 100, Durability: durability.Broken}}}
	if !swingReady(ctx, 3, broken, ref, skills, t0) || swingReady(ctx, 3, broken, ref, skills, t0.Add(1400*time.Millisecond)) {
		t.Error("a broken weapon uses the bare hand's delay")
	}

	// An item store without skill lookup (the tests' stubCombatItems) gates nothing.
	plain := stubCombatItems{100: {ID: 100, TypeID4: 2}}
	for i := 0; i < 3; i++ {
		if !swingReady(ctx, 4, sword, plain, skills, t0.Add(time.Duration(i)*time.Millisecond)) {
			t.Error("no skill data, no gate")
		}
	}
}
