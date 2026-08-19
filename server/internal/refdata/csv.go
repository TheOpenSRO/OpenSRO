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

	if err != nil {
		return Item{}, err
	}
	return it, nil
}
