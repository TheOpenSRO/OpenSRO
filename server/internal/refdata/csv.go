package refdata

import (
	"encoding/csv"
	"fmt"
	"io"
	"strconv"
)

// itemCSVColumns is the expected column order for LoadItemsCSV, matching
// the columns a player would export from their own restored reference-data
// database. See docs/protocol/refdata_schema.md for what each of the
// original columns means; this is the curated subset refdata.Item keeps.
var itemCSVColumns = []string{
	"ID", "MaxStack", "ReqStr", "ReqInt", "ItemClass", "TwoHanded",
	"Dur_L", "Dur_U", "PD_L", "PD_U", "MD_L", "MD_U",
	"PAttackMin_L", "PAttackMax_U", "MAttackMin_L", "MAttackMax_U",
	"HR_L", "HR_U", "CHR_L", "CHR_U",
	// Appended rather than slotted in by the original's column order, so
	// an export made for the earlier twenty columns is still a prefix of
	// this one.
	"TypeID1", "TypeID2", "TypeID3", "TypeID4", "Country", "ReqGender",
	"ReqLevelType1", "ReqLevel1",
}

// LoadItemsCSV parses item rows from r, a headerless CSV in
// itemCSVColumns's order (i.e. exactly what a plain `SELECT <those
// columns> FROM _RefObjItem ORDER BY ID` export produces). Returns a
// descriptive error naming the row/column on any parse failure rather than
// silently skipping bad data.
func LoadItemsCSV(r io.Reader) ([]Item, error) {
	cr := csv.NewReader(r)
	cr.FieldsPerRecord = len(itemCSVColumns)

	var items []Item
	rowNum := 0
	for {
		record, err := cr.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("refdata: reading row %d: %w", rowNum, err)
		}
		rowNum++

		item, err := parseItemRow(record)
		if err != nil {
			return nil, fmt.Errorf("refdata: row %d: %w", rowNum, err)
		}
		items = append(items, item)
	}
	return items, nil
}

func parseItemRow(f []string) (Item, error) {
	var (
		it  Item
		err error
	)
	parseInt := func(s string) int {
		var v int64
		if err == nil {
			v, err = strconv.ParseInt(s, 10, 64)
		}
		return int(v)
	}
	parseInt64 := func(s string) int64 {
		var v int64
		if err == nil {
			v, err = strconv.ParseInt(s, 10, 64)
		}
		return v
	}
	parseFloat := func(s string) float64 {
		var v float64
		if err == nil {
			v, err = strconv.ParseFloat(s, 64)
		}
		return v
	}
	parseBool := func(s string) bool {
		return parseInt(s) != 0
	}

	it.ID = parseInt64(f[0])
	it.MaxStack = parseInt(f[1])
	it.ReqStr = parseInt(f[2])
	it.ReqInt = parseInt(f[3])
	it.ItemClass = parseInt(f[4])
	it.TwoHanded = parseBool(f[5])
	it.DurabilityMin = parseFloat(f[6])
	it.DurabilityMax = parseFloat(f[7])
	it.PhysDefenseMin = parseFloat(f[8])
	it.PhysDefenseMax = parseFloat(f[9])
	it.MagDefenseMin = parseFloat(f[10])
	it.MagDefenseMax = parseFloat(f[11])
	it.PhysAttackMin = parseFloat(f[12])
	it.PhysAttackMax = parseFloat(f[13])
	it.MagAttackMin = parseFloat(f[14])
	it.MagAttackMax = parseFloat(f[15])
	it.HitRateMin = parseFloat(f[16])
	it.HitRateMax = parseFloat(f[17])
	it.CriticalMin = parseFloat(f[18])
	it.CriticalMax = parseFloat(f[19])
	it.TypeID1 = parseInt(f[20])
	it.TypeID2 = parseInt(f[21])
	it.TypeID3 = parseInt(f[22])
	it.TypeID4 = parseInt(f[23])
	it.Country = parseInt(f[24])
	it.ReqGender = parseInt(f[25])
	it.ReqLevelType1 = parseInt(f[26])
	it.ReqLevel1 = parseInt(f[27])

	if err != nil {
		return Item{}, err
	}
	return it, nil
}

// skillCSVColumns is the expected column order for LoadSkillsCSV, matching
// the columns a player would export from their own restored reference-data
// database. See docs/protocol/refdata_schema.md and refdata.Skill's doc
// comment for what each real column means and why only these are kept.
var skillCSVColumns = []string{
	"ID", "GroupID", "Basic_Code", "Basic_Name", "Basic_Level", "Basic_ChainCode",
	"Basic_RecycleCost", "PreparingTime", "CastingTime", "ActionDuration",
	"ReuseDelay", "CoolTime", "FlyingSpeed", "Interruptable", "Overlap", "AutoAttackType",
	"Range", "Consume_HP", "Consume_MP", "ReqLearn_SP", "ReqLearn_Race", "UI_SkillName",
	"ReqCommon_Mastery1", "ReqCommon_MasteryLevel1",
}

// LoadSkillsCSV parses skill rows from r, a headerless CSV in
// skillCSVColumns's order (i.e. exactly what a plain `SELECT <those
// columns> FROM _RefSkill ORDER BY ID` export produces). Returns a
// descriptive error naming the row/column on any parse failure rather than
// silently skipping bad data.
func LoadSkillsCSV(r io.Reader) ([]Skill, error) {
	cr := csv.NewReader(r)
	cr.FieldsPerRecord = len(skillCSVColumns)

	var skills []Skill
	rowNum := 0
	for {
		record, err := cr.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("refdata: reading row %d: %w", rowNum, err)
		}
		rowNum++

		sk, err := parseSkillRow(record)
		if err != nil {
			return nil, fmt.Errorf("refdata: row %d: %w", rowNum, err)
		}
		skills = append(skills, sk)
	}
	return skills, nil
}

func parseSkillRow(f []string) (Skill, error) {
	var (
		sk  Skill
		err error
	)
	parseInt := func(s string) int {
		var v int64
		if err == nil {
			v, err = strconv.ParseInt(s, 10, 64)
		}
		return int(v)
	}
	parseInt64 := func(s string) int64 {
		var v int64
		if err == nil {
			v, err = strconv.ParseInt(s, 10, 64)
		}
		return v
	}
	parseFloat := func(s string) float64 {
		var v float64
		if err == nil {
			v, err = strconv.ParseFloat(s, 64)
		}
		return v
	}
	parseBool := func(s string) bool {
		return parseInt(s) != 0
	}

	sk.ID = parseInt64(f[0])
	sk.GroupID = parseInt64(f[1])
	sk.BasicCode = f[2]
	sk.BasicName = f[3]
	sk.BasicLevel = parseInt(f[4])
	sk.BasicChainCode = parseInt64(f[5])
	sk.BasicRecycleCost = parseInt(f[6])
	sk.PreparingTimeMs = parseInt(f[7])
	sk.CastingTimeMs = parseInt(f[8])
	sk.ActionDurationMs = parseInt(f[9])
	sk.ReuseDelayMs = parseInt(f[10])
	sk.CoolTimeMs = parseInt(f[11])
	sk.FlyingSpeed = parseFloat(f[12])
	sk.Interruptable = parseBool(f[13])
	sk.Overlap = parseBool(f[14])
	sk.AutoAttackType = parseInt(f[15])
	sk.Range = parseInt(f[16])
	sk.ConsumeHP = parseInt(f[17])
	sk.ConsumeMP = parseInt(f[18])
	sk.ReqLearnSP = parseInt(f[19])
	sk.ReqLearnRace = parseInt(f[20])
	sk.UISkillName = f[21]
	sk.Mastery1 = parseInt64(f[22])
	sk.MasteryLevel1 = parseInt(f[23])

	if err != nil {
		return Skill{}, err
	}
	return sk, nil
}

// monsterDropCSVColumns is the expected column order for LoadMonsterDropsCSV.
// See docs/protocol/refdata_schema.md and refdata.MonsterDrop's doc comment.
var monsterDropCSVColumns = []string{
	"RefMonsterID", "RefItemGroupID", "Overlap", "DropAmountMin", "DropAmountMax", "DropRatio",
}

// LoadMonsterDropsCSV parses monster-drop rows from r, a headerless CSV in
// monsterDropCSVColumns's order (i.e. exactly what a plain `SELECT <those
// columns> FROM _RefMonster_AssignedItemRndDrop` export produces).
func LoadMonsterDropsCSV(r io.Reader) ([]MonsterDrop, error) {
	cr := csv.NewReader(r)
	cr.FieldsPerRecord = len(monsterDropCSVColumns)

	var drops []MonsterDrop
	rowNum := 0
	for {
		record, err := cr.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("refdata: reading row %d: %w", rowNum, err)
		}
		rowNum++

		d, err := parseMonsterDropRow(record)
		if err != nil {
			return nil, fmt.Errorf("refdata: row %d: %w", rowNum, err)
		}
		drops = append(drops, d)
	}
	return drops, nil
}

func parseMonsterDropRow(f []string) (MonsterDrop, error) {
	var (
		d   MonsterDrop
		err error
	)
	parseInt := func(s string) int {
		var v int64
		if err == nil {
			v, err = strconv.ParseInt(s, 10, 64)
		}
		return int(v)
	}
	parseInt64 := func(s string) int64 {
		var v int64
		if err == nil {
			v, err = strconv.ParseInt(s, 10, 64)
		}
		return v
	}
	parseFloat := func(s string) float64 {
		var v float64
		if err == nil {
			v, err = strconv.ParseFloat(s, 64)
		}
		return v
	}
	parseBool := func(s string) bool {
		return parseInt(s) != 0
	}

	d.MonsterID = parseInt64(f[0])
	d.ItemGroupID = parseInt64(f[1])
	d.Overlap = parseBool(f[2])
	d.DropAmountMin = parseInt(f[3])
	d.DropAmountMax = parseInt(f[4])
	d.DropRatio = parseFloat(f[5])

	if err != nil {
		return MonsterDrop{}, err
	}
	return d, nil
}

// dropGroupEntryCSVColumns is the expected column order for
// LoadDropGroupEntriesCSV. See docs/protocol/refdata_schema.md and
// refdata.DropGroupEntry's doc comment.
var dropGroupEntryCSVColumns = []string{
	"RefItemGroupID", "CodeName128", "RefItemID", "SelectRatio",
}

// LoadDropGroupEntriesCSV parses drop-group-entry rows from r, a headerless
// CSV in dropGroupEntryCSVColumns's order (i.e. exactly what a plain
// `SELECT <those columns> FROM _RefDropItemGroup` export produces).
func LoadDropGroupEntriesCSV(r io.Reader) ([]DropGroupEntry, error) {
	cr := csv.NewReader(r)
	cr.FieldsPerRecord = len(dropGroupEntryCSVColumns)

	var entries []DropGroupEntry
	rowNum := 0
	for {
		record, err := cr.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("refdata: reading row %d: %w", rowNum, err)
		}
		rowNum++

		e, err := parseDropGroupEntryRow(record)
		if err != nil {
			return nil, fmt.Errorf("refdata: row %d: %w", rowNum, err)
		}
		entries = append(entries, e)
	}
	return entries, nil
}

func parseDropGroupEntryRow(f []string) (DropGroupEntry, error) {
	var (
		e   DropGroupEntry
		err error
	)
	parseInt64 := func(s string) int64 {
		var v int64
		if err == nil {
			v, err = strconv.ParseInt(s, 10, 64)
		}
		return v
	}
	parseFloat := func(s string) float64 {
		var v float64
		if err == nil {
			v, err = strconv.ParseFloat(s, 64)
		}
		return v
	}

	e.GroupID = parseInt64(f[0])
	e.CodeName = f[1]
	e.ItemID = parseInt64(f[2])
	e.SelectRatio = parseFloat(f[3])

	if err != nil {
		return DropGroupEntry{}, err
	}
	return e, nil
}
