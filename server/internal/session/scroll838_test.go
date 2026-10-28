package session

import (
	"context"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
	"github.com/TheOpenSRO/OpenSRO/server/internal/worldmap"
)

// Round 838 (OURS): the special reverse return scroll's option 5. A location
// registered into a slot (OpReverseSaved, the scroll kept) is where option 5
// lands; an empty slot, and the plain scroll, are refused with nothing spent.
func TestRound838SpecialScrollSavedLocation(t *testing.T) {
	rig := newScrollRig(t, 60)
	rig.standAt(25000, 700, 400)
	wantRegion, wantX, wantZ := rig.localOf()
	bag, _ := rig.slot(fixtureSpecialReverse)

	list := func(req *ReverseSavedRequest) *ReverseSavedResult {
		t.Helper()
		p := rig.roundTrip(OpReverseSaved, req.Encode())
		for p != nil && p.Opcode != OpReverseSavedResult {
			p = rig.read(2e9)
		}
		if p == nil {
			t.Fatal("no OpReverseSavedResult")
		}
		r, err := DecodeReverseSavedResult(p.Data)
		if err != nil {
			t.Fatal(err)
		}
		return r
	}
	if r := list(&ReverseSavedRequest{Action: ReverseSavedList}); !r.OK || len(r.Slots) != 5 || r.Slots[2].Set() {
		t.Fatalf("a new character's list: %+v", r)
	}
	// Registering needs the special scroll in the named slot.
	plain, _ := rig.slot(fixtureReverseScroll)
	if r := list(&ReverseSavedRequest{Action: ReverseSavedRegister, Slot: 2, BagSlot: int32(plain)}); r.OK {
		t.Fatalf("registering with the plain scroll: %+v", r)
	}
	r := list(&ReverseSavedRequest{Action: ReverseSavedRegister, Slot: 2, BagSlot: int32(bag)})
	if !r.OK || !r.Registered || r.Slots[2].Region != wantRegion || !near778(r.Slots[2].X, wantX) || !near778(r.Slots[2].Z, wantZ) {
		t.Fatalf("registered: %+v; want slot 2 at %d (%v, %v)", r, wantRegion, wantX, wantZ)
	}
	if _, n := rig.slot(fixtureSpecialReverse); n != 5 {
		t.Fatalf("registering spent a scroll: %d left", n)
	}

	rig.standAt(25000, 1200, 200)
	for _, c := range []struct {
		id     int64
		target uint32
	}{{fixtureSpecialReverse, 3}, {fixtureReverseScroll, 2}} {
		if res := rig.use(c.id, ReverseOptionSaved, c.target); res.Error == "" {
			t.Fatalf("item %d slot %d: accepted, want refused", c.id, c.target)
		}
	}
	if res := rig.use(fixtureSpecialReverse, ReverseOptionSaved, 2); res.Error != "" || res.Remaining != 4 || res.CastMs != 1000 {
		t.Fatalf("option 5: %+v", res)
	}
	rig.fire()
	rig.arrival()
	if region, lx, lz := rig.localOf(); region != wantRegion || !near778(lx, wantX) || !near778(lz, wantZ) {
		t.Fatalf("landed at %d (%v, %v); want the saved %d (%v, %v)", region, lx, lz, wantRegion, wantX, wantZ)
	}
}

// Round 838 (OURS): option 4, a party member -- where the member stands when
// the cast runs out; a character outside the party is refused.
func TestRound838SpecialScrollPartyMember(t *testing.T) {
	rig := newScrollRig(t, 60)
	ctx := context.Background()
	bram, err := rig.chars.Create(ctx, 99, "Bram")
	if err != nil {
		t.Fatal(err)
	}
	e, _ := rig.hub.EntityByCharacterID(rig.charID)
	fx, fy, _ := entityFrame(e.Zone)
	// Far from Aria (Donwhang's region), out of her view: a test session
	// cannot be sent to.
	rx, ry := worldmap.RegionXY(26265)
	x, z := worldmap.ToWorld(rx, ry, 972, 1421, fx, fy)
	rig.hub.Enter(gateway.NewTestSession(83801), bram.ID, "Bram", 60, e.Zone, world.Position{X: x, Z: z})

	ph := party.NewHub()
	rig.caster.SetParties(ph)
	if res := rig.use(fixtureSpecialReverse, ReverseOptionParty, party.JIDOf(bram.ID)); res.Error == "" {
		t.Fatalf("option 4 to a stranger: accepted")
	}
	if _, err := ph.Form(party.Member{CharacterID: rig.charID, Name: "Aria"}, party.Member{CharacterID: bram.ID, Name: "Bram"}, 0); err != nil {
		t.Fatal(err)
	}
	if res := rig.use(fixtureSpecialReverse, ReverseOptionParty, party.JIDOf(rig.charID)); res.Error == "" {
		t.Fatalf("option 4 to oneself: accepted")
	}
	if res := rig.use(fixtureSpecialReverse, ReverseOptionParty, party.JIDOf(bram.ID)); res.Error != "" {
		t.Fatalf("option 4 to Bram: %+v", res)
	}
	rig.fire()
	rig.arrival()
	if region, lx, lz := rig.localOf(); region != 26265 || !near778(lx, 972) || !near778(lz, 1421) {
		t.Fatalf("landed at %d (%v, %v); want Bram's 26265 (972, 1421)", region, lx, lz)
	}
}
