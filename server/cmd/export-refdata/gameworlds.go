package main

// -mode gameworlds (round 869, docs/protocol/game_worlds.md 14 item 1): the
// game worlds' reference tables into one directory of CSVs, one per table,
// named after the database table (<table>.csv), which
// internal/gameworld.LoadDir reads.
//
// Two kinds of input, mixed freely:
//   - the operator's dumps of the shard database's tables (_RefGame_World,
//     _RefGame_World_Config, _RefGameWorldGroup, _RefGameWorldGroup_Config,
//     _RefGameWorldBindGameWorldGroup, _RefInstance_World_Region,
//     _RefInstance_World_Start_Pos, _RefEventZone and every _RefTrigger*
//     table), each file named after its table (any extension), in whatever
//     shape a SQL console or a CSV export writes (internal/reftable);
//   - the client's own copies (Media.pk2): gameworlddata.txt,
//     gameworldconfigdata.txt and eventzonedata.txt, used for their table
//     only when no dump of it is given. The client's world rows carry no
//     duration, empty-close time or entry/leave types (READ
//     RefParse_gameworlddata c:0x753400: u16, str, u8, u16, u16, str), so a
//     world table from the client alone has no lifecycle timers.
//
// Nothing else is read; the region, start-position, group and trigger tables
// exist only in the server's database.

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gameworld"
	"github.com/TheOpenSRO/OpenSRO/server/internal/reftable"
)

// clientGameWorldFiles maps a client file to the table it stands in for and
// the columns its fields are, in order.
var clientGameWorldFiles = map[string]struct {
	table   string
	columns []string
}{
	"gameworlddata.txt": {gameworld.TableWorld, []string{"ID", "WorldCodeName128", "Type", "WorldMaxCount",
		"WorldMaxUserCount", "ConfigGroupCodeName128"}},
	"gameworldconfigdata.txt": {gameworld.TableWorldConfig, []string{"GroupCodeName128", "ValueCodeName128", "Type", "Value"}},
	"eventzonedata.txt": {gameworld.TableEventZone, []string{"Service", "ID", "ZoneName", "EventName", "Param1", "Param2",
		"Param3", "Param4", "Param5", "strParam1", "strParam2", "strParam3", "strParam4", "strParam5"}},
}

func exportGameWorlds(out string, paths []string) error {
	if out == "" || out == "-" {
		return fmt.Errorf("-mode gameworlds writes a directory: -out must name it")
	}
	if len(paths) == 0 {
		return fmt.Errorf("-mode gameworlds needs the table dumps and/or the client's gameworlddata.txt")
	}
	known := map[string]string{}
	for _, n := range gameworld.TableNames() {
		known[strings.ToLower(n)] = n
	}
	dumps := map[string]*reftable.Table{}
	client := map[string]*reftable.Table{}
	for _, p := range paths {
		base := filepath.Base(p)
		if spec, ok := clientGameWorldFiles[strings.ToLower(base)]; ok {
			rows, err := readTable(p)
			if err != nil {
				return fmt.Errorf("reading %s: %w", p, err)
			}
			t := reftable.New(spec.columns...)
			for _, r := range rows {
				for j := range r {
					r[j] = strings.TrimSpace(r[j])
				}
				t.Append(r...)
			}
			client[spec.table] = t
			continue
		}
		name := strings.TrimSuffix(base, filepath.Ext(base))
		table, ok := known[strings.ToLower(name)]
		if !ok {
			return fmt.Errorf("%s: not a game-world table (want one of %s, or a client file %s)", p,
				strings.Join(gameworld.TableNames(), ", "), "gameworlddata.txt / gameworldconfigdata.txt / eventzonedata.txt")
		}
		t, err := reftable.ReadFile(p)
		if err != nil {
			return err
		}
		dumps[table] = t
	}
	for table, t := range client {
		if dumps[table] == nil {
			dumps[table] = t
		}
	}
	if dumps[gameworld.TableWorld] == nil {
		return fmt.Errorf("-mode gameworlds needs %s (a dump or the client's gameworlddata.txt)", gameworld.TableWorld)
	}
	// The set must load: a dump the loader cannot join is refused here, not
	// at the server's boot.
	ref, err := gameworld.Build(func(n string) *reftable.Table { return dumps[n] })
	if err != nil {
		return err
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		return err
	}
	for table, t := range dumps {
		f, err := os.Create(filepath.Join(out, table+".csv"))
		if err != nil {
			return err
		}
		if err := t.WriteCSV(f); err != nil {
			f.Close()
			return err
		}
		if err := f.Close(); err != nil {
			return err
		}
	}
	instanced, triggers := 0, 0
	for _, w := range ref.Worlds {
		if w.Instanced() {
			instanced++
		}
	}
	if ref.Triggers != nil {
		triggers = len(ref.Triggers.Triggers)
	}
	fmt.Fprintf(os.Stderr, "export-refdata: wrote %d tables to %s: %d worlds (%d instanced), %d groups, %d event zones, %d triggers\n",
		len(dumps), out, len(ref.Worlds), instanced, len(ref.Groups), len(ref.EventZones), triggers)
	return nil
}
