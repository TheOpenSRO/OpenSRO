package session

import (
	"context"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/mana"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
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
