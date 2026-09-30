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
// round-660 census, docs/WORLD_ISSUES.md): every one of the 10,195 field rows
// has a nest within 0.00015 units, and the nearest OTHER nest to any row
// stands 2.1 units off, so 1.0 sits between the two with room either way.
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
	Spot    Spot
	Cat     Category
	Nest    *NestRow    // Matched only
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
// every field monster row but the Egyptian temples' 90 joins one (round 661).
const FieldWorldID = 1

// JoinReport counts what Join did, for the boot log and the round's evidence.
type JoinReport struct {
	Rows       int // npcpos rows handed in
	NotMonster int // species not in the monster table (NPCs, structures)
	Dungeon    int // monster rows in dungeon regions (>= DungeonRegion), not placed
	// Unique is the rarity-3 rows NOT placed: without a DB, or whose spot
	// joins no nest of their own species in a world-1 hive with a total cap.
	Unique int
	// UniqueSpots is the rarity-3 rows placed as rotation spots, by species
	// (round 661).
	UniqueSpots map[int64]int
	// Rank8 is the rarity-8 rows (the unique-class bosses: combat.
	// RarityHPPercent keeps their authored HP, as rank 3's) NOT placed:
	// without a DB, or with no nest of their own species in a field-world hive
	// -- the shard's MOB_SD_APIS spot, whose only nest is the shard's custom
	// monster at cap 0 (round 661). One on its own world-1 nest is placed as
	// an ordinary nest.
	Rank8 int
	// OtherWorld is the rows whose joined nest's hive belongs to another game
	// world (FieldWorldID): the Egyptian temples' instance worlds 57-59 in the
	// shard (EXTERNAL). Not placed (round 661; round 660 placed them).
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
	// NearestOther the nearest any OTHER nest stood from a placed row, beyond
	// the tolerance (0 when none was measured).
	MaxMatchDist, NearestOther float64
	// ZeroCap is the matched nests whose alive cap (col 14) is 0: the pass's
	// `alive < cap` never holds, so they hatch nothing -- in the shard too.
	ZeroCap int
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
	rep := JoinReport{Rows: len(spots), SwappedTo: map[int64]int{}, UniqueSpots: map[int64]int{}}
	var byRegion map[int][]int
	if db != nil {
		byRegion = map[int][]int{}
		for i := range db.Nests {
			byRegion[db.Nests[i].Region] = append(byRegion[db.Nests[i].Region], i)
		}
	}
	used := map[int]bool{}
	out := make([]Joined, 0, len(spots))
	nearest := math.Inf(1)
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
			rep.Rank8++
			continue
		}
		j := Joined{Spot: s, Cat: StandIn}
		if db != nil {
			same, near := -1, -1
			sameD, nearD := math.Inf(1), math.Inf(1)
			for _, k := range byRegion[s.Region] {
				n := &db.Nests[k]
				d := math.Hypot(n.X-s.X, n.Z-s.Z)
				if d > JoinTolerance {
					if d < nearest {
						nearest = d
					}
					continue
				}
				if d < nearD {
					near, nearD = k, d
				}
				if t := db.Tactics[n.TacticsID]; t != nil && t.ObjID == s.ObjectID && d < sameD {
					same, sameD = k, d
				}
			}
			// A spot whose nest's hive is another world's is not in the
			// field (FieldWorldID).
			if k := same; k >= 0 || near >= 0 {
				if k < 0 {
					k = near
				}
				if h := db.Hives[db.Nests[k].HiveID]; h != nil && h.WorldID != FieldWorldID {
					used[k] = true
					rep.OtherWorld++
					continue
				}
			}
			// A unique is placed only on its own nest in a hive with a total
			// cap: the rotation (round 661). Its twin (_STR) hives name
			// another species, never the npcpos row's, so they never match.
			if sp.Rarity == 8 && same < 0 {
				// A boss on no nest of its own: no window or cap to give it.
				if near >= 0 {
					used[near] = true
				}
				rep.Rank8++
				continue
			}
			if sp.Rarity == 3 {
				if same < 0 {
					rep.Unique++
					continue
				}
				if h := db.Hives[db.Nests[same].HiveID]; h == nil || h.OverwriteMax <= 0 {
					rep.Unique++
					continue
				}
				j.Rotation = true
				rep.UniqueSpots[s.ObjectID]++
			}
			switch {
			case same >= 0:
				n := &db.Nests[same]
				used[same] = true
				j.Cat, j.Nest, j.Tactics, j.Hive = Matched, n, db.Tactics[n.TacticsID], db.Hives[n.HiveID]
				rep.MaxMatchDist = math.Max(rep.MaxMatchDist, sameD)
				if n.MaxCount <= 0 {
					rep.ZeroCap++
				}
			case near >= 0:
				n := &db.Nests[near]
				used[near] = true
				if t := db.Tactics[n.TacticsID]; t != nil {
					j.DBSpecies = t.ObjID
					rep.SwappedTo[t.ObjID]++
				}
				rep.MaxMatchDist = math.Max(rep.MaxMatchDist, nearD)
				if own := db.OwnTactics(s.ObjectID); own != nil {
					j.Cat, j.Tactics = SwappedOwn, own
				} else {
					j.Cat = SwappedStandIn
				}
			}
		}
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
		out = append(out, j)
	}
	if !math.IsInf(nearest, 1) {
		rep.NearestOther = nearest
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
