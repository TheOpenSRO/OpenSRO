package quest

import (
	"context"
	"errors"
	"os"
	"testing"
)

func testDSN() string {
	if v := os.Getenv("SRREVAMP_TEST_POSTGRES_DSN"); v != "" {
		return v
	}
	return "postgres://postgres:postgres@localhost:5432/srrevamp_test?sslmode=disable"
}

func openTestSQLStore(t *testing.T) *SQLStore {
	t.Helper()
	s, err := OpenSQLStore(testDSN())
	if err != nil {
		t.Fatalf("OpenSQLStore: %v (is postgres running?)", err)
	}
	if err := s.TruncateForTest(context.Background()); err != nil {
		t.Fatalf("truncating character_quests: %v", err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func TestAcceptAndListProgress(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()

	if err := store.Accept(ctx, 1, 1); err != nil {
		t.Fatalf("Accept: %v", err)
	}

	progress, err := store.ListProgress(ctx, 1)
	if err != nil {
		t.Fatalf("ListProgress: %v", err)
	}
	if len(progress) != 1 || progress[0].QuestID != 1 || progress[0].Kills != 0 || progress[0].Completed {
		t.Fatalf("unexpected progress: %+v", progress)
	}
}

func TestAcceptUnknownQuest(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()

	if err := store.Accept(ctx, 1, 999); !errors.Is(err, ErrUnknownQuest) {
		t.Fatalf("Accept unknown quest: got %v, want ErrUnknownQuest", err)
	}
}

func TestAcceptAlreadyAccepted(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()

	if err := store.Accept(ctx, 1, 1); err != nil {
		t.Fatalf("Accept: %v", err)
	}
	if err := store.Accept(ctx, 1, 1); !errors.Is(err, ErrAlreadyAccepted) {
		t.Fatalf("second Accept: got %v, want ErrAlreadyAccepted", err)
	}
}

func TestRecordKillProgressesAndCompletes(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()

	if err := store.Accept(ctx, 1, 1); err != nil {
		t.Fatalf("Accept: %v", err)
	}

	// Quest 1 targets 3 kills of "Stone Golem".
	for i := 0; i < 2; i++ {
		completed, err := store.RecordKill(ctx, 1, "Stone Golem")
		if err != nil {
			t.Fatalf("RecordKill: %v", err)
		}
		if len(completed) != 0 {
			t.Fatalf("kill %d: expected not yet completed, got %+v", i+1, completed)
		}
	}

	completed, err := store.RecordKill(ctx, 1, "Stone Golem")
	if err != nil {
		t.Fatalf("RecordKill: %v", err)
	}
	if len(completed) != 1 || completed[0].ID != 1 {
		t.Fatalf("expected quest 1 completed on 3rd kill, got %+v", completed)
	}

	progress, err := store.ListProgress(ctx, 1)
	if err != nil {
		t.Fatalf("ListProgress: %v", err)
	}
	if len(progress) != 1 || progress[0].Kills != 3 || !progress[0].Completed {
		t.Fatalf("unexpected final progress: %+v", progress)
	}

	// A kill after completion shouldn't increment further or re-complete.
	completed, err = store.RecordKill(ctx, 1, "Stone Golem")
	if err != nil {
		t.Fatalf("RecordKill after completion: %v", err)
	}
	if len(completed) != 0 {
		t.Fatalf("expected no re-completion, got %+v", completed)
	}
	progress, err = store.ListProgress(ctx, 1)
	if err != nil {
		t.Fatalf("ListProgress: %v", err)
	}
	if progress[0].Kills != 3 {
		t.Fatalf("expected kills to stay at 3, got %d", progress[0].Kills)
	}
}

func TestRecordKillIgnoresUnacceptedQuests(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()

	completed, err := store.RecordKill(ctx, 1, "Stone Golem")
	if err != nil {
		t.Fatalf("RecordKill: %v", err)
	}
	if len(completed) != 0 {
		t.Fatalf("expected no progress for unaccepted quest, got %+v", completed)
	}
}
