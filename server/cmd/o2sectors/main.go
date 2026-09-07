// Command o2sectors checks a real .o2 file's entries against the sector
// each one is filed under.
//
// A real .o2 lays its entries out in a 6x6 grid of sectors covering the
// region, so an entry's own position implies which sector it should be in.
// This reports how often that implied sector matches the sector it is
// actually listed in -- the question being whether a mismatch means "this
// entry belongs to a neighbouring region and is only cross-referenced
// here", which is what a real, region-straddling object (a city wall
// thousands of units long) looks like in the data.
//
// Usage:
//
//	go run ./cmd/o2sectors -map Map.pk2 -data Data.pk2 -region 97/168
package main

import (
	"flag"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"

	"github.com/OpenSRO/srrevamp/server/internal/mapo"
	"github.com/OpenSRO/srrevamp/server/internal/objidx"
	"github.com/OpenSRO/srrevamp/server/internal/pk2"
)

const (
	regionSpan     = 1920.0
	sectorsPerSide = 6
	sectorSpan     = regionSpan / sectorsPerSide
)

func main() {
	mapPath := flag.String("map", "", "path to a real Map.pk2 (required)")
	dataPath := flag.String("data", "", "path to a real Data.pk2 (required)")
	region := flag.String("region", "", "region as x/y (required)")
	show := flag.Int("show", 12, "how many mismatching entries to list")
	flag.Parse()
	if *mapPath == "" || *dataPath == "" || *region == "" {
		fmt.Fprintln(os.Stderr, "usage: o2sectors -map <Map.pk2> -data <Data.pk2> -region 97/168")
		os.Exit(1)
	}
	parts := strings.Split(*region, "/")
	rx, _ := strconv.Atoi(parts[0])
	ry, _ := strconv.Atoi(parts[1])

	dataArc, err := pk2.Open(*dataPath)
	must(err)
	defer dataArc.Close()
	mapArc, err := pk2.Open(*mapPath)
	must(err)
	defer mapArc.Close()

	idxBytes := readFile(mapArc, "object.ifo")
	if idxBytes == nil {
		idxBytes = readFile(dataArc, "navmesh\\object.ifo")
	}
	table, err := objidx.Parse(idxBytes)
	must(err)

	data := readFile(mapArc, fmt.Sprintf("%d\\%d.o2", rx, ry))
	if data == nil {
		fmt.Fprintf(os.Stderr, "no %d\\%d.o2\n", rx, ry)
		os.Exit(1)
	}
	reg, err := mapo.Parse2(data)
	must(err)

	perList := [3][2]int{}
	matched, mismatched := 0, 0
	type miss struct {
		listed, implied int
		typeID          uint32
		x, z            float32
	}
	var misses []miss
	for si, sec := range reg.Sectors {
		for li, list := range sec.Lists {
			for _, e := range list {
				col := int(e.Position[0] / sectorSpan)
				row := int(e.Position[2] / sectorSpan)
				implied := row*sectorsPerSide + col
				if implied == si {
					matched++
					perList[li][0]++
					continue
				}
				mismatched++
				perList[li][1]++
				misses = append(misses, miss{si, implied, e.TypeID, e.Position[0], e.Position[2]})
			}
		}
	}
	// How much of each list is genuinely new, i.e. not already placed by
	// the region's own .o -- the question being whether a list can be
	// ignored without losing real objects.
	own := map[string]bool{}
	if odata := readFile(mapArc, fmt.Sprintf("%d\\%d.o", rx, ry)); odata != nil {
		if oreg, err := mapo.Parse(odata); err == nil {
			for _, o := range oreg.Objects {
				own[key(o.TypeID, o.Position[0], o.Position[2])] = true
			}
		}
	}
	newPerList := [3]int{}
	for _, sec := range reg.Sectors {
		for li, list := range sec.Lists {
			for _, e := range list {
				if !own[key(e.TypeID, e.Position[0], e.Position[2])] {
					newPerList[li]++
				}
			}
		}
	}

	for li := 0; li < 3; li++ {
		n := perList[li][0] + perList[li][1]
		if n == 0 {
			fmt.Printf("  list %d: empty\n", li)
			continue
		}
		fmt.Printf("  list %d: %4d entries, %4d in their implied sector (%.1f%%), %d not already in the .o\n",
			li, n, perList[li][0], 100*float64(perList[li][0])/float64(n), newPerList[li])
	}
	total := matched + mismatched
	fmt.Printf("region %d/%d: %d real .o2 entries -- %d in the sector their position implies (%.1f%%), %d not\n",
		rx, ry, total, matched, 100*float64(matched)/float64(total), mismatched)

	// The real test of "list 1 is other regions' objects": take this
	// region's list-1 entries that its own .o does not place, and look for
	// the same placement in a neighbouring region's list 2.
	neighbourOwned := map[string]string{}
	for dy := -1; dy <= 1; dy++ {
		for dx := -1; dx <= 1; dx++ {
			if dx == 0 && dy == 0 {
				continue
			}
			nx, ny := rx+dx, ry+dy
			ndata := readFile(mapArc, fmt.Sprintf("%d\\%d.o2", nx, ny))
			if ndata == nil {
				continue
			}
			nreg, err := mapo.Parse2(ndata)
			if err != nil {
				continue
			}
			for _, sec := range nreg.Sectors {
				if len(sec.Lists) < 3 {
					continue
				}
				for _, e := range sec.Lists[2] {
					neighbourOwned[key(e.TypeID, e.Position[0], e.Position[2])] = fmt.Sprintf("%d/%d", nx, ny)
				}
			}
		}
	}
	claimed, unclaimed := 0, 0
	for _, sec := range reg.Sectors {
		if len(sec.Lists) < 2 {
			continue
		}
		for _, e := range sec.Lists[1] {
			k := key(e.TypeID, e.Position[0], e.Position[2])
			if own[k] {
				continue
			}
			if _, ok := neighbourOwned[k]; ok {
				claimed++
			} else {
				unclaimed++
				if unclaimed <= 5 {
					path := "<unresolved>"
					if te, ok := table.Lookup(e.TypeID); ok {
						path = te.Path
					}
					fmt.Printf("    unclaimed: id=%-5d (%.0f, %.0f) %s\n", e.TypeID, e.Position[0], e.Position[2], path)
				}
			}
		}
	}
	fmt.Printf("  list-1 entries this region's .o does not place: %d owned by a neighbour's list 2, %d unaccounted for\n",
		claimed, unclaimed)

	// The defect this is all chasing: one real object placed at identical
	// coordinates by several regions at once, and so drawn several times
	// over. Count, across a 3x3 block of regions, how many regions list
	// each such placement, and in how many of them it sits in list 2.
	type spread struct{ regions, inList2 int }
	shared := map[string]*spread{}
	for dy := -1; dy <= 1; dy++ {
		for dx := -1; dx <= 1; dx++ {
			ndata := readFile(mapArc, fmt.Sprintf("%d\\%d.o2", rx+dx, ry+dy))
			if ndata == nil {
				continue
			}
			nreg, err := mapo.Parse2(ndata)
			if err != nil {
				continue
			}
			seenHere := map[string]int{}
			for _, sec := range nreg.Sectors {
				for li, list := range sec.Lists {
					for _, e := range list {
						k := key(e.TypeID, e.Position[0], e.Position[2])
						if li == 2 {
							seenHere[k] = 2
						} else if _, ok := seenHere[k]; !ok {
							seenHere[k] = li
						}
					}
				}
			}
			for k, li := range seenHere {
				sp := shared[k]
				if sp == nil {
					sp = &spread{}
					shared[k] = sp
				}
				sp.regions++
				if li == 2 {
					sp.inList2++
				}
			}
		}
	}
	multi, exactlyOne, other := 0, 0, 0
	for _, sp := range shared {
		if sp.regions < 2 {
			continue
		}
		multi++
		if sp.inList2 == 1 {
			exactlyOne++
		} else {
			other++
		}
	}
	fmt.Printf("  placements shared by 2+ regions in this 3x3 block: %d -- %d appear in exactly one region's list 2, %d do not\n",
		multi, exactlyOne, other)

	sort.Slice(misses, func(i, j int) bool { return misses[i].typeID < misses[j].typeID })
	shown := 0
	seen := map[uint32]bool{}
	for _, m := range misses {
		if seen[m.typeID] || shown >= *show {
			continue
		}
		seen[m.typeID] = true
		shown++
		path := "<unresolved>"
		if e, ok := table.Lookup(m.typeID); ok {
			path = e.Path
		}
		fmt.Printf("  listed in sector %-2d but position (%.0f, %.0f) implies %-2d  id=%-5d %s\n",
			m.listed, m.x, m.z, m.implied, m.typeID, path)
	}
}

// key identifies one placement well enough to match the same real object
// between a .o and a .o2 listing.
func key(typeID uint32, x, z float32) string {
	return fmt.Sprintf("%d@%.1f,%.1f", typeID, x, z)
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
