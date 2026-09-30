package main

import (
	"context"
	"fmt"
	"log/slog"
	"math"
	"math/rand"
	"sort"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/nest"
	"github.com/OpenSRO/srrevamp/server/internal/session"
	"github.com/OpenSRO/srrevamp/server/internal/spawn"
	"github.com/OpenSRO/srrevamp/server/internal/species"
	"github.com/OpenSRO/srrevamp/server/internal/worldmap"
)

// The monster world's nests (round 660). Every placement the server keeps --
// the roster's, -qa-spread-monsters', and under -full-map every field monster
// row of npcpos -- is a nest run by internal/nest's READ hatch rules from ONE
// goroutine (round 656's single respawn scheduler, now the nest scheduler):
// the alive cap, the timer armed by the first loss out of a full nest, the
// uniform [min, max] window re-rolled at each hatch, the halving on a failed
// placement, the champion/giant roll, the party arming and the hatch spot.
//
// A nest joined to the operator's DB rows (-nest-db-dir, EXTERNAL: the
// Eternity shard's _RefNest/_RefTactics/_RefHive, round 658) takes its own
// numbers: window, radius, generate radius, cap, champion chance, hive cap and
// tactics. Every other placement is a STAND-IN nest (OURS, the user's D2/D3/
// D5/D6 decisions): one monster, the respawnDelay window at both ends, no
// hatch spread, MonsterRoamRadius, no champion roll, and -- unless a swapped
// spot's species has a DB tactics row of its own -- the monster AI's stand-in
// behaviour.

// nestPassPeriod is how often the scheduler runs its hive pass. OURS: the
// engine's hive tick period is unread; 250 ms keeps a 1-3 s window's hatch
// within a quarter second of its time. Round 656's loop checked once a second.
const nestPassPeriod = 250 * time.Millisecond

// nestSummaryPeriod is how often a large scheduler logs its counts. OURS.
const nestSummaryPeriod = time.Minute

// hatchData is what a nest hatches: the species, its stats and where its nest
// stands (the monster's home), with the tactics it runs under and its
// champion row's.
type hatchData struct {
	spec                   monsterSpec
	species                combat.Species
	maxHP, defense, attack int
	gold                   int64
	homeX, homeZ           float64
	tactics, champion      *combat.Tactics
	// rotation marks a unique's spot (round 661): its window is
	// -unique-respawn's, not -nest-respawn's, and its hatch faces the nest
	// row's direction (heading) and is logged.
	rotation bool
	heading  float64
}

// hatchDataOf is spec's hatch at its own X/Z: the stats a spawn carries, with
// the floors the roster has always applied (a spec without a defence gets the
// old curve, one without HP gets 1).
func hatchDataOf(spec monsterSpec) *hatchData {
	attack, gold := monsterStatsForLevel(spec.Level, spec.Rarity)
	defense := spec.Defense
	if defense < 1 {
		defense = 1 + spec.Level/3
	}
	maxHP := spec.MaxHP
	if maxHP < 1 {
		maxHP = 1
	}
	return &hatchData{spec: spec, species: combatSpeciesOf(spec), maxHP: maxHP, defense: defense, attack: attack, gold: gold,
		homeX: spec.X, homeZ: spec.Z}
}

// respawnScheduler keeps every placement's monsters alive from one goroutine
// (round 656), each placement a nest (round 660, internal/nest).
type respawnScheduler struct {
	monsters *combat.Hub
	logger   *slog.Logger
	spawned  func(id int64)
	sched    *nest.Scheduler
	// quiet logs counts instead of a line per hatch (a large world).
	quiet bool
	// delayOverride, when above zero, is every nest's window at both ends
	// (-nest-respawn) but the uniques'; uniqueOverride the uniques' window
	// (-unique-respawn, round 661). OURS, for testing.
	delayOverride  time.Duration
	uniqueOverride time.Duration
	rotations      []nest.Rotation
	nests          int
	capTotal       int
	deaths         []int64
	pending        []int64
	// byRank and party count the hatches by the rank and the party flag
	// they came out with, for the summary line (a champion's rate is the
	// nest's chance times the tactics row's champion row; a giant's is 15 in
	// 101 of those below level 11's clamp).
	byRank [9]int64
	party  int64
}

func newRespawnScheduler(monsters *combat.Hub, logger *slog.Logger, spawned func(id int64)) *respawnScheduler {
	s := &respawnScheduler{monsters: monsters, logger: logger, spawned: spawned}
	s.sched = nest.NewScheduler(rand.New(rand.NewSource(time.Now().UnixNano())), s.hatch)
	monsters.LogDeaths(true)
	return s
}

// standInSlot is the stand-in nest for data: one monster, respawnDelay at both
// ends of its window, no spread, no champion roll. OURS (D2/D3/D6).
func standInSlot(data *hatchData, typeID4 int) *nest.Slot {
	secs := int(respawnDelay / time.Second)
	return &nest.Slot{Cap: 1, Respawn: true, Active: true, Budget: 1, DelayMin: secs, DelayMax: secs,
		Input: nest.HatchInput{Rarity: data.spec.Rarity, TypeID4: typeID4}, Level: data.spec.Level, Data: data}
}

// add registers a roster or QA placement: a stand-in nest at spec's X/Z.
func (s *respawnScheduler) add(spec monsterSpec) {
	s.addSlot(standInSlot(hatchDataOf(spec), 1))
}

// checkNestRespawn refuses a -nest-respawn override that would round to 0 s
// (the window is whole seconds): every nest would re-hatch on each pass.
// 0 is "no override"; a negative value is refused too.
func checkNestRespawn(d time.Duration) error {
	if d == 0 {
		return nil
	}
	if d < time.Second {
		return fmt.Errorf("%v is under 1s: the window is whole seconds, and 0 s would re-hatch every nest on each %v pass", d, nestPassPeriod)
	}
	return nil
}

// checkUniqueRespawn is checkNestRespawn for -unique-respawn (round 661's
// review): a wait under 1 s would truncate to 0 s and re-hatch the unique on
// the pass after each death.
func checkUniqueRespawn(d time.Duration) error {
	if err := checkNestRespawn(d); err != nil {
		return fmt.Errorf("%v is under 1s: the uniques' wait is whole seconds, and 0 s would re-hatch a unique on the pass after its death", d)
	}
	return nil
}

// addSlot registers a nest, applying -nest-respawn.
func (s *respawnScheduler) addSlot(sl *nest.Slot) {
	override := s.delayOverride
	if d, ok := sl.Data.(*hatchData); ok && d.rotation {
		override = s.uniqueOverride
	}
	if override > 0 {
		secs := int(override / time.Second)
		sl.DelayMin, sl.DelayMax = secs, secs
	}
	s.sched.Add(sl)
	s.nests++
	s.capTotal += sl.Cap
}

// hatch is the scheduler's Hatcher: the monster for one hatch, at the nest's
// position plus the hatch offset, facing the hub's Nest_Hatch heading, its
// home the nest. The class's rank replaces the species' (a rank-0 species
// that rolled champion is a champion, x2 HP; giant x20; the party flag x10 --
// combat.ScaleHPForMonster), and a champion or giant runs under its tactics
// row's champion row -- or, when that row does not exist, as the engine's
// assert path does, with its rank cleared under its own row. srrevamp has no
// server-side navigation mesh, so no placement fails.
func (s *respawnScheduler) hatch(sl *nest.Slot, roll nest.HatchRoll, dx, dz float64) (int64, bool, bool) {
	d, ok := sl.Data.(*hatchData)
	if !ok {
		return 0, false, false
	}
	sp := d.species
	sp.Rarity = roll.Class.Rank()
	tac := d.tactics
	if roll.Champion {
		if d.champion != nil {
			tac = d.champion
		} else {
			sp.Rarity = 0
		}
	}
	m := s.monsters.SpawnHatched(d.spec.Zone, sp, d.homeX+dx, 0, d.homeZ+dz, d.maxHP, d.defense, d.attack, d.gold,
		combat.Hatch{HomeX: d.homeX, HomeZ: d.homeZ, Party: roll.Class.Party(), Tactics: tac, Heading: d.heading, HasHeading: d.rotation})
	if d.rotation {
		n := 0
		if sl.Hive != nil {
			n = len(sl.Hive.Nests())
		}
		s.logger.Info("unique hatched", "id", m.ID, "name", m.Name, "nest", sl.ID, "spot", sl.Index, "of", n,
			"x", math.Round(m.X*10)/10, "z", math.Round(m.Z*10)/10, "max_hp", m.MaxHP)
	}
	if sp.Rarity >= 0 && sp.Rarity < len(s.byRank) {
		s.byRank[sp.Rarity]++
	}
	if m.Party {
		s.party++
	}
	if !s.quiet {
		s.logger.Info("monster spawned", "id", m.ID, "name", m.Name, "zone", m.Zone, "level", m.Level, "rank", m.Rarity, "party", m.Party)
	}
	return m.ID, true, false
}

// run hatches every nest's first monster at once, then runs the pass every
// nestPassPeriod until ctx ends.
func (s *respawnScheduler) run(ctx context.Context) {
	now := time.Now()
	s.check(now)
	if s.quiet {
		s.logger.Info("nests hatched their first monsters", "nests", s.nests, "alive", s.sched.Alive(), "max_alive", s.capTotal)
	}
	ticker := time.NewTicker(nestPassPeriod)
	defer ticker.Stop()
	lastSummary := now
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-ticker.C:
			s.check(now)
			if s.quiet && now.Sub(lastSummary) >= nestSummaryPeriod {
				lastSummary = now
				hatched, died := s.sched.Counts()
				s.logger.Info("nest scheduler", "nests", s.nests, "alive", s.sched.Alive(), "max_alive", s.capTotal,
					"hatched", hatched, "died", died, "rank0", s.byRank[0], "champion", s.byRank[1], "giant", s.byRank[4],
					"elite", s.byRank[6], "party", s.party)
			}
		}
	}
}

// check is one pass at now: the deaths since the last one, then the hive
// pass, then the spawn push for each new monster -- outside the scheduler's
// lock, so a slow client never holds up a kill's party arming.
func (s *respawnScheduler) check(now time.Time) {
	s.deaths = s.monsters.DrainDeaths(s.deaths[:0])
	for _, id := range s.deaths {
		s.sched.Died(id, now)
	}
	// Round 661: each re-arm of a capped hive -- a unique's death moves it
	// to its next spot.
	s.rotations = s.sched.DrainRotations(s.rotations[:0])
	for _, r := range s.rotations {
		if r.Pinned == nil {
			continue
		}
		name, x, z := "", 0.0, 0.0
		if d, ok := r.Pinned.Data.(*hatchData); ok {
			name, x, z = d.spec.Name, d.homeX, d.homeZ
		}
		s.logger.Info("unique rotation: re-pinned", "unique", name, "hive", r.Hive.ID, "spot", r.Roll,
			"of", len(r.Hive.Nests()), "nest", r.Pinned.ID, "x", math.Round(x*10)/10, "z", math.Round(z*10)/10,
			"respawn_in", time.Duration(r.WaitMs)*time.Millisecond)
	}
	s.pending = s.sched.Pass(now, s.pending[:0])
	if s.spawned != nil {
		for _, id := range s.pending {
			s.spawned(id)
		}
	}
}

// armParty is the kill observer (session.SetMonsterKillObserver): a kill
// with more than one of the killer's party members near arms the nest.
func (s *respawnScheduler) armParty(m combat.Monster, members int) {
	if s.sched.ArmParty(m.ID, members) && !s.quiet {
		s.logger.Info("nest armed for a party monster", "monster", m.ID, "name", m.Name, "members", members)
	}
}

// combatTactics is a DB tactics row as the monster AI runs it, with the roam
// radius its nest gives it (Attach: the nest's column 9 when there is a
// nest). nil for no row.
func combatTactics(t *nest.TacticsRow, roamRadius float64) *combat.Tactics {
	if t == nil {
		return nil
	}
	return &combat.Tactics{ID: t.ID, SightRange: t.SightRange, AggressType: t.AggressType, AggressData: t.AggressData,
		ChangeTarget: t.ChangeTarget, TraceBoundary: t.TraceBoundary, TraceData: t.TraceData, HomingType: t.HomingType,
		FleeType: t.FleeType, Flags: t.Flags, RoamRadius: roamRadius}
}

// nestSwappedStandIn is -nest-swapped-stand-in (OURS, round 660's review):
// the swapped spots fall back to the one-monster stand-in nest instead of
// their DB nest's numbers. Set by main before fullMapSlots runs.
var nestSwappedStandIn bool

// fullMapReport is what fullMapSlots built, for the boot log.
type fullMapReport struct {
	join nest.JoinReport
	// nests and capTotal are the slots built and the sum of their caps (the
	// most monsters the map can hold at once).
	nests, capTotal int
	// cappedHives is the DB hives with a total cap among the matched nests'.
	cappedHives int
	// aggressive/passive count the placements under a DB tactics row by its
	// column 7 (0 aggressive, 1 passive; READ rule), standIn the rest.
	aggressive, passive, standIn int
	// championable is the placements whose roll can make a champion (a
	// champion row and a chance above 0), championSlots their caps' sum.
	championable, championSlots int
	// swappedOnNest is the swapped rows running their DB nest's numbers.
	swappedOnNest int
	// missingSpecies is npcpos species the join placed but the table could
	// not build (should be 0: the join asks the same table).
	missingSpecies int
	// densest is the most monsters one player's area of interest (the
	// session.AOIRadius square of region cells around the cell it stands in)
	// can hold with every nest full, and densestCell that cell -- the longest
	// monster list the map can send.
	densest     int
	densestCell combat.Cell
	// uniques is each placed unique species' rotation (round 661).
	uniques []uniqueReport
}

// fullMapSlots is -full-map's nests: every field monster row of npcs joined
// to db's nests (nil db: every row a stand-in), each a slot hatching its
// species from the species table in the one world frame (worldmap.
// WorldOrigin, bucket worldmap.WorldBucket -- -full-map needs -single-frame,
// main forces it on).
func fullMapSlots(npcs spawn.Table, table *species.Table, lookup species.SkillLookup, db *nest.DB) ([]*nest.Slot, fullMapReport) {
	swappedStandIn := nestSwappedStandIn
	var spots []nest.Spot
	for id, rows := range npcs {
		for _, r := range rows {
			spots = append(spots, nest.Spot{ObjectID: id, Region: r.RegionID, X: r.LocalX, Y: r.LocalY, Z: r.LocalZ})
		}
	}
	nest.SortSpots(spots)
	joined, jr := nest.Join(spots, db, func(id int64) (nest.SpeciesInfo, bool) {
		row, ok := table.ByID(id)
		if !ok {
			return nest.SpeciesInfo{}, false
		}
		return nest.SpeciesInfo{Rarity: row.Rarity, CodeName: row.CodeName}, true
	})
	rep := fullMapReport{join: jr}
	specs := map[int64]monsterSpec{}
	hives := map[int64]*nest.Hive{}
	// Round 661: the uniques' skills and minions, once per species.
	uniques := map[int64]*uniqueAI{}
	uniqueReps := map[int64]*uniqueReport{}
	minions := &minionCatalog{table: table, lookup: lookup, db: db, byID: map[int64]*combat.MinionSpec{}}
	perCell := map[combat.Cell]int{}
	var hiveIDs []int64
	out := make([]*nest.Slot, 0, len(joined))
	for _, j := range joined {
		row, ok := table.ByID(j.Spot.ObjectID)
		if !ok {
			rep.missingSpecies++
			continue
		}
		spec, seen := specs[row.ID]
		if !seen {
			spec, _ = specFromRow(monsterSpec{}, row, lookup)
			spec.Zone = worldmap.WorldBucket
			specs[row.ID] = spec
		}
		lx, lz := j.Spot.X, j.Spot.Z
		if j.Nest != nil {
			lx, lz = j.Nest.X, j.Nest.Z // the nest's own position: Attach's home
		}
		rx, ry := worldmap.RegionXY(j.Spot.Region)
		spec.X, spec.Z = worldmap.ToWorld(rx, ry, lx, lz, worldmap.WorldOrigin[0], worldmap.WorldOrigin[1])
		data := hatchDataOf(spec)
		// A swapped row runs its own species' row (or the stand-in behaviour)
		// on its claimed DB nest's numbers (the user's decision, round 660's
		// review), or on the one-monster stand-in under -nest-swapped-stand-in.
		n := j.Nest
		swapped := j.Cat == nest.SwappedOwn || j.Cat == nest.SwappedStandIn
		if swapped && (swappedStandIn || n == nil) {
			n = nil
		}
		var sl *nest.Slot
		switch {
		case j.Cat == nest.Matched || (swapped && n != nil):
			t := j.Tactics // nil for a SwappedStandIn row: the stand-in behaviour
			data.tactics = combatTactics(t, float64(n.Radius))
			hasChampion := t != nil && t.ChampionTacticsID != 0
			if hasChampion {
				data.champion = combatTactics(db.Tactics[t.ChampionTacticsID], float64(n.Radius))
			}
			sl = &nest.Slot{ID: n.ID, Cap: n.MaxCount, Respawn: n.Respawn != 0, Active: n.Type == 0, Budget: n.MaxCount,
				DelayMin: n.DelayMin, DelayMax: n.DelayMax, GenerateRadius: float64(n.GenerateRadius),
				Input: nest.HatchInput{Rarity: row.Rarity, TypeID4: row.TypeID4, HasChampionTactics: hasChampion,
					ChampionPct: n.ChampionPct},
				Level: row.Level, Data: data}
			// The hive's total cap only for a matched nest: a swapped nest's
			// hive is the shard's own grouping of its repointed nests.
			if h := j.Hive; j.Cat == nest.Matched && h != nil && h.OverwriteMax > 0 {
				rt := hives[h.ID]
				if rt == nil {
					rt = &nest.Hive{ID: h.ID, TotalCap: h.OverwriteMax}
					hives[h.ID] = rt
					hiveIDs = append(hiveIDs, h.ID)
				}
				sl.Hive = rt
			}
			// Only a rank-0 species rolls (a ranked one keeps its rank,
			// nest.RollClass), so only those slots count.
			if hasChampion && n.ChampionPct > 0 && nest.RollClass(func() int { return 0 }, nest.HatchInput{Rarity: row.Rarity}, 0).Class == 0 {
				rep.championable++
				rep.championSlots += n.MaxCount
			}
			if j.Rotation {
				// A unique's spot (round 661): its skills, selector and
				// triggers, its nest's direction, its rotation window.
				u := uniques[row.ID]
				if u == nil {
					u = buildUniqueAI(row, t, db, lookup, minions)
					uniques[row.ID] = u
				}
				applyUniqueAI(data, u)
				data.rotation, data.heading = true, nestHeading(n.Dir)
				ur := uniqueReps[row.ID]
				if ur == nil {
					ur = &uniqueReport{id: row.ID, name: uniqueName(spec), minS: n.DelayMin, maxS: n.DelayMax, kind: u.kind,
						triggers: len(u.triggers), attacks: len(u.attacks), tuples: u.tuples, zeroCount: u.zeroCount, dropped: u.dropped}
					if sl.Hive != nil {
						ur.hive = sl.Hive.ID
					}
					if u.summon != nil {
						for _, ss := range u.summon.Skills {
							if ss.Skill.ID == 0 {
								continue
							}
							ur.summonSkills++
							for _, tu := range ss.Tuples {
								if tu.Minion == nil {
									ur.missingMinionSpecs = append(ur.missingMinionSpecs, tu.RefObjID)
								}
							}
						}
					}
					uniqueReps[row.ID] = ur
				}
				ur.spots++
				ur.minS, ur.maxS = min(ur.minS, n.DelayMin), max(ur.maxS, n.DelayMax)
			}
			if swapped {
				rep.swappedOnNest++
			}
		case j.Cat == nest.SwappedOwn:
			data.tactics = combatTactics(j.Tactics, float64(session.MonsterRoamRadius))
			sl = standInSlot(data, row.TypeID4)
		default:
			sl = standInSlot(data, row.TypeID4)
		}
		switch {
		case data.tactics == nil:
			rep.standIn++
		case data.tactics.AggressType == 1:
			rep.passive++
		default:
			rep.aggressive++
		}
		rep.nests++
		rep.capTotal += sl.Cap
		perCell[combat.CellOf(spec.Zone, spec.X, spec.Z)] += sl.Cap
		out = append(out, sl)
	}
	for c := range perCell {
		n := 0
		for x := c.X - session.AOIRadius; x <= c.X+session.AOIRadius; x++ {
			for z := c.Z - session.AOIRadius; z <= c.Z+session.AOIRadius; z++ {
				n += perCell[combat.Cell{Zone: c.Zone, X: x, Z: z}]
			}
		}
		if n > rep.densest {
			rep.densest, rep.densestCell = n, c
		}
	}
	sort.Slice(hiveIDs, func(i, k int) bool { return hiveIDs[i] < hiveIDs[k] })
	rep.cappedHives = len(hiveIDs)
	for _, ur := range uniqueReps {
		rep.uniques = append(rep.uniques, *ur)
	}
	return out, rep
}

// rankEightTotal is the rarity-8 rows left out, all species.
func rankEightTotal(m map[int64]int) int {
	n := 0
	for _, c := range m {
		n += c
	}
	return n
}

// logFullMap writes fullMapSlots' report.
func logFullMap(logger *slog.Logger, rep fullMapReport, withDB bool) {
	j := rep.join
	logger.Info("full map: npcpos joined to nests", "rows", j.Rows, "not_monster", j.NotMonster, "dungeon_not_placed", j.Dungeon,
		"unique_not_placed", j.Unique, "unique_spots", j.UniqueSpots, "rank8_not_placed", rankEightTotal(j.RankEight), "other_world_not_placed", j.OtherWorld,
		"custom_not_placed", j.Custom, "placed", j.Placed,
		"matched", j.Matched, "swapped_own_tactics", j.SwappedOwn, "swapped_stand_in", j.SwappedStandIn, "stand_in", j.StandIn,
		"zero_cap_nests", j.ZeroCap, "db_nests_not_placed", j.Unjoined)
	if withDB {
		logger.Info(fmt.Sprintf("full map: join tolerance %.1f units, one row per nest; farthest joined nest %.5f, nearest OTHER nest to a placed row %.3f; %d rows with more than one nest within the tolerance, %d rows whose nests were all claimed first (stand-in)",
			nest.JoinTolerance, j.MaxMatchDist, j.NearestOther, j.CoLocated, j.NestTaken))
		var top []string
		type kv struct {
			id int64
			n  int
		}
		var sw []kv
		for id, n := range j.SwappedTo {
			sw = append(sw, kv{id, n})
		}
		sort.Slice(sw, func(a, b int) bool { return sw[a].n > sw[b].n })
		for i := 0; i < len(sw) && i < 5; i++ {
			top = append(top, fmt.Sprintf("%d:%d", sw[i].id, sw[i].n))
		}
		logger.Info("full map: swapped spots place the npcpos species; the DB nest's species is not used", "swapped_to_top", top)
	} else {
		logger.Info("full map: no nest DB (-nest-db-dir / SRREVAMP_NEST_DB_DIR) -- every npcpos row is a stand-in nest " +
			"of one monster, respawning 10 s after its death, with the stand-in behaviour (all aggressive, sight 100, " +
			"give-up 400, roam 200; OURS), and no champions")
	}
	logger.Info("full map: nests", "nests", rep.nests, "max_alive", rep.capTotal, "capped_hives", rep.cappedHives,
		"aggressive", rep.aggressive, "passive", rep.passive, "stand_in_behaviour", rep.standIn,
		"champion_rolls", rep.championable, "champion_slots", rep.championSlots, "swapped_on_db_nest", rep.swappedOnNest,
		"species_missing", rep.missingSpecies)
	logger.Info("full map: the densest area of interest, every nest full", "monsters", rep.densest,
		"cell_x", rep.densestCell.X, "cell_z", rep.densestCell.Z)
}
