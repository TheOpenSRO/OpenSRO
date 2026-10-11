package magicopt

// The blue options a dropped item is given (round 770): SR_GameServer.exe's
// _AddMagicOptions (0x7276a0; READ, asm 0x7276a0..0x727ba3), on a monster's
// equipment drop (FUN_00726a70 -> 0x726d84). Shops, quests and the generic
// item add (CGObjPC::AddItem_EXT 0x4ee370) never reach it.

import (
	"encoding/csv"
	"fmt"
	"io"
	"math"
	"os"
	"strconv"
	"strings"
)

// AssignTable is magicoptionassign.txt (`_RefMagicOptAssign`): which options
// an item kind can drop with, per race (FUN_00727f30; READ). The key is the
// item's Country (itemdata column 14, ref +0x88), TypeID3 and TypeID4.
type AssignTable struct {
	names map[[3]int][]string
}

// AssignCSVColumns is export-refdata -mode magicoptassign's order: the names
// joined by "|". Service 0 rows are left out by the export, as the loader
// skips them.
var AssignCSVColumns = []string{"Race", "TypeID3", "TypeID4", "Names"}

// Names is the option list for an item kind, or nil.
func (a *AssignTable) Names(race, tid3, tid4 int) []string {
	if a == nil {
		return nil
	}
	return a.names[[3]int{race, tid3, tid4}]
}

// Len is the number of rows.
func (a *AssignTable) Len() int {
	if a == nil {
		return 0
	}
	return len(a.names)
}

// LoadAssignCSV reads a headerless export.
func LoadAssignCSV(r io.Reader) (*AssignTable, error) {
	cr := csv.NewReader(r)
	cr.FieldsPerRecord = -1
	a := &AssignTable{names: map[[3]int][]string{}}
	for line := 1; ; line++ {
		f, err := cr.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("magicopt: assign line %d: %w", line, err)
		}
		if len(f) < len(AssignCSVColumns) {
			return nil, fmt.Errorf("magicopt: assign line %d: %d columns, want %d", line, len(f), len(AssignCSVColumns))
		}
		var key [3]int
		for k := 0; k < 3; k++ {
			v, err := strconv.Atoi(strings.TrimSpace(f[k]))
			if err != nil {
				return nil, fmt.Errorf("magicopt: assign line %d: bad field %q", line, f[k])
			}
			key[k] = v
		}
		var names []string
		for _, n := range strings.Split(f[3], "|") {
			if n = strings.TrimSpace(n); n != "" {
				names = append(names, n)
			}
		}
		a.names[key] = names
	}
	return a, nil
}

// LoadAssignCSVFile opens and reads path.
func LoadAssignCSVFile(path string) (*AssignTable, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return LoadAssignCSV(f)
}

// DropItem is what _AddMagicOptions reads off the item.
type DropItem struct {
	// Equip is TypeID 3/1.
	Equip bool
	// Rarity is itemdata column 15 (ref +0x89): 2 is a Seal item (`*_RARE`),
	// which always gets options.
	Rarity int
	// Race is itemdata column 14, Country (ref +0x88).
	Race             int
	TypeID3, TypeID4 int
	Code             string
	// MaxOptions is itemdata column 158 (ref +0x53c).
	MaxOptions int
}

// Rolled is one option given: the id the item stores and its value.
type Rolled struct {
	ID    uint16
	Value uint32
}

// DropChance is the roll that gives an ordinary drop options at all:
// `rand() % 101`, options when it is 30 or less (READ: the quit is on
// `> 30`), so 31 in 101.
const DropChance = 30

// The level roll's scale (FUN_0072f410; READ): r = ((rand2 << 15) | rand1)
// % 1,000,000 against the running sum of each record's round(prob * 1e6).
const levelScale = 1000000

// RollDrop is _AddMagicOptions for a fresh drop (no caller's fixed list):
//  1. unless the item is a Seal item (equipment, Rarity 2), rand()%101 above
//     30 gives no options;
//  2. the count is the least of four draws of rand()%6 + 1, no more than
//     column 158, at least 1 (column 158 of 0 gives none);
//  3. the item kind's assign list (by race, TypeID3, TypeID4), its '+'
//     options only; none: no options;
//  4. each of `count` draws picks a name uniformly: one picked already
//     wastes the draw; its level is the weighted roll over the option's rows
//     in table order (none hit: wasted); 'nrep' draws again; an option not
//     allowed on the kind wastes the draw (and may be picked later); else the
//     record's generator gives the value.
//
// Which level a drop gets: the group's rows in the order the server loads
// them, and every level of a STR-type option has probability 1, so the FIRST
// row always wins. The server reads `_RefMagicOpt` with `SELECT * FROM` (no
// ORDER BY); this uses magicoption.txt's own row order, the client's copy of
// the same table (INFERRED: that the copy keeps the database's order; OPEN,
// round 770 -- the alternative, id order, gives level 1 where the file order
// gives level 7 for MATTR_STR).
func RollDrop(t *Table, a *AssignTable, it DropItem, rng Rand) []Rolled {
	if t == nil || a == nil {
		return nil
	}
	if !(it.Equip && it.Rarity == 2) && rng.Intn(101) > DropChance {
		return nil
	}
	count := 6
	for i := 0; i < 4; i++ {
		count = min(count, rng.Intn(6)+1)
	}
	count = max(1, min(count, it.MaxOptions))
	if it.MaxOptions <= 0 {
		return nil
	}
	var pool []string
	for _, n := range a.Names(it.Race, it.TypeID3, it.TypeID4) {
		if t.GroupDrops(n) {
			pool = append(pool, n)
		}
	}
	if len(pool) == 0 {
		return nil
	}
	chosen := map[int]bool{}
	var out []Rolled
	retries := 0
	for i := 0; i < count; i++ {
		idx := rng.Intn(len(pool))
		if chosen[idx] {
			continue
		}
		rec := t.rollLevel(pool[idx], rng)
		if rec == nil {
			continue
		}
		if rec.Tag == PackTag("nrep") {
			// Draws again (READ). Unreachable on a drop -- 'nrep' is not a
			// '+' option -- and capped here all the same (OURS).
			if retries++; retries < 64 {
				i--
			}
			continue
		}
		if !rec.AllowedOn(it.TypeID3, it.TypeID4, it.Code) {
			continue
		}
		out = append(out, Rolled{ID: rec.ID, Value: rec.Generate(rng)})
		chosen[idx] = true
	}
	return out
}

// GroupDrops reports whether an option can drop: one of its rows is a '+'
// option (FUN_00727f30 files it under sub-vector 0, the one drops read). A
// table exported before the Sign column has no signs; then every option
// counts as '+' (OURS).
func (t *Table) GroupDrops(code string) bool {
	rows := t.Group(code)
	for _, r := range rows {
		if r.Sign == "" || strings.Contains(r.Sign, "+") {
			return true
		}
	}
	return false
}

// rollLevel is FUN_0072f410: the weighted pick over an option's rows in
// table order, or nil when the roll runs past them.
func (t *Table) rollLevel(code string, rng Rand) *Row {
	lo := rng.Intn(RandMax + 1)
	hi := rng.Intn(RandMax + 1)
	r := (hi<<15 | lo) % levelScale
	sum := 0
	for _, row := range t.Group(code) {
		sum += int(math.Round(row.Prob * levelScale))
		if r <= sum {
			return row
		}
	}
	return nil
}
