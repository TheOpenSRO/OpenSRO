package npcspawn

import (
	"encoding/csv"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"

	"github.com/TheOpenSRO/OpenSRO/server/internal/species"
)

// CSVColumns is the header cmd/export-refdata -mode npcs writes and LoadCSV
// reads: every characterdata row of TypeID (1,2,2,x) -- the NPCs (x = 0) and
// the gate-pulley structures (x = 1) the client creates as CICNPC (READ: its
// class picker IGIDObject::FUN_009c1fa0 sends every (1,2,2,*) word through
// FUN_0069a3f0 to class link 0xef1ac4, the class CICNPC's reader tests for) --
// and whether refshopgroup.txt (column 4, RefNPCCodeName) names it.
var CSVColumns = []string{"ID", "CodeName", "TypeID1", "TypeID2", "TypeID3", "TypeID4", "Shop"}

// TableRow is one NPC reference row.
type TableRow struct {
	ID      int64
	Code    string
	TypeID4 int
	Shop    bool
}

// Table is the NPC reference rows by id.
type Table map[int64]TableRow

// ExportRow turns one characterdata row into an NPC row, ok false when it is
// not one (too short, or another TypeID).
func ExportRow(cols []string) (TableRow, [4]int, bool) {
	var tid [4]int
	if len(cols) <= species.ColTypeID4 {
		return TableRow{}, tid, false
	}
	id, err := strconv.ParseInt(strings.TrimSpace(cols[species.ColID]), 10, 64)
	if err != nil {
		return TableRow{}, tid, false
	}
	for i := range tid {
		v, err := strconv.Atoi(strings.TrimSpace(cols[species.ColTypeID1+i]))
		if err != nil {
			return TableRow{}, tid, false
		}
		tid[i] = v
	}
	if tid[0] != 1 || tid[1] != 2 || tid[2] != 2 {
		return TableRow{}, tid, false
	}
	return TableRow{ID: id, Code: strings.TrimSpace(cols[species.ColCodeName]), TypeID4: tid[3]}, tid, true
}

// ShopNPCCol is refshopgroup.txt's RefNPCCodeName column (the client reads
// the same column, client/scripts/npc/npc_service_reader.gd SHOP_NPC_COL).
const ShopNPCCol = 4

// Read parses an npcs CSV.
func Read(r io.Reader) (Table, error) {
	cr := csv.NewReader(r)
	head, err := cr.Read()
	if err != nil {
		return nil, fmt.Errorf("npcspawn: reading the header: %w", err)
	}
	if strings.Join(head, ",") != strings.Join(CSVColumns, ",") {
		return nil, fmt.Errorf("npcspawn: header %q, want %q", strings.Join(head, ","), strings.Join(CSVColumns, ","))
	}
	t := Table{}
	for line := 2; ; line++ {
		rec, err := cr.Read()
		if err == io.EOF {
			return t, nil
		}
		if err != nil {
			return nil, fmt.Errorf("npcspawn: line %d: %w", line, err)
		}
		id, err := strconv.ParseInt(rec[0], 10, 64)
		if err != nil {
			return nil, fmt.Errorf("npcspawn: line %d: id %q", line, rec[0])
		}
		t4, err := strconv.Atoi(rec[5])
		if err != nil {
			return nil, fmt.Errorf("npcspawn: line %d: TypeID4 %q", line, rec[5])
		}
		t[id] = TableRow{ID: id, Code: rec[1], TypeID4: t4, Shop: rec[6] == "1"}
	}
}

// LoadCSV reads an npcs CSV file; a configured path that does not load is an
// error (the -npcpos-csv rule).
func LoadCSV(path string) (Table, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return Read(f)
}
