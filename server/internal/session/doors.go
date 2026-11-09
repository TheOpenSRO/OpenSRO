package session

import (
	"github.com/TheOpenSRO/OpenSRO/server/internal/gameworld"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 870: a layer's trigger doors on the wire. Each OBJECT event zone the
// layer's triggers switch is a structure standing at its objectstring.ifo
// position (READ s:0x5304e0, gameworld zoneplace.go), sent as the client's
// CIEventRuntimeObj -- 36513 STORE_EVENTZONE_DEFAULT with its zone's key --
// to the layer's players whose window holds it (the gates' window, fgw.go's
// reconcileGates), with its state in the record's +0x261 (0 built, 1
// removed: the same byte 0x351E sets, c:0x5359c0).

// doorView is one placed door of a layer as the window reconcile reads it.
type doorView struct {
	uid    uint32
	zone   string
	pos    world.Position
	record gameworld.StructureRecord
}

// isDoorUID reports an event-zone object's uid (gameworld's OURS range
// 0x7d000000..0x7d3fffff; the gates' start at 0x7d400000).
func isDoorUID(uid uint32) bool { return uid >= 0x7d000000 && uid < 0x7d400000 }

// placedDoors is hub's layer's doors that have a place, nil for the open
// world or a layer without any.
func placedDoors(hub *world.Hub) []doorView {
	w := instanceOf(hub)
	if w == nil {
		return nil
	}
	var out []doorView
	for _, z := range w.Zones() {
		if z.Place == nil || z.Ref == nil {
			continue
		}
		p := z.Place
		bucket, pos, ok := InstancePlace(w, p.Region, p.X, p.Y, p.Z)
		if !ok {
			continue
		}
		out = append(out, doorView{uid: z.UID, zone: bucket, pos: pos, record: doorRecord(z)})
	}
	return out
}

// doorRecord is z's spawn record: the head at its place, +0x260 1 (as every
// structure record measured; INFERRED for a door), the state, the runtime
// fields all zero (no owner rule; INFERRED) and the zone's key.
func doorRecord(z *gameworld.EventZoneObj) gameworld.StructureRecord {
	p := z.Place
	return gameworld.StructureRecord{RefObjID: gameworld.DoorRefObjID, UID: z.UID, Region: p.Region,
		X: float32(p.X), Y: float32(p.Y), Z: float32(p.Z), Angle: p.Angle, B260: 1, State: z.WireState(),
		Door: &gameworld.DoorTail{ZoneKey: uint32(z.Ref.ID)}}
}
