package session

import (
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 762 (READ, CMsgBlock slot 2 0x534340 and FUN_00533910): a full
// insert sends the neighbours' groups first and the object's own block last,
// and each group's records in its block map's order, by unique id.
func TestOwnBlockGoesLast(t *testing.T) {
	cells := []combat.Cell{{X: 0, Z: 0}, {X: 0, Z: 1}, {X: 1, Z: 0}, {X: 1, Z: 1}}
	got := ownCellLast(cells, combat.Cell{X: 0, Z: 1})
	want := []combat.Cell{{X: 0, Z: 0}, {X: 1, Z: 0}, {X: 1, Z: 1}, {X: 0, Z: 1}}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("got %v, want %v", got, want)
		}
	}
	if cells[1] != (combat.Cell{X: 0, Z: 1}) {
		t.Fatalf("the input was changed: %v", cells)
	}
	// A crossing's blocks: the own block is not among them, nothing moves.
	other := ownCellLast(cells, combat.Cell{X: 5, Z: 5})
	for i := range cells {
		if other[i] != cells[i] {
			t.Fatalf("without the own block the order changed: %v", other)
		}
	}
}

func TestGroupRecordsByUniqueID(t *testing.T) {
	// The unique id is the character id's low 32 bits (round 710): a high
	// character id whose low word is small sorts first.
	group := []playerSpawn{
		{e: world.Entity{CharacterID: 900}},
		{e: world.Entity{CharacterID: 1<<32 + 5}},
		{e: world.Entity{CharacterID: 42}},
	}
	sortSpawnsByUID(group)
	want := []uint32{5, 42, 900}
	for i, s := range group {
		if uint32(s.e.CharacterID) != want[i] {
			t.Fatalf("record %d has uid %d, want %v", i, uint32(s.e.CharacterID), want)
		}
	}
}
