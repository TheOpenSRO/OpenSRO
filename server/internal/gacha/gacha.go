// Package gacha is the Magic POP machine's tables and its draw (round 838,
// lane 5): gachaitemset.txt (_RefGachaItemSet) and gachanpcmap.txt
// (_RefGachaNpcMap). Every rule is READ from SR_GameServer.exe (s:) unless a
// line says otherwise; docs/protocol/magic_pop.md has the client's half.
//
//   - gachaitemset.txt, per row: Service, Set_ID, RefItemID, Ratio, Count,
//     GachaID, Visible, then four (int, Desc128) free-param pairs (MEASURED;
//     the server's row builder s:0x6bca80 keeps +4 Set_ID, +8 RefItemID, +0xc
//     Ratio u16, +0xe Count u16, +0x10 GachaID, +0x14 Visible).
//   - gachanpcmap.txt, per row: Service, RefNpcID, the prize ("WIN") set and
//     the consolation ("LOSE") set (s:0x4c802d reads +8 for the WIN lookup,
//     s:0x4c808b +0xc for the LOSE one). Which _RefGachaCode row names set 1
//     "WIN" and set 2 "LOSE" is INFERRED: the code table is not in the
//     archive, and any other mapping fails every draw with code 2.
//   - The draw (s:0x4c7e20): roll = rand() % 10000; the chosen GachaID's row
//     in the NPC's WIN set (missing: 2) wins when roll < its Ratio -- so a
//     prize's chance is Ratio/10000. Otherwise roll2 = rand() % 10000 picks
//     the LOSE set's row by lower_bound on its cumulative map (s:0x4cc5d0):
//     the first running total >= roll2.
//   - The LOSE map (built at load): each row's share is ratio / sum x 10000,
//     keyed by the running total. INFERRED: how the server rounds the shares
//     to a total of exactly 10000 (s:0x6bd2xx not read); this package floors
//     each share and gives the remainder to the last row. The archive's set 2
//     (1200/2400/1800/2100 of 7500) divides exactly: 1600/4800/7200/10000.
//   - Rows of Service 0 are skipped, as the client's parser (c:0x744bd0)
//     skips them; whether the server's DB loader filters Service too is OPEN.
package gacha

import (
	"encoding/csv"
	"fmt"
	"io"
	"sort"
	"strconv"
	"strings"
)

// Rolls is the draw's modulus: rand() % 10000 (READ).
const Rolls = 10000

// Row is one gachaitemset row.
type Row struct {
	Set       int
	RefItemID int64
	Ratio     int
	Count     int
	GachaID   int64
	Visible   bool
}

// NPCMap is one gachanpcmap row: the machine and its two sets.
type NPCMap struct {
	NPCRefID int64
	WinSet   int
	LoseSet  int
}

// Table is the loaded catalogue.
type Table struct {
	rows []Row
	maps []NPCMap
	// bySet: set -> GachaID -> row (the WIN lookup's key).
	bySet map[int]map[int64]Row
	// lose: set -> its rows in file order with their running totals.
	lose map[int][]cumRow
	npcs map[int64]NPCMap
}

type cumRow struct {
	upTo int
	row  Row
}

// Build indexes rows and maps.
func Build(rows []Row, maps []NPCMap) *Table {
	t := &Table{rows: rows, maps: maps, bySet: map[int]map[int64]Row{}, lose: map[int][]cumRow{}, npcs: map[int64]NPCMap{}}
	bySetOrder := map[int][]Row{}
	for _, r := range rows {
		if t.bySet[r.Set] == nil {
			t.bySet[r.Set] = map[int64]Row{}
		}
		t.bySet[r.Set][r.GachaID] = r
		bySetOrder[r.Set] = append(bySetOrder[r.Set], r)
	}
	for set, rs := range bySetOrder {
		sum := 0
		for _, r := range rs {
			sum += r.Ratio
		}
		if sum <= 0 {
			continue
		}
		total := 0
		for i, r := range rs {
			share := r.Ratio * Rolls / sum
			total += share
			if i == len(rs)-1 {
				total = Rolls // the remainder (INFERRED, the package comment)
			}
			t.lose[set] = append(t.lose[set], cumRow{upTo: total, row: r})
		}
	}
	for _, m := range maps {
		t.npcs[m.NPCRefID] = m
	}
	return t
}

// Rows and Maps return what the table was built from.
func (t *Table) Rows() []Row     { return t.rows }
func (t *Table) Maps() []NPCMap  { return t.maps }
func (t *Table) Len() (int, int) { return len(t.rows), len(t.maps) }

// Machine reports the map entry of an NPC ref id: the NPC is a Magic POP
// machine (its spawn gets interaction 0x11, s:0x4c77c2).
func (t *Table) Machine(npcRefID int64) (NPCMap, bool) {
	if t == nil {
		return NPCMap{}, false
	}
	m, ok := t.npcs[npcRefID]
	return m, ok
}

// Prize is the chosen GachaID's row in a set (the WIN lookup).
func (t *Table) Prize(set int, gachaID int64) (Row, bool) {
	r, ok := t.bySet[set][gachaID]
	return r, ok
}

// Consolation is the LOSE set's row for roll2 in [0, Rolls): the first
// running total >= roll2 (std::map::lower_bound, s:0x4cc5d0).
func (t *Table) Consolation(set int, roll2 int) (Row, bool) {
	rs := t.lose[set]
	i := sort.Search(len(rs), func(i int) bool { return rs[i].upTo >= roll2 })
	if i >= len(rs) {
		return Row{}, false
	}
	return rs[i].row, true
}

// Shares are the LOSE map's running totals of a set, in order (tests).
func (t *Table) Shares(set int) []int {
	var out []int
	for _, c := range t.lose[set] {
		out = append(out, c.upTo)
	}
	return out
}

// The draw's refusal codes (s:0x4c7e20, READ).
const (
	CodeNotMachine = 0x1c0f // the NPC has no 0x11 or no map entry
	CodeBadSlot    = 0x1806 // the slot is past the bag, or not a Magic POP card
	CodeEmptySlot  = 0x1809 // nothing in the slot
	CodeExpired    = 0x183d // UIIT_STT_RENT_EXP_ITEM_USED_ERORR (not modelled: no rental items)
	CodeNoRow      = 2      // the GachaID or the consolation row is not in the set
	CodeFailed     = 5      // the card could not be turned into its coupon
)

// Outcome is a draw's result.
type Outcome struct {
	Win bool
	Row Row
}

// Draw runs the draw for the machine m and the chosen GachaID with rnd
// answering rand() % n. code is 0 on success.
func (t *Table) Draw(m NPCMap, gachaID int64, rnd func(n int) int) (Outcome, int) {
	prize, ok := t.Prize(m.WinSet, gachaID)
	if !ok {
		return Outcome{}, CodeNoRow
	}
	if rnd(Rolls) < prize.Ratio {
		return Outcome{Win: true, Row: prize}, 0
	}
	row, ok := t.Consolation(m.LoseSet, rnd(Rolls))
	if !ok {
		return Outcome{}, CodeNoRow
	}
	return Outcome{Row: row}, 0
}

// The CSV the server loads (export-refdata -mode gacha, cmd/server's
// -gacha-csv): one "item" line per gachaitemset row and one "npc" line per
// gachanpcmap row.
//
//	item,<set>,<refItemID>,<ratio>,<count>,<gachaID>,<visible 0|1>
//	npc,<npcRefID>,<winSet>,<loseSet>

// WriteCSV writes t.
func WriteCSV(w io.Writer, t *Table) error {
	cw := csv.NewWriter(w)
	for _, r := range t.rows {
		v := "0"
		if r.Visible {
			v = "1"
		}
		if err := cw.Write([]string{"item", strconv.Itoa(r.Set), strconv.FormatInt(r.RefItemID, 10), strconv.Itoa(r.Ratio),
			strconv.Itoa(r.Count), strconv.FormatInt(r.GachaID, 10), v}); err != nil {
			return err
		}
	}
	for _, m := range t.maps {
		if err := cw.Write([]string{"npc", strconv.FormatInt(m.NPCRefID, 10), strconv.Itoa(m.WinSet), strconv.Itoa(m.LoseSet)}); err != nil {
			return err
		}
	}
	cw.Flush()
	return cw.Error()
}

// ReadCSV loads what WriteCSV wrote.
func ReadCSV(r io.Reader) (*Table, error) {
	cr := csv.NewReader(r)
	cr.FieldsPerRecord = -1
	var rows []Row
	var maps []NPCMap
	for line := 1; ; line++ {
		rec, err := cr.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("gacha: line %d: %w", line, err)
		}
		nums := func(want int) ([]int64, error) {
			if len(rec) != want {
				return nil, fmt.Errorf("gacha: line %d: %d fields, want %d", line, len(rec), want)
			}
			out := make([]int64, 0, want-1)
			for _, f := range rec[1:] {
				v, err := strconv.ParseInt(strings.TrimSpace(f), 10, 64)
				if err != nil {
					return nil, fmt.Errorf("gacha: line %d: %q: %w", line, f, err)
				}
				out = append(out, v)
			}
			return out, nil
		}
		switch rec[0] {
		case "item":
			v, err := nums(7)
			if err != nil {
				return nil, err
			}
			rows = append(rows, Row{Set: int(v[0]), RefItemID: v[1], Ratio: int(v[2]), Count: int(v[3]), GachaID: v[4], Visible: v[5] != 0})
		case "npc":
			v, err := nums(4)
			if err != nil {
				return nil, err
			}
			maps = append(maps, NPCMap{NPCRefID: v[0], WinSet: int(v[1]), LoseSet: int(v[2])})
		default:
			return nil, fmt.Errorf("gacha: line %d: unknown kind %q", line, rec[0])
		}
	}
	return Build(rows, maps), nil
}

// FromTextdata builds the table from the archive's two text tables, already
// split into columns (gachaitemset.txt and gachanpcmap.txt rows): rows whose
// Service (column 1) is not 1 are skipped, as are short and comment lines.
func FromTextdata(itemSet, npcMap [][]string) (*Table, error) {
	num := func(s string) (int64, bool) {
		v, err := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
		return v, err == nil
	}
	var rows []Row
	for _, c := range itemSet {
		if len(c) < 7 {
			continue
		}
		var v [7]int64
		ok := true
		for i := 0; i < 7 && ok; i++ {
			v[i], ok = num(c[i])
		}
		if !ok || v[0] == 0 {
			continue
		}
		rows = append(rows, Row{Set: int(v[1]), RefItemID: v[2], Ratio: int(v[3]), Count: int(v[4]), GachaID: v[5], Visible: v[6] != 0})
	}
	var maps []NPCMap
	for _, c := range npcMap {
		if len(c) < 4 {
			continue
		}
		var v [4]int64
		ok := true
		for i := 0; i < 4 && ok; i++ {
			v[i], ok = num(c[i])
		}
		if !ok || v[0] == 0 {
			continue
		}
		maps = append(maps, NPCMap{NPCRefID: v[1], WinSet: int(v[2]), LoseSet: int(v[3])})
	}
	if len(rows) == 0 || len(maps) == 0 {
		return nil, fmt.Errorf("gacha: %d item rows and %d NPC rows; want both", len(rows), len(maps))
	}
	return Build(rows, maps), nil
}
