// Command mapobjcensus measures which of the map's placed objects the Godot
// client draws, against the set the retail loader builds (round 643).
//
// The retail loader (sro_client.exe FUN_00a361b0, MapCallBack.cpp; see
// docs/protocol/MAPO2_FORMAT.md) reads a region's `.o2` only -- no loader of
// `.o` has been found -- and builds, per sector, every record of its second
// and third lists whose byte 27 has bit 0 clear. Each record is looked up by
// the 32-bit key CONCAT22(bytes 28-29 = the owner region, bytes 22-23 = the
// uid) in a refcounted cache (Map::FUN_00a1a1d0): the first record of a key
// creates the object, every later one shares it. So "the retail set" here is
// the distinct keys over every region's lists 1 and 2 (MapO2Reader's
// numbering), skip bit clear.
//
// "The client set" is what World3D._objects_prepare places for a file region
// F, reproduced with the options below: its `.o`, plus the `.o2` lists it
// reads, each placed in F's frame (not the owner's), exact repeats removed,
// then -- unless -nofilter -- the ownership filter by height
// (_placements_belonging_here) over `.o2` placements.
//
// With -media, force_addobject.txt's loaded rows join the retail set (round
// 643's review; READ chain: Client_LoadRefDataFile type 0x3d -> FUN_00927620
// -> SWorld::vslot_045 -> the tail of FUN_00a361b0), keyed as the loader
// keys them, at their own position, in regions that have a .o2.
//
// A retail key counts as drawn when the client set holds a placement in the
// key's owner region with the same type id and a local position within 0.01.
//
// Usage (the box):
//
//	go run ./cmd/mapobjcensus -map /opt/sro-files/client/Map.pk2 [-lists 2] [-o] [-nofilter]
//	    [-models 40] [-grep bridge] [-region 92/135]
package main

import (
	"flag"
	"fmt"
	"math"
	"os"
	"sort"
	"strconv"
	"strings"
	"unicode/utf16"

	"github.com/OpenSRO/OpenSRO/server/internal/mapm"
	"github.com/OpenSRO/OpenSRO/server/internal/mapo"
	"github.com/OpenSRO/OpenSRO/server/internal/objidx"
	"github.com/OpenSRO/OpenSRO/server/internal/pk2"
)

type region struct{ a, b int } // folder a\b, packed (a<<8)|b

func (r region) String() string { return fmt.Sprintf("%d/%d", r.a, r.b) }

type rec struct {
	file   region
	list   int
	typeID uint32
	pos    [3]float32
	yaw    float32
	uid    uint16
	owner  region
	skip   bool
	path   string // force_addobject rows: the row's own path
}

func (r rec) key() uint32 { return uint32(r.owner.a)<<24 | uint32(r.owner.b)<<16 | uint32(r.uid) }

type placement struct {
	typeID uint32
	pos    [3]float32
	yaw    float32
	fromO2 bool
}

func main() {
	mapPath := flag.String("map", "", "Map.pk2")
	mediaPath := flag.String("media", "", "Media.pk2: add force_addobject.txt's rows to the retail set (round 643 review)")
	keyFlag := flag.String("key", "", "print every record of this key, as <owner a>/<owner b>#<uid>")
	lists := flag.String("lists", "2", "the .o2 lists the client reads, comma separated (MapO2Reader numbering)")
	useO := flag.Bool("o", true, "the client also places the region's .o")
	noFilter := flag.Bool("nofilter", false, "skip the ownership-by-height filter")
	ownerFrame := flag.Bool("ownerframe", false, "the client since round 643: lists 1 and 2, skip bit clear, one object per key in its OWNER's frame, no .o")
	models := flag.Int("models", 40, "models to list, by undrawn count")
	grep := flag.String("grep", "", "list every undrawn key whose model path contains this")
	only := flag.String("region", "", "list the undrawn keys owned by this region")
	dumpModels := flag.String("dumpmodels", "", "write every retail key's model as <keys>\t<undrawn keys>\t<path> to this file")
	flag.Parse()
	arc, err := pk2.Open(*mapPath)
	must(err)
	defer arc.Close()
	table, err := objidx.Parse(readFile(arc, "object.ifo"))
	must(err)
	readLists := map[int]bool{}
	for _, s := range strings.Split(*lists, ",") {
		n, _ := strconv.Atoi(s)
		readLists[n] = true
	}

	// Every region folder at the root: a numeric directory holding <b>.o2 / <b>.o / <b>.m.
	root, err := arc.ReadDir()
	must(err)
	type files struct{ o, o2, m *pk2.Entry }
	all := map[region]*files{}
	for i := range root {
		d := root[i]
		if !d.IsDir {
			continue
		}
		a, err := strconv.Atoi(d.Name)
		if err != nil {
			continue
		}
		kids, err := arc.ReadDirAt(d)
		if err != nil {
			continue
		}
		for j := range kids {
			k := kids[j]
			if k.IsDir {
				continue
			}
			dot := strings.LastIndex(k.Name, ".")
			if dot < 0 {
				continue
			}
			b, err := strconv.Atoi(k.Name[:dot])
			if err != nil {
				continue
			}
			r := region{a, b}
			f := all[r]
			if f == nil {
				f = &files{}
				all[r] = f
			}
			e := k
			switch strings.ToLower(k.Name[dot+1:]) {
			case "o":
				f.o = &e
			case "o2":
				f.o2 = &e
			case "m":
				f.m = &e
			}
		}
	}
	var regions []region
	for r := range all {
		regions = append(regions, r)
	}
	sort.Slice(regions, func(i, j int) bool {
		if regions[i].a != regions[j].a {
			return regions[i].a < regions[j].a
		}
		return regions[i].b < regions[j].b
	})

	heights := map[region]*mapm.Region{}
	heightOf := func(r region) *mapm.Region {
		if h, ok := heights[r]; ok {
			return h
		}
		var h *mapm.Region
		if f := all[r]; f != nil && f.m != nil {
			if data, err := arc.ReadFile(*f.m); err == nil {
				h, _ = mapm.Parse(data)
			}
		}
		heights[r] = h
		return h
	}

	var recs []rec
	var oCount, o2Files, oFiles, oOnly int
	listCount := [4]int{}
	skipCount := [4]int{}
	client := map[region][]placement{}
	filtered := 0
	maxPerRegion, maxRegion := 0, region{}
	for _, r := range regions {
		f := all[r]
		var placements []placement
		if f.o != nil {
			oFiles++
			if data, err := arc.ReadFile(*f.o); err == nil {
				if o, err := mapo.Parse(data); err == nil {
					oCount += len(o.Objects)
					if f.o2 == nil && len(o.Objects) > 0 {
						oOnly++
						fmt.Printf("  %s has a .o of %d records and no .o2\n", r, len(o.Objects))
					}
					if *useO && !*ownerFrame {
						for _, ob := range o.Objects {
							placements = append(placements, placement{ob.TypeID, ob.Position, ob.Rotation, false})
						}
					}
				}
			}
		}
		if f.o2 != nil {
			o2Files++
			data, err := arc.ReadFile(*f.o2)
			must(err)
			o2, err := mapo.Parse2(data)
			if err != nil {
				fmt.Fprintf(os.Stderr, "%s: %v\n", r, err)
				continue
			}
			for _, sec := range o2.Sectors {
				for li, l := range sec.Lists {
					for _, e := range l {
						owner := e.OwnerRegion()
						x := rec{file: r, list: li, typeID: e.TypeID, pos: e.Position, yaw: e.Rotation,
							uid: e.Index, owner: region{int(owner >> 8), int(owner & 0xff)}, skip: e.Skipped()}
						recs = append(recs, x)
						listCount[li]++
						if x.skip {
							skipCount[li]++
						}
						if readLists[li] && !*ownerFrame {
							placements = append(placements, placement{e.TypeID, e.Position, e.Rotation, true})
						}
					}
				}
			}
		}
		// exact repeats removed, as World3D does
		seen := map[string]bool{}
		var dedup []placement
		for _, p := range placements {
			k := fmt.Sprintf("%d@%.4f,%.4f,%.4f,%.5f", p.typeID, p.pos[0], p.pos[1], p.pos[2], p.yaw)
			if seen[k] {
				continue
			}
			seen[k] = true
			dedup = append(dedup, p)
		}
		if !*noFilter && !*ownerFrame {
			var kept []placement
			here := heightOf(r)
			for _, p := range dedup {
				if !p.fromO2 || here == nil {
					kept = append(kept, p)
					continue
				}
				own := heightAt(here, p.pos[0], p.pos[2])
				if math.IsNaN(own) {
					kept = append(kept, p)
					continue
				}
				ownErr := math.Abs(float64(p.pos[1]) - own)
				better := false
				for dy := -1; dy <= 1 && !better; dy++ {
					for dx := -1; dx <= 1; dx++ {
						if dx == 0 && dy == 0 {
							continue
						}
						// World3D's coords: x = the folder's first number? _parse_region_coords
						// reads "<x>\<y>" -- the first number is its x.
						n := heightOf(region{r.a + dx, r.b + dy})
						if n == nil {
							continue
						}
						h := heightAt(n, p.pos[0], p.pos[2])
						if math.IsNaN(h) {
							continue
						}
						if math.Abs(float64(p.pos[1])-h) < ownErr-1.0 {
							better = true
							break
						}
					}
				}
				if better {
					filtered++
				} else {
					kept = append(kept, p)
				}
			}
			dedup = kept
		}
		client[r] = dedup
		if len(dedup) > maxPerRegion {
			maxPerRegion, maxRegion = len(dedup), r
		}
	}
	// force_addobject.txt (READ: Client_LoadRefDataFile type 0x3d ->
	// FUN_00927620 -> SWorld::vslot_045 -> the tail of FUN_00a361b0): each
	// loaded row is built as the region's object when that region's .o2
	// loads, by the key (region, sector bits | a per-sector counter from
	// 0x3ff down), at the row's position as given. Recorded as "list" 3.
	forced := 0
	if *mediaPath != "" {
		media, err := pk2.Open(*mediaPath)
		must(err)
		rows := parseForceAddObject(readFile(media, "server_dep\\silkroad\\textdata\\force_addobject.txt"))
		media.Close()
		byPath := map[string]uint32{}
		for _, e := range table.Entries {
			if _, ok := byPath[strings.ToLower(e.Path)]; !ok {
				byPath[strings.ToLower(e.Path)] = e.TypeID
			}
		}
		counters := map[region]map[int]int{}
		for _, row := range rows {
			if f := all[row.region]; f == nil || f.o2 == nil {
				fmt.Printf("  force_addobject row %s in %s: the region has no .o2, so it is not built\n", row.path, row.region)
				continue
			}
			if counters[row.region] == nil {
				counters[row.region] = map[int]int{}
			}
			ri, ci := (int(row.pos[2])/320)&7, (int(row.pos[0])/320)&7
			sector := ci + ri*6
			c, ok := counters[row.region][sector]
			if !ok {
				c = 0x3ff
			}
			counters[row.region][sector] = c - 1
			typeID, ok := byPath[strings.ToLower(row.path)]
			if !ok {
				typeID = 0xffffffff
			}
			recs = append(recs, rec{file: row.region, list: 3, typeID: typeID, pos: row.pos, yaw: row.yaw,
				uid: uint16((ri*8+ci)<<10 | (c & 0x3ff)), owner: row.region, path: row.path})
			listCount[3]++
			forced++
		}
	}

	if *ownerFrame {
		// Owner frame: each key once, in its owner region, skip bit honoured.
		seen := map[uint32]bool{}
		for _, x := range recs {
			if x.list == 0 || x.skip || seen[x.key()] {
				continue
			}
			seen[x.key()] = true
			client[x.owner] = append(client[x.owner], placement{x.typeID, x.pos, x.yaw, true})
		}
		maxPerRegion = 0
		for r, ps := range client {
			if len(ps) > maxPerRegion {
				maxPerRegion, maxRegion = len(ps), r
			}
		}
	}

	fmt.Printf("regions: %d folders with a file; %d .o2, %d .o (%d .o records; %d regions with a populated .o and no .o2)\n",
		len(regions), o2Files, oFiles, oCount, oOnly)
	for li := 0; li < 3; li++ {
		fmt.Printf("  .o2 list %d: %d records, %d with the skip bit\n", li, listCount[li], skipCount[li])
	}
	fmt.Printf("  force_addobject rows built: %d\n", forced)
	fmt.Printf("client options: lists=%s o=%v filter=%v ownerframe=%v; the height filter dropped %d; largest region %s places %d (MAX_MAP_OBJECTS 2000)\n",
		*lists, *useO && !*ownerFrame, !*noFilter && !*ownerFrame, *ownerFrame, filtered, maxRegion, maxPerRegion)

	// The retail set, and the frame check.
	type keyInfo struct {
		first   rec
		files   map[region]bool
		lists   [4]int
		samePos bool
	}
	keys := map[uint32]*keyInfo{}
	for _, x := range recs {
		if x.list == 0 || x.skip {
			continue
		}
		k := keys[x.key()]
		if k == nil {
			k = &keyInfo{first: x, files: map[region]bool{}, samePos: true}
			keys[x.key()] = k
		}
		k.files[x.file] = true
		k.lists[x.list]++
		if x.pos != k.first.pos || x.typeID != k.first.typeID {
			k.samePos = false
		}
	}
	for kk, k := range keys {
		if len(k.files) > 1 && !k.samePos {
			var fs []string
			for f := range k.files {
				fs = append(fs, f.String())
			}
			sort.Strings(fs)
			fmt.Printf("  key %08x (owner %s uid %d) differs between its files %v\n", kk, k.first.owner, k.first.uid, fs)
			for _, x := range recs {
				if x.key() == kk && x.list != 0 && !x.skip {
					fmt.Printf("    %s list %d type %d (%.2f, %.2f, %.2f)\n", x.file, x.list, x.typeID, x.pos[0], x.pos[1], x.pos[2])
				}
			}
		}
	}
	multi, multiSame, ownerLists, onlyL1, onlyL2, both := 0, 0, 0, 0, 0, 0
	for _, k := range keys {
		if len(k.files) > 1 {
			multi++
			if k.samePos {
				multiSame++
			}
		}
		if k.files[k.first.owner] {
			ownerLists++
		}
		switch {
		case k.lists[3] > 0:
		case k.lists[1] > 0 && k.lists[2] > 0:
			both++
		case k.lists[1] > 0:
			onlyL1++
		default:
			onlyL2++
		}
	}
	fmt.Printf("retail set: %d distinct keys (lists 1+2, skip bit clear); %d listed by more than one region, %d of those at the identical local position and type in every file\n",
		len(keys), multi, multiSame)
	fmt.Printf("  listed by their owner region's own file: %d; in list 1 only %d, list 2 only %d, both %d\n",
		ownerLists, onlyL1, onlyL2, both)

	// Which retail keys the client set draws.
	type pk struct {
		r       region
		typeID  uint32
		x, y, z int64
	}
	q := func(v float32) int64 { return int64(math.Round(float64(v) * 100)) }
	drawn := map[pk]bool{}
	for r, ps := range client {
		for _, p := range ps {
			drawn[pk{r, p.typeID, q(p.pos[0]), q(p.pos[1]), q(p.pos[2])}] = true
		}
	}
	undrawn := map[string]int{}
	undrawnKeys := 0
	var listed []string
	matchedPK := map[pk]bool{}
	for _, k := range keys {
		x := k.first
		p := pk{x.owner, x.typeID, q(x.pos[0]), q(x.pos[1]), q(x.pos[2])}
		if drawn[p] {
			matchedPK[p] = true
			continue
		}
		undrawnKeys++
		path := "<type id not in object.ifo>"
		if e, ok := table.Lookup(x.typeID); ok {
			path = e.Path
		} else if x.path != "" {
			path = x.path
		}
		undrawn[path]++
		why := "list 1 only"
		if k.lists[2] > 0 {
			why = "in a list 2"
		}
		if k.lists[3] > 0 {
			why = "a force_addobject row"
		}
		if (*grep != "" && strings.Contains(strings.ToLower(path), strings.ToLower(*grep))) || (*only != "" && x.owner.String() == *only) {
			listed = append(listed, fmt.Sprintf("  undrawn %s uid %d (%.1f, %.1f, %.1f) yaw %.3f type %d %s -- %s; listed by %d file(s)",
				x.owner, x.uid, x.pos[0], x.pos[1], x.pos[2], x.yaw, x.typeID, path, why, len(k.files)))
		}
	}
	if *dumpModels != "" {
		all := map[string]int{}
		for _, k := range keys {
			path := "<type id not in object.ifo>"
			if e, ok := table.Lookup(k.first.typeID); ok {
				path = e.Path
			}
			all[path]++
		}
		var lines []string
		for path, n := range all {
			lines = append(lines, fmt.Sprintf("%d\t%d\t%s", n, undrawn[path], path))
		}
		sort.Strings(lines)
		must(os.WriteFile(*dumpModels, []byte(strings.Join(lines, "\n")+"\n"), 0o644))
		fmt.Printf("wrote %d models to %s\n", len(lines), *dumpModels)
	}
	// The same object in another region's frame: a key's world spot, the
	// owner's second number stepping local x and its first local z.
	type wk struct {
		typeID uint32
		x, z   int64
	}
	world := map[wk]bool{}
	for _, k := range keys {
		x := k.first
		world[wk{x.typeID, q(x.pos[0] + float32(x.owner.b)*1920), q(x.pos[2] + float32(x.owner.a)*1920)}] = true
	}
	// The same type at the same LOCAL position under another owner: the
	// placement drawn in the wrong region's frame, which the owner rule
	// moves (e.g. tre_maple03_big, 97/167#5121, drawn in 97/168's frame).
	type lk struct {
		typeID  uint32
		x, y, z int64
	}
	localOwners := map[lk][]region{}
	for _, k := range keys {
		x := k.first
		l := lk{x.typeID, q(x.pos[0]), q(x.pos[1]), q(x.pos[2])}
		localOwners[l] = append(localOwners[l], x.owner)
	}
	extra, extraElsewhere, extraMoved := 0, 0, 0
	extraByModel := map[string]int{}
	for p := range drawn {
		if !matchedPK[p] {
			if world[wk{p.typeID, p.x + int64(p.r.b)*192000, p.z + int64(p.r.a)*192000}] {
				extraElsewhere++
				continue
			}
			var owners []region
			for _, o := range localOwners[lk{p.typeID, p.x, p.y, p.z}] {
				if o != p.r && o.a-p.r.a <= 1 && p.r.a-o.a <= 1 && o.b-p.r.b <= 1 && p.r.b-o.b <= 1 {
					owners = append(owners, o)
				}
			}
			if len(owners) > 0 {
				extraMoved++
				if *grep != "" || *only != "" {
					path := ""
					if e, ok := table.Lookup(p.typeID); ok {
						path = e.Path
					}
					if (*only != "" && p.r.String() == *only) || (*grep != "" && strings.Contains(strings.ToLower(path), strings.ToLower(*grep))) {
						listed = append(listed, fmt.Sprintf("  moved %s (%.1f, %.1f, %.1f) type %d %s -> owner %v", p.r, float64(p.x)/100, float64(p.y)/100, float64(p.z)/100, p.typeID, path, owners))
					}
				}
				continue
			}
			extra++
			path := "<type id not in object.ifo>"
			if e, ok := table.Lookup(p.typeID); ok {
				path = e.Path
			}
			extraByModel[path]++
			if (*only != "" && p.r.String() == *only) || (*grep != "" && strings.Contains(strings.ToLower(path), strings.ToLower(*grep))) {
				listed = append(listed, fmt.Sprintf("  extra %s (%.1f, %.1f, %.1f) type %d %s", p.r, float64(p.x)/100, float64(p.y)/100, float64(p.z)/100, p.typeID, path))
			}
		}
	}
	var em []string
	for path, n := range extraByModel {
		em = append(em, fmt.Sprintf("%6d  %s", n, path))
	}
	sort.Sort(sort.Reverse(sort.StringSlice(em)))
	for i, l := range em {
		if i >= *models/2 {
			break
		}
		fmt.Println("  extra " + l)
	}
	for _, k := range keys {
		if !k.files[k.first.owner] {
			x := k.first
			path := ""
			if e, ok := table.Lookup(x.typeID); ok {
				path = e.Path
			}
			var fs []string
			for f := range k.files {
				fs = append(fs, f.String())
			}
			fmt.Printf("  orphan key: owner %s uid %d type %d %s listed by %v lists %v (%.1f, %.1f, %.1f)\n", x.owner, x.uid, x.typeID, path, fs, k.lists, x.pos[0], x.pos[1], x.pos[2])
		}
	}
	fmt.Printf("drawn by the client: %d of %d retail keys; UNDRAWN %d; client placements matching no retail key: %d (and %d more matching a key's world spot in another region's frame, %d a key's type and local position under a NEIGHBOURING owner: moved into the owner's frame)\n",
		len(keys)-undrawnKeys, len(keys), undrawnKeys, extra, extraElsewhere, extraMoved)
	if *keyFlag != "" {
		for _, x := range recs {
			if fmt.Sprintf("%s#%d", x.owner, x.uid) == *keyFlag {
				fmt.Printf("  key %s: file %s list %d skip %v type %d (%.1f, %.1f, %.1f)\n", *keyFlag, x.file, x.list, x.skip, x.typeID, x.pos[0], x.pos[1], x.pos[2])
			}
		}
	}
	type mc struct {
		path string
		n    int
	}
	var ms []mc
	for p, n := range undrawn {
		ms = append(ms, mc{p, n})
	}
	sort.Slice(ms, func(i, j int) bool { return ms[i].n > ms[j].n || (ms[i].n == ms[j].n && ms[i].path < ms[j].path) })
	fmt.Printf("undrawn keys by model (%d models):\n", len(ms))
	for i, m := range ms {
		if i >= *models {
			break
		}
		fmt.Printf("  %6d  %s\n", m.n, m.path)
	}
	sort.Strings(listed)
	for _, l := range listed {
		fmt.Println(l)
	}
}

type forceRow struct {
	path   string
	region region
	pos    [3]float32
	yaw    float32
}

// parseForceAddObject reads force_addobject.txt (UTF-16LE): 11 tab-separated
// columns -- service, path, region X, region Y, X, Y, Z, rotation, type,
// guild/alliance, fortress -- and keeps the rows whose service is not 0. The
// row's region is (regionY << 8) | regionX, the <regionY>\<regionX> folder.
func parseForceAddObject(data []byte) []forceRow {
	if len(data) < 2 {
		return nil
	}
	u := make([]uint16, 0, len(data)/2)
	for i := 0; i+1 < len(data); i += 2 {
		u = append(u, uint16(data[i])|uint16(data[i+1])<<8)
	}
	text := string(utf16.Decode(u))
	var rows []forceRow
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimRight(line, "\r")
		line = strings.TrimPrefix(line, "\ufeff")
		if strings.HasPrefix(line, "//") {
			continue
		}
		c := strings.Split(line, "\t")
		if len(c) < 11 {
			continue
		}
		service, err := strconv.Atoi(strings.TrimSpace(c[0]))
		if err != nil || service == 0 {
			continue
		}
		f := func(i int) float32 { v, _ := strconv.ParseFloat(strings.TrimSpace(c[i]), 32); return float32(v) }
		rx, _ := strconv.Atoi(strings.TrimSpace(c[2]))
		ry, _ := strconv.Atoi(strings.TrimSpace(c[3]))
		rows = append(rows, forceRow{strings.TrimSpace(c[1]), region{ry, rx}, [3]float32{f(4), f(5), f(6)}, f(7)})
	}
	return rows
}

const (
	gridWidth = 17
	tileSize  = 20.0
	blocks    = 6
)

// heightAt mirrors MapmTerrainBuilder.height_at.
func heightAt(r *mapm.Region, x, z float32) float64 {
	if r == nil || len(r.Blocks) < blocks*blocks {
		return math.NaN()
	}
	span := float32(blocks * (gridWidth - 1) * tileSize)
	if x < 0 || z < 0 || x >= span || z >= span {
		return math.NaN()
	}
	fx, fz := float64(x)/tileSize, float64(z)/tileSize
	x0, z0 := int(math.Floor(fx)), int(math.Floor(fz))
	tx, tz := fx-float64(x0), fz-float64(z0)
	h := func(vx, vz int) float64 {
		stride := gridWidth - 1
		bx, bz, ix, iz := vx/stride, vz/stride, vx%stride, vz%stride
		if bx > blocks-1 {
			bx, ix = blocks-1, stride
		}
		if bz > blocks-1 {
			bz, iz = blocks-1, stride
		}
		return float64(r.Blocks[bz*blocks+bx].Vertices[iz*gridWidth+ix].Height)
	}
	return (h(x0, z0)*(1-tx)+h(x0+1, z0)*tx)*(1-tz) + (h(x0, z0+1)*(1-tx)+h(x0+1, z0+1)*tx)*tz
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
			data, err := a.ReadFile(*found)
			if err != nil {
				return nil
			}
			return data
		}
		entries, err = a.ReadDirAt(*found)
		if err != nil {
			return nil
		}
	}
	return nil
}

func must(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
