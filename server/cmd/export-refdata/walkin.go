package main

import (
	"encoding/csv"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/TheOpenSRO/OpenSRO/server/internal/teleport"
)

// The walk-in zones' export (round 773; internal/teleport/walkin.go).
//
// eventzonedata.txt (Media textdata, _RefEventZone; READ,
// ReferenceData::FUN_006a7650): column 0 the service flag, 1 the ID, 2 the
// ZoneName, 3 the EventType, 4..8 five ints, 9..13 five strings. For a
// TELEPORT row the first string is the teleportdata codename the server
// resolves (stricmp) to the point it fires; "xxx" is none. MEASURED: 85
// TELEPORT rows, the codename equal to the ZoneName in each.
//
// navmesh\objectstring.ifo (Data.pk2; MEASURED): "JMXVOBJI1000", a count,
// then one line per zone: `uid 0x00000000 rx rz x y z yaw "NAME"`, the four
// floats as hex bit patterns. The region id is (rz << 8) | rx (rz 128 for a
// dungeon: 0x80xx), x, y, z the zone's centre -- region-local in the field,
// dungeon space in a dungeon -- MEASURED equal to the centre of the mesh's
// trigger cells as placed, for both open-world entrances.
const (
	ezService   = 0
	ezZoneName  = 2
	ezEventType = 3
	ezParam1    = 9
)

// objectString is one objectstring.ifo line.
type objectString struct {
	region  int
	x, y, z float64
	// yaw is the fourth float (radians; round 870, the trigger doors' facing).
	yaw  float64
	name string
}

// readObjectStrings parses objectstring.ifo.
func readObjectStrings(path string) ([]objectString, error) {
	raw, err := inputs.ReadFile(path)
	if err != nil {
		return nil, err
	}
	lines := strings.Split(strings.ReplaceAll(string(raw), "\r", ""), "\n")
	if len(lines) < 2 || strings.TrimSpace(lines[0]) != "JMXVOBJI1000" {
		return nil, fmt.Errorf("%s: not a JMXVOBJI1000 file", path)
	}
	want, err := strconv.Atoi(strings.TrimSpace(lines[1]))
	if err != nil {
		return nil, fmt.Errorf("%s: the count %q is not a number", path, lines[1])
	}
	var out []objectString
	for i, line := range lines[2:] {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		q := strings.IndexByte(line, '"')
		if q < 0 || !strings.HasSuffix(line, "\"") || q == len(line)-1 {
			return nil, fmt.Errorf("%s line %d: no quoted name", path, i+3)
		}
		name := line[q+1 : len(line)-1]
		f := strings.Fields(line[:q])
		if len(f) != 8 {
			return nil, fmt.Errorf("%s line %d: %d fields before the name, want 8", path, i+3, len(f))
		}
		rx, errX := strconv.Atoi(f[2])
		rz, errZ := strconv.Atoi(f[3])
		if errX != nil || errZ != nil || rx < 0 || rx > 0xFF || rz < 0 || rz > 0xFF {
			return nil, fmt.Errorf("%s line %d: region bytes %q %q", path, i+3, f[2], f[3])
		}
		var xyz [4]float64
		for k := 0; k < 4; k++ {
			bits, err := strconv.ParseUint(strings.TrimPrefix(strings.ToLower(f[4+k]), "0x"), 16, 32)
			if err != nil {
				return nil, fmt.Errorf("%s line %d: %q is not a float's bits", path, i+3, f[4+k])
			}
			xyz[k] = float64(math.Float32frombits(uint32(bits)))
		}
		out = append(out, objectString{region: rz<<8 | rx, x: xyz[0], y: xyz[1], z: xyz[2], yaw: xyz[3], name: name})
	}
	if len(out) != want {
		return nil, fmt.Errorf("%s: %d entries, the header says %d", path, len(out), want)
	}
	return out, nil
}

// exportWalkIns writes walkin.csv: one row per TELEPORT event zone whose
// codename is a teleportdata point and which objectstring.ifo places,
// for each placement. points are teleportdata.txt's rows as read.
func exportWalkIns(outDir string, points [][]string, eventZonePath, objectStringPath string) error {
	pointID := map[string]string{}
	for _, c := range points {
		if len(c) <= tpCode {
			continue
		}
		if n, err := strconv.Atoi(strings.TrimSpace(c[0])); err == nil && n == 0 {
			continue
		}
		if _, err := strconv.Atoi(strings.TrimSpace(c[tpID])); err != nil {
			continue
		}
		pointID[strings.ToUpper(strings.TrimSpace(c[tpCode]))] = strings.TrimSpace(c[tpID])
	}
	strs, err := readObjectStrings(objectStringPath)
	if err != nil {
		return err
	}
	byName := map[string][]objectString{}
	for _, o := range strs {
		k := strings.ToUpper(o.name)
		byName[k] = append(byName[k], o)
	}
	rows, err := readTable(eventZonePath)
	if err != nil {
		return fmt.Errorf("reading %s: %w", eventZonePath, err)
	}
	f, err := os.Create(filepath.Join(outDir, teleport.WalkInsFile))
	if err != nil {
		return err
	}
	w := csv.NewWriter(f)
	if err := w.Write(teleport.WalkInCSVColumns); err != nil {
		f.Close()
		return err
	}
	zones, written, noPoint, unplaced := 0, 0, 0, 0
	for _, c := range rows {
		if len(c) <= ezParam1 {
			continue
		}
		for i := range c {
			c[i] = strings.TrimSpace(c[i])
		}
		if n, err := strconv.Atoi(c[ezService]); err != nil || n == 0 {
			continue
		}
		if !strings.EqualFold(c[ezEventType], "TELEPORT") || strings.EqualFold(c[ezParam1], "xxx") {
			continue
		}
		zones++
		id, ok := pointID[strings.ToUpper(c[ezParam1])]
		if !ok {
			noPoint++
			continue
		}
		places := byName[strings.ToUpper(c[ezZoneName])]
		if len(places) == 0 {
			unplaced++
			continue
		}
		for _, o := range places {
			rec := []string{c[ezParam1], id, strconv.Itoa(o.region),
				strconv.FormatFloat(o.x, 'f', -1, 32), strconv.FormatFloat(o.y, 'f', -1, 32), strconv.FormatFloat(o.z, 'f', -1, 32)}
			if err := w.Write(rec); err != nil {
				f.Close()
				return err
			}
			written++
		}
	}
	w.Flush()
	if err := w.Error(); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "export-refdata: wrote %d %s rows: %d TELEPORT zones, %d naming no teleport point, %d with no objectstring entry\n",
		written, teleport.WalkInsFile, zones, noPoint, unplaced)
	return nil
}

// removeIfExists removes path, and is no error when it is not there.
func removeIfExists(path string) error {
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}
