package nest

import (
	"math"
	"sort"
	"strings"
)

// Spot is one npcpos row (READ: the client's own placement table): a species
// and a position local to a region.
type Spot struct {
	ObjectID int64
	Region   int
	X, Y, Z  float64
}

// DungeonRegion is the first dungeon region id: npcpos rows at or above it
// stand in a dungeon's own region space (round 653's census: 1,915 monster
// rows), which this round does not place.
const DungeonRegion = 0x8000

// JoinTolerance is how far, in local units, a DB nest may stand from an
// npcpos row and still be that row's nest. OURS, set from a measurement (the
// round-660 census and its review, docs/WORLD_ISSUES.md): every field row has
// a nest within 0.00015 units; OTHER nests do stand within it -- co-located
// nests at the same point, and two at 0.713 from a MOB_KK_PLANAR row -- so the
// join also keeps one row per nest (Join).
const JoinTolerance = 1.0

// SpeciesInfo is what the join needs of a species: whether it is a monster
// the server knows (the -monsters-csv table), its rank and its code name.
type SpeciesInfo struct {
	Rarity   int
	CodeName string
}

// Category is how a row joined.
type Category uint8

const (
	// Matched: the DB nest at the spot hatches the npcpos species. Its
	// window, radius, cap, champion chance and tactics are used (EXTERNAL).
	Matched Category = iota
	// SwappedOwn: the DB nest at the spot hatches another species (the
	// shard's DEADWARRIOR and SD swaps). The npcpos species is placed, under
	// its own DB tactics row (DB.OwnTactics); the nest's numbers are the
	// stand-in's.
	SwappedOwn
	// SwappedStandIn: as SwappedOwn, but the species has no tactics row
	// left: the stand-in behaviour.
	SwappedStandIn
	// StandIn: no DB loaded, or no nest within JoinTolerance -- the stand-in
	// nest and behaviour.
	StandIn
)

func (c Category) String() string {
	switch c {
	case Matched:
		return "matched"
	case SwappedOwn:
		return "swapped-own-tactics"
	case SwappedStandIn:
		return "swapped-stand-in"
	}
	return "stand-in"
}

// Joined is one placed row and what it joined to.
type Joined struct {
	Spot Spot
	Cat  Category
	// Nest is the DB nest the row claimed: Matched's own species', or --
	// Swapped* -- the nest the shard repointed, whose numbers (cap, window,
	// radii, champion chance; EXTERNAL) the row takes by the user's decision
	// (round 660's review). nil for a stand-in.
	Nest    *NestRow
	Hive    *HiveRow    // Matched only, when the nest's hive row exists
	Tactics *TacticsRow // Matched: the nest's; SwappedOwn: the species' own; else nil
	// DBSpecies is the species the DB nest at the spot names (Swapped*).
	DBSpecies int64
}

// JoinReport counts what Join did, for the boot log and the round's evidence.
type JoinReport struct {
	Rows       int // npcpos rows handed in
	NotMonster int // species not in the monster table (NPCs, structures)
	Dungeon    int // monster rows in dungeon regions (>= DungeonRegion), not placed
	Unique     int // rarity-3 rows, not placed: round 661's rotation
	// RankEight counts the rarity-8 rows by species, not placed: unique-class
	// (the Egypt field bosses), round 661's.
	RankEight  map[int64]int
	Custom     int // custom species (IsCustomSpecies), never placed
	Placed     int
	Matched    int
	SwappedOwn int
	// SwappedStandIn and StandIn are the rows that run the stand-ins.
	SwappedStandIn, StandIn int
	// SwappedTo counts the species the DB nests at swapped spots name.
	SwappedTo map[int64]int
	// MaxMatchDist is the farthest a joined nest stood from its row;
	// NearestOther the nearest any OTHER nest -- not the row's own, at any
	// distance -- stood from a placed row (0 when none was measured).
	MaxMatchDist, NearestOther float64
	// CoLocated is the placed rows with more than one nest within the
	// tolerance; NestTaken the rows whose every nest within it was claimed by
	// another row first (they run the stand-in).
	CoLocated, NestTaken int
	// ZeroCap is the matched nests whose alive cap (col 14) is 0: the pass's
	// `alive < cap` never holds, so they hatch nothing -- in the shard too.
	ZeroCap int
	// SwappedZeroCap is the same count over the swapped rows' nests.
	SwappedZeroCap int
	// Unjoined is the DB's field monster nests of world 1 that no npcpos row
	// joined: the shard's own additions (round 658: 3,069), never placed.
	Unjoined int
}

// IsCustomSpecies reports whether a code name is one of the shard's own
// monsters (round 658: MOB_ETERNITY_DEADWARRIOR 62584, MOB_TQ_SNAKEMAN_ETERNITY,
// the seven _STR twins of the field uniques 43969-43975, the ANTHEIA
// monsters), which are never placed. OURS: the list is the round-658 finding,
// by name, since the shard's ids are its own.
func IsCustomSpecies(code string) bool {
	return strings.Contains(code, "ETERNITY") || strings.Contains(code, "ANTHEIA") ||
		(strings.HasPrefix(code, "MOB_") && strings.HasSuffix(code, "_STR"))
}

// Join matches every field monster row of spots to its DB nest (db may be
// nil: every row a stand-in). species answers for a species id; false leaves
// the row out as not a monster. The rows come back in the order given.
func Join(spots []Spot, db *DB, species func(id int64) (SpeciesInfo, bool)) ([]Joined, JoinReport) {
	rep := JoinReport{Rows: len(spots), SwappedTo: map[int64]int{}, RankEight: map[int64]int{}}
	var byRegion map[int][]int
	if db != nil {
		byRegion = map[int][]int{}
		for i := range db.Nests {
			byRegion[db.Nests[i].Region] = append(byRegion[db.Nests[i].Region], i)
		}
	}
	// Pass 1: the rows this round places.
	var rows []Joined
	for _, s := range spots {
		// The region id is the engine's u16: an export that read it signed
		// names a dungeon region (>= 0x8000) with a negative number.
		s.Region = int(uint16(s.Region))
		sp, ok := species(s.ObjectID)
		switch {
		case !ok:
			rep.NotMonster++
			continue
		case s.Region >= DungeonRegion:
			rep.Dungeon++
			continue
		case IsCustomSpecies(sp.CodeName):
			rep.Custom++
			continue
		case sp.Rarity == 3:
			rep.Unique++
			continue
		case sp.Rarity == 8:
			// Unique-class too (combat.RarityHPPercent's `case 3, 8`, the
			// target window's UIIT_STT_MOB_UNIQUE): the Egypt field bosses,
			// placed through their hives by round 661.
			rep.RankEight[s.ObjectID]++
			continue
		}
		rows = append(rows, Joined{Spot: s, Cat: StandIn})
	}
	// Pass 2: every (row, nest) pair within the tolerance, then ONE row per
	// nest and one nest per row, greedily in a deterministic order: a nest
	// of the row's own species first, then the nearest, then the row's and
	// the nest's order (OURS: the engine has no such join -- a nest is its
	// own object). Co-located nests exist: on the shard, spots where two or
	// three nests stand at the same point, and nests 0.7 units apart.
	used := map[int]bool{}
	if db != nil {
		type pair struct {
			row, nest int
			d         float64
			same      bool
		}
		var pairs []pair
		within := make([]int, len(rows))
		for i := range rows {
			s := rows[i].Spot
			for _, k := range byRegion[s.Region] {
				n := &db.Nests[k]
				d := math.Hypot(n.X-s.X, n.Z-s.Z)
				if d > JoinTolerance {
					continue
				}
				within[i]++
				t := db.Tactics[n.TacticsID]
				pairs = append(pairs, pair{row: i, nest: k, d: d, same: t != nil && t.ObjID == s.ObjectID})
			}
		}
		sort.SliceStable(pairs, func(x, y int) bool {
			a, b := pairs[x], pairs[y]
			if a.same != b.same {
				return a.same
			}
			if a.d != b.d {
				return a.d < b.d
			}
			if a.row != b.row {
				return a.row < b.row
			}
			return a.nest < b.nest
		})
		own := make([]int, len(rows))
		for i := range own {
			own[i] = -1
		}
		for _, p := range pairs {
			if own[p.row] >= 0 || used[p.nest] {
				continue
			}
			own[p.row], used[p.nest] = p.nest, true
			j := &rows[p.row]
			n := &db.Nests[p.nest]
			rep.MaxMatchDist = math.Max(rep.MaxMatchDist, p.d)
			if p.same {
				j.Cat, j.Nest, j.Tactics, j.Hive = Matched, n, db.Tactics[n.TacticsID], db.Hives[n.HiveID]
				if n.MaxCount <= 0 {
					rep.ZeroCap++
				}
				continue
			}
			j.Nest = n
			if n.MaxCount <= 0 {
				rep.SwappedZeroCap++
			}
			if t := db.Tactics[n.TacticsID]; t != nil {
				j.DBSpecies = t.ObjID
				rep.SwappedTo[t.ObjID]++
			}
			if ownRow := db.OwnTactics(j.Spot.ObjectID); ownRow != nil {
				j.Cat, j.Tactics = SwappedOwn, ownRow
			} else {
				j.Cat = SwappedStandIn
			}
		}
		// The evidence for the tolerance, measured so it can fail: every
		// OTHER nest's distance from a placed row, near or far.
		nearest := math.Inf(1)
		for i := range rows {
			if within[i] > 1 {
				rep.CoLocated++
			}
			if within[i] > 0 && own[i] < 0 {
				rep.NestTaken++
			}
			s := rows[i].Spot
			for _, k := range byRegion[s.Region] {
				if k == own[i] {
					continue
				}
				n := &db.Nests[k]
				if d := math.Hypot(n.X-s.X, n.Z-s.Z); d < nearest {
					nearest = d
				}
			}
		}
		if !math.IsInf(nearest, 1) {
			rep.NearestOther = nearest
		}
	}
	out := rows
	for _, j := range out {
		switch j.Cat {
		case Matched:
			rep.Matched++
		case SwappedOwn:
			rep.SwappedOwn++
		case SwappedStandIn:
			rep.SwappedStandIn++
		default:
			rep.StandIn++
		}
		rep.Placed++
	}
	if db != nil {
		for k := range db.Nests {
			n := &db.Nests[k]
			if used[k] || n.Region >= DungeonRegion {
				continue
			}
			t := db.Tactics[n.TacticsID]
			if t == nil {
				continue
			}
			if _, mob := species(t.ObjID); !mob {
				continue
			}
			if h := db.Hives[n.HiveID]; h != nil && h.WorldID != 1 {
				continue
			}
			rep.Unjoined++
		}
	}
	return out, rep
}

// SortSpots puts spots in a stable order -- region, then x, z and species --
// so a boot's placements, and a seeded run's rolls, do not depend on a map's
// iteration order.
func SortSpots(spots []Spot) {
	sort.SliceStable(spots, func(i, j int) bool {
		a, b := spots[i], spots[j]
		if a.Region != b.Region {
			return a.Region < b.Region
		}
		if a.X != b.X {
			return a.X < b.X
		}
		if a.Z != b.Z {
			return a.Z < b.Z
		}
		return a.ObjectID < b.ObjectID
	})
}
