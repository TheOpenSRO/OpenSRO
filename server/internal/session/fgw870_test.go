package session

import (
	"context"
	"encoding/binary"
	"fmt"
	"math"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gameworld"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npctalk"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/reftable"
	"github.com/TheOpenSRO/OpenSRO/server/internal/trigger"
)

// Round 870 (stage 3): the halves together. Synthetic ids throughout.

const testDoorZone = "POS_STRUCTURE_GOD_BIG_GATE_TOGUI_3"

// doorTables adds to gwRef's world 63 one trigger door: an OBJECT event zone
// (ID 238) its trigger switches ON on a kill, standing 40 west of the start
// by objectstring.ifo's named position, and a second OBJECT zone the triggers
// never name (no object for it).
func doorTables(tabs map[string]*reftable.Table) {
	ez := reftable.New("Service", "ID", "ZoneName", "EventName", "Param1", "Param2", "Param3", "Param4", "Param5",
		"strParam1", "strParam2", "strParam3", "strParam4", "strParam5")
	ez.Append("1", "238", testDoorZone, "OBJECT", "4", "2", "0", "0", "0", "STRUCTURE_GOD_BIG_GATE_TOGUI_3", "xxx", "xxx", "xxx", "xxx")
	ez.Append("1", "239", "POS_STRUCTURE_GOD_UNUSED", "OBJECT", "4", "2", "0", "0", "0", "STRUCTURE_GOD_UNUSED", "xxx", "xxx", "xxx", "xxx")
	tabs[gameworld.TableEventZone] = ez
	os := reftable.New(gameworld.ObjectStringColumns...)
	os.Append(fmt.Sprint(0x7EE4), "1023", "693", "1125", fmt.Sprint(math.Pi/2), testDoorZone)
	os.Append(fmt.Sprint(0x7EE4), "900", "693", "1125", "0", "POS_STRUCTURE_GOD_UNUSED")
	tabs[gameworld.TableObjectString] = os
	com := reftable.New("Service", "ID", "CodeName128", "TID1")
	com.Append("1", "5", trigger.EventMonsterKill, "1")
	com.Append("1", "17", trigger.ActSwitchEventZone, "3")
	tabs["_RefTriggerCommon"] = com
	tr := reftable.New("Service", "ID", "CodeName128", "IsActive", "IsRepeat")
	tr.Append("1", "173", "TRI_TEST_DOOR", "1", "0")
	tabs["_RefTrigger"] = tr
	ev := reftable.New("Service", "ID", "RefTriggerCommonID")
	ev.Append("1", "1", "5")
	tabs["_RefTriggerEvent"] = ev
	be := reftable.New("Service", "ID", "TriggerID", "TriggerEventID")
	be.Append("1", "1", "173", "1")
	tabs["_RefTriggerBindEvent"] = be
	a := reftable.New("Service", "ID", "RefTriggerCommonID", "Delay", "ParamGroupCodeName128")
	a.Append("1", "1", "17", "0", "A1")
	tabs["_RefTriggerAction"] = a
	ba := reftable.New("Service", "ID", "TriggerID", "TriggerActionID")
	ba.Append("1", "1", "173", "1")
	tabs["_RefTriggerBindAction"] = ba
	ap := reftable.New("Service", "ID", "GroupCodeName128", "ValueCodeName128", "Value", "Type")
	ap.Append("1", "1", "A1", "EVENT_ZONE_SELECT", testDoorZone, "STRING")
	ap.Append("1", "2", "A1", "ON_OFF_SWITCH", "ON", "STRING")
	tabs["_RefTriggerActionParam"] = ap
	cat := reftable.New("Service", "ID", "CodeName128")
	cat.Append("1", "4", "TRI_CATEGORY_TEST_DOOR")
	tabs["_RefTriggerCategory"] = cat
	cbt := reftable.New("Service", "ID", "TriggerCategoryID", "TriggerID")
	cbt.Append("1", "1", "4", "173")
	tabs["_RefTriggerCategoryBindTrigger"] = cbt
	wb := reftable.New("Service", "ID", "GameWorldID", "TriggerCategoryID")
	wb.Append("1", "1", "63", "4")
	tabs["_RefGameWorldBindTriggerCategory"] = wb
}

// TestDoorsOnTheWire: a layer's placed door reaches the player inside as a
// 0x3015 of 36513 STORE_EVENTZONE_DEFAULT at its objectstring.ifo place,
// with the whole runtime-structure record before the zone's key (READ
// c:0x535980 -> c:0x56dfa0), state 0 (built); the zone switched ON sends
// 0x351E {uid, 0x10, 1}; a player arriving after that gets the record with
// state 1 (removed).
func TestDoorsOnTheWire(t *testing.T) {
	gwRefExtra = doorTables
	defer func() { gwRefExtra = nil }()
	rig := newGWRig(t, nil, map[string]int{"Aria": 40, "Bram": 40})
	w := rig.open(t)
	z := w.Zone(testDoorZone)
	if z == nil || z.Place == nil || z.Place.Region != 0x7EE4 || z.Place.X != 1023 {
		t.Fatalf("the door's zone %+v: want it placed from objectstring", z)
	}
	if w.Zone("POS_STRUCTURE_GOD_UNUSED") != nil {
		t.Errorf("a zone no trigger names has an object")
	}
	aria := rig.players["Aria"]
	if err := EnterInstance(context.Background(), aria.sess, w, "test"); err != nil {
		t.Fatal(err)
	}
	rig.until("Aria", OpChangeZoneResult)
	reconcile := func() {
		done := make(chan struct{})
		w.Post(func() { reconcileGates(w.Hub, w.Hub.AllEntities()); close(done) })
		<-done
	}
	reconcile()
	rec := rig.until("Aria", npcspawn.OpSingleSpawn).Data
	if binary.LittleEndian.Uint32(rec) != gameworld.DoorRefObjID || binary.LittleEndian.Uint32(rec[4:]) != z.UID {
		t.Fatalf("spawn % x, want the door (36513, uid %#x)", rec, z.UID)
	}
	if region := binary.LittleEndian.Uint16(rec[8:]); region != 0x7EE4 {
		t.Errorf("region %#x", region)
	}
	if x := math.Float32frombits(binary.LittleEndian.Uint32(rec[10:])); x != 1023 {
		t.Errorf("x %v, want objectstring's 1023", x)
	}
	if angle := binary.LittleEndian.Uint16(rec[22:]); angle != 0 {
		t.Errorf("angle %d, want 0 for yaw pi/2", angle)
	}
	if got := fmt.Sprintf("% x", rec[24:]); got != "01 00 00 00 00 00 00 00 00 00 00 00 ee 00 00 00 00 01" {
		t.Errorf("record tail %s", got)
	}
	// The trigger opens it: 0x351E state 1.
	w.Post(func() { w.SwitchEventZone(testDoorZone, true) })
	w.Sync()
	if got := fmt.Sprintf("% x", rig.until("Aria", proto.OpEventZoneState).Data); got != fmt.Sprintf("% x", gameworld.EncodeEventZoneState(z.UID, 1)) {
		t.Errorf("0x351E %s", got)
	}
	// A later arrival is told the state in the record.
	bram := rig.players["Bram"]
	if err := EnterInstance(context.Background(), bram.sess, w, "test"); err != nil {
		t.Fatal(err)
	}
	rig.until("Bram", OpChangeZoneResult)
	reconcile()
	if rec := rig.until("Bram", npcspawn.OpSingleSpawn).Data; rec[25] != 1 {
		t.Errorf("the open door's state byte %d, want 1 (removed)", rec[25])
	}
}

// TestInstanceNPCSelect: the exit NPC 167 units from the start (MEASURED
// world 67's: the NPC nest at local (896.24, 692.16, 1122.54), the start at
// (1063, 693, 1125)) answers a select with the MEASURED {01, npc, 00, 01, 29,
// 00}.
func TestInstanceNPCSelect(t *testing.T) {
	f := newFGWRig(t, map[string]int{"Aria": 40})
	w := f.open(t)
	uid := NextInstanceNPCUID()
	SetInstanceNPCs(w, []npcspawn.NPC{{Record: npcspawn.Record{RefID: 36032, UID: uid, Region: 0x7EE4, X: 896.24, Y: 692.16, Z: 1122.54,
		Interact: []byte{0x29}}, Code: "NPC_INS_EXIT_TELEPORT"}}, nil)
	aria := f.players["Aria"]
	if err := EnterInstance(context.Background(), aria.sess, w, "test"); err != nil {
		t.Fatal(err)
	}
	f.until("Aria", OpChangeZoneResult)
	f.send("Aria", npctalk.OpSelect, binary.LittleEndian.AppendUint32(nil, uid))
	want := append(append([]byte{1}, binary.LittleEndian.AppendUint32(nil, uid)...), 0, 1, 0x29, 0)
	if got := f.until("Aria", npctalk.OpSelectResult).Data; fmt.Sprintf("% x", got) != fmt.Sprintf("% x", want) {
		t.Errorf("select %x, want %x", got, want)
	}
}

// TestRestoredHeight: a saved height is read as the wire's region-local one
// or as an older client's frame-anchored scene height plus the anchor,
// whichever lies on a surface; a frame with a small anchor keeps the local
// reading. Synthetic surfaces: a terrain at 692.5 and a deck at 900 (Togui's
// anchor 833.58).
func TestRestoredHeight(t *testing.T) {
	surfaces := []float64{692.5, 900}
	near := func(refY float64) (float64, bool) {
		best, gap := 0.0, math.Inf(1)
		for _, s := range surfaces {
			if d := math.Abs(s - refY); d < gap {
				best, gap = s, d
			}
		}
		return best, true
	}
	for _, c := range []struct {
		name          string
		saved, anchor float64
		want          float64
	}{
		{"saved local, on the terrain", 692.5, 833.58, 692.5},
		{"saved local, on the deck", 899.6, 833.58, 900},
		{"saved anchored (before round 870), on the terrain", 692.5 - 833.58, 833.58, 692.5},
		{"saved anchored, on the deck", 900 - 833.58, 833.58, 900},
		{"a small anchor (Jangan's)", 692.0, -2.49, 692.5},
	} {
		if got := restoredHeight(c.saved, c.anchor, near); math.Abs(got-c.want) > 1e-9 {
			t.Errorf("%s: %.2f, want %.2f", c.name, got, c.want)
		}
	}
	if got := restoredHeight(5, 100, func(float64) (float64, bool) { return 0, false }); got != 5 {
		t.Errorf("no surface: %.2f, want the saved 5", got)
	}
}

// TestCoolTimePushes: MEASURED, a new re-entry limit's 0x320C comes twice at
// the entry, a running one's once (a re-entry), and the arrival back in town
// carries it once.
func TestCoolTimePushes(t *testing.T) {
	rig := newGWRig(t, nil, map[string]int{"Aria": 40})
	w := rig.open(t)
	aria := rig.players["Aria"]
	count := func(what string, want int) {
		t.Helper()
		got := rig.collect("Aria", 400*time.Millisecond, proto.OpTimedJobPush)
		if len(got) != want {
			t.Errorf("%s: %d 0x320C, want %d", what, len(got), want)
		}
		for _, p := range got {
			if p.Data[0] != 0x0C || binary.LittleEndian.Uint32(p.Data[1:]) != 1 {
				t.Errorf("%s: 0x320C % x", what, p.Data)
			}
		}
	}
	if err := EnterInstance(context.Background(), aria.sess, w, "test"); err != nil {
		t.Fatal(err)
	}
	count("the first entry", 2)
	if err := returnFromInstance(context.Background(), aria.sess, w.Hub, "test"); err != nil {
		t.Fatal(err)
	}
	count("the arrival back in town", 1)
	if err := EnterInstance(context.Background(), aria.sess, w, "test"); err != nil {
		t.Fatal(err)
	}
	count("the re-entry", 1)
}
