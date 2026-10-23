package navmesh

import (
	"encoding/gob"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sync"

	"github.com/OpenSRO/OpenSRO/server/internal/worldmap"
)

// The export's layout (cmd/export-navmesh): dir/nvm/nv_xxxx.nvm, the user's
// own .nvm files as they are in Data.pk2's navmesh\ folder, and
// dir/objects.gob, every object index entry's navigation mesh by type id
// (NavObjectSource.load_collision's choice of mesh). Never committed.
const (
	NvmSubdir   = "nvm"
	ObjectsFile = "objects.gob"
)

// NvmName is a region's .nvm file name: its packed id in hex
// (navmesh\nv_62a8.nvm for region 98/168, worldmap.RegionID).
func NvmName(regionID int) string { return fmt.Sprintf("nv_%04x.nvm", regionID&0xFFFF) }

// World is the navigation mesh of every region, read on first use.
type World struct {
	dir     string
	objects map[uint32]*CollisionMesh
	mu      sync.Mutex
	graphs  map[int]*Graph // nil: the region has no .nvm (or it did not parse)
	// Loaded counts graphs built, for the boot and QA lines.
	Loaded int
}

// Open reads dir's object meshes; the regions load on first use.
func Open(dir string) (*World, error) {
	f, err := os.Open(filepath.Join(dir, ObjectsFile))
	if err != nil {
		return nil, err
	}
	defer f.Close()
	objs := map[uint32]*CollisionMesh{}
	if err := gob.NewDecoder(f).Decode(&objs); err != nil {
		return nil, fmt.Errorf("%s: %w", ObjectsFile, err)
	}
	if _, err := os.Stat(filepath.Join(dir, NvmSubdir)); err != nil {
		return nil, err
	}
	return &World{dir: dir, objects: objs, graphs: map[int]*Graph{}}, nil
}

// NewWorld is a World over meshes already in memory (tests): regions come
// from `regions` by id.
func NewWorld(objects map[uint32]*CollisionMesh, regions map[int]*Region) *World {
	w := &World{objects: objects, graphs: map[int]*Graph{}}
	for id, r := range regions {
		w.graphs[id] = w.build(r)
	}
	return w
}

// Objects is how many object meshes the export holds.
func (w *World) Objects() int { return len(w.objects) }

// Graph is region id's graph, loading it on first use; nil without one.
func (w *World) Graph(regionID int) *Graph {
	w.mu.Lock()
	defer w.mu.Unlock()
	if g, ok := w.graphs[regionID]; ok {
		return g
	}
	var g *Graph
	if w.dir != "" {
		if data, err := os.ReadFile(filepath.Join(w.dir, NvmSubdir, NvmName(regionID))); err == nil {
			if r, err := ParseNVM(data); err == nil {
				g = w.build(r)
				w.Loaded++
			}
		}
	}
	w.graphs[regionID] = g
	return g
}

// build places every object the region lists that has a mesh
// (World3D._prepare_nav_graph).
func (w *World) build(r *Region) *Graph {
	var placed []*Placed
	for i, o := range r.Objects {
		c := w.objects[o.ResourceID]
		if c == nil || len(c.Cells) == 0 {
			continue
		}
		placed = append(placed, Place(c, i, V3{float64(o.X), float64(o.Y), float64(o.Z)}, float64(o.Yaw)))
	}
	return Build(r, placed)
}

// The frame conversion. A region's local plan (x, z) is the .nvm's own; the
// world frame centred on region (ox, oy) is worldmap's (FromWorld/ToWorld:
// region y drives world X, region x drives world Z, Z mirrored). So a world
// step (dx, dz) is a local step (dx, -dz).
func toLocal(x, z float64, ox, oy int) (rid int, lx, lz float64) {
	rx, ry, lx, lz := worldmap.FromWorld(x, z, ox, oy)
	return worldmap.RegionID(rx, ry), lx, lz
}

// Height is the surface a mover at height refY stands on at world (x, z):
// NaN where no region graph covers the point.
func (w *World) Height(ox, oy int, x, z, refY float64) float64 {
	rid, lx, lz := toLocal(x, z, ox, oy)
	g := w.Graph(rid)
	if g == nil {
		return math.NaN()
	}
	if math.IsNaN(refY) {
		return g.LandingHeightAt(lx, lz)
	}
	return g.SurfaceAt(lx, lz, refY).Height
}

// WalkResult is where a walk ended.
type WalkResult struct {
	X, Y, Z float64
	// Blocked: a wall stopped it short of the destination.
	Blocked bool
	// Checked: a region graph covered the whole walk (false: some of it ran
	// where there is no navigation mesh, which is not tested).
	Checked bool
}

// WalkStep is the longest stretch walked in one StepTracked (OURS): the
// client walks a frame at a time -- about a unit at the run speed of 50 and
// 60 frames a second -- re-finding its cell on an object each frame, and the
// walk over one long segment is not the same walk (MEASURED round 812: from
// Jangan's cj_luxury at local 1734.87, 240.48 a 69.5-unit segment south
// stopped at 56.1 where 1-unit steps, as the client takes them, walk on).
const WalkStep = 1.0

// regionEps is how far past a region's edge a step is carried so the next
// is in the next region.
const regionEps = 0.001

// Walk walks a mover from world (x, y, z) toward (tx, tz) in the frame
// centred on (ox, oy) with no slide (the walk every order and every server
// mover uses, READ round 653): the end is the destination, or where the
// first blocking edge stopped it. It steps WalkStep at a time carrying the
// footing (terrain or an object) as the client carries it from frame to
// frame; the footing is settled as the client settles it after a teleport
// (SurfaceAt) at the start and on each region crossing. y NaN: the landing
// height.
func (w *World) Walk(ox, oy int, x, y, z, tx, tz float64) WalkResult {
	res := WalkResult{X: tx, Y: y, Z: tz, Checked: true}
	cx, cy, cz := x, y, z
	var g *Graph
	rid, on := -1, OnTerrain
	limit := int(math.Hypot(tx-x, tz-z)/WalkStep) + 64
	for guard := 0; guard < limit; guard++ {
		dx, dz := tx-cx, tz-cz
		dist := math.Hypot(dx, dz)
		if dist <= 1e-5 {
			res.X, res.Y, res.Z = cx, cy, cz
			return res
		}
		r, lx, lz := toLocal(cx, cz, ox, oy)
		if r != rid {
			rid, g = r, w.Graph(r)
			if g != nil {
				if math.IsNaN(cy) {
					cy = g.LandingHeightAt(lx, lz)
				}
				on = g.SurfaceAt(lx, lz, cy).Object
			}
		}
		// The local step toward the destination (a world +Z is a local -Z),
		// at most WalkStep, clipped just past the region's edge.
		k := math.Min(1, WalkStep/dist)
		mx, mz := dx*k, -dz*k
		t := 1.0
		if lx+mx < 0 {
			t = math.Min(t, (0-lx)/mx)
		} else if lx+mx >= RegionSpan {
			t = math.Min(t, (RegionSpan-lx)/mx)
		}
		if lz+mz < 0 {
			t = math.Min(t, (0-lz)/mz)
		} else if lz+mz >= RegionSpan {
			t = math.Min(t, (RegionSpan-lz)/mz)
		}
		if t < 1 {
			t = math.Min(1, t+regionEps/math.Hypot(mx, mz))
		}
		mx, mz = mx*t, mz*t
		if g == nil {
			res.Checked = false
			cx, cz = cx+mx, cz-mz
			continue
		}
		st := g.StepTracked(V3{lx, cy, lz}, V2{mx, mz}, on, false)
		cx += st.Pos.X - lx
		cz -= st.Pos.Z - lz
		cy, on = st.Pos.Y, st.On
		if st.Blocked {
			res.X, res.Y, res.Z, res.Blocked = cx, cy, cz, true
			return res
		}
	}
	res.X, res.Y, res.Z = cx, cy, cz
	return res
}
