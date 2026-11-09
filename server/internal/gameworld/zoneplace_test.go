package gameworld

import (
	"math"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/reftable"
)

// TestZonePlacesFromObjectStrings: an OBJECT event zone stands at the named
// position of the same name (READ s:0x5304e0, the name matched without case);
// a zone of another kind, or one with no entry, gets no place. Synthetic rows.
func TestZonePlacesFromObjectStrings(t *testing.T) {
	ez := reftable.New("Service", "ID", "ZoneName", "EventName", "Param1", "Param2", "Param3", "Param4", "Param5",
		"strParam1", "strParam2", "strParam3", "strParam4", "strParam5")
	ez.Append("1", "901", "POS_STRUCTURE_TEST_DOOR_1", "OBJECT", "4", "2", "0", "0", "0", "STRUCTURE_TEST_DOOR_1", "xxx", "xxx", "xxx", "xxx")
	ez.Append("1", "902", "POS_STRUCTURE_TEST_DOOR_2", "OBJECT", "4", "2", "0", "0", "0", "STRUCTURE_TEST_DOOR_2", "xxx", "xxx", "xxx", "xxx")
	ez.Append("1", "903", "GATE_TEST_IN", "TELEPORT", "0", "0", "0", "0", "0", "GATE_TEST_IN", "xxx", "xxx", "xxx", "xxx")
	os := reftable.New(ObjectStringColumns...)
	os.Append("30000", "100.5", "20.25", "-7", "0", "pos_structure_test_door_1")
	os.Append("32786", "-1", "2", "3", "3.14159265", "POS_STRUCTURE_TEST_DOOR_9")
	os.Append("30001", "1", "1", "1", "0", "GATE_TEST_IN")
	wt := reftable.New("ID", "WorldCodeName128", "Type")
	wt.Append("1", "INS_DEFAULT", "0")
	tables := map[string]*reftable.Table{TableWorld: wt, TableEventZone: ez, TableObjectString: os}
	ref, err := Build(func(n string) *reftable.Table { return tables[n] })
	if err != nil {
		t.Fatal(err)
	}
	if len(ref.ZonePlaces) != 1 {
		t.Fatalf("places %v, want the one OBJECT zone with an entry", ref.ZonePlaces)
	}
	p, ok := ref.ZonePlaces["POS_STRUCTURE_TEST_DOOR_1"]
	if !ok || p.Region != 30000 || p.X != 100.5 || p.Y != 20.25 || p.Z != -7 {
		t.Errorf("door 1 at %+v", p)
	}
	m := NewManager(ManagerConfig{Ref: ref})
	if _, ok := m.zonePlaces["POS_STRUCTURE_TEST_DOOR_1"]; !ok {
		t.Errorf("the manager does not take the reference data's places")
	}
}

// TestAngleOfYaw: the wire angle the client turns (adding its quarter turn,
// RemoteFacing.from_wire_angle) into the map object's facing for that yaw.
func TestAngleOfYaw(t *testing.T) {
	for _, c := range []struct {
		yaw  float64
		want uint16
	}{{math.Pi / 2, 0}, {math.Pi, 16384}, {0, 49152}, {-math.Pi / 2, 32768}, {2*math.Pi + math.Pi/2, 0}} {
		if got := angleOfYaw(c.yaw); got != c.want {
			t.Errorf("yaw %.4f: %d, want %d", c.yaw, got, c.want)
		}
	}
}
