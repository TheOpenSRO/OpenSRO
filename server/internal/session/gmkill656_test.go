package session

import (
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gm"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 656's second review: a GM /kill is announced to the players watching
// the monster before the command as well as to those watching where it died.
// Between the kill and the broadcast Bram's view moves far off (the hook
// stands in for a reconcile landing there): his leave can no longer name the
// dead monster, so only the before-watchers' death reaches him -- without it
// he keeps a ghost. Cyra, in another bucket, hears nothing.
func TestGMKillReachesTheWatchersBeforeIt(t *testing.T) {
	gate := gm.ParseAccounts("alice")
	z := startStrikeZone(t, func(chars character.Store, hub *world.Hub, monsters *combat.Hub) gateway.Handler {
		deps := &gm.Deps{Chars: chars, Monsters: monsters, Zones: []string{"jangan", "donwhang"}}
		return GMCommandHandler(chars, gate, deps, hub, nil)
	})
	v := installAOIForTest(t, z.hub, z.monsters)
	v.reconcile()
	m := z.monsters.SpawnSpecies("jangan", testMangyang, z.bram.x+20, 0, z.bram.z, 30, 1, 1, 1)
	bram, ok := z.hub.EntityByCharacterID(z.bramChar)
	if !ok {
		t.Fatal("setup: Bram is not in the world")
	}
	gmAfterRunHook = func() { v.setView(bram.Session, combat.CellOf(bram.Zone, bram.Pos.X+cellX(10), bram.Pos.Z)) }
	t.Cleanup(func() { gmAfterRunHook = nil })

	z.aria.write(t, OpGMCommand, (&GMCommandRequest{Name: "Aria", Line: "/kill", SelectedMonster: m.ID}).Encode())
	if p := z.aria.read(t); p.Opcode != OpGMCommandResult {
		t.Fatalf("the GM's reply is %#04x", p.Opcode)
	}
	if z.monsters.Exists(m.ID) {
		t.Fatal("precondition: /kill killed the monster")
	}
	_, died := z.bram.readUntil(t, OpMonsterDied, time.Second)
	if died == nil {
		t.Fatal("Bram, watching the monster when the GM killed it, was never told it died")
	}
	if d, err := DecodeMonsterDied(died.Data); err != nil || d.MonsterID != m.ID {
		t.Fatalf("Bram's death message: %+v %v, want monster %d", d, err, m.ID)
	}
	if _, other := z.cyra.readUntil(t, OpMonsterDied, 300*time.Millisecond); other != nil {
		t.Fatal("Cyra, in another bucket, heard the death")
	}
}
