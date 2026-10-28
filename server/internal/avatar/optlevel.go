package avatar

import (
	"encoding/csv"
	"fmt"
	"io"
	"os"
	"strconv"
)

// OptLevelTable is what a devil's spirit gives at its plus level (round
// 838): the joined refabilitybyitemoptleveldata / refmagicoptbyitemoptleveldata
// / refskillbyitemoptleveldata (export-refdata -mode itemoptlevel). READ,
// SR_GameServer.exe: PublishEquipItemParams (0x4e3760) runs FUN_00498020 for
// an awake 3/1/14 -- FUN_00498160 looks the ability up by (RefItemID,
// OptLevel) and writes each magic option row's value through
// Stat_ApplyTaggedModifier keyed by the item, BEFORE the item's own blue
// options; FUN_00498370 adds each skill row to the character's skill book
// (FUN_0059ea40, kind 3). No ability row: nothing.
type OptLevelTable struct {
	byKey map[[2]int64]*OptLevelGrant
}

// OptLevelGrant is one (item, plus level)'s magic options (option id ->
// value, in the table's order) and skills.
type OptLevelGrant struct {
	Options []OptLevelOption
	Skills  []int64
}

// OptLevelOption is one magic option row: the magicoption id and its value.
type OptLevelOption struct {
	ID    uint32
	Value int
}

// Grant returns the item's grant at optLevel, or nil.
func (t *OptLevelTable) Grant(refItemID int64, optLevel int) *OptLevelGrant {
	if t == nil {
		return nil
	}
	return t.byKey[[2]int64{refItemID, int64(optLevel)}]
}

// Len is the number of (item, level) keys.
func (t *OptLevelTable) Len() int {
	if t == nil {
		return 0
	}
	return len(t.byKey)
}

// ReadOptLevelCSV reads the export: RefItemID, OptLevel, "opt" | "skill", id,
// value.
func ReadOptLevelCSV(r io.Reader) (*OptLevelTable, error) {
	cr := csv.NewReader(r)
	cr.FieldsPerRecord = 5
	t := &OptLevelTable{byKey: map[[2]int64]*OptLevelGrant{}}
	line := 0
	for {
		rec, err := cr.Read()
		if err == io.EOF {
			break
		}
		line++
		if err != nil {
			return nil, fmt.Errorf("avatar: opt level csv line %d: %w", line, err)
		}
		var v [3]int64
		for i, k := range []int{0, 1, 3} {
			if v[i], err = strconv.ParseInt(rec[k], 10, 64); err != nil {
				return nil, fmt.Errorf("avatar: opt level csv line %d: field %d: %w", line, k, err)
			}
		}
		val, err := strconv.Atoi(rec[4])
		if err != nil {
			return nil, fmt.Errorf("avatar: opt level csv line %d: value: %w", line, err)
		}
		key := [2]int64{v[0], v[1]}
		g := t.byKey[key]
		if g == nil {
			g = &OptLevelGrant{}
			t.byKey[key] = g
		}
		switch rec[2] {
		case "opt":
			g.Options = append(g.Options, OptLevelOption{ID: uint32(v[2]), Value: val})
		case "skill":
			g.Skills = append(g.Skills, v[2])
		default:
			return nil, fmt.Errorf("avatar: opt level csv line %d: kind %q", line, rec[2])
		}
	}
	return t, nil
}

// LoadOptLevelCSV reads the export at path.
func LoadOptLevelCSV(path string) (*OptLevelTable, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return ReadOptLevelCSV(f)
}
