package guild

import (
	"context"
	"errors"
	"strings"
	"testing"
)

func TestMemStoreCreateAndJoin(t *testing.T) {
	store := NewMemStore()
	ctx := context.Background()

	g, err := store.Create(ctx, "Ironclad", 1, "Leader")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if g.LeaderID != 1 || len(g.Members) != 1 || g.Members[0].Role != RoleLeader {
		t.Fatalf("new guild = %+v, want its creator as sole leader", g)
	}

	if _, err := store.Create(ctx, "IRONCLAD", 2, "Other"); err != ErrNameTaken {
		t.Fatalf("a name differing only in case: got %v, want ErrNameTaken", err)
	}
	if _, err := store.Create(ctx, "Second", 1, "Leader"); err != ErrAlreadyInGuild {
		t.Fatalf("creating while in a guild: got %v, want ErrAlreadyInGuild", err)
	}

	joined, err := store.Join(ctx, g.ID, 2, "Member")
	if err != nil {
		t.Fatalf("Join: %v", err)
	}
	if len(joined.Members) != 2 {
		t.Fatalf("roster = %+v, want two members", joined.Members)
	}
	if _, err := store.Join(ctx, 999, 3, "Nobody"); err != ErrGuildNotFound {
		t.Fatalf("joining a guild that isn't there: got %v, want ErrGuildNotFound", err)
	}

	byChar, err := store.GetByCharacter(ctx, 2)
	if err != nil || byChar.ID != g.ID {
		t.Fatalf("GetByCharacter(2) = %+v, %v", byChar, err)
	}
	if _, err := store.GetByCharacter(ctx, 3); err != ErrNotInGuild {
		t.Fatalf("GetByCharacter for a guildless character: got %v, want ErrNotInGuild", err)
	}
}

// Leadership passes to the longest-standing remaining member, and the last
// member out disbands the guild -- and its name becomes free again.
func TestMemStoreLeaveSuccession(t *testing.T) {
	store := NewMemStore()
	ctx := context.Background()

	g, _ := store.Create(ctx, "Ironclad", 1, "Leader")
	if _, err := store.Join(ctx, g.ID, 2, "Second"); err != nil {
		t.Fatalf("Join: %v", err)
	}
	if _, err := store.Join(ctx, g.ID, 3, "Third"); err != nil {
		t.Fatalf("Join: %v", err)
	}

	guildID, remaining, err := store.Leave(ctx, 1)
	if err != nil {
		t.Fatalf("Leave: %v", err)
	}
	if guildID != g.ID || remaining == nil {
		t.Fatalf("Leave = %d, %+v", guildID, remaining)
	}
	if remaining.LeaderID != 2 {
		t.Fatalf("leadership went to %d, want the longest-standing member (2)", remaining.LeaderID)
	}
	if remaining.Members[0].CharacterID != 2 || remaining.Members[0].Role != RoleLeader {
		t.Fatalf("roster = %+v, want the new leader first", remaining.Members)
	}

	if _, _, err := store.Leave(ctx, 1); err != ErrNotInGuild {
		t.Fatalf("leaving twice: got %v, want ErrNotInGuild", err)
	}

	store.Leave(ctx, 2)
	_, remaining, err = store.Leave(ctx, 3)
	if err != nil {
		t.Fatalf("Leave: %v", err)
	}
	if remaining != nil {
		t.Fatalf("the last member out left %+v, want the guild disbanded", remaining)
	}
	if _, err := store.Get(ctx, g.ID); err != ErrGuildNotFound {
		t.Fatalf("a disbanded guild is still there: %v", err)
	}
	if _, err := store.Create(ctx, "Ironclad", 4, "New"); err != nil {
		t.Fatalf("re-using a disbanded guild's name: %v", err)
	}
}

// Round 481: Create enforces the engine's 2-12 byte name (0x00514ce0's
// `len - 2u < 0xb`), after the membership check and before uniqueness.
func TestMemStoreCreateEnforcesNameLength(t *testing.T) {
	store := NewMemStore()
	ctx := context.Background()

	for _, name := range []string{"", "A", strings.Repeat("a", 13), strings.Repeat("a", 40)} {
		if _, err := store.Create(ctx, name, 1, "Leader"); !errors.Is(err, ErrInvalidNameLength) {
			t.Fatalf("Create(%q) (%d bytes): got %v, want ErrInvalidNameLength", name, len(name), err)
		}
	}
	// The refusals wrote nothing: leader 1 is still guildless and can found one.
	if _, err := store.Create(ctx, "Ab", 1, "Leader"); err != nil {
		t.Fatalf("Create(\"Ab\"), the 2-byte minimum, after the refusals: %v", err)
	}
	if _, err := store.Create(ctx, strings.Repeat("a", 12), 2, "Other"); err != nil {
		t.Fatalf("Create of a 12-byte name, the maximum: %v", err)
	}
	// Membership is checked first: a guilded character with a bad name is
	// refused for being in a guild, as FUN_00514b20 runs before the length test.
	if _, err := store.Create(ctx, "A", 1, "Leader"); !errors.Is(err, ErrAlreadyInGuild) {
		t.Fatalf("Create(\"A\") by a guilded character: got %v, want ErrAlreadyInGuild", err)
	}
}
