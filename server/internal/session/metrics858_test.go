package session

import (
	"context"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/metrics"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 858: the instrumentation at the session layer's chokepoints moves the
// right families -- a login by its result, a world entry, a refused and a
// granted zone change, the packets by opcode, and the scrape's view of the
// world (MetricsSource).

func TestRound858LoginCountsByResult(t *testing.T) {
	accounts := account.NewMemStore()
	accounts.Add("carol", "pw")
	svc := &LoginService{Accounts: accounts}
	ok0 := metrics.Value("logins_total", "result", "ok")
	bad0 := metrics.Value("logins_total", "result", "wrong_password")
	if out := svc.Login(context.Background(), LoginAttempt{Username: "carol", Password: "nope"}); out.Ack.OK {
		t.Fatal("a wrong password logged in")
	}
	if out := svc.Login(context.Background(), LoginAttempt{Username: "carol", Password: "pw"}); !out.Ack.OK {
		t.Fatalf("the right password was refused: %+v", out.Ack)
	}
	if got := metrics.Value("logins_total", "result", "ok") - ok0; got != 1 {
		t.Errorf("ok logins moved by %v, want 1", got)
	}
	if got := metrics.Value("logins_total", "result", "wrong_password") - bad0; got != 1 {
		t.Errorf("wrong_password logins moved by %v, want 1", got)
	}
}

func TestRound858WorldEntryZoneChangeAndScrape(t *testing.T) {
	closeZoneChange(t)
	entries0 := metrics.Value("world_entries_total")
	in0 := metrics.Value("gateway_packets_total", "dir", "in", "opcode", "0x0026")
	refused0 := metrics.Value("zone_change_refused_total", "reason", "not_gm")
	warps0 := metrics.Value("teleports_total", "kind", "zone_change")
	rig := newArrivalRig(t) // Aria (alice, a GM) and Bram (bob) log in and enter
	if got := metrics.Value("world_entries_total") - entries0; got < 2 {
		t.Fatalf("world entries moved by %v, want 2", got)
	}
	// Bram is no GM: refused (round 854), counted under not_gm.
	rig.send("Bram", OpChangeZone, (&ChangeZoneRequest{Zone: "donwhang"}).Encode())
	rig.until("Bram", OpChangeZoneResult)
	if got := metrics.Value("zone_change_refused_total", "reason", "not_gm") - refused0; got != 1 {
		t.Errorf("not_gm refusals moved by %v, want 1", got)
	}
	// Aria is: a zone_change warp.
	rig.send("Aria", OpChangeZone, (&ChangeZoneRequest{Zone: "donwhang"}).Encode())
	if czr, err := DecodeChangeZoneResult(rig.until("Aria", OpChangeZoneResult).Data); err != nil || !czr.OK {
		t.Fatalf("Aria's zone change: %+v %v", czr, err)
	}
	if got := metrics.Value("teleports_total", "kind", "zone_change") - warps0; got != 1 {
		t.Errorf("zone_change warps moved by %v, want 1", got)
	}
	if got := metrics.Value("gateway_packets_total", "dir", "in", "opcode", "0x0026") - in0; got != 2 {
		t.Errorf("0x0026 packets in moved by %v, want 2", got)
	}
	snap := MetricsSource(rig.hub, rig.monsters, nil, nil, nil)()
	if snap.Entities["player"] != 2 || snap.PlayersByZone["donwhang"] != 1 || snap.PlayersByZone["jangan"] != 1 {
		t.Errorf("snapshot %+v; want 2 players, one in donwhang and one in jangan", snap)
	}
	if snap.Entities["monster"] != rig.monsters.Count() {
		t.Errorf("snapshot monsters %d, hub %d", snap.Entities["monster"], rig.monsters.Count())
	}
}

// The zone label is bounded: a town, its area in the one world frame, a
// served dungeon, or other.
func TestRound858ZoneLabel(t *testing.T) {
	if got := zoneLabelOf(world.Entity{Zone: "jangan"}); got != "jangan" {
		t.Errorf("jangan -> %q", got)
	}
	// The one world frame's origin is Jangan's centre region.
	if got := zoneLabelOf(world.Entity{Zone: "world", Pos: world.Position{X: 10, Z: 10}}); got != "jangan" {
		t.Errorf("world at the origin -> %q, want jangan", got)
	}
	if got := zoneLabelOf(world.Entity{Zone: "dungeon/32769"}); got != "dungeon" {
		t.Errorf("an unserved dungeon -> %q, want dungeon", got)
	}
	if got := zoneLabelOf(world.Entity{Zone: "Not A Zone"}); got != "other" {
		t.Errorf("a typo -> %q, want other", got)
	}
}
