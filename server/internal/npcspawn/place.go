package npcspawn

import (
	"math"
	"sort"

	"github.com/OpenSRO/OpenSRO/server/internal/nest"
)

// Row is one npcpos row (the client's own placement table, READ).
type Row struct {
	RefID   int64
	Region  int
	X, Y, Z float64
}

// Source says where a placed NPC's position and angle come from.
type Source uint8

const (
	// FromNest: the DB nest at the row's spot hatches this NPC (the nest's
	// tactics row names its species). Position and angle are the nest's, as
	// Nest_Hatch 0x5607b0 spawns it: the angle is wInitialDir (+0x1c, READ).
	FromNest Source = iota
	// FromNpcpos: no nest of the NPC's own within JoinTolerance, or no DB --
	// the npcpos position and no angle (OURS, the stand-in the client faces
	// by its own heuristic; OpNpcFacingUnknown).
	FromNpcpos
)

func (s Source) String() string {
	if s == FromNest {
		return "nest"
	}
	return "npcpos"
}

// NPC is one placed NPC.
type NPC struct {
	Record
	Code   string // characterdata CodeName, "" without an NPC table
	Source Source
	NestID int64
	// Near: the nest came from the second pass (NearRadius), not from the
	// row's own spot.
	Near bool
}

// UIDBase is the first unique id an NPC gets: OpenSRO's monsters and
// characters take their ids from their own counters, so the NPCs are kept in
// a range of their own (OURS; retail has one id space for every object).
const UIDBase uint32 = 0x7f000000

// JoinTolerance is how far a nest may stand from an npcpos row and still be
// its nest: nest.JoinTolerance, the round-660 measurement (MEASURED again in
// round 708: every NPC row with a nest of its own species has it within
// 0.0002 units).
const JoinTolerance = nest.JoinTolerance

// NearRadius is the second pass's reach (round 708's review; OURS, from a
// measurement): an npcpos row with no nest of its own within JoinTolerance
// takes the nearest unclaimed nest of its own species in its own region
// within this many units. In the original the server's NPCs ARE the nests
// (Nest_Hatch places each at its nest; npcpos is the client's table), so a
// nest of the NPC's own species a short way off is where that server puts
// it. MEASURED on the user's shard (EXTERNAL): two rows take one this way --
// NPC_CH_EVENT_KISAENG1 in region 26265 (its nest 58 units off) and
// NPC_BATTLE_ARENA_MANAGER in the same region (178 off) -- and no other row
// has an own-species nest in its region at any distance. That the shard
// moved those two (rather than meaning another NPC) is INFERRED.
const NearRadius = 200.0

// Info is what the placement needs of an NPC's reference row.
type Info struct {
	Code string
}

// Report counts what Place did, per source and per area.
type Report struct {
	Rows, FromNest, FromNpcpos int
	// NestTaken is the rows whose only own-species nests were claimed by an
	// earlier row (they fall back to npcpos).
	NestTaken int
	// MaxDist is the farthest a claimed nest stood from its row (first pass).
	MaxDist float64
	// Near is the rows placed by the second pass (NearRadius), NearMaxDist
	// the farthest of those nests from its row.
	Near        int
	NearMaxDist float64
}

// Place builds the NPCs from rows: each row is placed at its own nest -- the
// nest within JoinTolerance whose tactics row (dwTacticsID -> dwObjID) names
// the row's species, nearest first, one row per nest -- or, failing that, at
// the row's own position with no angle. info may be nil (no codes, so no
// interactions); interactions computes a code's interaction set (nil: none).
// The result is in a stable order (region, x, z, id) with uids UIDBase + i.
func Place(rows []Row, db *nest.DB, info func(int64) (Info, bool), interactions func(refID int64, code string) (byte, []byte)) ([]NPC, Report) {
	rows = append([]Row(nil), rows...)
	for i := range rows {
		rows[i].Region = int(uint16(rows[i].Region))
	}
	sort.SliceStable(rows, func(i, j int) bool {
		a, b := rows[i], rows[j]
		if a.Region != b.Region {
			return a.Region < b.Region
		}
		if a.X != b.X {
			return a.X < b.X
		}
		if a.Z != b.Z {
			return a.Z < b.Z
		}
		return a.RefID < b.RefID
	})
	rep := Report{Rows: len(rows)}
	byRegion := map[int][]int{}
	if db != nil {
		for k := range db.Nests {
			byRegion[db.Nests[k].Region] = append(byRegion[db.Nests[k].Region], k)
		}
	}
	type pair struct {
		row, nest int
		d         float64
	}
	var pairs []pair
	within := make([]bool, len(rows))
	for i, r := range rows {
		if db == nil {
			break
		}
		for _, k := range byRegion[r.Region] {
			n := &db.Nests[k]
			t := db.Tactics[n.TacticsID]
			if t == nil || t.ObjID != r.RefID {
				continue
			}
			d := math.Hypot(n.X-r.X, n.Z-r.Z)
			if d > JoinTolerance {
				continue
			}
			within[i] = true
			pairs = append(pairs, pair{i, k, d})
		}
	}
	sort.SliceStable(pairs, func(x, y int) bool {
		a, b := pairs[x], pairs[y]
		if a.d != b.d {
			return a.d < b.d
		}
		if a.row != b.row {
			return a.row < b.row
		}
		return a.nest < b.nest
	})
	own := make([]int, len(rows))
	for i := range own {
		own[i] = -1
	}
	used := map[int]bool{}
	for _, p := range pairs {
		if own[p.row] >= 0 || used[p.nest] {
			continue
		}
		own[p.row], used[p.nest] = p.nest, true
		rep.MaxDist = math.Max(rep.MaxDist, p.d)
	}
	// The second pass (NearRadius): the rows still without a nest take the
	// nearest unclaimed nest of their own species in their region.
	near := make([]bool, len(rows))
	if db != nil {
		var far []pair
		for i, r := range rows {
			if own[i] >= 0 {
				continue
			}
			for _, k := range byRegion[r.Region] {
				n := &db.Nests[k]
				t := db.Tactics[n.TacticsID]
				if used[k] || t == nil || t.ObjID != r.RefID {
					continue
				}
				if d := math.Hypot(n.X-r.X, n.Z-r.Z); d <= NearRadius {
					far = append(far, pair{i, k, d})
				}
			}
		}
		sort.SliceStable(far, func(x, y int) bool {
			a, b := far[x], far[y]
			if a.d != b.d {
				return a.d < b.d
			}
			if a.row != b.row {
				return a.row < b.row
			}
			return a.nest < b.nest
		})
		for _, p := range far {
			if own[p.row] >= 0 || used[p.nest] {
				continue
			}
			own[p.row], used[p.nest], near[p.row] = p.nest, true, true
			rep.Near++
			rep.NearMaxDist = math.Max(rep.NearMaxDist, p.d)
		}
	}
	out := make([]NPC, 0, len(rows))
	for i, r := range rows {
		n := NPC{Record: Record{RefID: uint32(r.RefID), UID: UIDBase + uint32(i), Region: uint16(r.Region),
			X: float32(r.X), Y: float32(r.Y), Z: float32(r.Z)}, Source: FromNpcpos}
		if k := own[i]; k >= 0 {
			ns := &db.Nests[k]
			n.Source, n.NestID = FromNest, ns.ID
			n.X, n.Z = float32(ns.X), float32(ns.Z)
			if ns.HasY {
				n.Y = float32(ns.Y)
			}
			n.Angle = ns.Dir
			n.Near = near[i]
			rep.FromNest++
		} else {
			if within[i] {
				rep.NestTaken++
			}
			rep.FromNpcpos++
		}
		if info != nil {
			if in, ok := info(r.RefID); ok {
				n.Code = in.Code
			}
		}
		if interactions != nil {
			n.Flags, n.Interact = interactions(r.RefID, n.Code)
		}
		out = append(out, n)
	}
	return out, rep
}

// HeadingOf is the client's heading for a record's angle (READ: the spawn
// reader FUN_009c3a70 makes radians of it -- a / 65535.0 * 360.0 *
// 0.01745329238474369 (0xdde7b0, 0xdde7a8, 0xe1b8d8) -- and FUN_009c40b0 adds
// pi/2 (0xe1b8f0) and takes 2 pi off while 2 pi or more), facing (sin h, 0,
// -cos h) in the region-local frame (FUN_009ec850). It equals the server's
// own heading (cos a, 0, sin a) for a = the angle in radians (SetHeading,
// slot 230 0x48ba10) -- which is the point of the pi/2.
func HeadingOf(angle uint16) float64 {
	h := float64(angle)/65535.0*360.0*0.01745329238474369 + 1.5707963705062866
	for h >= 6.2831854820251465 {
		h -= 6.2831854820251465
	}
	return h
}

// WireAngleOf is the u16 the server writes for its heading of a radians:
// FUN_00488050 adds 2 pi (0xb45c18) to a negative angle and rounds a *
// 57.295780181884766 (0xb45c38) / 360.0 (0xb45c30) * 65535.0 (0xb45c28). The
// angle is atan2 of the object's heading vector (0x487ce0: `fld [esi+0x2c];
// fld [esi+0x24]; call 0x9fc1aa`, the CRT's atan2 whose table names
// "atan2"). For a nest NPC that vector is (cos a, sin a) with a =
// wInitialDir / 65535 * 2 pi (Nest_Hatch 0x5609c2..0x5609e8 at float
// precision, then EnterWorld 0x485419 -> SetHeading), so the wire angle is
// wInitialDir back again to within the float rounding -- WireAngleOf is
// exact on every u16 in float64 (TestWireAngleRoundTrip).
func WireAngleOf(a float64) uint16 {
	if a < 0 {
		a += 6.2831854820251465
	}
	return uint16(uint32(int64(math.Round(a * 57.295780181884766 / 360.0 * 65535.0))))
}

// NestRadians is Nest_Hatch's conversion of a nest's wInitialDir.
func NestRadians(dir uint16) float64 {
	return float64(dir) / 65535.0 * 360.0 * 0.01745329238474369
}
