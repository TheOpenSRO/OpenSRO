// Package magicopt is the game's magic option table (`_RefMagicOpt`,
// Media.pk2's server_dep\silkroad\textdata\magicoption.txt): every blue option
// an item can carry, one row per option and level, as SR_GameServer.exe
// reads and uses it (round 768, docs/protocol/magic_options.md "The server's
// reading").
//
// Labels: READ is the game server's decompilation (addresses given); the
// column positions are INFERRED by matching MEASURED row values against the
// fields CGameServer::FUN_0072e2d0 reads -- the row loader itself was not
// found, because the reference tables are read by column position.
//
// The rows come from `export-refdata -mode magicoptions` run on the
// operator's own file; no table content ships with this package. The export
// leaves out Service 0 rows, as the server's loader does (FUN_00727c00 skips
// them; READ, round 770).
package magicopt

import (
	"encoding/csv"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
)

// Rand is the engine's rand(): Intn(n) uniform in [0, n).
type Rand interface {
	Intn(n int) int
}

// RandMax is the C runtime's RAND_MAX the range generator divides by.
const RandMax = 32767

// Generator is how a row turns into a value (FUN_0072e2d0 builds one of
// three mfunc objects by the row's tag; READ).
type Generator int

const (
	// GenNone: a tag none of the three constructors lists. Such a row has no
	// value to give (OURS: the binary's behaviour for it was not read).
	GenNone Generator = iota
	// GenSixValues is mfunc_6_values (vtable 0xb0b9a4): a uniform pick from
	// the non-zero 16-bit halves of columns 8, 9 and 10, high half first.
	GenSixValues
	// GenRange is mfunc_single_range (0xb0b98c): float(rand()/32767) *
	// (max-min) + min, TRUNCATED (the x87 chop mode its vslot sets at
	// 0x72fcbb; READ, round 770's drop research -- an earlier reading said
	// round), min column 9, max column 10.
	GenRange
	// GenSingle is mfunc_single_value (0xb0b974): column 9.
	GenSingle
)

// The tags each generator is built for (READ, FUN_0072e2d0).
var generatorTags = map[Generator][]string{
	GenSixValues: {"str", "int", "hp", "mp", "hr", "er", "es", "cri", "bri", "evbl", "evcr", "duru", "ps", "fz",
		"bu", "zb", "rsti", "rsli", "rfei", "rdii", "rcsi", "rals", "strj", "intj", "soli", "luck", "atha",
		"astr", "ape", "rep", "umdu", "brna", "hpmp"},
	GenRange: {"dura", "hra", "era", "hpa", "mpa", "stra", "inta", "strv", "intv", "luca", "mdia", "mpna",
		"hpna", "reis", "dara", "drua", "hprg", "mprg"},
	GenSingle: {"rein", "nrep"},
}

var generatorOf = func() map[uint32]Generator {
	m := map[uint32]Generator{}
	for g, tags := range generatorTags {
		for _, t := range tags {
			m[PackTag(t)] = g
		}
	}
	return m
}()

// PackTag packs a tag big-endian into a word, as the engine compares it
// ('cri' is 0x637269). It is combat.PackTag, repeated here so this package
// stays a leaf.
func PackTag(s string) uint32 {
	var v uint32
	for i := 0; i < len(s) && i < 4; i++ {
		v = v<<8 | uint32(s[i])
	}
	return v
}

// Kind is one item kind an option may sit on: a TypeID3/TypeID4 pair (TypeID4
// 0 meaning any), or an exact item code name.
type Kind struct {
	TypeID3, TypeID4 int
	Code             string
}

// Row is one magicoption.txt row.
type Row struct {
	// ID is column 1, the id an item's MagParam stores.
	ID uint16
	// Code is column 2, the MATTR_ name: the group key, compared without
	// regard to case.
	Code string
	// Level is column 4, the degree a stone's Param1 picks.
	Level int
	// Prob is column 5, the drop weighting (x 1e6).
	Prob float64
	// Tag is column 7, the packed tag the stats dispatch on.
	Tag uint32
	// Params are columns 8..11, the generator's parameters.
	Params [4]uint32
	// Kinds are the item kinds the option may sit on (columns 29, 31, ...,
	// 47, read until "xxx").
	Kinds []Kind
	// KindNames are those columns as written, for the tooltip and the logs.
	KindNames []string
	// Sign is column 3, the option's AttrType ("+", "-", "-@"): only a group
	// with a '+' row can drop (round 770; the assign loader files a name
	// under sub-vector 0 by it, FUN_00727f30). "" on an export before it.
	Sign string
}

// Generator is the row's value generator.
func (r *Row) Generator() Generator { return generatorOf[r.Tag] }

// Values is the six-value generator's pool: the non-zero 16-bit halves of
// columns 8, 9 and 10, high half first (mfunc_6_values vslot_001 0x72fbc0).
func (r *Row) Values() []uint32 {
	var out []uint32
	for _, w := range r.Params[:3] {
		for _, h := range []uint32{w >> 16, w & 0xffff} {
			if h != 0 {
				out = append(out, h)
			}
		}
	}
	return out
}

// Generate draws a value the way the row's generator does (READ: vslot_002
// of each mfunc). GenNone gives 0.
func (r *Row) Generate(rng Rand) uint32 {
	switch r.Generator() {
	case GenSixValues:
		v := r.Values()
		if len(v) == 0 {
			return 0
		}
		return v[rng.Intn(len(v))]
	case GenRange:
		lo, hi := float64(r.Params[1]), float64(r.Params[2])
		return uint32(float64(rng.Intn(RandMax+1))/RandMax*(hi-lo) + lo)
	case GenSingle:
		return r.Params[1]
	}
	return 0
}

// armourTID3 is what the kind "armor" expands to, and what an entry of TypeID3
// 2 matches (FUN_0072e960 / FUN_0072ff60; READ).
var armourTID3 = []int{1, 2, 3, 9, 10, 11}

// kindsFor expands one kind string (FUN_0072e960; READ). An unknown string is
// an exact item code name.
func kindsFor(name string) []Kind {
	pairs := func(tid3s []int, tid4s ...int) []Kind {
		var out []Kind
		for _, a := range tid3s {
			for _, b := range tid4s {
				out = append(out, Kind{TypeID3: a, TypeID4: b})
			}
		}
		return out
	}
	switch strings.ToLower(name) {
	case "weapon":
		return pairs([]int{6}, 0)
	case "armor":
		return pairs(armourTID3, 0)
	case "accessory":
		return pairs([]int{5, 12}, 0)
	case "sword":
		return pairs([]int{6}, 2, 7)
	case "blade":
		return pairs([]int{6}, 3)
	case "spear":
		return pairs([]int{6}, 4)
	case "tblade":
		return pairs([]int{6}, 5)
	case "bow":
		return pairs([]int{6}, 6)
	case "helm":
		return pairs([]int{2, 10}, 1)
	case "shoulderguard":
		return pairs([]int{2, 10}, 2)
	case "mail":
		return pairs([]int{2, 10}, 3)
	case "pants":
		return pairs([]int{2, 10}, 4)
	case "gauntlet":
		return pairs([]int{2, 10}, 5)
	case "boots":
		return pairs([]int{2, 10}, 6)
	case "shield":
		return pairs([]int{4}, 1, 2)
	case "earring":
		return pairs([]int{5, 12}, 1)
	case "necklace":
		return pairs([]int{5, 12}, 2)
	case "ring":
		return pairs([]int{5, 12}, 3)
	case "trader":
		return pairs([]int{7}, 1)
	case "thief":
		return pairs([]int{7}, 2)
	case "hunter":
		return pairs([]int{7}, 3)
	case "event":
		// 13/4, and the binary then falls through into the avatar
		// comparisons; only the event entry is kept (OURS: the fall-through
		// was not traced to its end).
		return pairs([]int{13}, 4)
	case "avatar":
		return pairs([]int{13}, 0)
	case "avatar_helm":
		return pairs([]int{13}, 1)
	case "avatar_mail":
		return pairs([]int{13}, 2)
	case "avatar_mail_addon":
		return pairs([]int{13}, 3)
	case "avatar_extra":
		return pairs([]int{13}, 4)
	case "avatar_special_armlet":
		return pairs([]int{14}, 1)
	}
	return []Kind{{Code: name}}
}

// matches is FUN_0072ff60's comparison (READ): an entry of TypeID3 2 matches
// any armour TypeID3 or 13; any other must be equal; the entry's TypeID4 must
// be 0 or equal. The ItemClass requirement it also tests is always 0 (every
// insert writes 0), so it always passes and is not modelled.
func (k Kind) matches(tid3, tid4 int, code string) bool {
	if k.Code != "" {
		return strings.EqualFold(k.Code, code)
	}
	if k.TypeID3 == 2 {
		ok := tid3 == 13
		for _, a := range armourTID3 {
			ok = ok || tid3 == a
		}
		if !ok {
			return false
		}
	} else if k.TypeID3 != tid3 {
		return false
	}
	return k.TypeID4 == 0 || k.TypeID4 == tid4
}

// AllowedOn reports whether the option may sit on an item of this kind
// (FUN_00727ef0 -> FUN_0072f2d0 / FUN_0072ff60; READ). code is the item's
// code name, for the rows that name an item outright.
func (r *Row) AllowedOn(tid3, tid4 int, code string) bool {
	for _, k := range r.Kinds {
		if k.matches(tid3, tid4, code) {
			return true
		}
	}
	return false
}

// Table is the loaded table.
type Table struct {
	rows   []*Row
	byID   map[uint16]*Row
	byCode map[string][]*Row
}

// New builds a table from rows.
func New(rows []*Row) *Table {
	t := &Table{byID: map[uint16]*Row{}, byCode: map[string][]*Row{}}
	for _, r := range rows {
		t.rows = append(t.rows, r)
		t.byID[r.ID] = r
		k := strings.ToUpper(r.Code)
		t.byCode[k] = append(t.byCode[k], r)
	}
	return t
}

// Len is the number of rows.
func (t *Table) Len() int {
	if t == nil {
		return 0
	}
	return len(t.rows)
}

// ByID is the row an item's MagParam id names, or nil.
func (t *Table) ByID(id uint16) *Row {
	if t == nil {
		return nil
	}
	return t.byID[id]
}

// Group is every row of one option, in file order (FUN_00727db0, a linear
// scan by name, case-insensitive; READ). Nil when the table has no such
// option.
func (t *Table) Group(code string) []*Row {
	if t == nil {
		return nil
	}
	return t.byCode[strings.ToUpper(strings.TrimSpace(code))]
}

// Record is the group's row for one level (FUN_00492730; READ), or nil.
func (t *Table) Record(code string, level int) *Row {
	for _, r := range t.Group(code) {
		if r.Level == level {
			return r
		}
	}
	return nil
}

// CSVColumns is the export's column order (export-refdata -mode
// magicoptions): the ten kind strings ride in one column joined by "|".
var CSVColumns = []string{"ID", "Code", "Level", "Prob", "Tag", "Param8", "Param9", "Param10", "Param11", "Kinds", "Sign"}

// csvRequired is how many leading columns every export carries; Sign (round
// 770) is an optional suffix.
const csvRequired = 10

// LoadCSV reads a headerless export.
func LoadCSV(r io.Reader) (*Table, error) {
	cr := csv.NewReader(r)
	cr.FieldsPerRecord = -1
	var rows []*Row
	for line := 1; ; line++ {
		f, err := cr.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("magicopt: line %d: %w", line, err)
		}
		if len(f) < csvRequired {
			return nil, fmt.Errorf("magicopt: line %d: %d columns, want %d", line, len(f), csvRequired)
		}
		u := func(i int) (uint64, error) { return strconv.ParseUint(strings.TrimSpace(f[i]), 10, 32) }
		id, err := u(0)
		if err != nil || id > 0xffff {
			return nil, fmt.Errorf("magicopt: line %d: bad id %q", line, f[0])
		}
		level, err := strconv.Atoi(strings.TrimSpace(f[2]))
		if err != nil {
			return nil, fmt.Errorf("magicopt: line %d: bad level %q", line, f[2])
		}
		prob, err := strconv.ParseFloat(strings.TrimSpace(f[3]), 64)
		if err != nil {
			return nil, fmt.Errorf("magicopt: line %d: bad prob %q", line, f[3])
		}
		row := &Row{ID: uint16(id), Code: strings.TrimSpace(f[1]), Level: level, Prob: prob}
		tag, err := u(4)
		if err != nil {
			return nil, fmt.Errorf("magicopt: line %d: bad tag %q", line, f[4])
		}
		row.Tag = uint32(tag)
		for k := 0; k < 4; k++ {
			v, err := u(5 + k)
			if err != nil {
				return nil, fmt.Errorf("magicopt: line %d: bad param %q", line, f[5+k])
			}
			row.Params[k] = uint32(v)
		}
		for _, name := range strings.Split(f[9], "|") {
			name = strings.TrimSpace(name)
			if name == "" {
				continue
			}
			row.KindNames = append(row.KindNames, name)
			row.Kinds = append(row.Kinds, kindsFor(name)...)
		}
		if len(f) > 10 {
			row.Sign = strings.TrimSpace(f[10])
		}
		rows = append(rows, row)
	}
	return New(rows), nil
}

// LoadCSVFile opens and reads path.
func LoadCSVFile(path string) (*Table, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return LoadCSV(f)
}
