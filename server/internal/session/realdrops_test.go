package session

import (
	"context"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
)

// The real drop tables were loadable, the engine's roll was implemented and
// tested, and neither was ever reached by a kill: combat.Monster carried no
// numeric RefObjID, which is the key those tables use. combat/loot.go named
// that as one of the two things blocking the real path.
//
// These tests pin the three outcomes that matter once it is wired.

const (
	testMangyangRefObjID int64 = 1933 // MOB_CH_MANGNYANG, characterdata col 1
	testDropGroup        int64 = 77
	testRealItem         int64 = 4242
)

func realDropStore(t *testing.T, drops []refdata.MonsterDrop, entries []refdata.DropGroupEntry) *refdata.MemStore {
	t.Helper()
	ref := refdata.NewMemStore()
	if err := ref.ImportMonsterDrops(context.Background(), drops); err != nil {
		t.Fatalf("importing drops: %v", err)
	}
	if err := ref.ImportDropGroupEntries(context.Background(), entries); err != nil {
		t.Fatalf("importing drop groups: %v", err)
	}
	return ref
}

// A monster with real drop rows drops from THEM, not from the own-design table.
// Mangyang's own-design entry is an HP potion at chance 1.0, so if the fallback
// were still running it would be impossible to miss.
func TestKillPrefersTheRealDropTable(t *testing.T) {
	ref := realDropStore(t,
		[]refdata.MonsterDrop{{
			MonsterID: testMangyangRefObjID, ItemGroupID: testDropGroup,
			DropAmountMin: 1, DropAmountMax: 1, DropRatio: 1.0,
		}},
		[]refdata.DropGroupEntry{{GroupID: testDropGroup, ItemID: testRealItem, SelectRatio: 1.0}},
	)

	got := dropsForKill(context.Background(), ref,
		combat.Monster{Name: "Mangyang", RefObjID: testMangyangRefObjID})

	if len(got) != 1 {
		t.Fatalf("want exactly one drop from the real table, got %d: %+v", len(got), got)
	}
	if got[0].ItemID != testRealItem {
		t.Errorf("dropped item %d, want the real table's %d", got[0].ItemID, testRealItem)
	}
	if got[0].ItemID == combat.ItemHPPotion {
		t.Error("dropped the own-design HP potion: the fallback ran even though real rows exist")
	}
}

// The case that would quietly double the loot: a monster that HAS real data and
// rolls nothing has dropped nothing. Falling through to the own-design table
// there pays out both, making every kill luckier than the engine allows.
func TestRealDropDataThatYieldsNothingDoesNotFallBack(t *testing.T) {
	// DropAmountMax 0 makes RollAssignedDrop return 0 unconditionally. A zero
	// DropRatio would NOT be deterministic: the engine's comparison is `<=`
	// against a roll in [0, 999999], so ratio 0 still fires once in a million
	// (see refdata.rollBelow, which reproduces that on purpose).
	ref := realDropStore(t,
		[]refdata.MonsterDrop{{
			MonsterID: testMangyangRefObjID, ItemGroupID: testDropGroup,
			DropAmountMin: 0, DropAmountMax: 0, DropRatio: 1.0,
		}},
		[]refdata.DropGroupEntry{{GroupID: testDropGroup, ItemID: testRealItem, SelectRatio: 1.0}},
	)

	got := dropsForKill(context.Background(), ref,
		combat.Monster{Name: "Mangyang", RefObjID: testMangyangRefObjID})

	if len(got) != 0 {
		t.Fatalf("want no drops, got %d: %+v -- the own-design table ran on top of real data", len(got), got)
	}
}

// An operator who has not imported the tables must see exactly what they saw
// before. Mangyang's own-design entry drops an HP potion at chance 1.0, so this
// is deterministic.
func TestKillWithoutRealDropDataFallsBackToTheOwnDesignTable(t *testing.T) {
	empty := realDropStore(t, nil, nil)

	for _, tc := range []struct {
		name    string
		src     DropSource
		monster combat.Monster
	}{
		{"no drop source at all", nil, combat.Monster{Name: "Mangyang", RefObjID: testMangyangRefObjID}},
		{"source with no rows for this monster", empty, combat.Monster{Name: "Mangyang", RefObjID: testMangyangRefObjID}},
		{"monster carries no RefObjID", empty, combat.Monster{Name: "Mangyang"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := dropsForKill(context.Background(), tc.src, tc.monster)
			if len(got) == 0 {
				t.Fatal("want the own-design fallback to drop something, got nothing")
			}
			if got[0].ItemID != combat.ItemHPPotion {
				t.Errorf("fallback dropped %d, want the own-design HP potion %d", got[0].ItemID, combat.ItemHPPotion)
			}
		})
	}
}

// A row produces a COUNT of independent instances, each picking its own entry
// from the group -- not one stack. Three guaranteed attempts must yield three
// separate drops.
func TestRealDropRowProducesIndependentInstances(t *testing.T) {
	ref := realDropStore(t,
		[]refdata.MonsterDrop{{
			MonsterID: testMangyangRefObjID, ItemGroupID: testDropGroup,
			DropAmountMin: 3, DropAmountMax: 3, DropRatio: 1.0,
		}},
		[]refdata.DropGroupEntry{{GroupID: testDropGroup, ItemID: testRealItem, SelectRatio: 1.0}},
	)

	got := dropsForKill(context.Background(), ref,
		combat.Monster{Name: "Mangyang", RefObjID: testMangyangRefObjID})

	if len(got) != 3 {
		t.Fatalf("want 3 independent instances, got %d: %+v", len(got), got)
	}
	for i, d := range got {
		if d.Quantity != 1 {
			t.Errorf("instance %d has quantity %d, want 1 -- these are separate drops, not a stack", i, d.Quantity)
		}
	}
}
