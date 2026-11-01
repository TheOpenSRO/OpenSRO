// Command navcensus measures the object collision the server's navigation
// mesh (internal/navmesh, cmd/export-navmesh) carries in a few regions
// (round 851): every placed object by its object.ifo name, whether it has a
// navigation mesh, how many of its outline edges block a mover from outside
// (flag bit 0, READ s:0x9b51e0 with the mover's +0x38 == 1) and from inside
// (0x12, s:0x9b55b3), and -- the probe -- straight walks fired through each
// placement's middle from 8 directions, counted blocked or not. A placement
// whose own walks all pass is one a mover walks through.
//
// Usage (the box; the archives and the export are the user's, never
// committed):
//
//	navcensus -dir NAVDIR -map Map.pk2 -regions 97/168,98/168 [-match tree] [-list]
package main

import (
	"flag"
	"fmt"
	"log"
	"math"
	"sort"
	"strings"

	"github.com/TheOpenSRO/OpenSRO/server/internal/navmesh"
	"github.com/TheOpenSRO/OpenSRO/server/internal/objidx"
	"github.com/TheOpenSRO/OpenSRO/server/internal/pk2"
	"github.com/TheOpenSRO/OpenSRO/server/internal/worldmap"
)

type kind struct {
	name               string
	placed, mesh       int
	outline, out, in   int
	walks, blocked     int
	placementsBlocking int
	radius             float64
}

func main() {
	dir := flag.String("dir", "", "the export directory (-navmesh-dir)")
	mapPath := flag.String("map", "", "Map.pk2 (its object.ifo names the objects)")
	regions := flag.String("regions", "97/168", "regions x/y, comma separated")
	match := flag.String("match", "", "only names containing this (lower case)")
	reach := flag.Float64("reach", 0, "the probe's start distance from the middle (0: the placement's own outline radius + 5)")
	list := flag.Bool("list", false, "one line per object kind")
	where := flag.Bool("where", false, "one line per placement: its region-local and Jangan-frame world position and its probe walks")
	flag.Parse()
	w, err := navmesh.Open(*dir)
	if err != nil {
		log.Fatal(err)
	}
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
	kinds := map[string]*kind{}
	totals := kind{name: "ALL"}
	for _, label := range strings.Split(*regions, ",") {
		rx, ry, ok := worldmap.ParseRegionLabel(strings.TrimSpace(label))
		if !ok {
			log.Fatalf("region %q", label)
		}
		rid := worldmap.RegionID(rx, ry)
		g := w.Graph(rid)
		if g == nil {
			log.Fatalf("no graph for %s", label)
		}
		for oi, o := range g.Region.Objects {
			e, ok := table.Lookup(o.ResourceID)
			name := fmt.Sprintf("type %d", o.ResourceID)
			if ok {
				name = strings.ToLower(e.Path)
			}
			if *match != "" && !strings.Contains(name, *match) {
				continue
			}
			k := kinds[name]
			if k == nil {
				k = &kind{name: name}
				kinds[name] = k
			}
			k.placed++
			p := g.Objects[oi]
			// The middle: the placement's own position (an object's mesh is
			// authored about its origin).
			cx, cz := float64(o.X), float64(o.Z)
			r := 8.0
			if p != nil {
				k.mesh++
				r = 0
				for e := range p.EdgeFlags {
					if !p.EdgeOutline[e] {
						continue
					}
					k.outline++
					if p.EdgeFlags[e]&navmesh.EdgeBlocksFromOutside != 0 {
						k.out++
					}
					if p.EdgeFlags[e]&(navmesh.EdgeBlocksFromInside|navmesh.EdgeIgnoredFromOut) != 0 {
						k.in++
					}
					for _, v := range []navmesh.V2{p.Edges[e*2], p.Edges[e*2+1]} {
						r = math.Max(r, math.Hypot(v.X-cx, v.Y-cz))
					}
				}
				k.radius = math.Max(k.radius, r)
			}
			start := r + 5
			if *reach > 0 {
				start = *reach
			}
			blockedHere := 0
			for a := 0; a < 8; a++ {
				ang := float64(a) * math.Pi / 4
				dx, dz := math.Cos(ang), math.Sin(ang)
				// Region-local -> the region's own world frame.
				fx, fz := worldmap.ToWorld(rx, ry, cx-dx*start, cz-dz*start, rx, ry)
				tx, tz := worldmap.ToWorld(rx, ry, cx+dx*start, cz+dz*start, rx, ry)
				res := w.Walk(rx, ry, fx, math.NaN(), fz, tx, tz)
				k.walks++
				totals.walks++
				if res.Blocked {
					k.blocked++
					totals.blocked++
					blockedHere++
				}
			}
			if blockedHere > 0 {
				k.placementsBlocking++
			}
			if *where {
				jx, jz, _ := worldmap.ToZoneWorld("jangan", rx, ry, cx, cz)
				fmt.Printf("  %-56s %s local (%.1f, %.1f, %.1f) jangan-world (%.1f, %.1f) radius %.1f blocked %d/8\n",
					name, label, cx, float64(o.Y), cz, jx, jz, r, blockedHere)
			}
			totals.placed++
			if p != nil {
				totals.mesh++
			}
		}
	}
	names := make([]string, 0, len(kinds))
	for n := range kinds {
		names = append(names, n)
	}
	sort.Strings(names)
	withMesh, withoutMesh := 0, 0
	for _, n := range names {
		k := kinds[n]
		if k.mesh > 0 {
			withMesh++
		} else {
			withoutMesh++
		}
		if *list {
			fmt.Printf("%-60s placed %3d mesh %3d outline %4d out-block %4d in-block %4d radius %6.1f walks %4d blocked %4d placements-blocking %3d\n",
				n, k.placed, k.mesh, k.outline, k.out, k.in, k.radius, k.walks, k.blocked, k.placementsBlocking)
		}
	}
	fmt.Printf("navcensus: %d kinds (%d with a navigation mesh, %d without), %d placements (%d with a mesh), %d probe walks, %d blocked\n",
		len(kinds), withMesh, withoutMesh, totals.placed, totals.mesh, totals.walks, totals.blocked)
}
