// Command waterat reports what a real region's .m says about its water: each
// block's PlaneType, WaveID and PlaneHeight, how the retail client classifies
// the block's shoreline from them, and -- for comparison -- the .nvm plane map
// this project drew water from until round 627.
//
// The rules it applies are the client's own (docs/protocol/MAPM_FORMAT.md,
// "Water"): a block is drawn as water when PlaneType is 0; each of its 17x17
// vertices gets a shoreline alpha nibble clamp(trunc((PlaneHeight - height) *
// 0.5), 0, 15) (Map::FUN_009fb280); a block whose every vertex is dry (all
// nibbles 0) is not drawn.
//
// Usage:
//
//	go run ./cmd/waterat -map Map.pk2 -data Data.pk2 -region 97/159 -at 720,900
//	go run ./cmd/waterat -map Map.pk2 -data Data.pk2 -census
//	go run ./cmd/waterat -map Map.pk2 -data Data.pk2 -column 159
package main

import (
	"encoding/binary"
	"flag"
	"fmt"
	"math"
	"os"
	"sort"
	"strconv"
	"strings"

	"github.com/OpenSRO/srrevamp/server/internal/mapm"
	"github.com/OpenSRO/srrevamp/server/internal/pk2"
)

const (
	regionSpan    = 1920.0
	blocksPerSide = 6
	gridWidth     = 17
	blockSpan     = regionSpan / blocksPerSide
	tileSpan      = blockSpan / (gridWidth - 1)
)

// nibble is Map::FUN_009fb280's per-vertex shoreline alpha, 0..15. The
// conversion truncates: the function sets the x87 rounding control to RC=11
// (chop) before its fistp (0x9fb338-0x9fb34e).
func nibble(plane, h float32) int {
	f := (plane - h) * 0.5
	if f <= 0 {
		return 0
	}
	if f > 15 {
		return 15
	}
	return int(f)
}

// state is the client's block+0x7ee after FUN_009fb280: 0 all dry (not
// drawn), 1 no dry vertex, 2 dry and partial, 3 dry and fully deep.
func state(b *mapm.Block) (int, [16]int) {
	var hist [16]int
	dry, part, deep := false, false, false
	for _, v := range b.Vertices {
		f := (b.PlaneHeight - v.Height) * 0.5
		n := nibble(b.PlaneHeight, v.Height)
		hist[n]++
		if f <= 0 || f > 15 {
			if f > 0 {
				deep = true
			} else {
				dry = true
			}
		} else {
			part = true
		}
	}
	switch {
	case !dry:
		return 1, hist
	case part && !deep:
		return 2, hist
	case deep:
		return 3, hist
	}
	return 0, hist
}

// allDeep reports whether every vertex of a block is nibble 15.
func allDeep(b *mapm.Block) bool {
	for _, v := range b.Vertices {
		if nibble(b.PlaneHeight, v.Height) != 15 {
			return false
		}
	}
	return true
}

type nvmPlanes struct {
	types   []byte
	heights []float32
}

func readNvm(dataArc *pk2.Archive, rx, ry int) *nvmPlanes {
	b := readFile(dataArc, fmt.Sprintf("navmesh\\nv_%04x.nvm", rx<<8|ry))
	if len(b) < 180 {
		return nil
	}
	tail := b[len(b)-180:]
	p := &nvmPlanes{types: tail[:36]}
	for i := 0; i < 36; i++ {
		p.heights = append(p.heights, math.Float32frombits(binary.LittleEndian.Uint32(tail[36+i*4:])))
	}
	return p
}

func main() {
	mapPath := flag.String("map", "", "path to a real Map.pk2 (required)")
	dataPath := flag.String("data", "", "path to a real Data.pk2 (for the .nvm comparison)")
	region := flag.String("region", "", "region as x/y")
	at := flag.String("at", "", "region-local x,z")
	census := flag.Bool("census", false, "tally every region's block water fields")
	column := flag.Int("column", -1, "list the water blocks of every region with this y")
	dump := flag.String("dump", "", "write this Map.pk2 file's raw bytes to stdout (e.g. Water\\water101.ddj)")
	flag.Parse()
	if *mapPath == "" {
		fmt.Fprintln(os.Stderr, "usage: waterat -map <Map.pk2> [-data <Data.pk2>] (-region x/y [-at x,z] | -census | -column y)")
		os.Exit(1)
	}
	mapArc, err := pk2.Open(*mapPath)
	must(err)
	defer mapArc.Close()
	var dataArc *pk2.Archive
	if *dataPath != "" {
		dataArc, err = pk2.Open(*dataPath)
		must(err)
		defer dataArc.Close()
	}

	if *dump != "" {
		b := readFile(mapArc, *dump)
		if b == nil {
			fmt.Fprintf(os.Stderr, "no %s\n", *dump)
			os.Exit(1)
		}
		os.Stdout.Write(b)
		return
	}
	if *census || *column >= 0 {
		runCensus(mapArc, dataArc, *column)
		return
	}
	parts := strings.Split(*region, "/")
	if len(parts) != 2 {
		fmt.Fprintln(os.Stderr, "-region must look like 97/168")
		os.Exit(1)
	}
	rx, _ := strconv.Atoi(parts[0])
	ry, _ := strconv.Atoi(parts[1])
	data := readFile(mapArc, fmt.Sprintf("%d\\%d.m", rx, ry))
	if data == nil {
		fmt.Fprintf(os.Stderr, "no %d\\%d.m\n", rx, ry)
		os.Exit(1)
	}
	reg, err := mapm.Parse(data)
	must(err)
	var nv *nvmPlanes
	if dataArc != nil {
		nv = readNvm(dataArc, rx, ry)
	}
	fmt.Printf("region %d/%d (.m version %s)\n", rx, ry, reg.Version)
	fmt.Printf("%-9s %5s %5s %9s %9s %9s %6s  %s\n", "block", "type", "wave", "plane", "hmin", "hmax", "state", "nvm type/height")
	for i := range reg.Blocks {
		b := &reg.Blocks[i]
		st, _ := state(b)
		lo, hi := float32(math.Inf(1)), float32(math.Inf(-1))
		for _, v := range b.Vertices {
			lo = min(lo, v.Height)
			hi = max(hi, v.Height)
		}
		nvs := ""
		if nv != nil {
			nvs = fmt.Sprintf("%d / %.2f", nv.types[i], nv.heights[i])
		}
		stateS := "-"
		if b.PlaneType == 0 {
			stateS = strconv.Itoa(st)
		}
		deep := ""
		if b.PlaneType == 0 && st != 0 {
			best := -1
			for vi, v := range b.Vertices {
				if best < 0 || v.Height < b.Vertices[best].Height {
					best = vi
				}
			}
			deep = fmt.Sprintf("  deepest at local (%.0f, %.0f)", float64(i%6)*blockSpan+float64(best%gridWidth)*tileSpan, float64(i/6)*blockSpan+float64(best/gridWidth)*tileSpan)
		}
		fmt.Printf("r%d c%d    %5d %5d %9.2f %9.2f %9.2f %6s  %s%s\n", i/6, i%6, b.PlaneType, b.WaveID, b.PlaneHeight, lo, hi, stateS, nvs, deep)
	}
	if *at != "" {
		c := strings.Split(*at, ",")
		ax, _ := strconv.ParseFloat(strings.TrimSpace(c[0]), 64)
		az, _ := strconv.ParseFloat(strings.TrimSpace(c[1]), 64)
		bx, bz := int(ax/blockSpan), int(az/blockSpan)
		b := &reg.Blocks[bz*blocksPerSide+bx]
		ix := int(math.Round((ax - float64(bx)*blockSpan) / tileSpan))
		iz := int(math.Round((az - float64(bz)*blockSpan) / tileSpan))
		h := b.Vertices[iz*gridWidth+ix].Height
		fmt.Printf("\nat local (%.0f, %.0f): block r%d c%d, nearest vertex (%d,%d) height %.2f; plane type %d height %.2f; water depth %.2f, shoreline nibble %d\n",
			ax, az, bz, bx, iz, ix, h, b.PlaneType, b.PlaneHeight, b.PlaneHeight-h, nibble(b.PlaneHeight, h))
	}
}

func runCensus(mapArc, dataArc *pk2.Archive, column int) {
	root, err := mapArc.ReadDir()
	must(err)
	typeCount := map[int8]int{}
	waveByType := map[string]int{}
	stateCount := map[int]int{}
	nvPair := map[string]int{}
	heightMatch, heightDiff := 0, 0
	// Triangles the client's builder emits per region: a drawn PlaneType-0
	// block is a 16x16 grid (512 triangles) unless it is deep at every
	// vertex, when it is one quad (2); a still block is one quad.
	type tris struct{ grid, quad int }
	perRegion := map[[2]int]tris{}
	drawn, deepDrawn := 0, 0
	type1Regions := map[string]int{}
	regions := 0
	for _, dir := range root {
		if !dir.IsDir {
			continue
		}
		rx, err := strconv.Atoi(dir.Name)
		if err != nil {
			continue
		}
		files, err := mapArc.ReadDirAt(dir)
		if err != nil {
			continue
		}
		for _, f := range files {
			if f.IsDir || !strings.HasSuffix(strings.ToLower(f.Name), ".m") {
				continue
			}
			ry, err := strconv.Atoi(strings.TrimSuffix(strings.ToLower(f.Name), ".m"))
			if err != nil {
				continue
			}
			if column >= 0 && ry != column {
				continue
			}
			data, err := mapArc.ReadFile(f)
			if err != nil {
				continue
			}
			reg, err := mapm.Parse(data)
			if err != nil {
				continue
			}
			regions++
			var nv *nvmPlanes
			if dataArc != nil {
				nv = readNvm(dataArc, rx, ry)
			}
			for i := range reg.Blocks {
				b := &reg.Blocks[i]
				typeCount[b.PlaneType]++
				if b.PlaneType == 1 {
					type1Regions[fmt.Sprintf("%d/%d plane %.0f", rx, ry, b.PlaneHeight)]++
				}
				waveByType[fmt.Sprintf("type %d wave %d", b.PlaneType, b.WaveID)]++
				st := -1
				if b.PlaneType == 0 {
					st, _ = state(b)
					stateCount[st]++
					if st != 0 {
						drawn++
						t := perRegion[[2]int{rx, ry}]
						t.grid += 512
						if allDeep(b) {
							deepDrawn++
							t.quad += 2
						} else {
							t.quad += 512
						}
						perRegion[[2]int{rx, ry}] = t
					}
				} else if b.PlaneType == 1 && b.WaveID != 0 {
					t := perRegion[[2]int{rx, ry}]
					t.grid += 2
					t.quad += 2
					perRegion[[2]int{rx, ry}] = t
				}
				if nv != nil {
					nvPair[fmt.Sprintf(".m %d -> .nvm %d", b.PlaneType, nv.types[i])]++
					if nv.heights[i] == b.PlaneHeight {
						heightMatch++
					} else {
						heightDiff++
					}
				}
				if column >= 0 && b.PlaneType == 0 && st != 0 {
					lo := float32(math.Inf(1))
					for _, v := range b.Vertices {
						lo = min(lo, v.Height)
					}
					nvs := ""
					if nv != nil {
						nvs = fmt.Sprintf(" nvm %d/%.2f", nv.types[i], nv.heights[i])
					}
					fmt.Printf("%d/%d block r%d c%d: plane %.2f, lowest ground %.2f, state %d%s\n", rx, ry, i/6, i%6, b.PlaneHeight, lo, st, nvs)
				}
			}
		}
	}
	fmt.Printf("\n%d regions\n", regions)
	fmt.Printf("drawn PlaneType-0 blocks: %d, deep at every vertex: %d (%.1f%%)\n", drawn, deepDrawn, 100*float64(deepDrawn)/float64(max(drawn, 1)))
	// The worst 5x5 window of loaded regions, as a streamed grid of radius 2
	// holds: the most water triangles, grid-only and with deep quads.
	bestGrid, bestQuad := 0, 0
	var atGrid, atQuad [2]int
	for c := range perRegion {
		g, q := 0, 0
		for dx := -2; dx <= 2; dx++ {
			for dy := -2; dy <= 2; dy++ {
				t := perRegion[[2]int{c[0] + dx, c[1] + dy}]
				g += t.grid
				q += t.quad
			}
		}
		if g > bestGrid {
			bestGrid, atGrid = g, c
		}
		if q > bestQuad {
			bestQuad, atQuad = q, c
		}
	}
	fmt.Printf("worst 5x5 window: %d water triangles as grids (centred %d/%d), %d with deep blocks as quads (centred %d/%d)\n",
		bestGrid, atGrid[0], atGrid[1], bestQuad, atQuad[0], atQuad[1])
	printMap("PlaneType", typeCount)
	printMap("state of type-0 blocks", stateCount)
	printMap("type/wave", waveByType)
	printMap("regions with PlaneType 1 blocks", type1Regions)
	if dataArc != nil {
		printMap(".m type vs .nvm type", nvPair)
		fmt.Printf("plane height .m == .nvm: %d equal, %d differ\n", heightMatch, heightDiff)
	}
}

func printMap[K comparable](title string, m map[K]int) {
	type kv struct {
		k string
		v int
	}
	var list []kv
	for k, v := range m {
		list = append(list, kv{fmt.Sprint(k), v})
	}
	sort.Slice(list, func(i, j int) bool { return list[i].v > list[j].v })
	fmt.Printf("%s:\n", title)
	for i, e := range list {
		if i >= 20 {
			fmt.Printf("  ... %d more\n", len(list)-i)
			break
		}
		fmt.Printf("  %-28s %d\n", e.k, e.v)
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
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}
