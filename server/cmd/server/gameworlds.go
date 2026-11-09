package main

// The game worlds (round 869, docs/protocol/game_worlds.md 14): the
// reference data (-gameworld-dir, cmd/export-refdata -mode gameworlds), the
// process's world manager with the open world attached as world 1 layer 1,
// and each instance's build -- its nests from the nest DB's hives of its
// world (dormant nests kept, no respawn where the row says so) and its NPCs
// (the NPC nests: the exit and recall NPCs).

import (
	"log/slog"
	"math/rand"
	"os"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gameworld"
	"github.com/TheOpenSRO/OpenSRO/server/internal/grounditem"
	"github.com/TheOpenSRO/OpenSRO/server/internal/nest"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/session"
	"github.com/TheOpenSRO/OpenSRO/server/internal/species"
	"github.com/TheOpenSRO/OpenSRO/server/internal/trigger"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
	"github.com/TheOpenSRO/OpenSRO/server/internal/worldmap"
)

// gameWorldBuild is what an instance's build reads.
type gameWorldBuild struct {
	logger *slog.Logger
	db     *nest.DB
	table  *species.Table
	lookup species.SkillLookup
	npcs   npcspawn.Table
}

// installGameWorlds loads the game-world data and installs the manager. nil
// when dir is empty: the open world alone, as before round 869.
func installGameWorlds(logger *slog.Logger, dir, npcsCSV string, hub *world.Hub, monsters *combat.Hub, ground *grounditem.Hub,
	db *nest.DB, table *species.Table, lookup species.SkillLookup, deps session.GameWorldDeps) *gameworld.Manager {
	if dir == "" {
		logger.Info("no game-world data (-gameworld-dir / OPENSRO_GAMEWORLD_DIR): the open world only, no instances")
		return nil
	}
	ref, err := gameworld.LoadDir(dir)
	if err != nil {
		logger.Error("loading the game-world data", "dir", dir, "err", err)
		os.Exit(1)
	}
	b := &gameWorldBuild{logger: logger, db: db, table: table, lookup: lookup}
	if npcsCSV != "" {
		if t, err := npcspawn.LoadCSV(npcsCSV); err == nil {
			b.npcs = t
		}
	}
	hooks := session.SessionWorldHooks()
	open := hooks.Open
	hooks.Open = func(w *gameworld.World) {
		if open != nil {
			open(w)
		}
		b.build(w)
	}
	mgr := gameworld.NewManager(gameworld.ManagerConfig{Ref: ref, Hooks: hooks, Logger: logger})
	mgr.AttachOpenWorld(hub, monsters, ground)
	deps.Spawn = b.spawn
	session.SetGameWorldDeps(deps)
	session.SetGameWorlds(mgr)
	instanced, triggers := 0, 0
	for _, w := range ref.Worlds {
		if w.Instanced() {
			instanced++
		}
	}
	if ref.Triggers != nil {
		triggers = len(ref.Triggers.Triggers)
	}
	logger.Info("game worlds loaded", "dir", dir, "worlds", len(ref.Worlds), "instanced", instanced, "groups", len(ref.Groups),
		"triggers", triggers, "world1_triggers", len(ref.Triggers.ForWorld(1)), "nest_db", db != nil, "species", table != nil)
	return mgr
}

// build files an instance's nests and NPCs: every nest of a hive whose
// GameWorldID is the instance's world (READ CreateHivesForWorld s:0x54b8d0;
// the layer's Init hatches its own copy, s:0x5f28f0).
func (b *gameWorldBuild) build(w *gameworld.World) {
	if b.db == nil {
		b.logger.Warn("instance opened without a nest DB (-nest-db-dir): no monsters", "world", w.ID.String())
		return
	}
	rs := &respawnScheduler{monsters: w.Monsters, logger: b.logger, quiet: true}
	hiveOf := map[*nest.Slot]int64{}
	rs.sched = nest.NewScheduler(rand.New(rand.NewSource(time.Now().UnixNano()^int64(w.Key))),
		func(sl *nest.Slot, roll nest.HatchRoll, dx, dz float64) (int64, bool, bool) {
			id, ok, failed := rs.hatch(sl, roll, dx, dz)
			if ok {
				if m, alive := w.Monsters.Get(id); alive {
					w.NoteHatched(id, trigger.Monster{Hive: hiveOf[sl], Code: m.CodeName, Rarity: m.Rarity, Level: m.Level})
				}
			}
			return id, ok, failed
		})
	w.SetNests(rs.sched)
	hives := map[int64]*nest.Hive{}
	var npcs []npcspawn.NPC
	slots, dormant, missing := 0, 0, 0
	for _, n := range b.db.Nests {
		h := b.db.Hives[n.HiveID]
		if h == nil || h.WorldID != int(w.ID.World) {
			continue
		}
		tac := b.db.Tactics[n.TacticsID]
		if tac == nil {
			missing++
			continue
		}
		row, isMonster := species.Row{}, false
		if b.table != nil {
			row, isMonster = b.table.ByID(tac.ObjID)
		}
		if !isMonster {
			if npc, ok := b.npcOf(n, tac.ObjID); ok {
				npcs = append(npcs, npc)
			} else {
				missing++
			}
			continue
		}
		spec, _ := specFromRow(monsterSpec{}, row, b.lookup)
		bucket, pos, ok := session.InstancePlace(w, uint16(n.Region), n.X, n.Y, n.Z)
		if !ok {
			missing++
			continue
		}
		spec.Zone, spec.X, spec.Z = bucket, pos.X, pos.Z
		data := hatchDataOf(spec)
		if worldmap.IsDungeonRegion(n.Region) {
			data.homeY = pos.Y
		}
		data.tactics = combatTactics(tac, float64(n.Radius))
		hasChampion := tac.ChampionTacticsID != 0
		if hasChampion {
			data.champion = combatTactics(b.db.Tactics[tac.ChampionTacticsID], float64(n.Radius))
		}
		sl := &nest.Slot{ID: n.ID, Cap: n.MaxCount, Respawn: n.Respawn != 0, Active: n.Type == 0, Budget: n.MaxCount,
			DelayMin: n.DelayMin, DelayMax: n.DelayMax, GenerateRadius: float64(n.GenerateRadius),
			Input: nest.HatchInput{Rarity: row.Rarity, TypeID4: row.TypeID4, HasChampionTactics: hasChampion, ChampionPct: n.ChampionPct},
			Level: row.Level, Data: data}
		if h.OverwriteMax > 0 {
			rt := hives[h.ID]
			if rt == nil {
				rt = &nest.Hive{ID: h.ID, TotalCap: h.OverwriteMax}
				hives[h.ID] = rt
			}
			sl.Hive = rt
		}
		if n.Type != 0 {
			dormant++
		}
		hiveOf[sl] = n.HiveID
		w.AddNest(sl, n.HiveID)
		slots++
	}
	placed := session.SetInstanceNPCs(w, npcs, b.logger)
	b.logger.Info("instance built", "world", w.ID.String(), "code", w.Ref.Code, "nests", slots, "dormant", dormant,
		"npcs", placed, "unplaced", missing, "triggers", len(w.Mgr().Ref().Triggers.ForWorld(int(w.ID.World))))
}

// npcOf is the NPC a nest places (the Forgotten World's NPCs are nests:
// forgotten_world.md 1), when the NPC table names its object.
func (b *gameWorldBuild) npcOf(n nest.NestRow, obj int64) (npcspawn.NPC, bool) {
	r, ok := b.npcs[obj]
	if !ok || r.Code == "" {
		return npcspawn.NPC{}, false
	}
	flags, ids := npcspawn.Interactions(r.Code, npcspawn.InteractionInputs{OwnsShop: r.Shop})
	return npcspawn.NPC{Record: npcspawn.Record{RefID: uint32(obj), UID: session.NextInstanceNPCUID(), Region: uint16(n.Region),
		X: float32(n.X), Y: float32(n.Y), Z: float32(n.Z), Angle: n.Dir, Flags: flags, Interact: ids},
		Code: r.Code, Shop: r.Shop, Source: npcspawn.FromNest, NestID: n.ID}, true
}

// spawn is a trigger's LOAD_MONSTER: one monster of code at a point of the
// world (the species table's row, the stand-in stats a GM /spawn uses).
func (b *gameWorldBuild) spawn(w *gameworld.World, code, zone string, x, y, z float64) (int64, bool) {
	if b.table == nil {
		return 0, false
	}
	row, ok := b.table.ByCode(code)
	if !ok {
		return 0, false
	}
	spec, _ := specFromRow(monsterSpec{}, row, b.lookup)
	spec.Zone, spec.X, spec.Z = zone, x, z
	d := hatchDataOf(spec)
	m := w.Monsters.SpawnHatched(zone, d.species, x, d.homeY, z, d.maxHP, d.defense, d.attack, d.gold,
		combat.Hatch{HomeX: x, HomeZ: z})
	return m.ID, true
}
