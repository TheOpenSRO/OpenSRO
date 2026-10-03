package main

import (
	"fmt"
	"log/slog"
	"os"
	"sort"
	"strings"

	"github.com/OpenSRO/OpenSRO/server/internal/nest"
	"github.com/OpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/OpenSRO/OpenSRO/server/internal/session"
	"github.com/OpenSRO/OpenSRO/server/internal/spawn"
	"github.com/OpenSRO/OpenSRO/server/internal/species"
	"github.com/OpenSRO/OpenSRO/server/internal/teleport"
)

// npcRows is every npcpos row that is an NPC: the rows whose species the
// monster table does not hold. MEASURED (round 708) on the retail npcpos.txt
// and the monsters.csv cmd/export-refdata writes from the same archive: 257
// of 12,367 rows, exactly the characterdata rows of TypeID (1,2,2,x) -- 249
// NPCs and 8 STRUCTURE_GATE_PULLEY rows. With an NPC table the rule is the
// table's own: a row is an NPC when the table holds its id.
func npcRows(placements spawn.Table, monsters *species.Table, table npcspawn.Table) []npcspawn.Row {
	var out []npcspawn.Row
	for id, rows := range placements {
		if table != nil {
			if _, ok := table[id]; !ok {
				continue
			}
		} else if _, mob := monsters.ByID(id); mob {
			continue
		}
		for _, r := range rows {
			out = append(out, npcspawn.Row{RefID: id, Region: r.RegionID, X: r.LocalX, Y: r.LocalY, Z: r.LocalZ})
		}
	}
	return out
}

// installNPCs builds and installs the NPCs (session.InstallNPCs). Without
// placements -- or without a way to tell an NPC row from a monster's -- there
// are none, and the boot log says so.
func installNPCs(logger *slog.Logger, placements spawn.Table, monsters *species.Table, db *nest.DB, tp *teleport.Table, npcsCSV string) {
	var table npcspawn.Table
	if npcsCSV != "" {
		t, err := npcspawn.LoadCSV(npcsCSV)
		if err != nil {
			logger.Error("loading the NPC table", "path", npcsCSV, "err", err)
			os.Exit(1)
		}
		table = t
		logger.Info("NPC table loaded", "path", npcsCSV, "rows", len(t))
	}
	if placements == nil {
		logger.Warn("no NPCs: the server spawns the NPCs from -npcpos-csv, and none is configured -- the client shows no NPC")
		session.InstallNPCs(nil, logger)
		return
	}
	if table == nil && monsters == nil {
		logger.Warn("no NPCs: telling an NPC row of -npcpos-csv from a monster's needs -npcs-csv or -monsters-csv")
		session.InstallNPCs(nil, logger)
		return
	}
	teleportFlags := map[int64][2]bool{}
	if tp != nil {
		for _, p := range tp.Points {
			if p.ObjectID != 0 {
				f := teleportFlags[int64(p.ObjectID)]
				teleportFlags[int64(p.ObjectID)] = [2]bool{f[0] || p.Interaction7, f[1] || p.Interaction9}
			}
		}
	}
	info := func(id int64) (npcspawn.Info, bool) {
		r, ok := table[id]
		return npcspawn.Info{Code: r.Code}, ok
	}
	if table == nil {
		info = nil
	}
	interactions := func(id int64, code string) (byte, []byte) {
		if code == "" {
			return 0, nil
		}
		f := teleportFlags[id]
		return npcspawn.Interactions(code, npcspawn.InteractionInputs{Teleport7: f[0], Teleport9: f[1], HasShop: table[id].Shop})
	}
	npcs, rep := npcspawn.Place(npcRows(placements, monsters, table), db, info, interactions)
	filed := session.InstallNPCs(npcs, logger)
	byArea := map[string][2]int{}
	for _, n := range npcs {
		area := fmt.Sprintf("region %d", n.Region)
		if n.Code != "" {
			if parts := strings.SplitN(n.Code, "_", 3); len(parts) >= 2 {
				area = parts[1]
			}
		}
		c := byArea[area]
		if n.Source == npcspawn.FromNest {
			c[0]++
		} else {
			c[1]++
		}
		byArea[area] = c
		logger.Debug("npc placed", "near", n.Near, "uid", n.UID, "ref", n.RefID, "code", n.Code, "region", n.Region,
			"x", n.X, "z", n.Z, "angle", n.Angle, "source", n.Source.String(), "nest", n.NestID, "interactions", n.Interact)
	}
	areas := make([]string, 0, len(byArea))
	for a := range byArea {
		areas = append(areas, a)
	}
	sort.Strings(areas)
	var b strings.Builder
	for _, a := range areas {
		c := byArea[a]
		fmt.Fprintf(&b, " %s=%d/%d", a, c[0], c[1])
	}
	logger.Info("NPCs spawned by the server (round 708): position and angle from the nest DB where a nest of the NPC's own stands, else the npcpos position with no angle (OURS)",
		"rows", rep.Rows, "from_nest", rep.FromNest, "from_npcpos", rep.FromNpcpos, "nest_taken", rep.NestTaken,
		"max_join_distance", rep.MaxDist, "near_nest", rep.Near, "near_max_distance", rep.NearMaxDist, "filed", filed, "nest_db", db != nil, "npc_table", table != nil,
		"by_area_nest/npcpos", strings.TrimSpace(b.String()))
}
