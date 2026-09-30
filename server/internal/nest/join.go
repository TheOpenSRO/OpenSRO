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
	// Rotation marks a unique's spot (rarity 3) joined to its own species'
	// nest in a hive with a total cap: one of the spots the unique's hive
	// rotates over (round 661). Always Matched.
	Rotation bool
}

// FieldWorldID is the field world's GameWorldID. CMainProcess::
// CreateHivesForWorld (0x54b8d0) builds a world's hives from the _RefHive
// rows whose +0x1a (col 8, GameWorldID) equals that world's id -- READ,
// monster_ai.md "The _RefAISkill and _RefHive rows" -- so a nest in a hive of
// another world never hatches in the field. That the field world's id is 1
// is EXTERNAL: 13,666 of the shard's 16,381 nests sit in world-1 hives, and
// every field monster row but the Pharaoh temple's 90 joins one (round 661).
const FieldWorldID = 1

// JoinReport counts what Join did, for the boot log and the round's evidence.
type JoinReport struct {
	Rows       int // npcpos rows handed in
	NotMonster int // species not in the monster table (NPCs, structures)
	Dungeon    int // monster rows in dungeon regions (>= DungeonRegion), not placed
	// Unique is the rarity-3 rows NOT placed: without a DB, or whose spot
	// joins no nest of their own species in a field-world hive with a total
	// cap (round 661).
	Unique int
	// UniqueSpots is the rarity-3 rows placed as rotation spots, by species
	// (round 661).
	UniqueSpots map[int64]int
	// RankEight counts the rarity-8 rows NOT placed, by species: without a
	// DB, or with no nest of their own species in a field-world hive -- the
	// shard's MOB_SD_APIS, whose spot's only nest is the shard's custom
	// monster at cap 0 (round 661). One on its own world-1 nest is placed as
	// an ordinary nest.
	RankEight map[int64]int
	// OtherWorld is the rows whose claimed nest's hive belongs to another game
	// world (FieldWorldID): the Pharaoh temple's instance worlds 57-59 in the
	// shard (EXTERNAL; the fourteen rarity-8 bosses among them). Not placed
	// (round 661).
	OtherWorld int
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
	rep := JoinReport{Rows: len(spots), SwappedTo: map[int64]int{}, RankEight: map[int64]int{}, UniqueSpots: map[int64]int{}}
	var byRegion map[int][]int
	if db != nil {
		byRegion = map[int][]int{}
		for i := range db.Nests {
			byRegion[db.Nests[i].Region] = append(byRegion[db.Nests[i].Region], i)
		}
	}
	// Pass 1: the rows this round places. rarity keeps each row's rank for
	// round 661's filter after the claim.
	var rows []Joined
	var rarity []int
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
		case sp.Rarity == 3 && db == nil:
			rep.Unique++
			continue
		case sp.Rarity == 8 && db == nil:
			// Unique-class too (combat.RarityHPPercent's `case 3, 8`, the
			// target window's UIIT_STT_MOB_UNIQUE): with no DB there is no
			// nest to place one on (round 661).
			rep.RankEight[s.ObjectID]++
			continue
		}
		rows = append(rows, Joined{Spot: s, Cat: StandIn})
		rarity = append(rarity, sp.Rarity)
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
	// Round 661's filter on the claims: a row whose nest's hive is another
	// world's is not in the field (FieldWorldID); a unique stands only on its
	// own nest in a capped hive (its rotation -- its _STR twin's nests name
	// another species, so they are never its own); a rank-8 boss only on its
	// own nest.
	out := rows[:0:0]
	for i, j := range rows {
		if j.Nest != nil && db != nil {
			if h := db.Hives[j.Nest.HiveID]; h != nil && h.WorldID != FieldWorldID {
				rep.OtherWorld++
				continue
			}
		}
		switch rarity[i] {
		case 3:
			if j.Cat != Matched || j.Hive == nil || j.Hive.OverwriteMax <= 0 {
				rep.Unique++
				continue
			}
			j.Rotation = true
			rep.UniqueSpots[j.Spot.ObjectID]++
		case 8:
			if j.Cat != Matched {
				rep.RankEight[j.Spot.ObjectID]++
				continue
			}
		}
		out = append(out, j)
	}
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
