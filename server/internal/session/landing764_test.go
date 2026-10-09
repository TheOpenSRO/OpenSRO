package session

import (
	"math"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/world"
	"github.com/OpenSRO/OpenSRO/server/internal/worldmap"
)

// Round 764: a zone change's request may carry the spot the client will stand
// at (the zone box's `x/y@lx,lz`); it round-trips, and anything but 0 or 8
// trailing bytes is refused.
func TestRound764ChangeZoneRequestSpot(t *testing.T) {
	want := &ChangeZoneRequest{Zone: "97/168", HasSpot: true, SpotX: 969, SpotZ: 1369}
	got, err := DecodeChangeZoneRequest(want.Encode())
	if err != nil || *got != *want {
		t.Fatalf("round trip: got %+v (err %v), want %+v", got, err, want)
	}
	plain := (&ChangeZoneRequest{Zone: "97/168"}).Encode()
	if len(plain) != 2+len("97/168") {
		t.Fatalf("a request with no spot is %d bytes, want the zone alone", len(plain))
	}
	if _, err := DecodeChangeZoneRequest(append(plain, 1, 2, 3)); err == nil {
		t.Fatal("3 trailing bytes were taken")
	}
}

// Round 764: a zone change lands where the client will stand -- the request's
// spot, else the zone's LandingSpot (Jangan's square), else the middle -- so
// the arrival's view window (its group spawns) is the one around the player.
func TestRound764ChangeZoneLanding(t *testing.T) {
	for _, single := range []bool{false, true} {
		prev := singleFrame.Load()
		singleFrame.Store(single)
		_, mid, _, _ := arrival("97/168")
		spot := changeZoneLanding(&ChangeZoneRequest{Zone: "97/168", HasSpot: true, SpotX: 969, SpotZ: 1369}, mid)
		if math.Abs(spot.X-(mid.X+9)) > 1e-9 || math.Abs(spot.Z-(mid.Z-409)) > 1e-9 {
			t.Errorf("single %v: the spot (969, 1369) lands at %+v, middle %+v", single, spot, mid)
		}
		sx, sz, _ := worldmap.LandingSpotFor("jangan", mid.X, mid.Z)
		for _, req := range []*ChangeZoneRequest{
			{Zone: "jangan"},
			{Zone: "97/168"},
			{Zone: "97/168", HasSpot: true, SpotX: -5, SpotZ: 100},
			{Zone: "97/168", HasSpot: true, SpotX: float32(math.NaN()), SpotZ: 100},
			{Zone: "97/168", HasSpot: true, SpotX: 100, SpotZ: 1920},
		} {
			got := changeZoneLanding(req, mid)
			if got.X != sx || got.Z != sz {
				t.Errorf("single %v: %+v lands at (%v, %v), want Jangan's spot (%v, %v)", single, req, got.X, got.Z, sx, sz)
			}
		}
		_, dmid, _, _ := arrival("donwhang")
		if got := changeZoneLanding(&ChangeZoneRequest{Zone: "donwhang"}, dmid); got != dmid {
			t.Errorf("single %v: donwhang (no spot) lands at %+v, want its middle %+v", single, got, dmid)
		}
		singleFrame.Store(prev)
	}
}

// Round 764: the client's placement at the landing is taken -- the point the
// server landed it at is named -- and the zone's LandingSpot named with it is
// the spot itself, measured from the zone's middle, not from the arrival.
func TestRound764ArrivalNamesTheSpot(t *testing.T) {
	const id = 764001
	defer forgetLandings(id)
	_, mid, _, _ := arrival("jangan")
	sx, sz, _ := worldmap.LandingSpotFor("jangan", mid.X, mid.Z)
	at := world.Position{X: mid.X + 9, Z: mid.Z - 409}
	noteArrivalLanding(id, "jangan", at)
	now := time.Now()
	if !landingTake(id, at.X, at.Z, now) {
		t.Fatal("the arrival's own point is not named")
	}
	noteArrivalLanding(id, "jangan", at)
	if !landingTake(id, sx, sz, now) {
		t.Fatal("Jangan's spot is not named")
	}
	noteArrivalLanding(id, "jangan", at)
	if landingTake(id, at.X+(sx-mid.X), at.Z+(sz-mid.Z), now) {
		t.Fatal("a point the spot's offset away from the arrival is named (the spot measured from the arrival)")
	}
}
