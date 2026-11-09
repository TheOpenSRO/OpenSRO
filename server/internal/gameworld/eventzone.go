package gameworld

import (
	"encoding/binary"
	"math"
	"sync/atomic"

	"github.com/TheOpenSRO/OpenSRO/server/internal/trigger"
)

// The event-zone states (READ s:0x683d90, game_worlds.md 8): a trigger's
// SWITCH_EVENTZONE sets 2 for ON and 1 for OFF.
const (
	ZoneOff uint8 = 1
	ZoneOn  uint8 = 2
)

// DoorBlockRadius is how far from a closed door's point a move is refused
// (OURS, game_worlds.md 14 item 9: what blocks movement at a closed door on
// the server is OPEN -- no navigation-mesh switch was found).
const DoorBlockRadius = 40.0

// zoneUIDSeq numbers the event-zone objects' unique ids (OURS range, beside
// the COS 0x7e000000 and NPC 0x7f000000 ones).
var zoneUIDSeq atomic.Uint32

const zoneUIDBase uint32 = 0x7d000000

// ZonePlace is where an event zone's structure stands. OPEN: the placement's
// source was not found (no table, nest or map list names the doors'
// positions); a zone without one switches state but spawns nothing and
// blocks nothing.
type ZonePlace struct {
	Region  uint16
	X, Y, Z float64
	Angle   uint16
}

// EventZoneObj is a layer's CGObjEventZone (game_worlds.md 8): one event
// zone its triggers name, with its state and the structure that shows it.
type EventZoneObj struct {
	Ref *EventZone
	// UID is the object id 0x351E names.
	UID   uint32
	State uint8
	// StructureCode is the structure the zone shows (strParam1, e.g.
	// STRUCTURE_GOD_BIG_GATE_TOGUI_1).
	StructureCode string
	Place         *ZonePlace
}

// Closed reports a door that still blocks (INFERRED: drawn while OFF,
// removed when switched ON).
func (z *EventZoneObj) Closed() bool { return z.State != ZoneOn }

// WireState is 0x351E's state byte: 0 builds the model, 1 removes it (READ
// c:0x5359c0). INFERRED: the server's OFF (1) is the client's 0 and its ON
// (2) the client's 1.
func (z *EventZoneObj) WireState() uint8 {
	if z.State == ZoneOn {
		return 1
	}
	return 0
}

// EncodeEventZoneState is 0x351E {u32 object, u8 0x10, u8 state} (READ
// c:0x89a7b0 -> c:0x5359c0).
func EncodeEventZoneState(uid uint32, wire uint8) []byte {
	b := make([]byte, 6)
	binary.LittleEndian.PutUint32(b, uid)
	b[4] = 0x10
	b[5] = wire
	return b
}

// buildZones makes the layer's event-zone objects: every zone its triggers
// switch or test, OFF (closed) at the start.
func (w *World) buildZones() {
	if w.mgr == nil || w.mgr.ref == nil {
		return
	}
	for _, t := range w.mgr.ref.Triggers.ForWorld(int(w.ID.World)) {
		names := []string{}
		for _, a := range t.Actions {
			if a.Kind == trigger.ActSwitchEventZone {
				names = append(names, a.Params.Get("EVENT_ZONE_SELECT"))
			}
		}
		for _, c := range t.Conditions {
			if c.Kind == trigger.CondZoneIn || c.Kind == trigger.CondZoneOut {
				names = append(names, c.Params.Get("EVENT_ZONE_SELECT"))
			}
		}
		for _, n := range names {
			if n == "" || w.zones[n] != nil {
				continue
			}
			ref := w.mgr.ref.EventZones[n]
			z := &EventZoneObj{Ref: ref, UID: zoneUIDBase + zoneUIDSeq.Add(1)&0x00ffffff, State: ZoneOff}
			if ref != nil {
				z.StructureCode = ref.Str[0]
			}
			if p, ok := w.mgr.zonePlaces[n]; ok {
				p := p
				z.Place = &p
			}
			w.zones[n] = z
		}
	}
}

// Zone is the layer's event zone named n, nil for none.
func (w *World) Zone(n string) *EventZoneObj { return w.zones[n] }

// Zones is every event zone of the layer.
func (w *World) Zones() []*EventZoneObj {
	out := make([]*EventZoneObj, 0, len(w.zones))
	for _, z := range w.zones {
		out = append(out, z)
	}
	return out
}

// SwitchEventZone is SWITCH_EVENTZONE: the zone's state, and on a change
// Hooks.ZoneSwitched (the 0x351E broadcast). Run on the world's goroutine.
func (w *World) SwitchEventZone(n string, on bool) {
	z := w.zones[n]
	if z == nil {
		return
	}
	st := ZoneOff
	if on {
		st = ZoneOn
	}
	if z.State == st {
		return
	}
	z.State = st
	if w.hooks.ZoneSwitched != nil {
		w.hooks.ZoneSwitched(w, z)
	}
}

// DoorBlocks reports whether a move from (x0, z0) to (x1, z1) passes within
// DoorBlockRadius of a closed, placed door of the layer (OURS mechanism).
// Read from any goroutine: the zones' states change only on the world's
// goroutine, and a stale read costs one move.
func (w *World) DoorBlocks(x0, z0, x1, z1 float64) bool {
	for _, z := range w.zones {
		if z.Place == nil || !z.Closed() {
			continue
		}
		if segmentDisc(x0, z0, x1, z1, z.Place.X, z.Place.Z, DoorBlockRadius) {
			return true
		}
	}
	return false
}

// segmentDisc reports whether the segment a-b comes within r of c.
func segmentDisc(ax, az, bx, bz, cx, cz, r float64) bool {
	dx, dz := bx-ax, bz-az
	l2 := dx*dx + dz*dz
	t := 0.0
	if l2 > 0 {
		t = ((cx-ax)*dx + (cz-az)*dz) / l2
		t = math.Max(0, math.Min(1, t))
	}
	px, pz := ax+t*dx-cx, az+t*dz-cz
	return px*px+pz*pz <= r*r
}

// StructureRecord is a structure's spawn record in the single (0x3015) and
// group (0x3019) spawns (forgotten_world.md 4, READ order c:0x8a6bd0 ->
// c:0x9c3a70 -> CIRuntimeStruct::vslot_025 c:0x56dfa0).
type StructureRecord struct {
	RefObjID uint32
	UID      uint32
	Region   uint16
	X, Y, Z  float32
	Angle    uint16
	// B260 is +0x260 (MEASURED 1, meaning OPEN); State is +0x261 (MEASURED 0
	// on the gate).
	B260, State uint8
	// Gate is a CITeleportGate's tail; Door a trigger door's.
	Gate *GateTail
	Door *DoorTail
}

// GateTail is the Dimension-hole gate's tail (MEASURED bytes): +0x254 1
// (INFERRED owner-restricted), +0x255 the access type (6 a named owner, 7 a
// party), the owner's name (type 6) or the party id (type 7), and +0x25c the
// hole's RefObjID.
type GateTail struct {
	Restricted uint8
	Access     uint8
	OwnerName  string
	PartyID    uint32
	HoleRefID  uint32
}

// DoorTail is a CIEventRuntimeObj's tail (READ c:0x535980: u32 event-zone
// key at +0x280 and u8 at +0x284; INFERRED that it follows the structure
// fields as the gate's tail does; which type id selects the door class is
// OPEN).
type DoorTail struct {
	ZoneKey uint32
	B284    uint8
}

// Encode is the record's bytes; single adds the 0x3015 trailer (u8 1).
func (r StructureRecord) Encode(single bool) []byte {
	b := make([]byte, 0, 48)
	b = binary.LittleEndian.AppendUint32(b, r.RefObjID)
	b = binary.LittleEndian.AppendUint32(b, r.UID)
	b = binary.LittleEndian.AppendUint16(b, r.Region)
	b = binary.LittleEndian.AppendUint32(b, math.Float32bits(r.X))
	b = binary.LittleEndian.AppendUint32(b, math.Float32bits(r.Y))
	b = binary.LittleEndian.AppendUint32(b, math.Float32bits(r.Z))
	b = binary.LittleEndian.AppendUint16(b, r.Angle)
	b = append(b, r.B260, r.State)
	if g := r.Gate; g != nil {
		b = append(b, g.Restricted, g.Access)
		if g.Access == 7 {
			b = binary.LittleEndian.AppendUint32(b, g.PartyID)
		} else {
			b = binary.LittleEndian.AppendUint16(b, uint16(len(g.OwnerName)))
			b = append(b, g.OwnerName...)
		}
		b = binary.LittleEndian.AppendUint32(b, g.HoleRefID)
	}
	if d := r.Door; d != nil {
		b = binary.LittleEndian.AppendUint32(b, d.ZoneKey)
		b = append(b, d.B284)
	}
	if single {
		b = append(b, 1)
	}
	return b
}
