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

func TestLoadSkillsCSV(t *testing.T) {
	// Synthetic data, not any real game's actual values.
	csv := "1,10,SKILL_CH_SWORD_ATTACK_01,SN_SWORD_ATTACK_01,1,0,5,500,300,1000,3000,3000,0.0,1,0,1\n" +
		"2,10,SKILL_CH_BOW_ATTACK_01,SN_BOW_ATTACK_01,5,1,15,700,400,1200,5000,4500,25.5,0,1,2\n"

	skills, err := LoadSkillsCSV(strings.NewReader(csv))
	if err != nil {
		t.Fatalf("LoadSkillsCSV: %v", err)
	}
	if len(skills) != 2 {
		t.Fatalf("got %d skills, want 2", len(skills))
	}

	if skills[0].ID != 1 || skills[0].GroupID != 10 || skills[0].BasicCode != "SKILL_CH_SWORD_ATTACK_01" {
		t.Fatalf("skill 0 fields wrong: %+v", skills[0])
	}
	if !skills[0].Interruptable || skills[0].Overlap {
		t.Fatalf("skill 0 Interruptable/Overlap wrong: %+v", skills[0])
	}
	if skills[0].ReuseDelayMs != 3000 {
		t.Fatalf("skill 0 ReuseDelayMs = %v, want 3000", skills[0].ReuseDelayMs)
	}

	if skills[1].ID != 2 || skills[1].BasicChainCode != 1 {
		t.Fatalf("skill 1 fields wrong: %+v", skills[1])
	}
	if skills[1].Interruptable || !skills[1].Overlap {
		t.Fatalf("skill 1 Interruptable/Overlap wrong: %+v", skills[1])
	}
	if skills[1].FlyingSpeed != 25.5 {
		t.Fatalf("skill 1 FlyingSpeed = %v, want 25.5", skills[1].FlyingSpeed)
	}
}

func TestLoadSkillsCSVEmpty(t *testing.T) {
	skills, err := LoadSkillsCSV(strings.NewReader(""))
	if err != nil {
		t.Fatalf("LoadSkillsCSV: %v", err)
	}
	if len(skills) != 0 {
		t.Fatalf("got %d skills, want 0", len(skills))
	}
}

func TestLoadSkillsCSVMalformedRow(t *testing.T) {
	_, err := LoadSkillsCSV(strings.NewReader("not,enough,columns\n"))
	if err == nil {
		t.Fatal("expected an error for a row with the wrong column count, got nil")
	}
}

func TestLoadSkillsCSVNonNumericField(t *testing.T) {
	csv := "1,10,SKILL_CH_SWORD_ATTACK_01,SN_SWORD_ATTACK_01,1,0,5,500,300,1000,3000,3000,0.0,1,0,notanumber\n"
	_, err := LoadSkillsCSV(strings.NewReader(csv))
	if err == nil {
		t.Fatal("expected an error for a non-numeric field, got nil")
	}
}
