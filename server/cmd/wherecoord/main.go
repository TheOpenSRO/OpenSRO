// Command wherecoord converts the position a real Silkroad client displays
// into the region and region-local position this project uses, and back.
//
// The client's own position readout is the fastest way to turn a reference
// screenshot of a running server into a place this project can render and
// compare. Recovered by matching three known landmarks -- Jangan's dragon
// fountain, its palace gate between the lion statues, and the shops -- against
// their already-known local coordinates:
//
//	displayed X = (region_y - 135) * 192 + local_x / 10
//	displayed Y = (region_x -  92) * 192 + local_z / 10
//
// 192 is a region's own 1920 units at the client's 10-units-per-displayed-unit
// scale; 135 and 92 are the origins of the two axes. Note which coordinate goes
// with which axis: region *y* drives displayed X and region *x* drives displayed
// Y, matching this project's own region-to-world mapping (see
// docs/WORLD_ISSUES.md's eighty-first round).
//
// Usage:
//
//	go run ./cmd/wherecoord -x 6485 -y 915           # displayed -> region/local
//	go run ./cmd/wherecoord -region 97/168 -at 1002,917   # region/local -> displayed
package main

import (
	"flag"
	"fmt"
	"os"
	"strconv"
	"strings"
)

const (
	unitsPerDisplayed = 10.0
	displayedPerRegion = 192
	regionXOrigin      = 92  // drives displayed Y
	regionYOrigin      = 135 // drives displayed X
)

func main() {
	dx := flag.Int("x", -1, "displayed X from the client")
	dy := flag.Int("y", -1, "displayed Y from the client")
	region := flag.String("region", "", "region as x/y, for the reverse conversion")
	at := flag.String("at", "", "region-local x,z, for the reverse conversion")
	flag.Parse()

	if *region != "" && *at != "" {
		parts := strings.Split(*region, "/")
		if len(parts) != 2 {
			fail("region must look like 97/168")
		}
		rx, err := strconv.Atoi(parts[0])
		must(err)
		ry, err := strconv.Atoi(parts[1])
		must(err)
		coords := strings.Split(*at, ",")
		if len(coords) != 2 {
			fail("-at must look like 1002,917")
		}
		lx, err := strconv.ParseFloat(strings.TrimSpace(coords[0]), 64)
		must(err)
		lz, err := strconv.ParseFloat(strings.TrimSpace(coords[1]), 64)
		must(err)
		x := float64((ry-regionYOrigin)*displayedPerRegion) + lx/unitsPerDisplayed
		y := float64((rx-regionXOrigin)*displayedPerRegion) + lz/unitsPerDisplayed
		fmt.Printf("region %d/%d local (%.0f, %.0f)  ->  the client shows X:%.0f Y:%.0f\n", rx, ry, lx, lz, x, y)
		return
	}

	if *dx < 0 || *dy < 0 {
		fmt.Fprintln(os.Stderr, "usage: wherecoord -x <X> -y <Y>   |   wherecoord -region 97/168 -at 1002,917")
		os.Exit(1)
	}
	ry := regionYOrigin + *dx/displayedPerRegion
	rx := regionXOrigin + *dy/displayedPerRegion
	lx := float64(*dx%displayedPerRegion) * unitsPerDisplayed
	lz := float64(*dy%displayedPerRegion) * unitsPerDisplayed
	fmt.Printf("X:%d Y:%d  ->  region %d/%d local (%.0f, %.0f)\n", *dx, *dy, rx, ry, lx, lz)
}

func must(err error) {
	if err != nil {
		fail(err.Error())
	}
}

func fail(msg string) {
	fmt.Fprintln(os.Stderr, "error:", msg)
	os.Exit(1)
}
