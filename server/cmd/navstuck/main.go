// Command navstuck asks the server's navigation mesh (internal/navmesh) why a
// mover at one point cannot leave it (round 857): the terrain cell under the
// point and the blocking terrain edges near it, every object whose footprint
// covers it (its object.ifo name, placement, whether the point is on the
// object's own cells or inside its outline, the outline edges near it with
// their flags), and an escape probe -- walks from the point in 72 directions
// at a few lengths, each counted by how far it got.
//
// Usage (the box; the archives and the export are the user's, never
// committed):
//
//	navstuck -dir NAVDIR -map Map.pk2 -region 90/143 -at 855,345[,Y] [-near 40]
package main

import (
	"flag"
	"fmt"
	"log"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/TheOpenSRO/OpenSRO/server/internal/navmesh"
	"github.com/TheOpenSRO/OpenSRO/server/internal/objidx"
	"github.com/TheOpenSRO/OpenSRO/server/internal/pk2"
	"github.com/TheOpenSRO/OpenSRO/server/internal/worldmap"
)

func floats(s string) []float64 {
	var out []float64
	for _, p := range strings.Split(s, ",") {
		if p == "" {
			continue
		}
		v, err := strconv.ParseFloat(strings.TrimSpace(p), 64)
		if err != nil {
			log.Fatalf("%q: %v", s, err)
		}
		out = append(out, v)
	}
	return out
}

func segDist(p, a, b navmesh.V2) float64 {
	ab := b.Sub(a)
	t := 0.0
	if l := ab.Len2(); l > 0 {
		t = math.Max(0, math.Min(1, p.Sub(a).Dot(ab)/l))
	}
	return p.Dist(a.Add(ab.Mul(t)))
}

// insideOutline: a ray east from p crosses the object's outline edges an odd
// number of times.
func insideOutline(p *navmesh.Placed, pt navmesh.V2) bool {
	n := 0
	for e := range p.EdgeFlags {
		if !p.EdgeOutline[e] {
			continue
		}
		a, b := p.Edges[e*2], p.Edges[e*2+1]
		if (a.Y > pt.Y) != (b.Y > pt.Y) {
			x := a.X + (pt.Y-a.Y)*(b.X-a.X)/(b.Y-a.Y)
			if x > pt.X {
				n++
			}
		}
	}
	return n%2 == 1
}

func main() {
	dir := flag.String("dir", "", "the export directory (-navmesh-dir)")
	mapPath := flag.String("map", "", "Map.pk2 (its object.ifo names the objects)")
	region := flag.String("region", "", "region x/y")
	at := flag.String("at", "", "lx,lz[,y]: a region-local point")
	near := flag.Float64("near", 30, "list edges within this distance")
	flag.Parse()
	w, err := navmesh.Open(*dir)
	if err != nil {
		log.Fatal(err)
	}
	if *mapPath != "" {
		m, err := pk2.Open(*mapPath)
		if err != nil {
			log.Fatal(err)
		}
		ifo, err := m.ReadPath("object.ifo")
		if err != nil {
			log.Fatal(err)
		}
		table, err := objidx.Parse(ifo)
		if err != nil {
			log.Fatal(err)
		}
		nameOf = func(id uint32) string {
			if e, ok := table.Lookup(id); ok {
				return strings.ToLower(e.Path)
			}
			return fmt.Sprintf("type %d", id)
		}
	}
	if census {
		runCensus(w, *dir)
		return
	}
	rx, ry, ok := worldmap.ParseRegionLabel(*region)
	if !ok {
		log.Fatalf("region %q", *region)
	}
	g := w.Graph(worldmap.RegionID(rx, ry))
	if g == nil {
		log.Fatalf("no graph for %s", *region)
	}
	p := floats(*at)
	pt := navmesh.V2{X: p[0], Y: p[1]}
	y := math.NaN()
	if len(p) > 2 {
		y = p[2]
	}
	land := g.LandingHeightAt(pt.X, pt.Y)
	ref := y
	if math.IsNaN(ref) {
		ref = land
	}
	surf := g.SurfaceAt(pt.X, pt.Y, ref)
	fmt.Printf("region %s local (%.2f, %.2f): terrain %.3f landing %.3f; surface at y %.2f: %.3f on %d\n",
		*region, pt.X, pt.Y, g.Region.TerrainHeight(pt.X, pt.Y), land, ref, surf.Height, surf.Object)
	ci := g.CellIndexAt(pt.X, pt.Y)
	if ci >= 0 && ci < len(g.Region.Cells) {
		c := g.Region.Cells[ci]
		fmt.Printf("terrain cell %d (of %d, %d walkable): (%.1f, %.1f)..(%.1f, %.1f), objects %v\n",
			ci, len(g.Region.Cells), g.Region.WalkableCells, c.MinX, c.MinZ, c.MaxX, c.MaxZ, c.Objects)
	} else {
		fmt.Printf("terrain cell %d: none\n", ci)
	}
	for li, list := range [][]navmesh.Edge{g.Region.InternalEdges, g.Region.GlobalEdges} {
		for i, e := range list {
			a, b := navmesh.V2{X: float64(e.AX), Y: float64(e.AZ)}, navmesh.V2{X: float64(e.BX), Y: float64(e.BZ)}
			if d := segDist(pt, a, b); d <= *near && e.Blocking() {
				fmt.Printf("  terrain edge %s %d (%.2f, %.2f)-(%.2f, %.2f) flags 0x%02x cells %d->%d dist %.2f\n",
					[]string{"internal", "global"}[li], i, a.X, a.Y, b.X, b.Y, e.Flags, e.CellFrom, e.CellTo, d)
			}
		}
	}
	for oi, o := range g.Region.Objects {
		pl := g.Objects[oi]
		if pl == nil {
			continue
		}
		if pt.X < pl.Min.X-*near || pt.X > pl.Max.X+*near || pt.Y < pl.Min.Y-*near || pt.Y > pl.Max.Y+*near {
			continue
		}
		fmt.Printf("object %d %s at (%.2f, %.2f, %.2f) yaw %.4f bbox (%.1f, %.1f)..(%.1f, %.1f) cells %d terrain-collide %v\n",
			oi, nameOf(o.ResourceID), o.X, o.Y, o.Z, o.Yaw, pl.Min.X, pl.Min.Y, pl.Max.X, pl.Max.Y, len(pl.Cells)/3, pl.TerrainCollide)
		fmt.Printf("  point: own surface %.3f, inside outline %v\n", navmesh.SurfaceHeightOf(pl, pt.X, pt.Y), insideOutline(pl, pt))
		for e := range pl.EdgeFlags {
			a, b := pl.Edges[e*2], pl.Edges[e*2+1]
			if d := segDist(pt, a, b); d <= *near && pl.EdgeOutline[e] {
				fmt.Printf("  outline edge %d (%.2f, %.2f)-(%.2f, %.2f) flags 0x%02x cells %d/%d dist %.2f\n",
					e, a.X, a.Y, b.X, b.Y, pl.EdgeFlags[e], pl.EdgeCellFrom[e], pl.EdgeCellTo[e], d)
			}
		}
	}
	dumpAndGrid(g)
	// The escape probe, in the region's own world frame.
	fx, fz := worldmap.ToWorld(rx, ry, pt.X, pt.Y, rx, ry)
	for _, L := range []float64{1, 5, 20, 60} {
		moved, free := 0, 0
		best := 0.0
		var line []string
		for a := 0; a < 72; a++ {
			ang := float64(a) * math.Pi / 36
			tx, tz := fx+math.Cos(ang)*L, fz+math.Sin(ang)*L
			r := w.Walk(rx, ry, fx, y, fz, tx, tz)
			d := math.Hypot(r.X-fx, r.Z-fz)
			if d > 0.05 {
				moved++
			}
			if !r.Blocked {
				free++
			}
			best = math.Max(best, d)
			ch := "."
			switch {
			case !r.Blocked:
				ch = "o"
			case d > 0.05:
				ch = "+"
			}
			line = append(line, ch)
		}
		fmt.Printf("escape %4.0f: %2d/72 reach the end, %2d/72 move at all, farthest %.2f  [%s]\n", L, free, moved, best, strings.Join(line, ""))
	}
}

var nameOf = func(id uint32) string { return fmt.Sprintf("type %d", id) }

func init() {
	flag.Func("dump", "object index: print every cell and edge of that placement", func(s string) error {
		dumpObject, _ = strconv.Atoi(s)
		return nil
	})
	flag.Func("grid", "x0,z0,x1,z1,step: a map of the area ('#' on an object's cells, 'I' inside an outline, '.' terrain)", func(s string) error {
		gridSpec = floats(s)
		return nil
	})
}

var (
	dumpObject = -1
	gridSpec   []float64
	census     bool
)

func init() {
	flag.BoolVar(&census, "census", false, "every region of the export: the placements whose footprint lies under the terrain and the wall stops round them the pre-857 settle put on them")
}

// oldSurfaceObject is the pre-round-857 SurfaceAt's footing: the highest
// object cell under the point no more than SurfaceReachUp above refY, which
// beat the terrain however far below it lay; OnTerrain for none.
func oldSurfaceObject(g *navmesh.Graph, x, z, refY float64) int {
	best, bestH := navmesh.OnTerrain, math.Inf(-1)
	for _, oi := range g.ObjectsAt(x, z) {
		h := navmesh.SurfaceHeightOf(g.Objects[oi], x, z)
		if math.IsNaN(h) || h > refY+navmesh.SurfaceReachUp {
			continue
		}
		if h > bestH {
			best, bestH = oi, h
		}
	}
	return best
}

// runCensus walks at every buried footprint (most of its cells' middles 1 or
// more under the terrain, its outline blocking both ways) from 16 directions
// and counts the stops the old settle put on it, and the new one.
func runCensus(w *navmesh.World, dir string) {
	entries, err := os.ReadDir(filepath.Join(dir, navmesh.NvmSubdir))
	if err != nil {
		log.Fatal(err)
	}
	type kind struct{ placed, buried, trapped, stops, oldIn, newIn int }
	kinds := map[string]*kind{}
	regions, placements := 0, 0
	for _, e := range entries {
		var id int
		if _, err := fmt.Sscanf(e.Name(), "nv_%x.nvm", &id); err != nil {
			continue
		}
		rx, ry := id>>8, id&0xff
		g := w.Graph(id)
		if g == nil {
			continue
		}
		regions++
		for oi, o := range g.Region.Objects {
			pl := g.Objects[oi]
			if pl == nil || len(pl.Cells) == 0 {
				continue
			}
			placements++
			name := nameOf(o.ResourceID)
			k := kinds[name]
			if k == nil {
				k = &kind{}
				kinds[name] = k
			}
			k.placed++
			under, cells, both := 0, len(pl.Cells)/3, 0
			for c := 0; c < cells; c++ {
				a, b, cc := pl.Vertices[pl.Cells[c*3]], pl.Vertices[pl.Cells[c*3+1]], pl.Vertices[pl.Cells[c*3+2]]
				mx, mz := (a.X+b.X+cc.X)/3, (a.Z+b.Z+cc.Z)/3
				if mx < 0 || mz < 0 || mx >= navmesh.RegionSpan || mz >= navmesh.RegionSpan {
					continue
				}
				if g.Region.TerrainHeight(mx, mz)-(a.Y+b.Y+cc.Y)/3 >= 1 {
					under++
				}
			}
			for e := range pl.EdgeFlags {
				if pl.EdgeOutline[e] && pl.EdgeFlags[e]&3 == 3 {
					both++
				}
			}
			if under*2 < cells || both == 0 {
				continue
			}
			k.buried++
			cx, cz := float64(o.X), float64(o.Z)
			r := 0.0
			for _, v := range pl.Vertices {
				r = math.Max(r, math.Hypot(v.X-cx, v.Z-cz))
			}
			trapped := false
			for a := 0; a < 16; a++ {
				ang := float64(a) * math.Pi / 8
				fx, fz := cx+math.Cos(ang)*(r+10), cz+math.Sin(ang)*(r+10)
				if fx < 0 || fz < 0 || fx >= navmesh.RegionSpan || fz >= navmesh.RegionSpan {
					continue
				}
				if g.SurfaceAt(fx, fz, g.Region.TerrainHeight(fx, fz)).Object != navmesh.OnTerrain {
					continue
				}
				x0, z0 := worldmap.ToWorld(rx, ry, fx, fz, rx, ry)
				x1, z1 := worldmap.ToWorld(rx, ry, cx, cz, rx, ry)
				res := w.Walk(rx, ry, x0, math.NaN(), z0, x1, z1)
				if !res.Blocked {
					continue
				}
				_, _, lx, lz := worldmap.FromWorld(res.X, res.Z, rx, ry)
				k.stops++
				if oldSurfaceObject(g, lx, lz, res.Y) == oi {
					k.oldIn++
					trapped = true
				}
				if g.SurfaceAt(lx, lz, res.Y).Object == oi {
					k.newIn++
				}
			}
			if trapped {
				k.trapped++
			}
		}
	}
	names := make([]string, 0, len(kinds))
	tot := kind{}
	for n, k := range kinds {
		if k.buried > 0 {
			names = append(names, n)
		}
		tot.placed += k.placed
		tot.buried += k.buried
		tot.trapped += k.trapped
		tot.stops += k.stops
		tot.oldIn += k.oldIn
		tot.newIn += k.newIn
	}
	sort.Slice(names, func(i, j int) bool { return kinds[names[i]].trapped > kinds[names[j]].trapped })
	for i, n := range names {
		if i >= 40 {
			break
		}
		k := kinds[n]
		fmt.Printf("%-64s placed %5d buried %5d trapping %5d wall stops %6d settled inside: old %6d new %d\n", n, k.placed, k.buried, k.trapped, k.stops, k.oldIn, k.newIn)
	}
	fmt.Printf("census: %d regions, %d placements with a mesh; %d buried footprints of %d kinds, %d of them trapping under the old settle; %d wall stops, %d settled inside by the old settle, %d by the new\n",
		regions, placements, tot.buried, len(names), tot.trapped, tot.stops, tot.oldIn, tot.newIn)
}

func dumpAndGrid(g *navmesh.Graph) {
	if pl := g.Objects[dumpObject]; pl != nil {
		for c := 0; c < len(pl.Cells)/3; c++ {
			a, b, cc := pl.Vertices[pl.Cells[c*3]], pl.Vertices[pl.Cells[c*3+1]], pl.Vertices[pl.Cells[c*3+2]]
			fmt.Printf("  cell %d: (%.2f, %.2f, %.2f) (%.2f, %.2f, %.2f) (%.2f, %.2f, %.2f) edges %v\n", c, a.X, a.Y, a.Z, b.X, b.Y, b.Z, cc.X, cc.Y, cc.Z, pl.CellEdges[c])
		}
		for e := range pl.EdgeFlags {
			a, b := pl.Edges[e*2], pl.Edges[e*2+1]
			fmt.Printf("  edge %d outline %v (%.2f, %.2f)-(%.2f, %.2f) flags 0x%02x cells %d/%d\n", e, pl.EdgeOutline[e], a.X, a.Y, b.X, b.Y, pl.EdgeFlags[e], pl.EdgeCellFrom[e], pl.EdgeCellTo[e])
		}
	}
	if len(gridSpec) != 5 {
		return
	}
	x0, z0, x1, z1, st := gridSpec[0], gridSpec[1], gridSpec[2], gridSpec[3], gridSpec[4]
	for z := z1; z >= z0; z -= st {
		row := []byte{}
		for x := x0; x <= x1; x += st {
			ch := byte('.')
			for oi := range g.Region.Objects {
				pl := g.Objects[oi]
				if pl == nil || x < pl.Min.X || x > pl.Max.X || z < pl.Min.Y || z > pl.Max.Y {
					continue
				}
				if !math.IsNaN(navmesh.SurfaceHeightOf(pl, x, z)) {
					ch = '#'
				} else if insideOutline(pl, navmesh.V2{X: x, Y: z}) && ch == '.' {
					ch = 'I'
				}
			}
			row = append(row, ch)
		}
		fmt.Printf("%7.1f %s\n", z, row)
	}
}
