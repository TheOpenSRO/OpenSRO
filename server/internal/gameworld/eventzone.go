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

// zoneUIDSeq numbers the event-zone objects' unique ids (OURS range
// 0x7d000000..0x7d3fffff -- round 869 lane W3 gives 0x7d400000.. to the
// Dimension-hole gates --, beside the COS 0x7e000000 and NPC 0x7f000000 ones).
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
	// Yaw is the named position's own yaw in radians (objectstring.ifo), the
	// one Angle is made from (angleOfYaw).
	Yaw float64
}

// DoorBlock is where a closed door stops a mover in its layer's frame (round
// 879): the door's point and, when the navigation export has the door
// model's own navigation mesh, its blocking outline placed as a map object
// at the door's point and yaw (segments {x0, z0, x1, z1}). MEASURED: the
// Wrecked Ship's door model (wreck_event_door.bsr) names wreck_eventdoor01.bms,
// whose navigation mesh is one 153.6 x 31.2 rectangle of two cells with every
// outline edge blocking both ways (flags 0x3) -- a slab a mover cannot enter
// or cross. INFERRED: the original stops a mover at that outline while the
// door stands; how it registers the mesh at run time was not found (the
// client's CIEventRuntimeObj::FUN_00535750 builds the model, the server's
// CGObjEventZone keeps the state, s:0x52de60), so the mechanism is OURS.
type DoorBlock struct {
	X, Z float64
	Segs [][4]float64
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
	// Block is the door's footprint in the layer's frame (round 879), set
	// when the layer opens (session's openWorldRuntime) before any player
	// is in; nil: the door's Place is taken as the frame point (a test).
	Block *DoorBlock
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
			z := &EventZoneObj{Ref: ref, UID: zoneUIDBase + zoneUIDSeq.Add(1)&0x003fffff, State: ZoneOff}
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

// doorNudge is how far short of a door's outline a stopped move ends (the
// walk's own wall nudge, READ: at most 0.2 back from the crossing).
const doorNudge = 0.2

// DoorStop is where a move from (x0, z0) to (x1, z1) in the layer's frame
// stops at a closed door (round 879; read from any goroutine: the zones'
// states change only on the world's goroutine, and a stale read costs one
// move): a door with a footprint stops it
// doorNudge short of the first outline segment it crosses; one without, at
// its start when it passes within DoorBlockRadius of the door's point (round
// 869's OURS block, now at the frame point, not the region-local one).
func (w *World) DoorStop(x0, z0, x1, z1 float64) (sx, sz float64, blocked bool) {
	best := math.Inf(1)
	for _, z := range w.zones {
		if z.Place == nil || !z.Closed() {
			continue
		}
		b := z.Block
		if b == nil {
			b = &DoorBlock{X: z.Place.X, Z: z.Place.Z}
		}
		if len(b.Segs) == 0 {
			if segmentDisc(x0, z0, x1, z1, b.X, b.Z, DoorBlockRadius) && best > 0 {
				best = 0
			}
			continue
		}
		for _, sg := range b.Segs {
			if t, ok := segmentCross(x0, z0, x1, z1, sg); ok && t < best {
				best = t
			}
		}
	}
	if math.IsInf(best, 1) {
		return x1, z1, false
	}
	dx, dz := x1-x0, z1-z0
	l := math.Hypot(dx, dz)
	back := 0.0
	if l > 0 {
		back = math.Min(best, doorNudge/l)
	}
	t := best - back
	return x0 + dx*t, z0 + dz*t, true
}

// segmentCross is where (as a fraction of a-b) the segment a-b crosses sg,
// ok false when it does not.
func segmentCross(ax, az, bx, bz float64, sg [4]float64) (float64, bool) {
	rx, rz := bx-ax, bz-az
	sx, sz := sg[2]-sg[0], sg[3]-sg[1]
	den := rx*sz - rz*sx
	if den == 0 {
		return 0, false
	}
	qx, qz := sg[0]-ax, sg[1]-az
	t := (qx*sz - qz*sx) / den
	u := (qx*rz - qz*rx) / den
	if t < 0 || t > 1 || u < 0 || u > 1 {
		return 0, false
	}
	return t, true
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
//
// READ (round 870, c:0x56dfa0): after the CIGIDObject head every runtime
// structure carries u8 +0x260, u8 +0x261 (the state), u8 +0x254, u8 +0x255
// (the access type), then a u16-length ANSI name when +0x255 is 6 and a u32
// (+0x258) for any other value, then u32 +0x25c. A CIEventRuntimeObj (a
// trigger door, c:0x535980) reads that whole record first and only then u32
// +0x280 (the event zone) and u8 +0x284.
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
// party), the owner's name (type 6) or the party id (any other type: the
// u32 +0x258), and +0x25c the hole's RefObjID.
type GateTail struct {
	Restricted uint8
	Access     uint8
	OwnerName  string
	PartyID    uint32
	HoleRefID  uint32
}

// DoorTail is a CIEventRuntimeObj's part of the record: the runtime
// structure's fields (+0x254, +0x255, the name or u32 +0x258, u32 +0x25c;
// INFERRED all zero for a door: no owner rule), then u32 +0x280, the event
// zone's key (the _RefEventZone ID, eventzonedata.txt column 1), and u8
// +0x284 (READ c:0x535980; its meaning OPEN, sent 0).
type DoorTail struct {
	B254, Access uint8
	Name         string
	U258, U25C   uint32
	ZoneKey      uint32
	B284         uint8
}

// appendRuntime is CIRuntimeStruct::vslot_025's part after +0x261 (READ
// c:0x56dfa0): the name only for access type 6, the u32 for any other.
func appendRuntime(b []byte, b254, access uint8, name string, u258, u25c uint32) []byte {
	b = append(b, b254, access)
	if access == AccessOwner {
		b = binary.LittleEndian.AppendUint16(b, uint16(len(name)))
		b = append(b, name...)
	} else {
		b = binary.LittleEndian.AppendUint32(b, u258)
	}
	return binary.LittleEndian.AppendUint32(b, u25c)
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
	switch {
	case r.Gate != nil:
		g := r.Gate
		b = appendRuntime(b, g.Restricted, g.Access, g.OwnerName, g.PartyID, g.HoleRefID)
	case r.Door != nil:
		d := r.Door
		b = appendRuntime(b, d.B254, d.Access, d.Name, d.U258, d.U25C)
		b = binary.LittleEndian.AppendUint32(b, d.ZoneKey)
		b = append(b, d.B284)
	default:
		b = appendRuntime(b, 0, 0, "", 0, 0)
	}
	if single {
		b = append(b, 1)
	}
	return b
}
