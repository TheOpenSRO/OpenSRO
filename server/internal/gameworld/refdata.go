// Package gameworld is OpenSRO's game worlds (round 869,
// docs/protocol/game_worlds.md): the reference tables of a world, a group
// and a region set (this file), the instance unit World and its Manager
// (world.go, manager.go), the instance lifecycle (lifecycle.go), the entry
// rules (enter.go) and the event zones (eventzone.go).
//
// Labels as in the spec: READ (s: SR_GameServer.exe, m: SR_ShardManager.exe,
// c: sro_client.exe), MEASURED, INFERRED, OURS, OPEN.
package gameworld

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/reftable"
	"github.com/TheOpenSRO/OpenSRO/server/internal/trigger"
)

// OpenWorldID is INS_DEFAULT, the open world (MEASURED _RefGame_World row 1;
// READ CGObj::EnterWorld s:0x485360: the open world is world 1, layer 1).
const OpenWorldID uint16 = 1

// OpenLayer is the open world's one layer.
const OpenLayer uint16 = 1

// The world types (READ, section 1): 0 a single always-present world, 1 an
// instanced world of up to WorldMaxCount layers.
const (
	TypeSingle    uint8 = 0
	TypeInstanced uint8 = 1
)

// DefaultEntryUntouchable is the world's +0x5c default, the arrival
// protection (READ, game_worlds.md 1.3: 6.0 s).
const DefaultEntryUntouchable = 6 * time.Second

// DefaultMaxSquad is MAX_SQUAD_MEMBER_COUNT's default (+0x60, READ).
const DefaultMaxSquad = 6

// The tables, by their database names. The export (cmd/export-refdata -mode
// gameworlds) writes each as <name>.csv.
const (
	TableWorld        = "_RefGame_World"
	TableWorldConfig  = "_RefGame_World_Config"
	TableGroup        = "_RefGameWorldGroup"
	TableGroupConfig  = "_RefGameWorldGroup_Config"
	TableGroupBind    = "_RefGameWorldBindGameWorldGroup"
	TableRegion       = "_RefInstance_World_Region"
	TableStartPos     = "_RefInstance_World_Start_Pos"
	TableEventZone    = "_RefEventZone"
	TableWorldNPC     = "_RefGameWorldNPC"
	TableCharInstance = "_CharInstanceWorldData"
)

// TableNames is every table LoadDir reads (the trigger tables included).
func TableNames() []string {
	return append([]string{TableWorld, TableWorldConfig, TableGroup, TableGroupConfig, TableGroupBind,
		TableRegion, TableStartPos, TableEventZone, TableAssignedDrop, TableObjectString}, trigger.TableNames...)
}

// StartPos is one _RefInstance_World_Start_Pos row: an arrival point.
type StartPos struct {
	Region  uint16
	X, Y, Z float64
	Param   int
}

// Config is a world's _RefGame_World_Config group as the server reads it
// (READ vslot_055 s:0x608630, game_worlds.md 1.3).
type Config struct {
	// Normalize is GAME_WORLD_NORMALIZE_TYPE (the factory's class).
	Normalize string
	// LevelMin / LevelMax are ENTER_LIMIT_CONDITION_LEVEL_MINIMUM_NUM /
	// _MAXIMUM_NUM (+0x90..+0x93); 0 is no limit.
	LevelMin, LevelMax int
	// The ON/OFF entry limits: no job suit (+0x88), not riding (+0x98), no
	// trade transport out (+0xa0), no free-PvP voucher (+0xa8).
	JobSuitOff, NotRiding, NoTradeCOS, VoucherOff bool
	// PartyMonsterSpawn is PARTYMONSTER_SPAWN (+0x58).
	PartyMonsterSpawn bool
	// MaxSquad is MAX_SQUAD_MEMBER_COUNT (+0x60; consumer OPEN).
	MaxSquad int
	// NotifyUnique is CONTROL_NOTIFY_SPAWN_UNIQUE_MONSTER_MSG (+0x108;
	// consumer OPEN).
	NotifyUnique bool
	// Warnings are the GAMEWORLD_DISAPPEARANCE_TIME thresholds before the
	// end, longest first (the shard manager's; game_worlds.md 4).
	Warnings []time.Duration
	// EntryUntouchable is the arrival protection (+0x5c).
	EntryUntouchable time.Duration
	// Raw is every key's values, for what no field names.
	Raw map[string][]string
}

// Group is a _RefGameWorldGroup row with its config and its worlds.
type Group struct {
	ID          int
	Code        string
	ConfigGroup string
	// CoolTime is ENTER_WORLD_GROUP_COOL_TIME x 60 s (READ +0xdc): the
	// re-entry limit (game_worlds.md 13, choice 2: the database's 300 minutes).
	CoolTime time.Duration
	Raw      map[string][]string
	Worlds   []uint16
}

// WorldRef is a _RefGame_World row with what the other tables give it.
type WorldRef struct {
	ID       uint16
	Code     string
	Type     uint8
	MaxCount int // WorldMaxCount: the layer slots
	// MaxUsers is WorldMaxUserCount (0: no limit).
	MaxUsers                           int
	EntryType, EntranceType, LeaveType int
	Duration, EmptyRemain              time.Duration
	ConfigGroup                        string
	Config                             Config
	Group                              *Group
	Regions                            []uint16
	regionSet                          map[uint16]bool
	Starts                             []StartPos
}

// Instanced reports a Type-1 world.
func (w *WorldRef) Instanced() bool { return w != nil && w.Type == TypeInstanced }

// HasRegion reports whether region rid is one of the world's
// (_RefInstance_World_Region).
func (w *WorldRef) HasRegion(rid uint16) bool { return w != nil && w.regionSet[rid] }

// EventZone is one _RefEventZone row.
type EventZone struct {
	ID     int
	Zone   string
	Event  string
	Params [5]int64
	Str    [5]string
}

// Ref is the game-world reference data.
type Ref struct {
	Worlds     map[uint16]*WorldRef
	Groups     map[int]*Group
	EventZones map[string]*EventZone
	Triggers   *trigger.Ref
	// AssignedDrops are _RefMonster_AssignedItemDrop's rows by monster
	// (round 869 lane W3: the ENVY_DROP pillars' holes; fgw.go).
	AssignedDrops map[int64][]AssignedDrop
	// ZonePlaces is where each OBJECT event zone's structure stands, from
	// the named positions of objectstring.ifo (round 870, zoneplace.go).
	ZonePlaces map[string]ZonePlace
}

// World is world id's row, nil for none.
func (r *Ref) World(id uint16) *WorldRef {
	if r == nil {
		return nil
	}
	return r.Worlds[id]
}

// WorldByCode is the world of a codename (INS_GOD_...), nil for none.
func (r *Ref) WorldByCode(code string) *WorldRef {
	if r == nil {
		return nil
	}
	for _, w := range r.Worlds {
		if strings.EqualFold(w.Code, code) {
			return w
		}
	}
	return nil
}

// IDs is every world id, ascending.
func (r *Ref) IDs() []uint16 {
	out := make([]uint16, 0, len(r.Worlds))
	for id := range r.Worlds {
		out = append(out, id)
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}

// LoadDir reads the export's CSVs from dir. _RefGame_World.csv is required;
// every other table is optional and leaves its part empty.
func LoadDir(dir string) (*Ref, error) {
	read := func(name string) (*reftable.Table, error) {
		t, err := reftable.ReadFile(filepath.Join(dir, name+".csv"))
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return t, err
	}
	tables := map[string]*reftable.Table{}
	for _, n := range TableNames() {
		t, err := read(n)
		if err != nil {
			return nil, err
		}
		tables[n] = t
	}
	if tables[TableWorld] == nil {
		return nil, fmt.Errorf("gameworld: %s has no %s.csv", dir, TableWorld)
	}
	return Build(func(name string) *reftable.Table { return tables[name] })
}

func inService(t *reftable.Table, row []string) bool {
	return !t.Has("Service") || t.Int(row, "Service") != 0
}

// Build joins the tables (a nil table is empty).
func Build(tables trigger.Tables) (*Ref, error) {
	ref := &Ref{Worlds: map[uint16]*WorldRef{}, Groups: map[int]*Group{}, EventZones: map[string]*EventZone{}}
	wt := tables(TableWorld)
	if wt == nil {
		return nil, fmt.Errorf("gameworld: no %s table", TableWorld)
	}
	for _, r := range wt.Rows {
		id := uint16(wt.Int(r, "ID"))
		w := &WorldRef{ID: id, Code: wt.Get(r, "WorldCodeName128"), Type: uint8(wt.Int(r, "Type")),
			MaxCount: int(wt.Int(r, "WorldMaxCount")), MaxUsers: int(wt.Int(r, "WorldMaxUserCount")),
			EntryType: int(wt.Int(r, "WorldEntryType")), EntranceType: int(wt.Int(r, "WorldEntranceType")),
			LeaveType:   int(wt.Int(r, "WorldLeaveType")),
			Duration:    time.Duration(wt.Int(r, "WorldDurationTime")) * time.Millisecond,
			EmptyRemain: time.Duration(wt.Int(r, "WorldEmptyRemainTime")) * time.Millisecond,
			ConfigGroup: wt.Get(r, "ConfigGroupCodeName128"), regionSet: map[uint16]bool{},
			Config: Config{MaxSquad: DefaultMaxSquad, EntryUntouchable: DefaultEntryUntouchable, Raw: map[string][]string{}}}
		ref.Worlds[id] = w
	}
	raw := map[string]map[string][]string{}
	if t := tables(TableWorldConfig); t != nil {
		for _, r := range t.Rows {
			if !inService(t, r) {
				continue
			}
			g := t.Get(r, "GroupCodeName128")
			if raw[g] == nil {
				raw[g] = map[string][]string{}
			}
			k := t.Get(r, "ValueCodeName128")
			raw[g][k] = append(raw[g][k], t.Get(r, "Value"))
		}
	}
	for _, w := range ref.Worlds {
		if g := raw[w.ConfigGroup]; g != nil {
			w.Config = configOf(g)
		}
	}
	groupRaw := map[string]map[string][]string{}
	if t := tables(TableGroupConfig); t != nil {
		for _, r := range t.Rows {
			if !inService(t, r) {
				continue
			}
			g := t.Get(r, "GroupCodeName128")
			if groupRaw[g] == nil {
				groupRaw[g] = map[string][]string{}
			}
			k := t.Get(r, "ValueCodeName128")
			groupRaw[g][k] = append(groupRaw[g][k], t.Get(r, "Value"))
		}
	}
	if t := tables(TableGroup); t != nil {
		for _, r := range t.Rows {
			id := int(t.Int(r, "ID"))
			g := &Group{ID: id, Code: t.Get(r, "CodeName128"), ConfigGroup: t.Get(r, "ConfigGroupCodeName128")}
			g.Raw = groupRaw[g.ConfigGroup]
			if v := firstInt(g.Raw["ENTER_WORLD_GROUP_COOL_TIME"]); v > 0 {
				g.CoolTime = time.Duration(v) * time.Minute
			}
			ref.Groups[id] = g
		}
	}
	if t := tables(TableGroupBind); t != nil {
		for _, r := range t.Rows {
			if !inService(t, r) {
				continue
			}
			w, g := ref.Worlds[uint16(t.Int(r, "GameWorldID"))], ref.Groups[int(t.Int(r, "GameWorldGroupID"))]
			if w == nil || g == nil {
				continue
			}
			w.Group = g
			g.Worlds = append(g.Worlds, w.ID)
		}
	}
	for _, g := range ref.Groups {
		sort.Slice(g.Worlds, func(i, j int) bool { return g.Worlds[i] < g.Worlds[j] })
	}
	if t := tables(TableRegion); t != nil {
		for _, r := range t.Rows {
			w := ref.Worlds[uint16(t.Int(r, "WorldID"))]
			rid := uint16(t.Int(r, "RegionID"))
			if w == nil || w.regionSet[rid] {
				continue
			}
			w.regionSet[rid] = true
			w.Regions = append(w.Regions, rid)
		}
	}
	for _, w := range ref.Worlds {
		sort.Slice(w.Regions, func(i, j int) bool { return w.Regions[i] < w.Regions[j] })
	}
	if t := tables(TableStartPos); t != nil {
		for _, r := range t.Rows {
			w := ref.Worlds[uint16(t.Int(r, "WorldID"))]
			if w == nil {
				continue
			}
			w.Starts = append(w.Starts, StartPos{Region: uint16(t.Int(r, "RegionID")), X: t.Float(r, "PosX"),
				Y: t.Float(r, "PosY"), Z: t.Float(r, "PosZ"), Param: int(t.Int(r, "Param"))})
		}
	}
	if t := tables(TableEventZone); t != nil {
		for _, r := range t.Rows {
			if !inService(t, r) {
				continue
			}
			z := &EventZone{ID: int(t.Int(r, "ID")), Zone: t.Get(r, "ZoneName"), Event: t.Get(r, "EventName")}
			for i := 0; i < 5; i++ {
				z.Params[i] = t.Int(r, fmt.Sprintf("Param%d", i+1))
				z.Str[i] = t.Get(r, fmt.Sprintf("strParam%d", i+1))
			}
			ref.EventZones[z.Zone] = z
		}
	}
	buildZonePlaces(ref, tables(TableObjectString))
	ref.AssignedDrops = map[int64][]AssignedDrop{}
	if t := tables(TableAssignedDrop); t != nil {
		for _, r := range t.Rows {
			if !inService(t, r) {
				continue
			}
			d := AssignedDrop{Monster: t.Int(r, "RefMonsterID"), Item: t.Int(r, "RefItemID"),
				AmountMin: int(t.Int(r, "DropAmountMin")), AmountMax: int(t.Int(r, "DropAmountMax")), Ratio: t.Float(r, "DropRatio")}
			if d.Monster == 0 || d.Item == 0 {
				continue
			}
			ref.AssignedDrops[d.Monster] = append(ref.AssignedDrops[d.Monster], d)
		}
	}
	trig, err := trigger.BuildRef(tables)
	if err != nil {
		return nil, err
	}
	ref.Triggers = trig
	return ref, nil
}

func firstInt(vs []string) int64 {
	for _, v := range vs {
		var n int64
		if _, err := fmt.Sscan(strings.TrimSpace(v), &n); err == nil {
			return n
		}
	}
	return 0
}

func on(vs []string) bool {
	return len(vs) > 0 && strings.EqualFold(strings.TrimSpace(vs[0]), "ON")
}

// configOf reads one config group.
func configOf(raw map[string][]string) Config {
	c := Config{Raw: raw, MaxSquad: DefaultMaxSquad, EntryUntouchable: DefaultEntryUntouchable}
	if v := raw["GAME_WORLD_NORMALIZE_TYPE"]; len(v) > 0 {
		c.Normalize = v[0]
	}
	c.LevelMin = int(firstInt(raw["ENTER_LIMIT_CONDITION_LEVEL_MINIMUM_NUM"]))
	c.LevelMax = int(firstInt(raw["ENTER_LIMIT_CONDITION_LEVEL_MAXIMUM_NUM"]))
	c.JobSuitOff = on(raw["ENTER_LIMIT_CONDITION_JOB_CLOTHES_TAKE_OFF"])
	c.NotRiding = on(raw["ENTER_LIMIT_CONDITION_RIDE_COS_NOT_RIDING"])
	c.NoTradeCOS = on(raw["ENTER_LIMIT_CONDITION_TRADE_COS_NOT_RIDING"])
	c.VoucherOff = on(raw["ENTER_LIMIT_CONDITION_FRPVP_VOUCHER_TAKE_OFF"])
	c.PartyMonsterSpawn = on(raw["PARTYMONSTER_SPAWN"])
	c.NotifyUnique = on(raw["CONTROL_NOTIFY_SPAWN_UNIQUE_MONSTER_MSG"])
	if v := firstInt(raw["MAX_SQUAD_MEMBER_COUNT"]); v > 0 {
		c.MaxSquad = int(v)
	}
	for _, s := range raw["GAMEWORLD_DISAPPEARANCE_TIME"] {
		if v := firstInt([]string{s}); v > 0 {
			c.Warnings = append(c.Warnings, time.Duration(v)*time.Millisecond)
		}
	}
	sort.Slice(c.Warnings, func(i, j int) bool { return c.Warnings[i] > c.Warnings[j] })
	return c
}
