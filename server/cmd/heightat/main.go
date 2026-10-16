// Command heightat reports the raw terrain height a real .m heightmap gives
// at a region-local position, alongside the placement heights of the real
// objects nearest that spot.
//
// Built to settle whether scenery that renders off the ground disagrees
// with the *data* or only with what this project builds from it: if the
// raw heightmap agrees with an object's own placement Y, the mesh built
// from that heightmap is what drifted; if it does not, the data itself
// disagrees and the client must be reconciling them some other way.
//
// Usage:
//
//	go run ./cmd/heightat -map Map.pk2 -data Data.pk2 -region 96/167 -at 1500,900
package main

import (
	"flag"
	"fmt"
	"math"
	"os"
	"sort"
	"strconv"
	"strings"

	"github.com/OpenSRO/OpenSRO/server/internal/mapm"
	"github.com/OpenSRO/OpenSRO/server/internal/mapo"
	"github.com/OpenSRO/OpenSRO/server/internal/objidx"
	"github.com/OpenSRO/OpenSRO/server/internal/pk2"
)

const (
	regionSpan    = 1920.0
	blocksPerSide = 6
	gridWidth     = 17
	// A block spans a sixth of the region; its 17x17 vertices leave 16
	// intervals across that span.
	blockSpan = regionSpan / blocksPerSide
	tileSpan  = blockSpan / (gridWidth - 1)
)

// heightAt samples the real heightmap at a region-local (x, z), bilinearly
// between the four surrounding real vertices.
func heightAt(r *mapm.Region, x, z float64) (float64, error) {
	if x < 0 || z < 0 || x >= regionSpan || z >= regionSpan {
		return 0, fmt.Errorf("(%.1f, %.1f) is outside the region", x, z)
	}
	sample := func(vx, vz int) (float64, error) {
		bx, bz := vx/(gridWidth-1), vz/(gridWidth-1)
		ix, iz := vx%(gridWidth-1), vz%(gridWidth-1)
		if bx >= blocksPerSide {
			bx, ix = blocksPerSide-1, gridWidth-1
		}
		if bz >= blocksPerSide {
			bz, iz = blocksPerSide-1, gridWidth-1
		}
		bi := bz*blocksPerSide + bx
		if bi < 0 || bi >= len(r.Blocks) {
			return 0, fmt.Errorf("block %d out of range", bi)
		}
		return float64(r.Blocks[bi].Vertices[iz*gridWidth+ix].Height), nil
	}
	fx, fz := x/tileSpan, z/tileSpan
	x0, z0 := int(math.Floor(fx)), int(math.Floor(fz))
	tx, tz := fx-float64(x0), fz-float64(z0)
	h00, err := sample(x0, z0)
	if err != nil {
		return 0, err
	}
	h10, err := sample(x0+1, z0)
	if err != nil {
		return 0, err
	}
	h01, err := sample(x0, z0+1)
	if err != nil {
		return 0, err
	}
	h11, err := sample(x0+1, z0+1)
	if err != nil {
		return 0, err
	}
	return (h00*(1-tx)+h10*tx)*(1-tz) + (h01*(1-tx)+h11*tx)*tz, nil
}

func main() {
	mapPath := flag.String("map", "", "path to a real Map.pk2 (required)")
	dataPath := flag.String("data", "", "path to a real Data.pk2 (required)")
	region := flag.String("region", "", "region as x/y (required)")
	at := flag.String("at", "", "region-local x,z (required)")
	radius := flag.Float64("radius", 120, "how far around -at to list real placements")
	scan := flag.Bool("scan", false, "instead, check every real .o placement in the region against the heightmap")
	flag.Parse()
	if *mapPath == "" || *dataPath == "" || *region == "" || *at == "" {
		fmt.Fprintln(os.Stderr, "usage: heightat -map <Map.pk2> -data <Data.pk2> -region 96/167 -at 1500,900")
		os.Exit(1)
	}
	parts := strings.Split(*region, "/")
	rx, _ := strconv.Atoi(parts[0])
	ry, _ := strconv.Atoi(parts[1])
	coords := strings.Split(*at, ",")
	ax, _ := strconv.ParseFloat(strings.TrimSpace(coords[0]), 64)
	az, _ := strconv.ParseFloat(strings.TrimSpace(coords[1]), 64)

	mapArc, err := pk2.Open(*mapPath)
	must(err)
	defer mapArc.Close()
	dataArc, err := pk2.Open(*dataPath)
	must(err)
	defer dataArc.Close()

	mdata := readFile(mapArc, fmt.Sprintf("%d\\%d.m", rx, ry))
	if mdata == nil {
		fmt.Fprintf(os.Stderr, "no %d\\%d.m\n", rx, ry)
		os.Exit(1)
	}
	reg, err := mapm.Parse(mdata)
	must(err)

	if *scan {
		scanRegion(mapArc, dataArc, reg, rx, ry)
		return
	}

	h, err := heightAt(reg, ax, az)
	must(err)
	fmt.Printf("region %d/%d: raw heightmap at local (%.0f, %.0f) = %.2f\n", rx, ry, ax, az, h)

	idxBytes := readFile(mapArc, "object.ifo")
	if idxBytes == nil {
		idxBytes = readFile(dataArc, "navmesh\\object.ifo")
	}
	table, err := objidx.Parse(idxBytes)
	must(err)

	type near struct {
		d    float64
		y    float64
		hm   float64
		path string
	}
	var list []near
	if odata := readFile(mapArc, fmt.Sprintf("%d\\%d.o", rx, ry)); odata != nil {
		if oreg, err := mapo.Parse(odata); err == nil {
			for _, o := range oreg.Objects {
				d := math.Hypot(float64(o.Position[0])-ax, float64(o.Position[2])-az)
				if d > *radius {
					continue
				}
				oh, err := heightAt(reg, float64(o.Position[0]), float64(o.Position[2]))
				if err != nil {
					continue
				}
				p := "<unresolved>"
				if e, ok := table.Lookup(o.TypeID); ok {
					p = e.Path
				}
				list = append(list, near{d, float64(o.Position[1]), oh, p})
			}
		}
	}
	sort.Slice(list, func(i, j int) bool { return list[i].d < list[j].d })
	fmt.Printf("\n%-8s %10s %10s %9s  %s\n", "dist", "placed y", "heightmap", "diff", "model")
	for i, n := range list {
		if i >= 15 {
			break
		}
		fmt.Printf("%8.1f %10.2f %10.2f %+9.2f  %s\n", n.d, n.y, n.hm, n.y-n.hm, n.path)
	}
	if len(list) == 0 {
		fmt.Println("(no real .o placements within radius)")
	}
}

// readFile resolves path with the pk2 package's shared lookup (Find:
// case-insensitive, `\` and `/` alike; round 789), nil when it is missing.
func readFile(a *pk2.Archive, path string) []byte {
	data, err := a.ReadPath(path)
	if err != nil {
		return nil
	}
	return data
}

func must(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

// scanRegion checks every real .o placement in a region against the raw
// heightmap beneath it, which answers whether the authored data is
// self-consistent across the whole region rather than at one spot.
func scanRegion(mapArc, dataArc *pk2.Archive, reg *mapm.Region, rx, ry int) {
	idxBytes := readFile(mapArc, "object.ifo")
	if idxBytes == nil {
		idxBytes = readFile(dataArc, "navmesh\\object.ifo")
	}
	table, _ := objidx.Parse(idxBytes)

	odata := readFile(mapArc, fmt.Sprintf("%d\\%d.o", rx, ry))
	if odata == nil {
		fmt.Printf("no %d\\%d.o\n", rx, ry)
		return
	}
	oreg, err := mapo.Parse(odata)
	must(err)

	type row struct {
		diff float64
		path string
		x, z float64
	}
	var rows []row
	var checked, agree int
	for _, o := range oreg.Objects {
		h, err := heightAt(reg, float64(o.Position[0]), float64(o.Position[2]))
		if err != nil {
			continue
		}
		checked++
		d := float64(o.Position[1]) - h
		if math.Abs(d) <= 2.0 {
			agree++
		}
		p := "<unresolved>"
		if table != nil {
			if e, ok := table.Lookup(o.TypeID); ok {
				p = e.Path
			}
		}
		rows = append(rows, row{d, p, float64(o.Position[0]), float64(o.Position[2])})
	}
	sort.Slice(rows, func(i, j int) bool { return math.Abs(rows[i].diff) > math.Abs(rows[j].diff) })
	fmt.Printf("region %d/%d: %d real .o placements checked against the raw heightmap, %d within 2 units (%.1f%%)\n",
		rx, ry, checked, agree, 100*float64(agree)/float64(max(checked, 1)))

	// The same question for the .o2 lists, which is an independent way to
	// ask which of them actually belongs to this region: an entry that
	// belongs here should sit on this region's own ground.
	if o2data := readFile(mapArc, fmt.Sprintf("%d\\%d.o2", rx, ry)); o2data != nil {
		if o2reg, err := mapo.Parse2(o2data); err == nil {
			var lc, la [3]int
			for _, sec := range o2reg.Sectors {
				for li, list := range sec.Lists {
					for _, e := range list {
						h, err := heightAt(reg, float64(e.Position[0]), float64(e.Position[2]))
						if err != nil {
							continue
						}
						lc[li]++
						if math.Abs(float64(e.Position[1])-h) <= 2.0 {
							la[li]++
						}
					}
				}
			}
			for li := 0; li < 3; li++ {
				if lc[li] == 0 {
					fmt.Printf("  .o2 list %d: empty\n", li)
					continue
				}
				fmt.Printf("  .o2 list %d: %4d entries, %4d sit on this region's ground (%.1f%%)\n",
					li, lc[li], la[li], 100*float64(la[li])/float64(lc[li]))
			}
		}
	}
	fmt.Printf("\n%9s %8s %8s  %s\n", "diff", "x", "z", "model")
	for i, r := range rows {
		if i >= 10 {
			break
		}
		fmt.Printf("%+9.2f %8.0f %8.0f  %s\n", r.diff, r.x, r.z, r.path)
	}
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}
