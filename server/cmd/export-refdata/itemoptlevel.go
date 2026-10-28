package main

import (
	"encoding/csv"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// exportItemOptLevel joins the three by-opt-level tables (round 838):
// the abilities (Service, AbilityID, RefItemID, OptLevel), their magic
// options (AbilityID, magic option id, value, ...) and their skills
// (AbilityID, skill id) -- what an awake devil's or angel's spirit gives at
// its plus level (GObjPC FUN_00498020: FUN_00498160 reads the ability by
// RefItemID + OptLevel, then each magic option row's id (+0x10) and value
// (+0x14); FUN_00498370 each skill row; READ). One CSV row per grant:
// RefItemID, OptLevel, "opt" | "optinf" | "skill", the id, the value (0 for
// a skill). A row of Service 0 is left out.
//
// Two sources (round 839). The client archive's text tables
// (refabilitybyitemoptleveldata.txt, refmagicoptbyitemoptleveldata.txt,
// refskillbyitemoptleveldata.txt), which the client reads for its spirit
// skill strip; or the shard database's own tables exported to CSV
// (_RefAbilityByItemOptLevel.csv, _RefMagicOptByItemOptLevel.csv,
// _RefSkillByItemOptLevel.csv, header row = the DB's column names), which
// are what the server runs on: SR_ShardManager.exe loads
// _REFABILITYBYITEMOPTLEVEL, _REFMAGICOPTBYITEMOPTLEVEL and
// _REFSKILLBYITEMOPTLEVEL from the shard DB for the game server (MEASURED,
// round 839: the table names are strings of SR_ShardManager.exe, and
// SR_GameServer.exe reports "Can`t attach passive skill on
// _RefAbilityByItemOptLevel Table!"). The two agree on abilities 1..159
// except 89; the archive adds 110 event-spirit abilities (160..269) the
// shard never had (docs/WORLD_ISSUES.md, round 839 lane P).
//
// "optinf" rows (round 839, INFERRED, OURS) fill a gap: an ability with no
// magic option row at all (five of the six angel's spirits at +6..+10)
// takes the option rows of the same plus level from every sibling spirit
// -- one whose option rows equal the item's own at each level both have
// rows for -- when those siblings all agree (inferOptions). The server
// applies them unless -item-opt-level-inferred=false.
func exportItemOptLevel(out string, paths []string) error {
	var abilityPath, optPath, skillPath string
	db := false
	for _, p := range paths {
		switch strings.ToLower(filepath.Base(p)) {
		case "refabilitybyitemoptleveldata.txt":
			abilityPath = p
		case "refmagicoptbyitemoptleveldata.txt":
			optPath = p
		case "refskillbyitemoptleveldata.txt":
			skillPath = p
		case "_refabilitybyitemoptlevel.csv":
			abilityPath, db = p, true
		case "_refmagicoptbyitemoptlevel.csv":
			optPath, db = p, true
		case "_refskillbyitemoptlevel.csv":
			skillPath, db = p, true
		}
	}
	if abilityPath == "" || optPath == "" || skillPath == "" {
		return fmt.Errorf("-mode itemoptlevel reads refabilitybyitemoptleveldata.txt, refmagicoptbyitemoptleveldata.txt and refskillbyitemoptleveldata.txt, or the shard's _RefAbilityByItemOptLevel.csv, _RefMagicOptByItemOptLevel.csv and _RefSkillByItemOptLevel.csv (got %q)", paths)
	}
	if out == "-" || out == "" {
		return fmt.Errorf("-mode itemoptlevel writes a file: -out must name it")
	}
	read := readOptLevelText
	if db {
		read = readOptLevelDB
	}
	src, err := read(abilityPath, optPath, skillPath)
	if err != nil {
		return err
	}
	recs, inferred := src.records()
	f, err := os.Create(out)
	if err != nil {
		return err
	}
	w := csv.NewWriter(f)
	if err := w.WriteAll(recs); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "export-refdata: wrote %d by-opt-level grants for %d abilities (%d inferred option rows)\n", len(recs), len(src.order), inferred)
	return nil
}

// optLevelSource is the three tables, joined by ability id.
type optLevelSource struct {
	abilities map[int64]optAbility
	order     []int64 // ability ids in the table's order
	opts      map[int64][][2]int64
	skills    map[int64][]int64
}

type optAbility struct{ item, level int64 }

func newOptLevelSource() *optLevelSource {
	return &optLevelSource{abilities: map[int64]optAbility{}, opts: map[int64][][2]int64{}, skills: map[int64][]int64{}}
}

func (s *optLevelSource) addAbility(service, id, item, level int64) {
	if service == 0 {
		return
	}
	if _, dup := s.abilities[id]; !dup {
		s.order = append(s.order, id)
	}
	s.abilities[id] = optAbility{item: item, level: level}
}

func parseOptNum(path string, row int, s string) (int64, error) {
	v, err := strconv.ParseInt(strings.TrimSpace(strings.TrimPrefix(s, "\uFEFF")), 10, 64)
	if err != nil {
		return 0, fmt.Errorf("%s: row %d: %q is not a number", path, row, s)
	}
	return v, nil
}

// readOptLevelText reads the client archive's three text tables.
func readOptLevelText(abilityPath, optPath, skillPath string) (*optLevelSource, error) {
	s := newOptLevelSource()
	rows, err := readTable(abilityPath)
	if err != nil {
		return nil, fmt.Errorf("reading %s: %w", abilityPath, err)
	}
	for i, cols := range rows {
		if len(cols) < 4 {
			return nil, fmt.Errorf("%s: row %d has %d fields, want 4", abilityPath, i+1, len(cols))
		}
		var v [4]int64
		for k := 0; k < 4; k++ {
			if v[k], err = parseOptNum(abilityPath, i+1, cols[k]); err != nil {
				return nil, err
			}
		}
		s.addAbility(v[0], v[1], v[2], v[3])
	}
	rows, err = readTable(optPath)
	if err != nil {
		return nil, fmt.Errorf("reading %s: %w", optPath, err)
	}
	for i, cols := range rows {
		if len(cols) < 3 {
			return nil, fmt.Errorf("%s: row %d has %d fields, want 3 or more", optPath, i+1, len(cols))
		}
		var v [3]int64
		for k := 0; k < 3; k++ {
			if v[k], err = parseOptNum(optPath, i+1, cols[k]); err != nil {
				return nil, err
			}
		}
		s.opts[v[0]] = append(s.opts[v[0]], [2]int64{v[1], v[2]})
	}
	rows, err = readTable(skillPath)
	if err != nil {
		return nil, fmt.Errorf("reading %s: %w", skillPath, err)
	}
	for i, cols := range rows {
		if len(cols) < 2 {
			return nil, fmt.Errorf("%s: row %d has %d fields, want 2", skillPath, i+1, len(cols))
		}
		a, err := parseOptNum(skillPath, i+1, cols[0])
		if err != nil {
			return nil, err
		}
		k, err := parseOptNum(skillPath, i+1, cols[1])
		if err != nil {
			return nil, err
		}
		s.skills[a] = append(s.skills[a], k)
	}
	return s, nil
}

// readOptLevelDB reads the shard database's three tables, exported with
// their own column names as the header (deploy/README.md, "External shard
// DB"): _RefAbilityByItemOptLevel (Service, ID, RefItemID, ItemOptLevel),
// _RefMagicOptByItemOptLevel (Link, RefMagicOptID, MagicOptValue,
// TooltipType, TooltipCodename) and _RefSkillByItemOptLevel (Link,
// RefSkillID).
func readOptLevelDB(abilityPath, optPath, skillPath string) (*optLevelSource, error) {
	s := newOptLevelSource()
	if err := readHeaderCSV(abilityPath, []string{"Service", "ID", "RefItemID", "ItemOptLevel"}, func(v []int64) {
		s.addAbility(v[0], v[1], v[2], v[3])
	}); err != nil {
		return nil, err
	}
	if err := readHeaderCSV(optPath, []string{"Link", "RefMagicOptID", "MagicOptValue"}, func(v []int64) {
		s.opts[v[0]] = append(s.opts[v[0]], [2]int64{v[1], v[2]})
	}); err != nil {
		return nil, err
	}
	if err := readHeaderCSV(skillPath, []string{"Link", "RefSkillID"}, func(v []int64) {
		s.skills[v[0]] = append(s.skills[v[0]], v[1])
	}); err != nil {
		return nil, err
	}
	return s, nil
}

// readHeaderCSV reads a CSV whose first row names its columns and calls fn
// with the named columns' numbers, in want's order, for every later row.
func readHeaderCSV(path string, want []string, fn func(v []int64)) error {
	f, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("reading %s: %w", path, err)
	}
	defer f.Close()
	r := csv.NewReader(f)
	r.FieldsPerRecord = -1
	head, err := r.Read()
	if err != nil {
		return fmt.Errorf("reading %s: %w", path, err)
	}
	idx := make([]int, len(want))
	for i, name := range want {
		idx[i] = -1
		for k, h := range head {
			if strings.EqualFold(strings.TrimSpace(strings.TrimPrefix(h, "\uFEFF")), name) {
				idx[i] = k
			}
		}
		if idx[i] < 0 {
			return fmt.Errorf("%s: no %s column in %q", path, name, head)
		}
	}
	for row := 2; ; row++ {
		rec, err := r.Read()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return fmt.Errorf("%s: %w", path, err)
		}
		v := make([]int64, len(want))
		for i, k := range idx {
			if k >= len(rec) {
				return fmt.Errorf("%s: row %d has %d fields", path, row, len(rec))
			}
			if v[i], err = parseOptNum(path, row, rec[k]); err != nil {
				return err
			}
		}
		fn(v)
	}
}

// records is the CSV: per ability in the table's order its option rows
// ("opt"), or the inferred ones ("optinf") when it has none, then its skill
// rows. inferred counts the "optinf" rows.
func (s *optLevelSource) records() (recs [][]string, inferred int) {
	infer := s.inferOptions()
	for _, id := range s.order {
		a := s.abilities[id]
		head := []string{strconv.FormatInt(a.item, 10), strconv.FormatInt(a.level, 10)}
		row := func(kind string, k, v int64) []string {
			return append(append([]string(nil), head...), kind, strconv.FormatInt(k, 10), strconv.FormatInt(v, 10))
		}
		if opts := s.opts[id]; len(opts) > 0 {
			for _, o := range opts {
				recs = append(recs, row("opt", o[0], o[1]))
			}
		} else {
			for _, o := range infer[id] {
				recs = append(recs, row("optinf", o[0], o[1]))
				inferred++
			}
		}
		for _, k := range s.skills[id] {
			recs = append(recs, row("skill", k, 0))
		}
	}
	return recs, inferred
}

// inferOptions is the round-839 gap fill (INFERRED, OURS). For each ability
// with no option row, it takes the option rows of the same plus level from
// each sibling that has rows there -- a sibling being another item whose
// option rows equal this item's (compared order-free) at every level where
// both have rows, with at least one such level. It is used only when every
// such sibling gives the same set; otherwise the ability stays without.
func (s *optLevelSource) inferOptions() map[int64][][2]int64 {
	type key struct{ item, level int64 }
	byKey := map[key]int64{}
	levels := map[int64][]int64{}
	for _, id := range s.order {
		a := s.abilities[id]
		byKey[key{a.item, a.level}] = id
		levels[a.item] = append(levels[a.item], a.level)
	}
	canon := func(o [][2]int64) string {
		c := append([][2]int64(nil), o...)
		sort.Slice(c, func(i, j int) bool { return c[i][0] < c[j][0] || (c[i][0] == c[j][0] && c[i][1] < c[j][1]) })
		return fmt.Sprint(c)
	}
	optsAt := func(item, level int64) ([][2]int64, bool) {
		id, ok := byKey[key{item, level}]
		if !ok || len(s.opts[id]) == 0 {
			return nil, false
		}
		return s.opts[id], true
	}
	items := make([]int64, 0, len(levels))
	for it := range levels {
		items = append(items, it)
	}
	sort.Slice(items, func(i, j int) bool { return items[i] < items[j] })
	sibling := func(a, b int64) bool {
		shared := 0
		for _, lv := range levels[a] {
			oa, okA := optsAt(a, lv)
			ob, okB := optsAt(b, lv)
			if !okA || !okB {
				continue
			}
			if canon(oa) != canon(ob) {
				return false
			}
			shared++
		}
		return shared > 0
	}
	out := map[int64][][2]int64{}
	for _, id := range s.order {
		if len(s.opts[id]) > 0 {
			continue
		}
		a := s.abilities[id]
		var pick [][2]int64
		agreed := true
		for _, other := range items {
			if other == a.item {
				continue
			}
			o, ok := optsAt(other, a.level)
			if !ok || !sibling(a.item, other) {
				continue
			}
			if pick == nil {
				pick = o
			} else if canon(pick) != canon(o) {
				agreed = false
			}
		}
		if agreed && pick != nil {
			out[id] = pick
		}
	}
	return out
}
