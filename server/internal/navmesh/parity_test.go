package navmesh

import (
	"bufio"
	"fmt"
	"math"
	"os"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// TestClientWalkParity replays the client's own walks (client/tools/
// walk_probe.gd --sweep, 300 steps of 1.0 on a seeded heading each) through
// this port and wants the same end and the same number of walls. It needs
// the user's data, so it runs only when pointed at it:
//
//	NAVMESH_PARITY_DIR=<export-navmesh dir>
//	NAVMESH_PARITY_SWEEP=<region id hex>:<sweep output>[,<id>:<file>...]
func TestClientWalkParity(t *testing.T) {
	dir, sweeps := os.Getenv("NAVMESH_PARITY_DIR"), os.Getenv("NAVMESH_PARITY_SWEEP")
	if dir == "" || sweeps == "" {
		t.Skip("NAVMESH_PARITY_DIR / NAVMESH_PARITY_SWEEP unset: no data to compare with")
	}
	w, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	line := regexp.MustCompile(`^sweep\s+(\d+) from ([-\d.]+),([-\d.]+),([-\d.]+) on (\S+) heading ([-\d.]+) -> ([-\d.]+),([-\d.]+),([-\d.]+) on (\S+) walls (\d+)`)
	idx := regexp.MustCompile(`\[(\d+)\]$`)
	for _, spec := range strings.Split(sweeps, ",") {
		parts := strings.SplitN(spec, ":", 2)
		rid, err := strconv.ParseInt(parts[0], 16, 32)
		if err != nil {
			t.Fatal(err)
		}
		g := w.Graph(int(rid))
		if g == nil {
			t.Fatalf("no graph for region %x", rid)
		}
		f, err := os.Open(parts[1])
		if err != nil {
			t.Fatal(err)
		}
		sc := bufio.NewScanner(f)
		n, bad := 0, 0
		for sc.Scan() {
			m := line.FindStringSubmatch(sc.Text())
			if m == nil {
				continue
			}
			fl := func(i int) float64 { v, _ := strconv.ParseFloat(m[i], 64); return v }
			foot := OnTerrain
			if s := idx.FindStringSubmatch(m[5]); s != nil {
				foot, _ = strconv.Atoi(s[1])
			}
			endFoot := OnTerrain
			if s := idx.FindStringSubmatch(m[10]); s != nil {
				endFoot, _ = strconv.Atoi(s[1])
			}
			hd := fl(6)
			mv := V2{math.Sin(hd), math.Cos(hd)}
			p := V3{fl(2), fl(3), fl(4)}
			on, walls := foot, 0
			for i := 0; i < 300; i++ {
				r := g.StepTracked(p, mv, on, true)
				if r.Blocked {
					walls++
				}
				p, on = r.Pos, r.On
			}
			want := V3{fl(7), fl(8), fl(9)}
			wantWalls, _ := strconv.Atoi(m[11])
			n++
			if p.Dist(want) > 0.05 || on != endFoot || walls != wantWalls {
				bad++
				if bad <= 15 {
					t.Errorf("%x walk %s: Go ends (%.3f, %.3f, %.3f) on %d walls %d; the client (%.3f, %.3f, %.3f) on %d walls %d",
						rid, m[1], p.X, p.Y, p.Z, on, walls, want.X, want.Y, want.Z, endFoot, wantWalls)
				}
			}
		}
		f.Close()
		fmt.Printf("region %x: %d walks, %d differ\n", rid, n, bad)
	}
}
