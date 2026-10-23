package gm

import (
	"strings"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
)

// Round 814: /guildlevel raises the GM's own guild through the store's own
// level-up, never lowers it, and refuses without a guild or a store.
func TestGuildLevelRaisesTheGMsGuild(t *testing.T) {
	f := newFixture(t)
	if res := f.run(t, "/guildlevel 4"); !res.Refused || !strings.Contains(res.Text, "no guild store") {
		t.Fatalf("no store: %+v", res)
	}
	store := guild.NewMemStore()
	f.deps.Guilds = store
	if res := f.run(t, "/guildlevel 4"); !res.Refused || !strings.Contains(res.Text, "not in a guild") {
		t.Fatalf("no guild: %+v", res)
	}
	g, err := store.Create(f.ctx, "Verizon", f.actor.CharacterID, "Aria")
	if err != nil {
		t.Fatal(err)
	}
	for _, bad := range []string{"/guildlevel", "/guildlevel 0", "/guildlevel 6", "/guildlevel x"} {
		if res := f.run(t, bad); !res.Refused {
			t.Errorf("%q: %+v", bad, res)
		}
	}
	if res := f.run(t, "/guildlevel 4"); res.Refused {
		t.Fatalf("/guildlevel 4: %+v", res)
	}
	if got, _ := store.Get(f.ctx, g.ID); got.Level != 4 {
		t.Fatalf("level %d, want 4", got.Level)
	}
	if res := f.run(t, "/guildlevel 2"); res.Refused {
		t.Fatalf("/guildlevel 2: %+v", res)
	}
	if got, _ := store.Get(f.ctx, g.ID); got.Level != 4 {
		t.Fatalf("lowered to %d", got.Level)
	}
}
