package guild

import (
	"context"
	"errors"
	"fmt"
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

// checkLevelUp is Store.LevelUp's contract, run against both stores (round
// 528). The refusals come in CGuild::HandleLevelUp's order (0x005c63d0), each
// leaving the level, the guild's points and the purse (pay) untouched. A
// level-up then takes exactly LevelUpCost of the current level -- the gold
// through pay, the guild points off GatheredSP -- up to level 5, where the
// next one is refused with 0x4c21.
func checkLevelUp(t *testing.T, store Store) {
	t.Helper()
	ctx := context.Background()
	const rich = int64(1) << 40

	g, err := store.Create(ctx, "Silk Legion", 1, "A")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if g.Level != FoundingLevel {
		t.Fatalf("a new guild is level %d, want %d", g.Level, FoundingLevel)
	}
	if _, err := store.Join(ctx, g.ID, 2, "B"); err != nil {
		t.Fatalf("Join: %v", err)
	}

	var paid []int64
	pay := func(gold int64) error {
		paid = append(paid, gold)
		return nil
	}
	state := func() (int, int64) {
		t.Helper()
		got, err := store.Get(ctx, g.ID)
		if err != nil {
			t.Fatalf("Get: %v", err)
		}
		return got.Level, got.GatheredSP
	}
	refused := func(what string, who int64, alive bool, gold int64, want error, code int) {
		t.Helper()
		paid = nil
		level, sp := state()
		_, err := store.LevelUp(ctx, who, alive, gold, pay)
		if !errors.Is(err, want) || LevelUpCode(err) != code {
			t.Fatalf("%s: got %v (code 0x%x), want %v (0x%x)", what, err, LevelUpCode(err), want, code)
		}
		if l, s := state(); l != level || s != sp || len(paid) != 0 {
			t.Fatalf("%s: a refusal changed something: level %d -> %d, points %d -> %d, paid %v",
				what, level, l, sp, s, paid)
		}
	}

	// NEGATIVE, in the engine's order. B has earned 5,399 guild points: one
	// short of the level-1 cost.
	if err := store.AddPoints(ctx, g.ID, 2, 5_399); err != nil {
		t.Fatalf("AddPoints: %v", err)
	}
	refused("the master, dead", 1, false, rich, ErrLevelUpDead, 0x4c07)
	refused("a guildless character", 3, true, rich, ErrNotInGuild, 0x4c0d)
	refused("a member who is not the master", 2, true, rich, ErrNotGuildMaster, 0x4c1e)
	refused("2,999,999 gold", 1, true, 2_999_999, ErrLevelUpGoldDeficit, 0x4c31)
	refused("5,399 guild points", 1, true, 3_000_000, ErrLevelUpGPDeficit, 0x4c32)

	// NEGATIVE: a payment that fails keeps nothing either.
	if err := store.AddPoints(ctx, g.ID, 1, 1); err != nil {
		t.Fatalf("AddPoints: %v", err)
	}
	purseEmptied := errors.New("the purse was emptied")
	if _, err := store.LevelUp(ctx, 1, true, 3_000_000, func(int64) error { return purseEmptied }); !errors.Is(err, purseEmptied) {
		t.Fatalf("a failing pay: got %v, want its own error", err)
	}
	if l, s := state(); l != 1 || s != 5_400 {
		t.Fatalf("after a failing pay: level %d, points %d; want 1 and 5400", l, s)
	}

	// Level 1 -> 2 with exactly 3,000,000 gold and 5,400 points.
	paid = nil
	up, err := store.LevelUp(ctx, 1, true, 3_000_000, pay)
	if err != nil {
		t.Fatalf("LevelUp from 1: %v", err)
	}
	if up.Level != 2 || up.GatheredSP != 0 || len(paid) != 1 || paid[0] != 3_000_000 {
		t.Fatalf("after levelling from 1: level %d, points %d, paid %v; want 2, 0, [3000000]",
			up.Level, up.GatheredSP, paid)
	}
	if l, s := state(); l != 2 || s != 0 {
		t.Fatalf("the store reads level %d, points %d after the level-up; want 2 and 0", l, s)
	}
	// Spending the guild's points spends no member's donation.
	got, err := store.Get(ctx, g.ID)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	for _, m := range got.Members {
		if want := map[string]int64{"A": 1, "B": 5_399}[m.Name]; m.GPDonation != want {
			t.Fatalf("%s's GPDonation is %d after the level-up, want %d untouched", m.Name, m.GPDonation, want)
		}
	}

	// 2 -> 5, each at its own level's cost.
	for from := 2; from < MaxLevel; from++ {
		gold, gp, _ := LevelUpCost(from)
		if err := store.AddPoints(ctx, g.ID, 2, gp); err != nil {
			t.Fatalf("AddPoints: %v", err)
		}
		paid = nil
		up, err := store.LevelUp(ctx, 1, true, gold, pay)
		if err != nil {
			t.Fatalf("LevelUp from %d: %v", from, err)
		}
		if up.Level != from+1 || up.GatheredSP != 0 || len(paid) != 1 || paid[0] != gold {
			t.Fatalf("after levelling from %d: level %d, points %d, paid %v; want %d, 0, [%d]",
				from, up.Level, up.GatheredSP, paid, from+1, gold)
		}
	}

	// NEGATIVE: level 5 is the cap (5c6434 cmp al,0x5; jb), whatever the
	// guild and the master can pay.
	if err := store.AddPoints(ctx, g.ID, 2, 1_000_000); err != nil {
		t.Fatalf("AddPoints: %v", err)
	}
	refused("a level-5 guild", 1, true, rich, ErrLevelUpFull, 0x4c21)
}

// checkLevelRaisesMemberCap: a level-1 guild takes 15 members and refuses the
// sixteenth; after a level-up the same join succeeds, up to level 2's 20
// (CGuild::IsFull, 0x005d0fb0, indexes MaxMembersByLevel by the guild's level).
func checkLevelRaisesMemberCap(t *testing.T, store Store) {
	t.Helper()
	ctx := context.Background()
	g, err := store.Create(ctx, "Capstone", 100, "Lead")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	join := func(id int64) error {
		_, err := store.Join(ctx, g.ID, id, fmt.Sprintf("M%d", id))
		return err
	}
	for id := int64(101); id < 100+int64(MaxMembersFor(1)); id++ {
		if err := join(id); err != nil {
			t.Fatalf("join %d: %v", id, err)
		}
	}
	// NEGATIVE: the sixteenth at level 1.
	if err := join(200); !errors.Is(err, ErrGuildFull) {
		t.Fatalf("the 16th member of a level-1 guild: got %v, want ErrGuildFull", err)
	}
	if err := store.AddPoints(ctx, g.ID, 100, 5_400); err != nil {
		t.Fatalf("AddPoints: %v", err)
	}
	if _, err := store.LevelUp(ctx, 100, true, 3_000_000, nil); err != nil {
		t.Fatalf("LevelUp: %v", err)
	}
	for id := int64(200); id < 200+int64(MaxMembersFor(2)-MaxMembersFor(1)); id++ {
		if err := join(id); err != nil {
			t.Fatalf("join %d at level 2: %v", id, err)
		}
	}
	if err := join(300); !errors.Is(err, ErrGuildFull) {
		t.Fatalf("the 21st member of a level-2 guild: got %v, want ErrGuildFull", err)
	}
	got, err := store.Get(ctx, g.ID)
	if err != nil || len(got.Members) != MaxMembersFor(2) {
		t.Fatalf("roster after filling level 2: %v members, %v; want %d", len(got.Members), err, MaxMembersFor(2))
	}
}

func TestMemStoreLevelUp(t *testing.T) {
	checkLevelUp(t, NewMemStore())
}

func TestMemStoreLevelRaisesMemberCap(t *testing.T) {
	checkLevelRaisesMemberCap(t, NewMemStore())
}
