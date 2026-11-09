package session

import (
	"context"
	"math"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/mana"
	"github.com/TheOpenSRO/OpenSRO/server/internal/navmesh"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
	"github.com/TheOpenSRO/OpenSRO/server/internal/worldmap"
)

// TestReviveAtReturnPointFromALayer (round 873): a character dead inside an
// instanced world asks for "Resurrect at the specified point" (option 1).
// READ (s:0x50fee0 -> GObjPC::Revive(0) s:0x4df290 -> s:0x4e08a0): the
// return point is the designated gate's, in the open world, whatever world
// the character died in -- the server has no Forgotten World resurrect hook
// (its only OnResurrectMyChar handlers are the battle arena's and the flag
// world's). On prod the move went to the open world but the revive was then
// asked of the layer's hub, which no longer held the character: it arrived
// in Jangan still dead, its client was told "not dead" and showed the dead
// window again, and a second click warped it a second time. One request must
// do the whole of it: one zone change, alive, the result without an error.
func TestReviveAtReturnPointFromALayer(t *testing.T) {
	for _, single := range []bool{false, true} {
		SetSingleFrame(single)
		gwRigExtra = func(rig *gwRig) []gateway.Handler {
			return []gateway.Handler{ReviveHandler(rig.chars, rig.hub, RegenDeps{Mana: mana.NewTracker()})}
		}
		rig := newGWRig(t, nil, map[string]int{"Aria": 40})
		gwRigExtra = nil
		w := rig.open(t)
		aria := rig.players["Aria"]
		if err := EnterInstance(context.Background(), aria.sess, w, "test"); err != nil {
			t.Fatal(err)
		}
		rig.until("Aria", OpChangeZoneResult)
		if !w.Hub.SetLifeState(aria.charID, world.LifeAlive, world.LifeDead, time.Now()) {
			t.Fatal("could not kill")
		}
		rig.send("Aria", OpRevive, []byte{ReviveOptionReturnPoint})
		czr, err := DecodeChangeZoneResult(rig.until("Aria", OpChangeZoneResult).Data)
		if err != nil || !czr.OK {
			t.Fatalf("single %v: zone change %+v %v", single, czr, err)
		}
		res, err := DecodeReviveResult(rig.until("Aria", OpReviveResult).Data)
		if err != nil || res.Error != "" || res.HP <= 0 {
			t.Fatalf("single %v: revive result %+v %v, want alive with no error", single, res, err)
		}
		e, ok := rig.hub.EntityByCharacterID(aria.charID)
		if !ok || e.Life != world.LifeAlive {
			t.Fatalf("single %v: in the open world %v, life %d, want alive there", single, ok, e.Life)
		}
		if _, in := w.Hub.EntityByCharacterID(aria.charID); in {
			t.Errorf("single %v: still in the layer", single)
		}
		if got := len(w.Members()); got != 0 {
			t.Errorf("single %v: the layer counts %d member(s), want 0", single, got)
		}
		// A second request finds it alive: refused, and nothing moves.
		rig.send("Aria", OpRevive, []byte{ReviveOptionReturnPoint})
		if res, _ := DecodeReviveResult(rig.until("Aria", OpReviveResult).Data); res == nil || res.Error != "not dead" {
			t.Errorf("single %v: a second request %+v, want \"not dead\"", single, res)
		}
		if n := len(rig.collect("Aria", 200*time.Millisecond, OpChangeZoneResult)); n != 0 {
			t.Errorf("single %v: a second request moved the character %d time(s)", single, n)
		}
		// Out by its death, the layer is empty, and an empty layer closes
		// WorldEmptyRemainTime (600 s) after its last user left, however it
		// left (READ, the shard manager: the user's leave m:0x658f10 stamps
		// "empty since" (+0x54) when the count (+0x14) reaches 0; its tick
		// m:0x658810 closes a layer at count 0 once now - +0x54 >= +0x3c).
		// Its gate in town goes with it.
		rig.clock.Advance(599 * time.Second)
		w.Sync()
		if w.Closed() {
			t.Fatalf("single %v: closed before 600 s empty", single)
		}
		rig.clock.Advance(time.Second)
		select {
		case <-w.Done():
		case <-time.After(3 * time.Second):
			t.Fatalf("single %v: not closed 600 s after the death emptied it", single)
		}
	}
	SetSingleFrame(false)
}

// TestSprintLandsOnTheSurface (round 873): a sprint's landing takes the
// target's height, and a monster here keeps its nest's height -- 81 above the
// Wrecked Ship's deck at the measured landing -- so the landing is put on the
// walkable surface nearest that height; with no mesh it is kept.
func TestSprintLandsOnTheSurface(t *testing.T) {
	SetNavmesh(navmesh.NewWorld(nil, map[int]*navmesh.Region{worldmap.RegionID(97, 168): wallRegion(1900)}))
	t.Cleanup(func() { SetNavmesh(nil) })
	p := sprintLandingOnSurface("jangan", world.Position{X: 10, Y: 81, Z: 20})
	if p.X != 10 || p.Z != 20 || math.Abs(p.Y) > 1e-6 {
		t.Errorf("landing %+v, want (10, 0, 20) on the flat mesh", p)
	}
	SetNavmesh(nil)
	if p := sprintLandingOnSurface("jangan", world.Position{X: 10, Y: 81, Z: 20}); p.Y != 81 {
		t.Errorf("no mesh: %+v, want the height kept", p)
	}
}

// TestEveryReviveFindsTheCharactersWorld (round 873): a revive handed the
// open world's hub finds a character dead inside a layer (the skill's
// resurrection, the scroll and the in-place revive all take the hub the
// character is in).
func TestEveryReviveFindsTheCharactersWorld(t *testing.T) {
	rig := newGWRig(t, nil, map[string]int{"Aria": 40})
	w := rig.open(t)
	aria := rig.players["Aria"]
	if err := EnterInstance(context.Background(), aria.sess, w, "test"); err != nil {
		t.Fatal(err)
	}
	rig.until("Aria", OpChangeZoneResult)
	w.Hub.SetLifeState(aria.charID, world.LifeAlive, world.LifeDead, time.Now())
	if _, _, err := revivePlayer(context.Background(), rig.chars, nil, rig.hub, aria.charID); err != nil {
		t.Fatalf("revive through the open world's hub: %v", err)
	}
	if e, _ := w.Hub.EntityByCharacterID(aria.charID); e.Life != world.LifeAlive {
		t.Errorf("life %d in the layer, want alive", e.Life)
	}
	w.Hub.SetLifeState(aria.charID, world.LifeAlive, world.LifeDead, time.Now())
	if _, _, _, err := reviveByScroll(context.Background(), rig.chars, RegenDeps{}, rig.hub, aria.charID, 100, 0); err != nil {
		t.Fatalf("scroll through the open world's hub: %v", err)
	}
	if e, _ := w.Hub.EntityByCharacterID(aria.charID); e.Life != world.LifeAlive {
		t.Errorf("life %d in the layer after the scroll, want alive", e.Life)
	}
}
