package guild

import (
	"context"
	"errors"
	"strings"
	"testing"
)

// Round 814: CheckNickname's ladder in FUN_005c7560's order, with the
// self-only rule (OURS), and each refusal's engine code.
func TestCheckNicknameLadder(t *testing.T) {
	filter := func(s string) bool { return !strings.Contains(s, "!") }
	cases := []struct {
		name          string
		inGuild       bool
		level         int
		actor, target int64
		nick          string
		want          error
		code          int
	}{
		{"not in a guild", false, 5, 1, 1, "Ace", ErrNotInGuild, 0x4c0d},
		{"level 3", true, 3, 1, 1, "Ace", ErrNicknameGuildLevel, 0x4c51},
		{"level before self", true, 3, 1, 2, "Ace", ErrNicknameGuildLevel, 0x4c51},
		{"another member's", true, 4, 1, 2, "Ace", ErrNicknameNotSelf, 0x4c1e},
		{"13 bytes", true, 4, 1, 1, "ABCDEFGHIJKLM", ErrNicknameInvalid, 0x4c4d},
		{"filtered", true, 4, 1, 1, "Bad!", ErrNicknameInvalid, 0x4c4d},
		{"12 bytes", true, 4, 1, 1, "ABCDEFGHIJKL", nil, 0},
		{"empty clears", true, 4, 1, 1, "", nil, 0},
	}
	for _, c := range cases {
		err := CheckNickname(c.inGuild, c.level, c.actor, c.target, c.nick, filter)
		if !errors.Is(err, c.want) || (c.want == nil && err != nil) {
			t.Errorf("%s: got %v, want %v", c.name, err, c.want)
		}
		if NicknameCode(err) != c.code {
			t.Errorf("%s: code %#x, want %#x", c.name, NicknameCode(err), c.code)
		}
	}
}

// raiseToLevel levels leaderID's guild up to level, paying with plenty of
// gold and guild points.
func raiseToLevel(t *testing.T, store Store, guildID, leaderID int64, level int) {
	t.Helper()
	ctx := context.Background()
	for {
		g, err := store.Get(ctx, guildID)
		if err != nil {
			t.Fatal(err)
		}
		if g.Level >= level {
			return
		}
		if err := store.AddPoints(ctx, guildID, leaderID, 10_000_000); err != nil {
			t.Fatal(err)
		}
		if _, err := store.LevelUp(ctx, leaderID, true, 1<<40, func(int64) error { return nil }); err != nil {
			t.Fatalf("level up from %d: %v", g.Level, err)
		}
	}
}

func checkSetNickname(t *testing.T, store Store) {
	ctx := context.Background()
	g, err := store.Create(ctx, "Verizon", 1, "Ann")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Join(ctx, g.ID, 2, "Bob"); err != nil {
		t.Fatal(err)
	}
	if _, err := store.SetNickname(ctx, 2, 2, "Roaster", nil); !errors.Is(err, ErrNicknameGuildLevel) {
		t.Fatalf("a level-1 guild: %v, want ErrNicknameGuildLevel", err)
	}
	raiseToLevel(t, store, g.ID, 1, MinLevelForNickname)
	if _, err := store.SetNickname(ctx, 1, 2, "Roaster", nil); !errors.Is(err, ErrNicknameNotSelf) {
		t.Fatalf("the master naming Bob: %v, want ErrNicknameNotSelf", err)
	}
	if _, err := store.SetNickname(ctx, 3, 3, "Nobody", nil); !errors.Is(err, ErrNotInGuild) {
		t.Fatalf("a guildless character: %v, want ErrNotInGuild", err)
	}
	got, err := store.SetNickname(ctx, 2, 2, "Roaster", nil)
	if err != nil {
		t.Fatal(err)
	}
	nick := func(g *Guild, id int64) string {
		for _, m := range g.Members {
			if m.CharacterID == id {
				return m.Nickname
			}
		}
		return "?"
	}
	if nick(got, 2) != "Roaster" || nick(got, 1) != "" {
		t.Fatalf("after Bob names himself: %+v", got.Members)
	}
	again, _ := store.GetByCharacter(ctx, 1)
	if nick(again, 2) != "Roaster" {
		t.Fatalf("not kept: %+v", again.Members)
	}
	cleared, err := store.SetNickname(ctx, 2, 2, "", nil)
	if err != nil || nick(cleared, 2) != "" {
		t.Fatalf("clearing: %v %+v", err, cleared)
	}
	// Leaving drops it with the membership.
	if _, err := store.SetNickname(ctx, 2, 2, "Back", nil); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.Leave(ctx, 2); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Join(ctx, g.ID, 2, "Bob"); err != nil {
		t.Fatal(err)
	}
	rejoined, _ := store.Get(ctx, g.ID)
	if nick(rejoined, 2) != "" {
		t.Fatalf("a rejoined member keeps an old grant name: %+v", rejoined.Members)
	}
}

func TestMemStoreSetNickname(t *testing.T) { checkSetNickname(t, NewMemStore()) }

func TestSQLStoreSetNickname(t *testing.T) { checkSetNickname(t, openTestSQLStore(t)) }
