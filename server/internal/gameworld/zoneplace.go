package gameworld

import (
	"math"
	"strings"

	"github.com/TheOpenSRO/OpenSRO/server/internal/reftable"
)

// TableObjectString is the client archive's navmesh\objectstring.ifo as the
// export writes it (OURS file name, round 870): one row per named position
// {Region, X, Y, Z, Yaw, Name}, region-local (dungeon space for a 0x80xx
// region), the yaw in radians.
//
// READ (round 870): the game server loads the same file into its region
// manager's named positions at start-up (RegionManagerBody::FUN_0098c7f0
// s:0x98c7f0: "%x %x %d %d %x %x %x %x" and the quoted name, lower-cased),
// and CMainProcess::FUN_005304e0 (s:0x5304e0) looks every _RefEventZone row
// up there by its ZoneName (the position kept at the zone's +0xdc); a zone of
// kind OBJECT whose region this server holds is filed for its structure
// (s:0x6a2e20). So a trigger door (POS_STRUCTURE_GOD_*) stands where
// objectstring.ifo names it -- the placement round 869 left OPEN.
const TableObjectString = "objectstring"

// ObjectStringColumns are the export's columns, in order.
var ObjectStringColumns = []string{"Region", "X", "Y", "Z", "Yaw", "Name"}

// ZoneEventObject is the EventName of an event zone shown by a structure.
const ZoneEventObject = "OBJECT"

// DoorRefObjID is the object a trigger door travels as: 36513
// STORE_EVENTZONE_DEFAULT, the only not-bionic TypeID 4/2 row (MEASURED), which
// the client builds as a CIEventRuntimeObj (READ c:0x9c1fa0 -> c:0x9c1cc0)
// and draws with its event zone's model (c:0x535750).
const DoorRefObjID = 36513

// angleOfYaw is the wire angle (u16, 65536 to a turn) that the client turns
// into the same facing as a map object placed with yaw (radians): the client
// adds a quarter turn to every object's wire angle (c:0x9c40b0; the client's
// RemoteFacing.from_wire_angle) and draws a map object at -yaw (NavGraph's
// godot_yaw). INFERRED: the original server's conversion of the
// objectstring yaw for the zone's structure was not read.
func angleOfYaw(yaw float64) uint16 {
	t := (yaw - math.Pi/2) / (2 * math.Pi)
	t -= math.Floor(t)
	return uint16(int(math.Round(t*65536)) & 0xffff)
}

// buildZonePlaces fills ref.ZonePlaces: each OBJECT event zone's named
// position, matched by name without case (the loader lower-cases the names).
func buildZonePlaces(ref *Ref, t *reftable.Table) {
	ref.ZonePlaces = map[string]ZonePlace{}
	if t == nil {
		return
	}
	byName := map[string][]string{}
	for _, r := range t.Rows {
		byName[strings.ToLower(t.Get(r, "Name"))] = r
	}
	for name, z := range ref.EventZones {
		if !strings.EqualFold(z.Event, ZoneEventObject) {
			continue
		}
		r, ok := byName[strings.ToLower(name)]
		if !ok {
			continue
		}
		ref.ZonePlaces[name] = ZonePlace{Region: uint16(t.Int(r, "Region")), X: t.Float(r, "X"), Y: t.Float(r, "Y"),
			Z: t.Float(r, "Z"), Angle: angleOfYaw(t.Float(r, "Yaw"))}
	}
}
