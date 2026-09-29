// Package worldmap converts the real game's own spatial addressing into the
// coordinates this project's client and server actually exchange.
//
// Every real placement table says WHERE in exactly one way: a region id whose
// high byte is the region's x and whose low byte is its y, plus a position
// local to that region with x and z each running [0, REGION_SPAN). npcpos --
// 12,367 rows across 1,451 regions -- is the table that matters here, and it
// is the game's own answer to "where does this creature stand". Nothing in the
// real data is ever expressed in the flat world coordinates the client draws
// in and the server stores, so a real spawn point cannot be used without this
// conversion.
//
// The client builds its world around ONE region -- the zone's own centre, laid
// down at the world origin, with the neighbours streamed in around it (see
// World3D.gd's _load_region_neighborhood and JANGAN_ZONE_REGION). So a world
// coordinate only means something once you say which region the frame is
// centred on, and ToWorld takes that as an argument rather than assuming it.
// Since round 570 the server says it on the wire: EnterWorldResult and
// ChangeZoneResult carry FrameFor(zone) as FrameRegion, and the client builds
// the zone's grid inside that frame. For every zone it is the zone's centre --
// unless cmd/server runs with -single-frame (round 571), when every zone with
// a frame is named in ONE frame, WorldOrigin's, and lands at Landing.
//
// The transform below was MEASURED, not derived from the region layout. Every
// term was read out of the real client's own region group nodes in headless
// runs on the render box (World3D.gd's _qa_columns_report), all in a world
// centred on Jangan's real region 97/168:
//
//	within a region   97/168 local (1002, 1020) -> (   42,   -60)  the zone spawn
//	                  97/168 local ( 960, 1800) -> (    0,  -840)  monster anchor A
//	                  97/168 local (1300, 1300) -> (  340,  -340)  monster anchor B
//	one region in y   97/169 local ( 960,  960) -> ( 1920,     0)
//	                  97/167 local ( 960,  960) -> (-1920,     0)
//	one region in x   98/168 local ( 960,  960) -> (    0, -1920)
//	                  96/168 local ( 960,  960) -> (    0,  1920)
//
// Anchors A and B are the two positions this project's own monsters already
// stood on, arrived at by an unrelated route in an earlier session; the
// formula reproduces both exactly, which is an independent check on the
// within-region half rather than a restatement of it.
//
// Two things here are not what the layout suggests, and both were measured
// precisely because they are not:
//
//   - The axes are swapped. Region *y* drives world X and region *x* drives
//     world Z. (Established twice before this, from terrain edge matching and
//     from how the authored minimaps tile.)
//   - World Z is MIRRORED, and mirrored consistently: local z runs opposite to
//     world Z inside a region, AND the region-to-region step runs opposite too,
//     so the two agree and the regions tile without a seam. Deriving the
//     cross-region term from the grid layout alone gets its sign wrong -- the
//     prediction for the first real Mangyang row was (130, -1560) and the
//     measurement was (130, 2280). Shipping the prediction would have put that
//     monster 3,840 units away, on the far side of the town.
//
// World X has no such mirror, which is why both axes were probed in both
// directions rather than one being assumed from the other.
//
// This is NOT cmd/wherecoord's mapping. That one converts to the coordinates
// the retail client DISPLAYS, has no mirror, and must not be substituted here.
package worldmap

import (
	"sort"
	"strconv"
	"strings"
)

// RegionSpan is one region's extent in world units, on both axes. The real
// value: a region's own mesh is 97 vertices at TILE_SIZE, exactly 1920 units.
const RegionSpan = 1920.0

// halfSpan is the offset from a region's corner-origin local coordinates to
// its centre, which is where the client puts the origin of the centre region.
const halfSpan = RegionSpan / 2

// RegionXY splits a real region id into its x and y. The id is packed with x
// in the high byte and y in the low byte -- e.g. 25257 is 98/169.
func RegionXY(id int) (x, y int) {
	return (id >> 8) & 0xFF, id & 0xFF
}

// RegionID packs an x and y back into the id the real tables use.
func RegionID(x, y int) int {
	return (x&0xFF)<<8 | (y & 0xFF)
}

// ToWorld converts a position local to region (rx, ry) into the world
// coordinates the client draws in and the server stores, for a world whose
// grid is centred on region (originX, originY).
//
// Only x and z are returned: the height in a real placement row is not what
// the client uses. It resolves the standing height from the region's own
// walkable graph instead (World3D.gd's landing_height_at), because the
// authored y and the navmesh disagree by 10-40 units on real rows.
func ToWorld(rx, ry int, localX, localZ float64, originX, originY int) (x, z float64) {
	x = float64(ry-originY)*RegionSpan + (localX - halfSpan)
	z = float64(originX-rx)*RegionSpan + (halfSpan - localZ)
	return x, z
}

// ZoneCentre is the region each named zone's world is built around, and so
// the region that zone's world coordinates are relative to. It must equal the
// client's own World3D.gd *_ZONE_REGION constants (what _resolve_zone_region
// returns for the same label): the server's world coordinates for a zone and
// the grid the client builds for it are one frame only when the two agree.
//
// Until round 569 three entries did not: constantinople {100, 98}, hotan
// {87, 118} and samarkand {88, 130} arrived in edc6fea with no recorded
// source, and the game's own region names (textzonename.txt, keyed by region
// id) call those three regions "Cleopatra's Gate", "Aircraft dock" and
// "East-Karakoram" -- none of them the town.
//
// The rule since round 569 (docs/RE_COMPLETION.md, round 569, has the table):
// where a town's own NPC rows and its dimensional gate agree on a region,
// that region is the centre, on both sides. The NPC rows are npcpos.txt's
// first column (the NPC's id) joined to characterdata's second (its ID;
// characterdata's first is the Service flag), counted by the town's code
// (NPC_CH_ Jangan, NPC_WC_ Donwhang, NPC_KT_ Hotan, NPC_EU_ Constantinople,
// NPC_CA_ Samarkand); the gate is teleportdata.txt's GATE_<code> row
// (SN_ZONE_22001..22005, whose names are the five towns):
//
//	jangan          97/168  NPC_CH_ 18 of 67 (the most), GATE_CH 97/168
//	donwhang        102/153 NPC_WC_ 15 of 26 (6 more in 103/153), GATE_WC 102/153
//	constantinople  105/79  NPC_EU_ 10 of 33 (the most), GATE_EU 105/79
//	hotan           92/135  NPC_KT_ 6 of 29 (the most), GATE_KT 92/135
//
// Samarkand is UNRESOLVED, disclosed: its NPC_CA_ rows split 5/4/4/3 over
// 107/108, 106/108, 107/107 and 106/107 (the town sits on their shared
// corner), and GATE_CA is in 106/108, so rows and gate do not agree on one
// region. Rather than pick between them, the entry takes the client's
// SAMARKAND_ZONE_REGION, 106/107 -- one of the four, named "Samarkand" by
// textzonename -- so the two sides at least agree. "dunhuang" and
// "donwhang" are the same town; the server's roster and ZoneNames say
// "donwhang", and the client resolves both.
var ZoneCentre = map[string][2]int{
	"jangan":         {97, 168},
	"dunhuang":       {102, 153},
	"donwhang":       {102, 153},
	"constantinople": {105, 79},
	"hotan":          {92, 135},
	"samarkand":      {106, 107},
}

// ParseRegionLabel reads a zone label shaped "x/y" -- the project's own
// region notation, which a client sends for a raw region (World3D.gd's
// _zone_paths: "97/168" is Jangan's file 97\168.m) -- into the region's x and
// y. ok is false for any other shape, and for a part outside 0..255: a real
// region id carries each in one byte (RegionXY).
func ParseRegionLabel(label string) (x, y int, ok bool) {
	parts := strings.Split(label, "/")
	if len(parts) != 2 {
		return 0, 0, false
	}
	x, errX := strconv.Atoi(parts[0])
	y, errY := strconv.Atoi(parts[1])
	if errX != nil || errY != nil || x < 0 || x > 0xFF || y < 0 || y > 0xFF {
		return 0, 0, false
	}
	return x, y, true
}

// FrameFor is the region a zone's world coordinates are relative to, which
// the server names on the wire as FrameRegion (session's EnterWorldResult and
// ChangeZoneResult, round 570): a named zone's ZoneCentre, or the region an
// "x/y" label names. ok is false for any other label -- there is no frame the
// server could name, and the client keeps its own reading of the label.
//
// Every frame this returns is the zone's own centre, the region the client
// builds its grid around for the same label (World3D._resolve_zone_region,
// which passes an "x/y" label through): so naming it changes nothing a client
// does with the coordinates. A frame that is NOT the zone's centre is
// -single-frame's (round 571): session then names WorldOrigin for every zone
// this answers ok for, and sends Landing -- a position inside the centre
// region -- because (0, 0, 0) in another region's frame is that region's
// middle, outside the grid the client builds.
func FrameFor(zone string) (rx, ry int, ok bool) {
	if centre, found := ZoneCentre[zone]; found {
		return centre[0], centre[1], true
	}
	return ParseRegionLabel(zone)
}

// WorldOrigin is the region the ONE world frame is centred on when cmd/server
// runs with -single-frame (round 571): Jangan's 97/168, ZoneCentre's "jangan".
// Under it every zone's coordinates, every roster monster and every player
// share this frame, so a walk from one town to another is a walk inside one
// coordinate system, and FrameRegion names this region for every zone.
//
// OWN DESIGN, disclosed: the retail client addresses a position by region id
// plus region-local offset, and srrevamp's placeholder protocol has no retail
// world frame to copy. Jangan is the choice because every character enters
// there (session's spawnZone), because the transform above was measured in
// its frame, and because Jangan's own coordinates are then the same with the
// flag on or off (ToWorld against 97/168 is Jangan's zone frame).
//
// The far towns sit 28,800 (Donwhang) to 170,880 (Constantinople) units from
// this origin in X, where a float32 -- the wire's position type and the
// client's -- steps by 1/512 to 1/64 of a unit (docs/RE_COMPLETION.md, round
// 571). Recorded, not rebased here.
var WorldOrigin = [2]int{97, 168}

// WorldBucket is the world hub's zone -- the bucket a character is kept and
// broadcast in -- that every label with a frame (FrameFor) shares under
// -single-frame (round 571; session.ZoneBucket), and the zone every roster
// monster is spawned in then. A label is then only the client's grid-centre
// hint; the bucket is where the entity is. OWN DESIGN, disclosed with
// WorldOrigin: one bucket, no spatial filter (a move, a chat line and the
// monster list reach the whole world).
const WorldBucket = "world"

// Landing is where a character arriving in zone stands, in the frame centred
// on region (frameX, frameY): the middle of the zone's centre region, local
// (960, 960). FrameFor is that centre -- every zone's own frame is its centre
// (round 570) -- so with the frame the centre this is (0, 0), session's
// spawnPos, the point every zone change has always landed at; round 569
// measured it open, walkable terrain on each corrected town's own graph
// (docs/RE_COMPLETION.md, round 569, "6. The landing"; the client then moves a
// Jangan arrival on to ZONE_SPAWN_LOCAL itself). In any other frame it is the
// same place, named in that frame -- what -single-frame sends, since the client
// builds the zone's grid around its centre and (0, 0, 0) would be the frame
// region's middle, off that grid. ok is false for a label with no frame.
func Landing(zone string, frameX, frameY int) (x, z float64, ok bool) {
	rx, ry, ok := FrameFor(zone)
	if !ok {
		return 0, 0, false
	}
	x, z = ToWorld(rx, ry, halfSpan, halfSpan, frameX, frameY)
	return x, z, true
}

// LandingSpot is where the client stands an arrival in a zone whose centre
// region is the key, in that region's local coordinates -- World3D.gd's
// ZONE_SPAWN_LOCAL, row for row (OURS, the client's choice: Jangan's square a
// little north of the dragon's plinth, which is a solid 11.45 tall at local
// 1002,917). The server's own landing stays Landing's region middle; this
// table only tells it where the client will put the player, so a walled
// caster's landing there can be recognised (session.warpLandingAdmits, round
// 646's review). A zone with no row is left where the server lands it.
var LandingSpot = map[[2]int][2]float64{
	{97, 168}: {1002, 1020},
}

// LandingSpotFor names zone's LandingSpot in the frame the arrival
// (landingX, landingZ) -- Landing's region middle in some frame -- is named
// in. ok is false for a zone with no frame or no spot.
func LandingSpotFor(zone string, landingX, landingZ float64) (x, z float64, ok bool) {
	rx, ry, found := FrameFor(zone)
	if !found {
		return 0, 0, false
	}
	spot, has := LandingSpot[[2]int{rx, ry}]
	if !has {
		return 0, 0, false
	}
	// ToWorld is a translation per frame: the spot's offset from the middle
	// is the same in every frame.
	mx, mz := ToWorld(rx, ry, halfSpan, halfSpan, rx, ry)
	sx, sz := ToWorld(rx, ry, spot[0], spot[1], rx, ry)
	return landingX + (sx - mx), landingZ + (sz - mz), true
}

// Rebase names a world point given in the frame centred on region
// (fromX, fromY) in the frame centred on (toX, toY): the same place, other
// coordinates. The shift is the from-region's middle as the to-frame sees it,
// ToWorld(from, (960, 960), to) -- the same derivation as round 570's "a point
// moved from the 97/168 frame into 98/157's shifts by (+21120, +1920)", which
// is Rebase(x, z, 97, 168, 98, 157) - (x, z). It is how -single-frame moves an
// own-design anchor, which is relative to its zone's centre, into WorldOrigin's
// frame.
func Rebase(x, z float64, fromX, fromY, toX, toY int) (float64, float64) {
	dx, dz := ToWorld(fromX, fromY, halfSpan, halfSpan, toX, toY)
	return x + dx, z + dz
}

// ZoneNames returns the named zones ToZoneWorld can convert into, sorted --
// the keys of ZoneCentre. It is what the GM console's /goto offers.
func ZoneNames() []string {
	out := make([]string, 0, len(ZoneCentre))
	for name := range ZoneCentre {
		out = append(out, name)
	}
	sort.Strings(out)
	return out
}

// ToZoneWorld converts a real region-local placement into the world
// coordinates of a named zone. ok is false for a zone whose centre region is
// not known, in which case no conversion is possible and the caller must not
// fall back to treating the local position as a world one.
//
// It takes ZoneCentre's named zones only, while FrameFor (round 570) also
// names the region an "x/y" label spells: an npcpos row in an "x/y" zone is
// refused here although the wire names a frame for that label. The two meet
// only in cmd/server's realSpawnWorld, whose callers pass a roster species'
// zone -- "jangan" or "donwhang" today -- so no row is refused for it; under
// -single-frame realSpawnWorld goes through FrameFor instead. Recorded, not
// changed (round 570's review; documented in round 574).
func ToZoneWorld(zone string, rx, ry int, localX, localZ float64) (x, z float64, ok bool) {
	centre, ok := ZoneCentre[zone]
	if !ok {
		return 0, 0, false
	}
	x, z = ToWorld(rx, ry, localX, localZ, centre[0], centre[1])
	return x, z, true
}
