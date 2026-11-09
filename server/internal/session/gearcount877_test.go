package session

import (
	"context"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/skill"
)

// Round 877: a worn item whose level or mastery requirement failed when it
// was last published counts for nothing (gearcount.go). The defences are
// round 875's MEASURED panels: the robe set worn by a Warrior 110 reads the
// naked phy def 93 / mag def 50 (Str 491 / Int 164); with its requirement met
// it reads 2602 / 3984 (Str 533 / Int 206).

// gear877 is a European level-110 character holding Warrior 110 (and Cleric
// at cleric), wearing round 875's synthetic robe set given the real robe's
// requirement (Wizard, Warlock, Bard or Cleric 101).
func gear877(t *testing.T, cleric int) (context.Context, *character.MemStore, *skill.MemStore, fixedEquipment, stubCombatItems, int64) {
	t.Helper()
	ctx := context.Background()
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Robed")
	if err != nil {
		t.Fatal(err)
	}
	if err := chars.SetGender(ctx, c.ID, character.GenderEuropeMan); err != nil {
		t.Fatal(err)
	}
	if err := chars.SetLeveling(ctx, c.ID, 110, 0, 0, 20, 20); err != nil {
		t.Fatal(err)
	}
	skills := skill.NewMemStore()
	raise877(t, skills, c.ID, 513, 110)
	raise877(t, skills, c.ID, 518, cleric)
	items, worn := set875(true)
	for _, it := range items {
		it.ReqLevelType1, it.ReqLevel1 = 514, 101
		it.ReqLevelType2, it.ReqLevel2 = 516, 101
		it.ReqLevelType3, it.ReqLevel3 = 517, 101
		it.ReqLevelType4, it.ReqLevel4 = 518, 101
	}
	eq := fixedEquipment{worn: worn}
	SetGearRequirementSource(chars, eq, skills, items)
	t.Cleanup(func() { SetGearRequirementSource(nil, nil, nil, nil) })
	return ctx, chars, skills, eq, items, c.ID
}

func raise877(t *testing.T, skills *skill.MemStore, id, mastery int64, to int) {
	t.Helper()
	for i := 0; i < to; i++ {
		if _, err := skills.RaiseMastery(context.Background(), id, mastery, 0, 200); err != nil {
			t.Fatal(err)
		}
	}
}

func defences877(t *testing.T, ctx context.Context, id int64, str, intel int, eq equipment.Store, items stubCombatItems) (int, int) {
	t.Helper()
	phy, err := defenderArmor(ctx, id, str, eq, items)
	if err != nil {
		t.Fatal(err)
	}
	mag, err := defenderMagicArmor(ctx, id, intel, eq, items)
	if err != nil {
		t.Fatal(err)
	}
	return phy, mag
}

func TestUnqualifiedRobeCountsForNothing(t *testing.T) {
	ctx, chars, _, eq, items, id := gear877(t, 0)
	c, _ := chars.GetByID(ctx, id)
	gearAtEntry(ctx, chars, c)
	// MEASURED (round 875): the player's exact case.
	if phy, mag := defences877(t, ctx, id, 491, 164, eq, items); phy != 93 || mag != 50 {
		t.Errorf("Warrior in robes: phy %d mag %d, want the naked 93 / 50", phy, mag)
	}
	// Taken off and put on again (as at Cleric 101: an equip passes the
	// test first), it counts -- here its blues and plus included.
	gearSlotChanged(id, equipment.SlotMail)
	if phy, _ := defences877(t, ctx, id, 491, 164, eq, items); phy <= 93 {
		t.Errorf("chest published: phy %d, want above the naked 93", phy)
	}
}

func TestQualifiedRobeCounts(t *testing.T) {
	ctx, chars, _, eq, items, id := gear877(t, 101)
	c, _ := chars.GetByID(ctx, id)
	gearAtEntry(ctx, chars, c)
	if phy, mag := defences877(t, ctx, id, 533, 206, eq, items); phy != 2602 || mag != 3984 {
		t.Errorf("Cleric 101 in robes: phy %d mag %d, want 2602 / 3984", phy, mag)
	}
}

// MEASURED: worn at a login with Cleric 100, raised to 101 in the skill
// window, the robe still counts nothing; taken off and put on again, or a
// level change (GObjPC_SetLevel's refresh, READ), it counts.
func TestARaisedMasteryWaitsForTheNextPublish(t *testing.T) {
	ctx, chars, skills, eq, items, id := gear877(t, 100)
	c, _ := chars.GetByID(ctx, id)
	gearAtEntry(ctx, chars, c)
	if phy, _ := defences877(t, ctx, id, 491, 164, eq, items); phy != 93 {
		t.Fatalf("Cleric 100: phy %d, want 93", phy)
	}
	raise877(t, skills, id, 518, 1) // 101
	if phy, _ := defences877(t, ctx, id, 491, 164, eq, items); phy != 93 {
		t.Errorf("after the raise: phy %d, want still 93", phy)
	}
	// An equip of the chest piece publishes it alone.
	gearSlotChanged(id, equipment.SlotMail)
	if phy, _ := defences877(t, ctx, id, 491, 164, eq, items); phy == 93 || phy == 2602 {
		t.Errorf("chest re-equipped: phy %d, want the chest alone counted", phy)
	}
	// A level change publishes every worn item again.
	if err := chars.SetLeveling(ctx, id, 109, 0, 0, 20, 20); err != nil {
		t.Fatal(err)
	}
	if phy, mag := defences877(t, ctx, id, 533, 206, eq, items); phy != 2602 || mag != 3984 {
		t.Errorf("after a level change: phy %d mag %d, want 2602 / 3984", phy, mag)
	}
}

// READ: a level lost below a level requirement stops the item counting at
// once (GObjPC_SetLevel -> RefreshEquipParamEntryForPC(1) -> the test).
func TestALevelLostBelowTheRequirement(t *testing.T) {
	ctx, chars, _, eq, items, id := gear877(t, 110)
	for _, it := range items {
		it.ReqLevelType1, it.ReqLevel1 = 1, 110
		it.ReqLevelType2, it.ReqLevelType3, it.ReqLevelType4 = -1, -1, -1
	}
	c, _ := chars.GetByID(ctx, id)
	gearAtEntry(ctx, chars, c)
	if phy, _ := defences877(t, ctx, id, 533, 206, eq, items); phy != 2602 {
		t.Fatalf("level 110: phy %d, want 2602", phy)
	}
	if err := chars.SetLeveling(ctx, id, 109, 0, 0, 20, 20); err != nil {
		t.Fatal(err)
	}
	if phy, _ := defences877(t, ctx, id, 491, 164, eq, items); phy != 93 {
		t.Errorf("level 109: phy %d, want the naked 93", phy)
	}
}

func TestEquipRefusalWords(t *testing.T) {
	eu := &character.Character{Gender: character.GenderEuropeMan}
	ch := &character.Character{Gender: character.GenderChinaMan}
	if got := equipRefusalText(equipment.ErrRequirementNotMet, eu); got != "UIIT_MSG_STRGERR_HIGHER_LEVEL_REQUIRED_TO_USE_THISITEM" {
		t.Errorf("mastery: %q", got)
	}
	if got := equipRefusalText(equipment.ErrLevelTooLow, ch); got != "UIIT_MSG_STRGERR_HIGHER_LEVEL_REQUIRED_TO_USE_THISITEM" {
		t.Errorf("level: %q", got)
	}
	if got := equipRefusalText(equipment.ErrArmourMix, eu); got != "UIIT_MSG_STRGERR_EU_CANT_MIX_EXCLUSIVE_ARMOR_TYPE" {
		t.Errorf("mix, Europe: %q", got)
	}
	if got := equipRefusalText(equipment.ErrArmourMix, ch); got != "UIIT_MSG_STRGERR_CANT_MIX_EXCLUSIVE_ARMOR_TYPE" {
		t.Errorf("mix, China: %q", got)
	}
}
