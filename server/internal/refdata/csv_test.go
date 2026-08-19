package refdata

import (
	"strings"
	"testing"
)

func TestLoadItemsCSV(t *testing.T) {
	// Synthetic data, not any real game's actual values.
	csv := "1,5000,10,0,1,0,0.5,1.0,10.0,20.0,5.0,15.0,50.0,80.0,20.0,40.0,0.5,0.9,0.1,0.3\n" +
		"2,1,0,20,3,1,1.0,1.0,0.0,0.0,30.0,60.0,0.0,0.0,100.0,150.0,0.6,0.95,0.05,0.2\n"

	items, err := LoadItemsCSV(strings.NewReader(csv))
	if err != nil {
		t.Fatalf("LoadItemsCSV: %v", err)
	}
	if len(items) != 2 {
		t.Fatalf("got %d items, want 2", len(items))
	}

	if items[0].ID != 1 || items[0].MaxStack != 5000 || items[0].ReqStr != 10 {
		t.Fatalf("item 0 fields wrong: %+v", items[0])
	}
	if items[0].TwoHanded {
		t.Fatal("item 0 should not be two-handed")
	}
	if items[0].PhysAttackMax != 80.0 {
		t.Fatalf("item 0 PhysAttackMax = %v, want 80.0", items[0].PhysAttackMax)
	}

	if items[1].ID != 2 || !items[1].TwoHanded {
		t.Fatalf("item 1 fields wrong: %+v", items[1])
	}
	if items[1].MagAttackMax != 150.0 {
		t.Fatalf("item 1 MagAttackMax = %v, want 150.0", items[1].MagAttackMax)
	}
}

func TestLoadItemsCSVEmpty(t *testing.T) {
	items, err := LoadItemsCSV(strings.NewReader(""))
	if err != nil {
		t.Fatalf("LoadItemsCSV: %v", err)
	}
	if len(items) != 0 {
		t.Fatalf("got %d items, want 0", len(items))
	}
}

func TestLoadItemsCSVMalformedRow(t *testing.T) {
	_, err := LoadItemsCSV(strings.NewReader("not,enough,columns\n"))
	if err == nil {
		t.Fatal("expected an error for a row with the wrong column count, got nil")
	}
}

func TestLoadItemsCSVNonNumericField(t *testing.T) {
	csv := "1,5000,10,0,1,0,0.5,1.0,10.0,20.0,5.0,15.0,50.0,80.0,20.0,40.0,0.5,0.9,0.1,notanumber\n"
	_, err := LoadItemsCSV(strings.NewReader(csv))
	if err == nil {
		t.Fatal("expected an error for a non-numeric field, got nil")
	}
}
