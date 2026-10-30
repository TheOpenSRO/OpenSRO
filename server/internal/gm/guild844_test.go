package gm

import (
	"strings"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
)

// Round 844 part 2: /guildabsent backdates a member's last logout, /guildgp
// credits the GM's guild; both refuse without a guild.
func TestGuild844AbsentAndGP(t *testing.T) {
	f := newFixture(t)
	store := guild.NewMemStore()
	f.deps.Guilds = store
	if res := f.run(t, "/guildgp 100"); !res.Refused || !strings.Contains(res.Text, "not in a guild") {
		t.Fatalf("no guild: %+v", res)
	}
	g, err := store.Create(f.ctx, "Verizon", f.actor.CharacterID, "Aria")
	if err != nil {
		t.Fatal(err)
	}
	for _, bad := range []string{"/guildgp", "/guildgp 0", "/guildgp x", "/guildabsent Aria", "/guildabsent Aria -1"} {
		if res := f.run(t, bad); !res.Refused {
			t.Errorf("%q: %+v", bad, res)
		}
	}
	before, _ := store.Get(f.ctx, g.ID)
	if res := f.run(t, "/guildgp 25000"); res.Refused {
		t.Fatalf("/guildgp: %+v", res)
	}
	if got, _ := store.Get(f.ctx, g.ID); got.GatheredSP != before.GatheredSP+25000 {
		t.Fatalf("points %d, want %d", got.GatheredSP, before.GatheredSP+25000)
	}
	if res := f.run(t, "/guildabsent Nobody 46"); !res.Refused {
		t.Fatalf("a stranger: %+v", res)
	}
	if res := f.run(t, "/guildabsent aria 46"); res.Refused {
		t.Fatalf("/guildabsent: %+v", res)
	}
	at, _ := store.LastLogouts(f.ctx, g.ID)
	if d := guild.DaysSince(at[f.actor.CharacterID], time.Now()); d < 45 || d > 47 {
		t.Fatalf("%d days, want 46", d)
	}
}
