package refdata

// The creatable catalogue (round 682): which bodies and which starting items a
// new character may be made from. docs/protocol/charselect.md section 6, "The
// creatable catalogue", is the one definition; this file and the client's
// frontend/char_catalog.gd implement the same rule.
//
// The retail client fills its create screen from a list of object ids it holds
// at 0xeedf08 (READ, CCustomInfoManager's loader 0x80b980); where that list
// comes from is OPEN (INFERRED: the shard DB's `_RefCharGen`, 104 rows,
// EXTERNAL). What is MEASURED is that one rule over the player's own
// characterdata and itemdata picks exactly 104 ids -- 52 bodies and 52 items --
// and those are the ids the screens offer. Nothing is shipped: the rule runs
// over the operator's own archive (cmd/export-refdata -mode chargen) and the
// server reads the CSV it writes (cmd/server -chargen-csv).

import (
	"encoding/csv"
	"errors"
	"fmt"
	"io"
	"sort"
	"strconv"
	"strings"
)

// The textdata columns the rule reads, 0-based on a tab-split row (column 0 is
// the Service flag). The same indices as cmd/export-refdata's item columns;
// the 1-based "column 59" in older notes is index 58.
const (
	cgService   = 0
	cgID        = 1
	cgCodeName  = 2
	cgTypeID1   = 9 // TypeID1..4 are 9..12
	cgCountry   = 14
	cgSex       = 58 // ReqGender on an item; on a characterdata row the body's sex (MEASURED: 1 on all 26 _MAN_ rows, 0 on all 26 _WOMAN_)
	cgMaxStack  = 57
	cgTwoHanded = 93 // itemdata only
)

// Creatable kinds.
const (
	CreatableModel = "model"
	CreatableItem  = "item"
	// CreatableAmmo is not part of the 104: it is what the server adds beside
	// a bow or a crossbow (READ ShardManager FUN_00429c80, by code name), kept
	// in the same CSV so the server needs no other table to make a character.
	CreatableAmmo = "ammo"
)

// The ammunition the server adds, by code name (READ, ShardManager strings).
const (
	AmmoArrowCode = "ITEM_ETC_AMMO_ARROW_01_DEF"
	AmmoBoltCode  = "ITEM_ETC_AMMO_BOLT_01_DEF"
)

// Creatable is one row of the catalogue.
type Creatable struct {
	ID        int64
	Code      string
	Kind      string
	Country   int // 0 China, 1 Europe, 3 either
	Sex       int // models: 1 man, 0 woman; items: ReqGender, 1 man, 0 woman, 2 either
	TypeID1   int
	TypeID2   int
	TypeID3   int
	TypeID4   int
	TwoHanded bool
	MaxStack  int
}

// Piece is an item's place on the create packet, from its type ids.
type Piece int

const (
	PieceNone Piece = iota
	PieceChest
	PieceLegs
	PieceFeet
	PieceWeapon
	PieceShield
)

// Piece reads an item row's piece by the READ rules (tightened in round
// 682's review to match round 683's char_catalog.gd piece()):
//
//   - TypeID3 6 is a weapon;
//   - TypeID3 4 is a shield only with TypeID4 1 or 2 (READ, IsShieldItem
//     0x56fab0: China's and Europe's shield families);
//   - TypeID4 3 / 4 / 6 is the chest / legs / feet only within an armour
//     family, TypeID3 1, 2, 3 (China) or 9, 10, 11 (Europe) (READ, the
//     create screen's list builder 0x80b980).
//
// Anything else is PieceNone. On the box's archive the looser rule this
// replaced agreed on all 52 catalogue items (MEASURED); the two differ only
// on rows the catalogue does not hold today.
func (c Creatable) Piece() Piece {
	if c.Kind != CreatableItem {
		return PieceNone
	}
	switch c.TypeID3 {
	case 6:
		return PieceWeapon
	case 4:
		if c.TypeID4 == 1 || c.TypeID4 == 2 {
			return PieceShield
		}
		return PieceNone
	case 1, 2, 3, 9, 10, 11:
		switch c.TypeID4 {
		case 3:
			return PieceChest
		case 4:
			return PieceLegs
		case 6:
			return PieceFeet
		}
	}
	return PieceNone
}

// ArmourClass is the armour family a piece belongs to: its TypeID3 (China 1
// garment, 2 protector, 3 armour; Europe 9 robe, 10 light, 11 heavy). The
// server's create worker requires the three pieces to share it (READ,
// ShardManager 0x429dc2-0x429dd7: bits 7..10 of the packed type word).
func (c Creatable) ArmourClass() int { return c.TypeID3 }

// IsBow and IsCrossbow are the two weapons that come with ammunition (TypeID4
// 6 China bow, 12 Europe crossbow; MEASURED on ITEM_CH_BOW_01_A_DEF and
// ITEM_EU_CROSSBOW_01_A_DEF).
func (c Creatable) IsBow() bool      { return c.Piece() == PieceWeapon && c.TypeID4 == 6 }
func (c Creatable) IsCrossbow() bool { return c.Piece() == PieceWeapon && c.TypeID4 == 12 }

// CreatableSet is the catalogue, by id.
type CreatableSet struct {
	byID map[int64]Creatable
	ammo map[string]Creatable
}

// NewCreatableSet builds a set from rows (a test or the CSV loader).
func NewCreatableSet(rows []Creatable) *CreatableSet {
	s := &CreatableSet{byID: map[int64]Creatable{}, ammo: map[string]Creatable{}}
	for _, r := range rows {
		if r.Kind == CreatableAmmo {
			s.ammo[r.Code] = r
			continue
		}
		s.byID[r.ID] = r
	}
	return s
}

// Get returns the catalogue row for id; ok is false for an id outside it.
func (s *CreatableSet) Get(id int64) (Creatable, bool) {
	if s == nil {
		return Creatable{}, false
	}
	c, ok := s.byID[id]
	return c, ok
}

// Ammo returns the ammunition row for code (AmmoArrowCode, AmmoBoltCode).
func (s *CreatableSet) Ammo(code string) (Creatable, bool) {
	if s == nil {
		return Creatable{}, false
	}
	c, ok := s.ammo[code]
	return c, ok
}

// Shield returns the race's catalogue shield (TypeID3 4 in the catalogue,
// one per race: China 10886, Europe 10896 on a retail archive, MEASURED).
func (s *CreatableSet) Shield(country int) (Creatable, bool) {
	if s == nil {
		return Creatable{}, false
	}
	var best Creatable
	found := false
	for _, c := range s.byID {
		if c.Piece() == PieceShield && c.Country == country && (!found || c.ID < best.ID) {
			best, found = c, true
		}
	}
	return best, found
}

// Len is how many catalogue ids (models and items, not ammunition) the set holds.
func (s *CreatableSet) Len() int {
	if s == nil {
		return 0
	}
	return len(s.byID)
}

// Rows returns every row, catalogue first then ammunition, by id.
func (s *CreatableSet) Rows() []Creatable {
	var out []Creatable
	for _, c := range s.byID {
		out = append(out, c)
	}
	for _, c := range s.ammo {
		out = append(out, c)
	}
	sort.Slice(out, func(i, j int) bool {
		if (out[i].Kind == CreatableAmmo) != (out[j].Kind == CreatableAmmo) {
			return out[j].Kind == CreatableAmmo
		}
		return out[i].ID < out[j].ID
	})
	return out
}

// CreatableExtractor applies the rule to textdata rows. Feed it every
// characterdata part (AddCharacterRow) and every itemdata part (AddItemRow) in
// the index files' order; the LAST definition of an id wins, the same rule the
// item exporter follows (the China bodies 1908-1932 appear in two
// characterdata parts, MEASURED).
type CreatableExtractor struct {
	models map[int64][]string
	items  map[int64][]string
}

// NewCreatableExtractor returns an empty extractor.
func NewCreatableExtractor() *CreatableExtractor {
	return &CreatableExtractor{models: map[int64][]string{}, items: map[int64][]string{}}
}

func cgInt(cols []string, i int) (int, bool) {
	if i >= len(cols) {
		return 0, false
	}
	v, err := strconv.Atoi(strings.TrimSpace(cols[i]))
	return v, err == nil
}

// AddCharacterRow takes one tab-split characterdata row. It reports whether
// the row's id was recorded (the rule is applied in Set, after the last
// definition is known).
func (e *CreatableExtractor) AddCharacterRow(cols []string) bool {
	id, ok := cgInt(cols, cgID)
	if !ok || len(cols) <= cgSex {
		return false
	}
	e.models[int64(id)] = cols
	return true
}

// AddItemRow takes one tab-split itemdata row.
func (e *CreatableExtractor) AddItemRow(cols []string) bool {
	id, ok := cgInt(cols, cgID)
	if !ok || len(cols) <= cgTwoHanded {
		return false
	}
	e.items[int64(id)] = cols
	return true
}

func cgRow(kind string, cols []string) Creatable {
	g := func(i int) int { v, _ := cgInt(cols, i); return v }
	id, _ := cgInt(cols, cgID)
	c := Creatable{
		ID: int64(id), Code: strings.TrimSpace(cols[cgCodeName]), Kind: kind,
		Country: g(cgCountry), Sex: g(cgSex),
		TypeID1: g(cgTypeID1), TypeID2: g(cgTypeID1 + 1), TypeID3: g(cgTypeID1 + 2), TypeID4: g(cgTypeID1 + 3),
		TwoHanded: kind != CreatableModel && g(cgTwoHanded) != 0,
	}
	if kind != CreatableModel {
		// characterdata's column 57 is not a stack size; only items carry one.
		c.MaxStack = g(cgMaxStack)
	}
	return c
}

// Set applies the rule (charselect.md section 6):
//
//   - a body: a characterdata row with Service 1 and TypeID1/TypeID2 = 1/1 (a
//     player character -- the same test ShardManager's create makes on the
//     model, READ FUN_0048d8d0);
//   - an item: an itemdata row with Service 1, TypeID1/TypeID2 = 3/1
//     (equipment) and a code name ending "_A_DEF";
//   - plus the two ammunition rows by code name, which are not offered on the
//     screen and are not counted in the 104.
//
// On a retail archive this is 52 bodies and 52 items (MEASURED 2026-10-02).
func (e *CreatableExtractor) Set() *CreatableSet {
	var rows []Creatable
	for _, cols := range e.models {
		if s, _ := cgInt(cols, cgService); s != 1 {
			continue
		}
		if t1, _ := cgInt(cols, cgTypeID1); t1 != 1 {
			continue
		}
		if t2, _ := cgInt(cols, cgTypeID1+1); t2 != 1 {
			continue
		}
		rows = append(rows, cgRow(CreatableModel, cols))
	}
	for _, cols := range e.items {
		if s, _ := cgInt(cols, cgService); s != 1 {
			continue
		}
		code := strings.TrimSpace(cols[cgCodeName])
		if code == AmmoArrowCode || code == AmmoBoltCode {
			rows = append(rows, cgRow(CreatableAmmo, cols))
			continue
		}
		if t1, _ := cgInt(cols, cgTypeID1); t1 != 3 {
			continue
		}
		if t2, _ := cgInt(cols, cgTypeID1+1); t2 != 1 {
			continue
		}
		if !strings.HasSuffix(code, "_A_DEF") {
			continue
		}
		rows = append(rows, cgRow(CreatableItem, cols))
	}
	return NewCreatableSet(rows)
}

// CreatableCSVColumns is the header cmd/export-refdata -mode chargen writes
// and LoadCreatableCSV reads.
var CreatableCSVColumns = []string{"ID", "Code", "Kind", "Country", "Sex", "TypeID1", "TypeID2", "TypeID3", "TypeID4", "TwoHanded", "MaxStack"}

// WriteCreatableCSV writes s under CreatableCSVColumns.
func WriteCreatableCSV(w io.Writer, s *CreatableSet) error {
	cw := csv.NewWriter(w)
	if err := cw.Write(CreatableCSVColumns); err != nil {
		return err
	}
	b := func(v bool) string {
		if v {
			return "1"
		}
		return "0"
	}
	for _, c := range s.Rows() {
		rec := []string{
			strconv.FormatInt(c.ID, 10), c.Code, c.Kind,
			strconv.Itoa(c.Country), strconv.Itoa(c.Sex),
			strconv.Itoa(c.TypeID1), strconv.Itoa(c.TypeID2), strconv.Itoa(c.TypeID3), strconv.Itoa(c.TypeID4),
			b(c.TwoHanded), strconv.Itoa(c.MaxStack),
		}
		if err := cw.Write(rec); err != nil {
			return err
		}
	}
	cw.Flush()
	return cw.Error()
}

// LoadCreatableCSV reads what WriteCreatableCSV wrote.
func LoadCreatableCSV(r io.Reader) (*CreatableSet, error) {
	cr := csv.NewReader(r)
	head, err := cr.Read()
	if err != nil {
		return nil, fmt.Errorf("refdata: chargen csv header: %w", err)
	}
	if strings.Join(head, ",") != strings.Join(CreatableCSVColumns, ",") {
		return nil, fmt.Errorf("refdata: chargen csv header %q, want %q", head, CreatableCSVColumns)
	}
	var rows []Creatable
	for line := 2; ; line++ {
		rec, err := cr.Read()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("refdata: chargen csv line %d: %w", line, err)
		}
		n := make([]int, len(rec))
		for i, f := range rec {
			if i == 1 || i == 2 {
				continue
			}
			v, err := strconv.Atoi(f)
			if err != nil {
				return nil, fmt.Errorf("refdata: chargen csv line %d column %s: %w", line, CreatableCSVColumns[i], err)
			}
			n[i] = v
		}
		switch rec[2] {
		case CreatableModel, CreatableItem, CreatableAmmo:
		default:
			return nil, fmt.Errorf("refdata: chargen csv line %d: kind %q", line, rec[2])
		}
		rows = append(rows, Creatable{
			ID: int64(n[0]), Code: rec[1], Kind: rec[2], Country: n[3], Sex: n[4],
			TypeID1: n[5], TypeID2: n[6], TypeID3: n[7], TypeID4: n[8], TwoHanded: n[9] != 0, MaxStack: n[10],
		})
	}
	return NewCreatableSet(rows), nil
}
