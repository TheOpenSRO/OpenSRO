// Command findregionassets scans every real region's .o/.o2 object
// placements across a real Map.pk2 and reports which regions place any
// real object whose resolved .bsr path (via a real Data.pk2 object.ifo)
// contains a given case-insensitive substring.
//
// Built to answer a concrete real question this project needed (2026-08-23):
// which real Map.pk2 region(s) are actually "Jangan," the starting city,
// since no other real table names regions -- every other real reference
// this project has found is purely numeric (region coordinates, type
// IDs). Real object placements are the one real, directly checkable
// signal that ties a specific real region to a specific real, named
// resource folder (e.g. "Res\Bldg\China\Jangan01\..."). Kept as a general
// tool (not hardcoded to "jangan") since the same technique answers the
// same question for any other named real location this project might
// need to find later.
//
// Usage:
//
//	go run ./cmd/findregionassets -map "C:\Silkroad\Map.pk2" -data "C:\Silkroad\Data.pk2" -filter jangan
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

func main() {
	mapPath := flag.String("map", "", "path to a real Map.pk2 (required)")
	dataPath := flag.String("data", "", "path to a real Data.pk2, for object.ifo (required)")
	filter := flag.String("filter", "", "case-insensitive substring to match against each object's resolved .bsr path (required)")
	flag.Parse()

	if *mapPath == "" || *dataPath == "" || *filter == "" {
		fmt.Fprintln(os.Stderr, "usage: findregionassets -map <path to Map.pk2> -data <path to Data.pk2> -filter <substring>")
		os.Exit(1)
	}

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

	root, err := mapArc.ReadDir()
	must(err)

	filterLower := strings.ToLower(*filter)
	regions, matches := 0, 0
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

			found := map[string]bool{}
			if data, err := mapArc.ReadFile(f); err == nil {
				if region, err := mapo.Parse(data); err == nil {
					for _, obj := range region.Objects {
						matchEntry(objTable, obj.TypeID, filterLower, found)
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
										matchEntry(objTable, e.TypeID, filterLower, found)
									}
								}
							}
						}
					}
				}
			}

			if len(found) > 0 {
				matches++
				fmt.Printf("region %d/%d: %d distinct matching path(s)\n", xVal, yVal, len(found))
				for p := range found {
					fmt.Println("   ", p)
				}
			}
		}
	}
	fmt.Fprintf(os.Stderr, "\nscanned %d regions, %d matched \"%s\"\n", regions, matches, *filter)
}

func matchEntry(t *objidx.Table, typeID uint32, filterLower string, found map[string]bool) {
	entry, ok := t.Lookup(typeID)
	if !ok {
		return
	}
	if strings.Contains(strings.ToLower(entry.Path), filterLower) {
		found[entry.Path] = true
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
		panic(err)
	}
}
