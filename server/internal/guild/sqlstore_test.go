package guild

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
		t.Fatalf("truncating guild tables: %v", err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func TestCreateAndGet(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()

	g, err := store.Create(ctx, "Silk Legion", 1, "Alice")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if g.Name != "Silk Legion" || g.LeaderID != 1 {
		t.Fatalf("unexpected guild: %+v", g)
	}
	if len(g.Members) != 1 || g.Members[0].Role != RoleLeader {
		t.Fatalf("expected sole leader member, got %+v", g.Members)
	}

	got, err := store.Get(ctx, g.ID)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if got.Name != g.Name {
		t.Fatalf("Get returned different guild: %+v", got)
	}
}

func TestCreateNameTaken(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()

	if _, err := store.Create(ctx, "Silk Legion", 1, "Alice"); err != nil {
		t.Fatalf("Create: %v", err)
	}
	if _, err := store.Create(ctx, "silk legion", 2, "Bob"); !errors.Is(err, ErrNameTaken) {
		t.Fatalf("Create with taken name: got %v, want ErrNameTaken", err)
	}
}

func TestCreateAlreadyInGuild(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()

	if _, err := store.Create(ctx, "First", 1, "Alice"); err != nil {
		t.Fatalf("Create: %v", err)
	}
	if _, err := store.Create(ctx, "Second", 1, "Alice"); !errors.Is(err, ErrAlreadyInGuild) {
		t.Fatalf("second Create by same character: got %v, want ErrAlreadyInGuild", err)
	}
}

func TestJoin(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()

	g, err := store.Create(ctx, "Silk Legion", 1, "Alice")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}

	joined, err := store.Join(ctx, g.ID, 2, "Bob")
	if err != nil {
		t.Fatalf("Join: %v", err)
	}
	if len(joined.Members) != 2 {
		t.Fatalf("expected 2 members after join, got %d", len(joined.Members))
	}
}

func TestJoinNotFound(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()

	if _, err := store.Join(ctx, 999, 1, "Alice"); !errors.Is(err, ErrGuildNotFound) {
		t.Fatalf("Join nonexistent guild: got %v, want ErrGuildNotFound", err)
	}
}

func TestJoinAlreadyInGuild(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()

	if _, err := store.Create(ctx, "First", 1, "Alice"); err != nil {
		t.Fatalf("Create: %v", err)
	}
	g2, err := store.Create(ctx, "Second", 2, "Bob")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if _, err := store.Join(ctx, g2.ID, 1, "Alice"); !errors.Is(err, ErrAlreadyInGuild) {
		t.Fatalf("Join while already in a guild: got %v, want ErrAlreadyInGuild", err)
	}
}

func TestLeavePromotesNextMember(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()

	g, err := store.Create(ctx, "Silk Legion", 1, "Alice")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if _, err := store.Join(ctx, g.ID, 2, "Bob"); err != nil {
		t.Fatalf("Join: %v", err)
	}

	guildID, remaining, err := store.Leave(ctx, 1)
	if err != nil {
		t.Fatalf("Leave: %v", err)
	}
	if guildID != g.ID {
		t.Fatalf("Leave returned guild %d, want %d", guildID, g.ID)
	}
	if remaining == nil || remaining.LeaderID != 2 {
		t.Fatalf("expected Bob promoted to leader, got %+v", remaining)
	}
	if len(remaining.Members) != 1 || remaining.Members[0].Role != RoleLeader {
		t.Fatalf("expected Bob's role to be leader, got %+v", remaining.Members)
	}
}

func TestLeaveDisbandsWhenLastMember(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()

	g, err := store.Create(ctx, "Silk Legion", 1, "Alice")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}

	guildID, remaining, err := store.Leave(ctx, 1)
	if err != nil {
		t.Fatalf("Leave: %v", err)
	}
	if guildID != g.ID {
		t.Fatalf("Leave returned guild %d, want %d", guildID, g.ID)
	}
	if remaining != nil {
		t.Fatalf("expected guild disbanded, got %+v", remaining)
	}
	if _, err := store.Get(ctx, g.ID); !errors.Is(err, ErrGuildNotFound) {
		t.Fatalf("Get disbanded guild: got %v, want ErrGuildNotFound", err)
	}
}

func TestLeaveNotInGuild(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()

	if _, _, err := store.Leave(ctx, 999); !errors.Is(err, ErrNotInGuild) {
		t.Fatalf("Leave when not in a guild: got %v, want ErrNotInGuild", err)
	}
}

func TestGetByCharacter(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()

	g, err := store.Create(ctx, "Silk Legion", 1, "Alice")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}

	got, err := store.GetByCharacter(ctx, 1)
	if err != nil {
		t.Fatalf("GetByCharacter: %v", err)
	}
	if got.ID != g.ID {
		t.Fatalf("GetByCharacter returned guild %d, want %d", got.ID, g.ID)
	}

	if _, err := store.GetByCharacter(ctx, 999); !errors.Is(err, ErrNotInGuild) {
		t.Fatalf("GetByCharacter for non-member: got %v, want ErrNotInGuild", err)
	}
}
