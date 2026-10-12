package quest

import (
	"context"
	"os"
	"testing"
)

func testDSN() string {
	if v := os.Getenv("OPENSRO_TEST_POSTGRES_DSN"); v != "" {
		return v
	}
	return "postgres://postgres:postgres@localhost:5432/opensro_test?sslmode=disable"
}

func openTestSQLStore(t *testing.T) *SQLStore {
	t.Helper()
	s, err := OpenSQLStore(testDSN())
	if err != nil {
		t.Fatalf("OpenSQLStore: %v (is postgres running?)", err)
	}
	if err := s.TruncateForTest(context.Background()); err != nil {
		t.Fatalf("truncating: %v", err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func TestSQLStoreStates(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()
	if err := store.Put(ctx, 1, State{QuestID: 5, Status: StatusAchieving, Counts: []int{3, 0, 1}}); err != nil {
		t.Fatal(err)
	}
	if err := store.Put(ctx, 1, State{QuestID: 5, Status: StatusAchievedButNotPaid, Counts: []int{14, 1, 1}}); err != nil {
		t.Fatal(err)
	}
	if err := store.Put(ctx, 1, State{QuestID: 4, Status: StatusAchieved, Achieved: 2}); err != nil {
		t.Fatal(err)
	}
	got, err := store.States(ctx, 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0].QuestID != 4 || got[0].Achieved != 2 || got[0].Counts != nil {
		t.Fatalf("states %+v", got)
	}
	if got[1].Status != StatusAchievedButNotPaid || len(got[1].Counts) != 3 || got[1].Counts[0] != 14 {
		t.Fatalf("the replaced state %+v", got[1])
	}
	if err := store.Delete(ctx, 1, 5); err != nil {
		t.Fatal(err)
	}
	if got, _ := store.States(ctx, 1); len(got) != 1 {
		t.Fatalf("after delete %+v", got)
	}
}
