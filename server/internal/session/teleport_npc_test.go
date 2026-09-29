package session

// Round 642: the teleport NPCs -- the ferry, airship and tunnel ticket
// sellers, Jangan's gate soldiers and Constantinople's guides -- teleport as
// the town gates do. The engine serves any object a teleport point is
// associated with (RefTeleport_ExtractData sets the ref object's +0x190 for
// every associated object, 0x6a7ce7; GObjPC::HandleTeleportUse takes the link
// through it), and lands the player on the destination point exactly
// (0x407760). See gateObject in teleport.go and
// docs/protocol/teleport_network.md, "Teleport NPCs (round 642)".

import (
	"context"
	"fmt"
	"math"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/teleport"
	"github.com/OpenSRO/srrevamp/server/internal/worldmap"
)

// A synthetic network of NPC-hosted points, shaped on the retail rows (each
// row's region, x, z and links read on the render box's teleportdata.txt /
// teleportlink.txt in round 642; no archive file is in the repo). The Jangan
// river ferries (3 <-> 4 across 97/161 and 100/161, 9 <-> 6), Hotan's
// Karakoram airship to Roc Mountain (16 -> 18), two of Jangan's gate soldiers
// (42 -> 43), the Constantinople harbour to Alexandria's (21 -> 177, fee
// 5,000, level 95 and up, the engine's type-7 cart rule) and a fortress gate
// whose destination is in another game world (46 -> 49, world 2).
const (
	npcPointsCSV = "ID,Code,ObjectID,ZoneName,Region,X,Y,Z,Radius,Interaction7,Interaction9,WorldID\n" +
		"1,GATE_CH,2094,SN_ZONE_22001,25000,969,0,1369,150,1,0,1\n" +
		"3,GATE_NPC_CH_FERRY,2011,SN_ZONE_21002,24993,560,140,1460,200,0,0,1\n" +
		"4,GATE_NPC_WC_FERRY,2056,SN_ZONE_21004,25761,636,160,1482,200,0,0,1\n" +
		"6,GATE_NPC_WC_FERRY2,2120,SN_ZONE_21005,25244,1025,160,601,200,0,0,1\n" +
		"9,GATE_NPC_CH_FERRY2,2119,SN_ZONE_21003,24734,523,140,1267,200,0,0,1\n" +
		"16,GATE_NPC_KT_FLYSHIP1,5901,SN_ZONE_25031_1,23929,862,2105,1623,150,0,0,1\n" +
		"18,GATE_NPC_RM_FLYSHIP1,5910,SN_ZONE_25033_1,24438,888,2523,538,150,0,0,1\n" +
		"21,GATE_NPC_EU_FERRY2,7524,SN_ZONE_21009,25163,734,-184,168,150,0,0,1\n" +
		"42,GATE_NPC_CH_SOLDIER_EM1,2031,SN_ZONE_13002,25000,976,-6,1834,60,0,0,1\n" +
		"43,GATE_NPC_CH_SOLDIER_EA2,2034,SN_ZONE_14022,25001,1340,0,1817,60,0,0,1\n" +
		"46,GATE_CH_FORT_GATE1,23269,SN_ZONE_40008,23719,465,145,363,200,0,0,1\n" +
		"49,GATE_JA_FORT_GATE1,22902,SN_ZONE_41008,17221,812,31,677,200,0,0,2\n" +
		"177,GATE_NPC_SD_M_AREA_FERRY,26799,SN_ZONE_21836_13,23856,1525,585,1688,50,0,0,1\n"
	npcLinksCSV = "From,To,Fee,Rule1Type,Rule1Data1,Rule1Data2,Rule2Type,Rule2Data1,Rule2Data2," +
		"Rule3Type,Rule3Data1,Rule3Data2,Rule4Type,Rule4Data1,Rule4Data2,Rule5Type,Rule5Data1,Rule5Data2\n" +
		"3,4,500,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0\n" +
		"4,3,500,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0\n" +
		"6,9,500,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0\n" +
		"9,6,500,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0\n" +
		"16,18,500,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0\n" +
		"18,16,500,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0\n" +
		"21,177,5000,1,95,999,0,0,0,7,0,0,0,0,0,0,0,0\n" +
		"42,43,0,1,0,999,2,0,0,0,0,0,0,0,0,0,0,0\n" +
		"46,49,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0\n"
	npcBuildingsCSV = "ID,Code,NameStrID,Region,X,Y,Z,Fortress\n" +
		"2094,STORE_CH_GATE,SN_NPC_CH_GATE,25000,1254,-6,1374,xxx\n" +
		"23269,STORE_CH_FORT_GATE1,SN_STORE_CH_FORT_GATE1,23719,465,145,363,xxx\n" +
		"22902,STORE_JA_FORT_GATE1,SN_STORE_JA_FORT_GATE1,17221,812,31,677,xxx\n"
)

func npcTeleportFixture(t *testing.T) *teleport.Table {
	t.Helper()
	tab, err := teleport.Read(strings.NewReader(npcPointsCSV), strings.NewReader(npcLinksCSV), strings.NewReader(npcBuildingsCSV))
	if err != nil {
		t.Fatalf("teleport.Read on the NPC fixture: %v", err)
	}
	return tab
}

// The ferries, the airship and the gate soldier teleport: each is charged its
// link's fee and lands at its linked point, under the zone label
// teleportZoneFor gives the point's region -- a ferry dock two regions out of
// Jangan arrives under its own "x/y" label, a soldier's gate one region over
// under "jangan".
func TestTeleportNPCsMoveToTheLinkedPoint(t *testing.T) {
	cases := []struct {
		name       string
		gate, dest uint16
		fee        int64
		region     int
		x, z       int
		zone       string
	}{
		{"Jangan east ferry across the river", 3, 4, 500, 25761, 636, 1482, "100/161"},
		{"and back", 4, 3, 500, 24993, 560, 1460, "97/161"},
		{"Jangan west ferry", 9, 6, 500, 25244, 1025, 601, "98/156"},
		{"Karakoram airship to Roc Mountain", 16, 18, 500, 24438, 888, 538, "95/118"},
		{"Roc Mountain airship back", 18, 16, 500, 23929, 862, 1623, "93/121"},
		{"Jangan palace soldier to the east gate", 42, 43, 0, 25001, 1340, 1817, "jangan"},
		{"Constantinople harbour to Alexandria's", 21, 177, 5000, 23856, 1525, 1688, "93/48"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rig := newTeleportRig(t, teleportRigOpts{network: npcTeleportFixture(t), level: 100, gold: 10000})
			res := rig.use(tc.gate, tc.dest)
			if !res.OK || res.Code != 0 || res.Fee != tc.fee {
				t.Fatalf("receipt %+v; want ok, fee %d", res, tc.fee)
			}
			czr := rig.arrival()
			if czr.Zone != tc.zone {
				t.Fatalf("arrived in zone %q; want %q", czr.Zone, tc.zone)
			}
			wantAt(t, czr, tc.region, tc.x, tc.z)
			if g := rig.gold(); g != 10000-tc.fee {
				t.Fatalf("gold %d; want %d", g, 10000-tc.fee)
			}
		})
	}
}

// NEGATIVES at NPC points: the harbour's (1, 95, 999) refuses level 94 with
// the engine's 0x1c15; a GM is still bound by it (the GM rule waives the fee,
// not the restrictions); a fortress gate whose destination is in world 2 is
// refused with nothing moved; a destination the point has no link to is code
// 2.
func TestTeleportNPCRefusals(t *testing.T) {
	cases := []struct {
		name       string
		opts       teleportRigOpts
		gate, dest uint16
		code       uint16
	}{
		{"level 94 at the Alexandria harbour", teleportRigOpts{level: 94, gold: 10000}, 21, 177, teleport.ErrLevelRange},
		{"a GM at level 94 there", teleportRigOpts{level: 94, gold: 10000, gms: "alice"}, 21, 177, teleport.ErrLevelRange},
		{"an instanced destination", teleportRigOpts{level: 100, gold: 10000}, 46, 49, 0},
		{"a ferry has no link to the airship", teleportRigOpts{level: 100, gold: 10000}, 3, 18, teleportNoLink},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			tc.opts.network = npcTeleportFixture(t)
			rig := newTeleportRig(t, tc.opts)
			res := rig.use(tc.gate, tc.dest)
			if res.OK || res.Code != tc.code || res.Fee != 0 || res.Reason == "" {
				t.Fatalf("result %+v; want refused with code 0x%x and a reason", res, tc.code)
			}
			rig.noMove()
			if g := rig.gold(); g != tc.opts.gold {
				t.Fatalf("gold %d after a refusal; want %d", g, tc.opts.gold)
			}
		})
	}
}

// A GM crosses on the ferry free (OURS, the user's rule), at any level.
func TestTeleportNPCFreeForGMs(t *testing.T) {
	rig := newTeleportRig(t, teleportRigOpts{network: npcTeleportFixture(t), level: 50, gold: 100, gms: "alice"})
	res := rig.use(3, 4)
	if !res.OK || res.Fee != 0 || res.Waiver != teleport.WaiverGM {
		t.Fatalf("receipt %+v; want ok, free, the GM waiver", res)
	}
	wantAt(t, rig.arrival(), 25761, 636, 1482)
	if g := rig.gold(); g != 100 {
		t.Fatalf("gold %d; want 100", g)
	}
}

// Every link of the retail network, driven through the handler one after
// another by one character (the server has no range test, so each request is
// served wherever the last put her). Runs only when SRREVAMP_TELEPORT_DIR
// names a directory of the three CSVs cmd/export-refdata -mode teleport
// writes -- the operator's own export; no archive data is in the repo. For
// each link the level is set to the lowest its level rules allow, and the
// outcome expected is derived from the rows, not listed:
//
//   - the source point has no associated object: code 2 (nothing to talk to);
//   - the destination is in another game world or has a dungeon region:
//     refused, code 0 (OURS -- srrevamp has the open world only);
//   - a type-4/5 rule (the Roc quest item) or a type-6 rule: 0x1c23 / 0x1c24;
//   - otherwise: charged the link's fee (the level is above 20 unless a rule
//     keeps it lower) and moved to the destination point, exactly.
func TestTeleportEveryRetailLink(t *testing.T) {
	dir := os.Getenv("SRREVAMP_TELEPORT_DIR")
	if dir == "" {
		t.Skip("SRREVAMP_TELEPORT_DIR is not set (a directory of cmd/export-refdata -mode teleport's CSVs)")
	}
	tab, err := teleport.Load(dir)
	if err != nil {
		t.Fatalf("teleport.Load(%s): %v", dir, err)
	}
	const purse = int64(1) << 40
	rig := newTeleportRig(t, teleportRigOpts{network: tab, level: 100, gold: purse})
	ctx := context.Background()
	id := rig.players["Aria"].charID
	counts := map[string]int{}
	var moved []string
	for _, l := range tab.Links {
		src, _ := tab.PointByID(l.From)
		dst, _ := tab.PointByID(l.To)
		level, blocked := 21, uint16(0)
		lo, hi := 1, 255
		for _, r := range l.Rules {
			switch r.Type {
			case 1:
				lo, hi = max(lo, r.D1), min(hi, r.D2)
			case 4, 5:
				if r.D1 != 0 && blocked == 0 {
					blocked = teleport.ErrRocItem
				}
			case 6:
				if r.D1 == 0 && r.D2 == 0 && blocked == 0 {
					blocked = teleport.ErrRocJob
				}
			}
		}
		if lo > hi {
			t.Fatalf("link %d -> %d: its level rules admit no level (%d..%d)", l.From, l.To, lo, hi)
		}
		level = max(level, lo)
		if level > hi {
			level = hi
		}
		if err := rig.chars.SetLeveling(ctx, id, level, 0, 0, 20, 20); err != nil {
			t.Fatalf("SetLeveling: %v", err)
		}
		before, _ := rig.hub.EntityByCharacterID(id)
		gold := rig.gold()
		res := rig.use(uint16(l.From), uint16(l.To))
		name := fmt.Sprintf("link %d %s -> %d %s (level %d)", l.From, src.Code, l.To, dst.Code, level)
		wantCode, wantOK := uint16(0), false
		switch {
		case src.ObjectID == 0:
			wantCode, counts["no object at the source"] = teleportNoLink, counts["no object at the source"]+1
		case blocked != 0:
			wantCode, counts["the Roc rules"] = blocked, counts["the Roc rules"]+1
		case (dst.WorldID != 0 && dst.WorldID != teleport.MainWorld) || dst.Region < 0:
			counts["another world or a dungeon"]++
		default:
			wantOK = true
		}
		if !wantOK {
			if res.OK || res.Code != wantCode {
				t.Errorf("%s: %+v; want refused with code 0x%x", name, res, wantCode)
				continue
			}
			if p := rig.next("Aria", 50*time.Millisecond); p != nil {
				t.Errorf("%s: a refusal was followed by op 0x%04x", name, p.Opcode)
			}
			if after, _ := rig.hub.EntityByCharacterID(id); after.Pos != before.Pos || after.Zone != before.Zone {
				t.Errorf("%s: a refusal moved her from %+v to %+v", name, before, after)
			}
			continue
		}
		wantFee := l.Fee
		if level <= 20 {
			wantFee = 0
		}
		if !res.OK || res.Fee != wantFee {
			t.Errorf("%s: %+v; want ok with fee %d", name, res, wantFee)
			continue
		}
		czr := rig.arrival()
		fx, fy, ok := worldmap.ParseRegionLabel(czr.FrameRegion)
		rx, ry := worldmap.RegionXY(dst.Region)
		if !ok {
			t.Errorf("%s: frame %q", name, czr.FrameRegion)
			continue
		}
		x, z := worldmap.ToWorld(rx, ry, float64(dst.X), float64(dst.Z), fx, fy)
		if math.Abs(float64(czr.X)-x) > 0.01 || math.Abs(float64(czr.Z)-z) > 0.01 {
			t.Errorf("%s: arrived at (%v, %v) in %s; want the point %d/%d (%d, %d) = (%v, %v)",
				name, czr.X, czr.Z, czr.FrameRegion, rx, ry, dst.X, dst.Z, x, z)
		}
		if czr.Zone != teleportZoneFor(rx, ry) {
			t.Errorf("%s: zone %q; want %q", name, czr.Zone, teleportZoneFor(rx, ry))
		}
		if g := rig.gold(); g != gold-wantFee {
			t.Errorf("%s: gold %d; want %d", name, g, gold-wantFee)
		}
		for rig.next("Aria", 20*time.Millisecond) != nil {
		}
		counts["moved"]++
		if strings.Contains(src.Code, "_NPC_") {
			moved = append(moved, fmt.Sprintf("%d->%d", l.From, l.To))
		}
	}
	t.Logf("%d links: %v; NPC links moved (%d): %s", len(tab.Links), counts, len(moved), strings.Join(moved, " "))
}
