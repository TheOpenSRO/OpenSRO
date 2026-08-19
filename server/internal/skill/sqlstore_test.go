package skill

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"
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
		t.Fatalf("truncating character_skills: %v", err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func TestLearnAndKnows(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()

	known, err := store.Knows(ctx, 1, 1)
	if err != nil {
		t.Fatalf("Knows: %v", err)
	}
	if known {
		t.Fatal("should not know an unlearned skill")
	}

	if err := store.Learn(ctx, 1, 1); err != nil {
		t.Fatalf("Learn: %v", err)
	}

	known, err = store.Knows(ctx, 1, 1)
	if err != nil {
		t.Fatalf("Knows: %v", err)
	}
	if !known {
		t.Fatal("should know the skill after learning it")
	}
}

func TestLearnAlreadyKnown(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()
	store.Learn(ctx, 1, 1)

	err := store.Learn(ctx, 1, 1)
	if !errors.Is(err, ErrAlreadyKnown) {
		t.Fatalf("got %v, want ErrAlreadyKnown", err)
	}
}

func TestKnownSkillsIsolatedPerCharacter(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()
	store.Learn(ctx, 1, 1)
	store.Learn(ctx, 1, 2)
	store.Learn(ctx, 2, 1)

	list1, err := store.KnownSkills(ctx, 1)
	if err != nil {
		t.Fatalf("KnownSkills: %v", err)
	}
	if len(list1) != 2 {
		t.Fatalf("character 1: got %v, want 2 skills", list1)
	}

	list2, err := store.KnownSkills(ctx, 2)
	if err != nil {
		t.Fatalf("KnownSkills: %v", err)
	}
	if len(list2) != 1 {
		t.Fatalf("character 2: got %v, want 1 skill", list2)
	}
}

func TestLastUsedBeforeAnyUse(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()
	store.Learn(ctx, 1, 1)

	_, used, err := store.LastUsed(ctx, 1, 1)
	if err != nil {
		t.Fatalf("LastUsed: %v", err)
	}
	if used {
		t.Fatal("should report not-yet-used for a freshly learned skill")
	}
}

func TestLastUsedNotKnown(t *testing.T) {
	store := openTestSQLStore(t)
	_, _, err := store.LastUsed(context.Background(), 1, 999)
	if !errors.Is(err, ErrNotKnown) {
		t.Fatalf("got %v, want ErrNotKnown", err)
	}
}

func TestRecordUseAndLastUsed(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()
	store.Learn(ctx, 1, 1)

	now := time.Now().Truncate(time.Second)
	if err := store.RecordUse(ctx, 1, 1, now); err != nil {
		t.Fatalf("RecordUse: %v", err)
	}

	got, used, err := store.LastUsed(ctx, 1, 1)
	if err != nil {
		t.Fatalf("LastUsed: %v", err)
	}
	if !used {
		t.Fatal("should report used after RecordUse")
	}
	if !got.Equal(now) {
		t.Fatalf("got %v, want %v", got, now)
	}
}

func TestRecordUseNotKnown(t *testing.T) {
	store := openTestSQLStore(t)
	err := store.RecordUse(context.Background(), 1, 999, time.Now())
	if !errors.Is(err, ErrNotKnown) {
		t.Fatalf("got %v, want ErrNotKnown", err)
	}
}

var _ Store = (*SQLStore)(nil)
