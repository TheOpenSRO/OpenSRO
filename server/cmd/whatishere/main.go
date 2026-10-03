// Command whatishere lists the real objects placed near one spot in one
// real map region, so a question like "what is that wall in front of me?"
// can be answered from the real placement data instead of by eye.
//
// It reads the region's real .o and .o2 placements, resolves each type ID
// to its real .bsr path through a real Data.pk2 object.ifo, and prints
// everything within a radius of the given region-local position, nearest
// first.
//
// Usage:
//
//	go run ./cmd/whatishere -map Map.pk2 -data Data.pk2 -region 98/168 -at 970,144 -radius 60
package main

import (
	"flag"
	"fmt"
	"math"
	"os"
	"sort"
	"strconv"
	"strings"

	"github.com/OpenSRO/OpenSRO/server/internal/mapo"
	"github.com/OpenSRO/OpenSRO/server/internal/objidx"
	"github.com/OpenSRO/OpenSRO/server/internal/pk2"
)

type hit struct {
	source   string
	typeID   uint32
	pos      [3]float32
	rotation float32
	dist     float64
}

func main() {
	mapPath := flag.String("map", "", "path to a real Map.pk2 (required)")
	dataPath := flag.String("data", "", "path to a real Data.pk2, for object.ifo (required)")
	region := flag.String("region", "", "region as x/y, e.g. 98/168 (required)")
	at := flag.String("at", "", "region-local x,z to search around (required)")
	radius := flag.Float64("radius", 60, "search radius in world units")
	flag.Parse()

	if *mapPath == "" || *dataPath == "" || *region == "" || *at == "" {
		fmt.Fprintln(os.Stderr, "usage: whatishere -map <Map.pk2> -data <Data.pk2> -region 98/168 -at 970,144 [-radius 60]")
		os.Exit(1)
	}

	rx, ry := splitPair(*region, "/")
	ax, az := splitPairF(*at, ",")

	dataArc, err := pk2.Open(*dataPath)
	must(err)
	defer dataArc.Close()
	objBytes := readFile(dataArc, "navmesh\\object.ifo")
	if objBytes == nil {
		objBytes = readFile(dataArc, "object.ifo")
	}
	if objBytes == nil {
		fmt.Fprintln(os.Stderr, "object.ifo not found in", *dataPath)
		os.Exit(1)
	}
	objTable, err := objidx.Parse(objBytes)
	must(err)

	mapArc, err := pk2.Open(*mapPath)
	must(err)
	defer mapArc.Close()

	var hits []hit
	consider := func(source string, typeID uint32, pos [3]float32, rot float32) {
		d := math.Hypot(float64(pos[0])-ax, float64(pos[2])-az)
		if d <= *radius {
			hits = append(hits, hit{source, typeID, pos, rot, d})
		}
	}

	oName := fmt.Sprintf("%d\\%d.o", rx, ry)
	if data := readFile(mapArc, oName); data != nil {
		reg, err := mapo.Parse(data)
		must(err)
		for _, o := range reg.Objects {
			consider(".o", o.TypeID, o.Position, o.Rotation)
		}
	} else {
		fmt.Fprintln(os.Stderr, "no", oName)
	}

	o2Name := fmt.Sprintf("%d\\%d.o2", rx, ry)
	if data := readFile(mapArc, o2Name); data != nil {
		reg2, err := mapo.Parse2(data)
		must(err)
		for si, sec := range reg2.Sectors {
			for li, list := range sec.Lists {
				for _, e := range list {
					consider(fmt.Sprintf(".o2 s%d/l%d", si, li), e.TypeID, e.Position, e.Rotation)
				}
			}
		}
	}

	sort.Slice(hits, func(i, j int) bool { return hits[i].dist < hits[j].dist })
	fmt.Printf("%d real placement(s) within %.0f of local (%.0f, %.0f) in region %d/%d\n\n",
		len(hits), *radius, ax, az, rx, ry)
	for _, h := range hits {
		path := "<not in object.ifo>"
		if e, ok := objTable.Lookup(h.typeID); ok {
			path = e.Path
		}
		fmt.Printf("%7.1f  %-12s id=%-6d (%8.2f, %7.2f, %8.2f) yaw=%6.1f  %s\n",
			h.dist, h.source, h.typeID, h.pos[0], h.pos[1], h.pos[2],
			float64(h.rotation)*180/math.Pi, path)
	}
}

func splitPair(s, sep string) (int, int) {
	parts := strings.Split(s, sep)
	if len(parts) != 2 {
		fmt.Fprintln(os.Stderr, "expected two values separated by", sep, "in", s)
		os.Exit(1)
	}
	a, err := strconv.Atoi(strings.TrimSpace(parts[0]))
	must(err)
	b, err := strconv.Atoi(strings.TrimSpace(parts[1]))
	must(err)
	return a, b
}

func splitPairF(s, sep string) (float64, float64) {
	parts := strings.Split(s, sep)
	if len(parts) != 2 {
		fmt.Fprintln(os.Stderr, "expected two values separated by", sep, "in", s)
		os.Exit(1)
	}
	a, err := strconv.ParseFloat(strings.TrimSpace(parts[0]), 64)
	must(err)
	b, err := strconv.ParseFloat(strings.TrimSpace(parts[1]), 64)
	must(err)
	return a, b
}

func readFile(a *pk2.Archive, path string) []byte {
	parts := strings.Split(strings.ReplaceAll(path, "\\", "/"), "/")
	entries, err := a.ReadDir()
	if err != nil {
		return nil
	}
	for i, part := range parts {
		var found *pk2.Entry
		for j := range entries {
			if strings.EqualFold(entries[j].Name, part) {
				found = &entries[j]
				break
			}
		}
		if found == nil {
			return nil
		}
		if i == len(parts)-1 {
			if found.IsDir {
				return nil
			}
			data, err := a.ReadFile(*found)
			if err != nil {
				return nil
			}
			return data
		}
		if !found.IsDir {
			return nil
		}
		children, err := a.ReadDirAt(*found)
		if err != nil {
			return nil
		}
		entries = children
	}
	return nil
}

func must(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}
