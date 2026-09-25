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

import "sort"

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
// that region is the centre, on both sides. The NPC rows are npcpos.txt
// joined to characterdata on the first column, counted by the town's code
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
func ToZoneWorld(zone string, rx, ry int, localX, localZ float64) (x, z float64, ok bool) {
	centre, ok := ZoneCentre[zone]
	if !ok {
		return 0, 0, false
	}
	x, z = ToWorld(rx, ry, localX, localZ, centre[0], centre[1])
	return x, z, true
}
