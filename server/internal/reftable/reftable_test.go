package reftable

import (
	"bytes"
	"strings"
	"testing"
)

func TestReadConsoleDump(t *testing.T) {
	in := "\xef\xbb\xbfID~CodeName128~Value\r\n--~-----------~-----\r\n1~INS_DEFAULT~0\r\n2~INS_FORT_JA~2500\r\n\r\n"
	tab, err := Read(strings.NewReader(in))
	if err != nil {
		t.Fatal(err)
	}
	if len(tab.Rows) != 2 || tab.Get(tab.Rows[1], "codename128") != "INS_FORT_JA" || tab.Int(tab.Rows[1], "Value") != 2500 {
		t.Fatalf("rows %q", tab.Rows)
	}
}

func TestReadQuotedCSVRoundTrip(t *testing.T) {
	in := "ID,Desc\n2,\"NPC, town\"\n"
	tab, err := Read(strings.NewReader(in))
	if err != nil {
		t.Fatal(err)
	}
	if tab.Get(tab.Rows[0], "Desc") != "NPC, town" {
		t.Fatalf("desc %q", tab.Get(tab.Rows[0], "Desc"))
	}
	var b bytes.Buffer
	if err := tab.WriteCSV(&b); err != nil {
		t.Fatal(err)
	}
	back, err := Read(&b)
	if err != nil || back.Get(back.Rows[0], "Desc") != "NPC, town" {
		t.Fatalf("round trip %v %q", err, back.Rows)
	}
}
