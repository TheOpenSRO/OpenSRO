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
	// ...and before uniqueness. "A" above cannot tell the orders apart, because
	// it was never taken; a VALID, TAKEN name can. Before round 481 MemStore
	// checked the name first and answered ErrNameTaken here.
	if _, err := store.Create(ctx, "Ab", 1, "Leader"); !errors.Is(err, ErrAlreadyInGuild) {
		t.Fatalf("Create(\"Ab\") again by its guilded founder: got %v, want ErrAlreadyInGuild", err)
	}
	// A guildless character asking for the taken name still gets ErrNameTaken.
	if _, err := store.Create(ctx, "Ab", 3, "Third"); !errors.Is(err, ErrNameTaken) {
		t.Fatalf("Create(\"Ab\") by a guildless character: got %v, want ErrNameTaken", err)
	}
}

// checkAddPoints runs the Store.AddPoints contract against either store:
// CGuild::AddPoints (0x5c4110) credits the guild's GatheredSP (+0x3c) and the
// member's GP_Donation (+0x40) together, and neither once FUN_005d0c90 fails
// to find the member.
func checkAddPoints(t *testing.T, store Store) {
	t.Helper()
	ctx := context.Background()

	g, err := store.Create(ctx, "Ironclad", 1, "A")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if _, err := store.Join(ctx, g.ID, 2, "B"); err != nil {
		t.Fatalf("Join: %v", err)
	}
	other, err := store.Create(ctx, "Elsewhere", 4, "D")
	if err != nil {
		t.Fatalf("Create(other): %v", err)
	}

	// state reads the guild's total and each member's donation back.
	state := func() (int64, map[string]int64) {
		t.Helper()
		got, err := store.Get(ctx, g.ID)
		if err != nil {
			t.Fatalf("Get: %v", err)
		}
		don := map[string]int64{}
		for _, m := range got.Members {
			don[m.Name] = m.GPDonation
		}
		return got.GatheredSP, don
	}

	if total, don := state(); total != 0 || don["A"] != 0 || don["B"] != 0 {
		t.Fatalf("a new guild: total %d, donations %v, want all zero", total, don)
	}

	if err := store.AddPoints(ctx, g.ID, 2, 12); err != nil {
		t.Fatalf("AddPoints(B, 12): %v", err)
	}
	if total, don := state(); total != 12 || don["B"] != 12 || don["A"] != 0 {
		t.Fatalf("after B earns 12: total %d, donations %v, want total 12, B 12, A 0", total, don)
	}

	// NEGATIVE: a character outside the guild -- guildless (3), or in another
	// guild (4) -- is refused, and neither total moves.
	for _, who := range []int64{3, 4} {
		if err := store.AddPoints(ctx, g.ID, who, 50); !errors.Is(err, ErrNotInGuild) {
			t.Fatalf("AddPoints for non-member %d: got %v, want ErrNotInGuild", who, err)
		}
	}
	if total, don := state(); total != 12 || don["B"] != 12 || don["A"] != 0 {
		t.Fatalf("after refused credits: total %d, donations %v, want 12 / B 12 / A 0 untouched", total, don)
	}
	if o, err := store.Get(ctx, other.ID); err != nil || o.GatheredSP != 0 || o.Members[0].GPDonation != 0 {
		t.Fatalf("the other guild moved on a refused credit: %+v, %v", o, err)
	}

	// A guild that does not exist.
	if err := store.AddPoints(ctx, 9999, 2, 10); !errors.Is(err, ErrGuildNotFound) {
		t.Fatalf("AddPoints to a missing guild: got %v, want ErrGuildNotFound", err)
	}

	// Nothing to credit is a no-op, not an error.
	if err := store.AddPoints(ctx, g.ID, 1, 0); err != nil {
		t.Fatalf("AddPoints(0): %v", err)
	}
	if err := store.AddPoints(ctx, g.ID, 1, 10); err != nil {
		t.Fatalf("AddPoints(A, 10): %v", err)
	}
	if total, don := state(); total != 22 || don["A"] != 10 || don["B"] != 12 {
		t.Fatalf("after A earns 10: total %d, donations %v, want 22 / A 10 / B 12", total, don)
	}

	// The donation is the member's: GetByCharacter reads the same numbers.
	byChar, err := store.GetByCharacter(ctx, 2)
	if err != nil || byChar.GatheredSP != 22 {
		t.Fatalf("GetByCharacter(2) = %+v, %v; want GatheredSP 22", byChar, err)
	}

	// GuildIDOf, the membership test the crediting paths make first
	// (pc[0x72f] != 0): each member's own guild, and ErrNotInGuild for a
	// guildless character.
	for who, want := range map[int64]int64{1: g.ID, 2: g.ID, 4: other.ID} {
		if got, err := store.GuildIDOf(ctx, who); err != nil || got != want {
			t.Fatalf("GuildIDOf(%d) = %d, %v; want %d", who, got, err, want)
		}
	}
	if got, err := store.GuildIDOf(ctx, 3); !errors.Is(err, ErrNotInGuild) {
		t.Fatalf("GuildIDOf(guildless) = %d, %v; want ErrNotInGuild", got, err)
	}
}

func TestMemStoreAddPointsCreditsGuildAndMember(t *testing.T) {
	checkAddPoints(t, NewMemStore())
}
