package species

import (
	"strings"
	"testing"
)

// Round 712: col 79 (ExpToGive) is exported and read; a CSV without it reads
// with HasExpToGive false.
func TestExpToGiveColumn(t *testing.T) {
	row := make([]string, len(CSVColumns))
	for i := range row {
		row[i] = "0"
	}
	row[cID], row[cCodeName], row[cExpToGive] = "7", "MOB_X", "749"
	tab, err := Read(strings.NewReader(strings.Join(CSVColumns, ",") + "\n" + strings.Join(row, ",") + "\n"))
	if err != nil {
		t.Fatal(err)
	}
	if r, _ := tab.ByID(7); !r.HasExpToGive || r.ExpToGive != 749 {
		t.Fatalf("read %+v", r)
	}
	old := strings.Join(CSVColumns[:RequiredCSVColumns], ",") + "\n" + strings.Join(row[:RequiredCSVColumns], ",") + "\n"
	tab, err = Read(strings.NewReader(old))
	if err != nil {
		t.Fatal(err)
	}
	if r, _ := tab.ByID(7); r.HasExpToGive {
		t.Fatalf("a pre-712 CSV claimed an ExpToGive: %+v", r)
	}
	// The exporter writes col 79.
	cols := make([]string, minFields)
	for i := range cols {
		cols[i] = "0"
	}
	cols[ColID], cols[ColCodeName], cols[ColTypeID1], cols[ColTypeID2], cols[ColTypeID3], cols[ColExpToGive] = "9", "MOB_Y", "1", "2", "1", "1234"
	e := NewExporter()
	e.Add(cols)
	recs, _ := e.Records(nil, nil)
	if len(recs) != 1 || recs[0][cExpToGive] != "1234" {
		t.Fatalf("exported %v", recs)
	}
}
