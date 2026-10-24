package guild

import (
	"context"
	"errors"
	"os"
	"strings"
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

// Round 481: the SQL store enforces the same 2-12 byte name as the memory
// store, in the same order -- membership, then length, then the unique index.
func TestCreateEnforcesNameLength(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()

	for _, name := range []string{"", "A", strings.Repeat("a", 13), strings.Repeat("a", 40)} {
		if _, err := store.Create(ctx, name, 1, "Alice"); !errors.Is(err, ErrInvalidNameLength) {
			t.Fatalf("Create(%q) (%d bytes): got %v, want ErrInvalidNameLength", name, len(name), err)
		}
	}
	// The refusals wrote nothing: Alice is still guildless and can found one.
	g, err := store.Create(ctx, "Ab", 1, "Alice")
	if err != nil {
		t.Fatalf("Create(\"Ab\"), the 2-byte minimum, after the refusals: %v", err)
	}
	if _, err := store.Create(ctx, strings.Repeat("a", 12), 2, "Bob"); err != nil {
		t.Fatalf("Create of a 12-byte name, the maximum: %v", err)
	}
	if _, err := store.Create(ctx, "A", 1, "Alice"); !errors.Is(err, ErrAlreadyInGuild) {
		t.Fatalf("Create(\"A\") by a guilded character: got %v, want ErrAlreadyInGuild", err)
	}

	got, err := store.Get(ctx, g.ID)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if len(got.Members) != 1 || got.Members[0].CharacterID != 1 {
		t.Fatalf("roster = %+v, want exactly the one leader", got.Members)
	}
}

// TestSQLAddPointsRoundTrip is checkAddPoints against Postgres, plus the schema
// upgrade: opening the store a second time re-runs the ADD COLUMN IF NOT EXISTS
// statements, which must neither fail nor reset the stored points.
func TestSQLAddPointsRoundTrip(t *testing.T) {
	store := openTestSQLStore(t)
	checkAddPoints(t, store)

	again, err := OpenSQLStore(testDSN())
	if err != nil {
		t.Fatalf("OpenSQLStore a second time (the ALTERs must be idempotent): %v", err)
	}
	defer again.Close()
	g, err := again.GetByCharacter(context.Background(), 2)
	if err != nil {
		t.Fatalf("GetByCharacter after reopening: %v", err)
	}
	if g.GatheredSP != 22 {
		t.Fatalf("GatheredSP after reopening = %d, want 22", g.GatheredSP)
	}
	for _, m := range g.Members {
		if want := map[string]int64{"A": 10, "B": 12}[m.Name]; m.GPDonation != want {
			t.Fatalf("%s's GPDonation after reopening = %d, want %d", m.Name, m.GPDonation, want)
		}
	}
}

// TestSQLLevelUp is checkLevelUp against Postgres, plus the schema upgrade:
// opening the store again re-runs `ADD COLUMN IF NOT EXISTS lvl`, which must
// neither fail nor reset the level.
func TestSQLLevelUp(t *testing.T) {
	store := openTestSQLStore(t)
	checkLevelUp(t, store)

	again, err := OpenSQLStore(testDSN())
	if err != nil {
		t.Fatalf("OpenSQLStore a second time (the ALTERs must be idempotent): %v", err)
	}
	defer again.Close()
	g, err := again.GetByCharacter(context.Background(), 1)
	if err != nil {
		t.Fatalf("GetByCharacter after reopening: %v", err)
	}
	if g.Level != MaxLevel {
		t.Fatalf("level after reopening = %d, want %d", g.Level, MaxLevel)
	}
}

func TestSQLLevelRaisesMemberCap(t *testing.T) {
	checkLevelRaisesMemberCap(t, openTestSQLStore(t))
}

// Round 821: the guild block's fields round-trip; the master reads the full
// mask, a member none, and a master stored before the column existed is
// given the mask when the schema runs again.
func TestSQLRound821Fields(t *testing.T) {
	store := openTestSQLStore(t)
	ctx := context.Background()
	g, err := store.Create(ctx, "Verizon", 1, "Tess")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Join(ctx, g.ID, 2, "Rook"); err != nil {
		t.Fatal(err)
	}
	got, err := store.Get(ctx, g.ID)
	if err != nil {
		t.Fatal(err)
	}
	perm := map[int64]Permission{}
	for _, m := range got.Members {
		perm[m.CharacterID] = m.Permission
	}
	if perm[1] != PermAll || perm[2] != 0 {
		t.Fatalf("permissions %v", perm)
	}
	if got.NoticeTitle != "" || got.CrestRev != 0 || got.SoldierFlags != 0 {
		t.Fatalf("new guild fields %+v", got)
	}
	// A master from before round 821.
	if _, err := store.db.ExecContext(ctx, `UPDATE guild_members SET permission = 0 WHERE character_id = 1`); err != nil {
		t.Fatal(err)
	}
	if _, err := NewSQLStore(store.db); err != nil {
		t.Fatal(err)
	}
	got, _ = store.Get(ctx, g.ID)
	for _, m := range got.Members {
		if m.CharacterID == 1 && m.Permission != PermAll {
			t.Fatalf("the old master after the upgrade: %#x", uint32(m.Permission))
		}
		if m.CharacterID == 2 && m.Permission != 0 {
			t.Fatalf("the member after the upgrade: %#x", uint32(m.Permission))
		}
	}
}
