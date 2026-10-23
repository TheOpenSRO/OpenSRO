// Command navprobe asks the server's navigation mesh (internal/navmesh,
// round 812) about points and walks in a zone's world frame: a diagnostic
// for checking the export (cmd/export-navmesh) against what the client draws.
//
// Usage:
//
//	navprobe -dir DIR -zone jangan -at X,Z[,Y] [-to X,Z]
package main

import (
	"flag"
	"fmt"
	"log"
	"math"
	"strconv"
	"strings"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/navmesh"
	"github.com/OpenSRO/OpenSRO/server/internal/worldmap"
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

func main() {
	dir := flag.String("dir", "", "the export directory")
	zone := flag.String("zone", "jangan", "the zone whose world frame the points are in")
	at := flag.String("at", "", "X,Z[,Y]: a world point")
	to := flag.String("to", "", "X,Z: walk there from -at")
	flag.Parse()
	w, err := navmesh.Open(*dir)
	if err != nil {
		log.Fatal(err)
	}
	ox, oy, ok := worldmap.FrameFor(*zone)
	if !ok {
		log.Fatalf("no frame for zone %q", *zone)
	}
	p := floats(*at)
	if len(p) < 2 {
		log.Fatal("-at X,Z")
	}
	y := math.NaN()
	if len(p) > 2 {
		y = p[2]
	}
	rx, ry, lx, lz := worldmap.FromWorld(p[0], p[1], ox, oy)
	fmt.Printf("at (%.1f, %.1f) in %s: region %d/%d (%s) local (%.2f, %.2f); landing height %.2f; height under y %.1f: %.2f\n",
		p[0], p[1], *zone, rx, ry, navmesh.NvmName(worldmap.RegionID(rx, ry)), lx, lz,
		w.Height(ox, oy, p[0], p[1], math.NaN()), y, w.Height(ox, oy, p[0], p[1], y))
	// Every surface over the point (the client tool's --column): the
	// terrain, then each object listed there with its height.
	if g := w.Graph(worldmap.RegionID(rx, ry)); g != nil {
		fmt.Printf("  terrain %.3f; %d objects placed in the region\n", g.Region.TerrainHeight(lx, lz), len(g.Objects))
		for _, oi := range g.ObjectsAt(lx, lz) {
			o := g.Region.Objects[oi]
			fmt.Printf("  object %d (type %d at %.1f, %.1f, %.1f yaw %.3f): surface %.3f\n", oi, o.ResourceID, o.X, o.Y, o.Z, o.Yaw,
				navmesh.SurfaceHeightOf(g.Objects[oi], lx, lz))
		}
	}
	if *to != "" {
		q := floats(*to)
		t0 := time.Now()
		r := w.Walk(ox, oy, p[0], y, p[1], q[0], q[1])
		took := time.Since(t0)
		t0 = time.Now()
		for i := 0; i < 20; i++ {
			w.Walk(ox, oy, p[0], y, p[1], q[0], q[1])
		}
		fmt.Printf("walk took %v the first time (the region load included), %v each after\n", took, time.Since(t0)/20)
		fmt.Printf("walk to (%.1f, %.1f): ends (%.2f, %.2f, %.2f) blocked %v checked %v (%.1f of %.1f)\n",
			q[0], q[1], r.X, r.Y, r.Z, r.Blocked, r.Checked, math.Hypot(r.X-p[0], r.Z-p[1]), math.Hypot(q[0]-p[0], q[1]-p[1]))
	}
}
