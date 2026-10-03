// Command scanlandmarks scans every real region's .o/.o2 object placements
// across a real Map.pk2 in a single pass and reports, for each of several
// real substrings (comma-separated), which region has the densest real
// match -- the multi-keyword generalization of findregionassets, built to
// systematically build up a real region<->named-place table instead of
// checking one candidate name at a time.
//
// Usage:
//
//	go run ./cmd/scanlandmarks -map "C:\Silkroad\Map.pk2" -data "C:\Silkroad\Data.pk2" -filters jangan,dunhuang,hotan
package main

import (
	"flag"
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/OpenSRO/OpenSRO/server/internal/mapo"
	"github.com/OpenSRO/OpenSRO/server/internal/objidx"
	"github.com/OpenSRO/OpenSRO/server/internal/pk2"
)

type regionCount struct {
	x, y  int
	count int
}

func main() {
	mapPath := flag.String("map", "", "path to a real Map.pk2 (required)")
	dataPath := flag.String("data", "", "path to a real Data.pk2, for object.ifo (required)")
	filtersFlag := flag.String("filters", "", "comma-separated case-insensitive substrings to match (required)")
	flag.Parse()

	if *mapPath == "" || *dataPath == "" || *filtersFlag == "" {
		fmt.Fprintln(os.Stderr, "usage: scanlandmarks -map <Map.pk2> -data <Data.pk2> -filters <a,b,c>")
		os.Exit(1)
	}
	var filters []string
	for _, f := range strings.Split(*filtersFlag, ",") {
		f = strings.ToLower(strings.TrimSpace(f))
		if f != "" {
			filters = append(filters, f)
		}
	}

	dataArc, err := pk2.Open(*dataPath)
	must(err)
	defer dataArc.Close()

	objBytes := readFile(dataArc, "navmesh\\object.ifo")
	if objBytes == nil {
		objBytes = readFile(dataArc, "object.ifo")
	}
	if objBytes == nil {
		fmt.Fprintln(os.Stderr, "object.ifo not found")
		os.Exit(1)
	}
	objTable, err := objidx.Parse(objBytes)
	must(err)

	mapArc, err := pk2.Open(*mapPath)
	must(err)
	defer mapArc.Close()

	root, err := mapArc.ReadDir()
	must(err)

	best := map[string]regionCount{} // filter -> densest region so far
	regions := 0
	for _, dir := range root {
		if !dir.IsDir {
			continue
		}
		xVal, err := strconv.Atoi(dir.Name)
		if err != nil {
			continue
		}
		children, err := mapArc.ReadDirAt(dir)
		if err != nil {
			continue
		}
		for _, f := range children {
			if f.IsDir || !strings.HasSuffix(strings.ToLower(f.Name), ".o") {
				continue
			}
			yVal, err := strconv.Atoi(strings.TrimSuffix(f.Name, ".o"))
			if err != nil {
				continue
			}
			regions++

			counts := map[string]int{}
			if data, err := mapArc.ReadFile(f); err == nil {
				if region, err := mapo.Parse(data); err == nil {
					for _, obj := range region.Objects {
						tallyEntry(objTable, obj.TypeID, filters, counts)
					}
				}
			}
			o2Name := fmt.Sprintf("%d.o2", yVal)
			for _, f2 := range children {
				if strings.EqualFold(f2.Name, o2Name) {
					if data2, err := mapArc.ReadFile(f2); err == nil {
						if region2, err := mapo.Parse2(data2); err == nil {
							for _, sec := range region2.Sectors {
								for _, list := range sec.Lists {
									for _, e := range list {
										tallyEntry(objTable, e.TypeID, filters, counts)
									}
								}
							}
						}
					}
				}
			}

			for filter, c := range counts {
				if c > best[filter].count {
					best[filter] = regionCount{xVal, yVal, c}
				}
			}
		}
	}

	fmt.Printf("scanned %d regions\n\n", regions)
	for _, filter := range filters {
		rc, ok := best[filter]
		if !ok {
			fmt.Printf("%-12s: no match found\n", filter)
			continue
		}
		fmt.Printf("%-12s: densest region %d/%d (%d matching placements)\n", filter, rc.x, rc.y, rc.count)
	}
}

func tallyEntry(t *objidx.Table, typeID uint32, filters []string, counts map[string]int) {
	entry, ok := t.Lookup(typeID)
	if !ok {
		return
	}
	pathLower := strings.ToLower(entry.Path)
	for _, filter := range filters {
		if strings.Contains(pathLower, filter) {
			counts[filter]++
		}
	}
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
		panic(err)
	}
}
