package session

import (
	"context"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/statuseffect"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// Round 786's /afflict (OURS, a test tool) on a server where no monster has
// struck yet: the status pass reads a character's life through the stores a
// monster's blow binds (statusFX.sdeps), and with none bound it took the
// afflicted character for gone and dropped its states silently -- the live
// run's poison stayed on the client and no pill could reach it. The tool
// binds its own.
func TestRound786AfflictedStateSurvivesTheStatusPass(t *testing.T) {
	ctx := context.Background()
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatal(err)
	}
	hub := world.NewHub()
	hub.Enter(gateway.NewTestSession(7861), c.ID, "Aria", c.Level, "jangan", world.Position{X: 1, Z: 1})
	statusFX.mu.Lock()
	saved := statusFX.sdeps
	statusFX.sdeps = strikeDeps{}
	statusFX.mu.Unlock()
	t.Cleanup(func() {
		statusFX.mu.Lock()
		statusFX.sdeps = saved
		delete(statusFX.pcs, c.ID)
		statusFX.mu.Unlock()
	})
	a := gmAfflict{deps: strikeDeps{chars: chars, hub: hub}} // no broadcast: a test session cannot send
	if _, err := a.Afflict(c.ID, "ps", []int{34, 100, 16}); err != nil {
		t.Fatal(err)
	}
	statusFX.step(ctx, time.Now())
	statusFX.mu.Lock()
	h := statusFX.pcs[c.ID]
	held := h != nil && h.Holds(statuseffect.SlotPoison)
	statusFX.mu.Unlock()
	if !held {
		t.Fatal("the status pass dropped the afflicted poison")
	}
}
