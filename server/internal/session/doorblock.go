package session

import (
	"github.com/TheOpenSRO/OpenSRO/server/internal/gameworld"
	"github.com/TheOpenSRO/OpenSRO/server/internal/navmesh"
	"github.com/TheOpenSRO/OpenSRO/server/internal/worldmap"
)

// Round 879: where a layer's closed trigger doors stop a mover, in the
// layer's frame (gameworld.DoorBlock). The user: "There was one I couldn't
// see but it let me through the gate anyways." Round 869's block compared
// the door's region-local point with the mover's frame position, so it
// stopped nothing near the door (on the Wrecked Ship a region-local point is
// ~1,000 units from the frame point of the same spot), and its 40-unit disc
// was narrower than the door: the door model's navigation mesh is 153.6
// wide (MEASURED, gameworld.DoorBlock).

// setDoorBlocks gives each placed door of w its footprint: the frame point
// of its named position and, when the navigation export holds its model's
// navigation mesh (navmesh.StructuresFile), that mesh's blocking edges placed
// as a map object at the position and yaw (navmesh.Place, the rule every
// region object's mesh is placed by), each end turned into the frame
// (worldmap.ToWorld). Run when the layer opens, before anyone is in.
func setDoorBlocks(w *gameworld.World) {
	_, fx, fy, framed := InstanceFrame(w)
	nav := navWorld.Load()
	for _, z := range w.Zones() {
		p := z.Place
		if p == nil {
			continue
		}
		_, pos, ok := InstancePlace(w, p.Region, p.X, p.Y, p.Z)
		if !ok {
			continue
		}
		b := &gameworld.DoorBlock{X: pos.X, Z: pos.Z}
		if mesh := nav.Structure(z.StructureCode); mesh != nil && framed && !worldmap.IsDungeonRegion(int(p.Region)) {
			b.Segs = doorSegments(mesh, int(p.Region), p.X, p.Y, p.Z, p.Yaw, fx, fy)
		}
		z.Block = b
	}
}

// doorSegments is mesh's blocking edges placed at region-local (x, y, z)
// with yaw in region, in the frame centred on (fx, fy).
func doorSegments(mesh *navmesh.CollisionMesh, region int, x, y, z, yaw float64, fx, fy int) [][4]float64 {
	pl := navmesh.Place(mesh, 0, navmesh.V3{X: x, Y: y, Z: z}, yaw)
	rx, ry := worldmap.RegionXY(region)
	var out [][4]float64
	for i := 0; i+1 < len(pl.Edges); i += 2 {
		if pl.EdgeFlags[i/2]&3 == 0 {
			continue
		}
		ax, az := worldmap.ToWorld(rx, ry, pl.Edges[i].X, pl.Edges[i].Y, fx, fy)
		bx, bz := worldmap.ToWorld(rx, ry, pl.Edges[i+1].X, pl.Edges[i+1].Y, fx, fy)
		out = append(out, [4]float64{ax, az, bx, bz})
	}
	return out
}
