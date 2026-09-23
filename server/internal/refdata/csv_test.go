package refdata

import (
	"strings"
	"testing"
)

func TestLoadItemsCSV(t *testing.T) {
	// Synthetic data, not any real game's actual values.
	csv := "1,5000,10,0,1,0,0.5,1.0,10.0,20.0,5.0,15.0,50.0,80.0,20.0,40.0,0.5,0.9,0.1,0.3,3,1,6,2,0,1,1,1\n" +
		"2,1,0,20,3,1,1.0,1.0,0.0,0.0,30.0,60.0,0.0,0.0,100.0,150.0,0.6,0.95,0.05,0.2,3,1,3,3,0,0,1,12\n"

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
	// The classification and requirement columns ride at the end.
	if items[0].TypeID1 != 3 || items[0].TypeID3 != 6 || items[0].Country != 0 || items[0].ReqGender != 1 || items[0].ReqLevelType1 != 1 || items[0].ReqLevel1 != 1 {
		t.Fatalf("item 0 classification/requirement fields wrong: %+v", items[0])
	}
	if items[1].TypeID3 != 3 || items[1].TypeID4 != 3 || items[1].ReqGender != 0 || items[1].ReqLevel1 != 12 {
		t.Fatalf("item 1 classification/requirement fields wrong: %+v", items[1])
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
	csv := "1,5000,10,0,1,0,0.5,1.0,10.0,20.0,5.0,15.0,50.0,80.0,20.0,40.0,0.5,0.9,0.1,notanumber,3,1,6,2,0,1,1,1\n"
	_, err := LoadItemsCSV(strings.NewReader(csv))
	if err == nil {
		t.Fatal("expected an error for a non-numeric field, got nil")
	}
}

func TestLoadSkillsCSV(t *testing.T) {
	// Synthetic data, not any real game's actual values.
	csv := "1,10,SKILL_CH_SWORD_ATTACK_01,SN_SWORD_ATTACK_01,1,0,5,500,300,1000,3000,3000,0.0,1,0,1,10,0,20,100,0,Sword Slash,257,5\n" +
		"2,10,SKILL_CH_BOW_ATTACK_01,SN_BOW_ATTACK_01,5,1,15,700,400,1200,5000,4500,25.5,0,1,2,50,5,40,500,0,Piercing Shot,259,3\n"

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
	if skills[0].Range != 10 || skills[0].ConsumeMP != 20 || skills[0].ReqLearnSP != 100 {
		t.Fatalf("skill 0 Range/ConsumeMP/ReqLearnSP wrong: %+v", skills[0])
	}
	if skills[0].UISkillName != "Sword Slash" {
		t.Fatalf("skill 0 UISkillName = %q, want %q", skills[0].UISkillName, "Sword Slash")
	}
	if skills[0].Mastery1 != 257 || skills[0].MasteryLevel1 != 5 {
		t.Fatalf("skill 0 Mastery1/MasteryLevel1 = %d/%d, want 257/5", skills[0].Mastery1, skills[0].MasteryLevel1)
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
	if skills[1].ConsumeHP != 5 || skills[1].UISkillName != "Piercing Shot" {
		t.Fatalf("skill 1 ConsumeHP/UISkillName wrong: %+v", skills[1])
	}
	if skills[1].Mastery1 != 259 || skills[1].MasteryLevel1 != 3 {
		t.Fatalf("skill 1 Mastery1/MasteryLevel1 = %d/%d, want 259/3", skills[1].Mastery1, skills[1].MasteryLevel1)
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
	csv := "1,10,SKILL_CH_SWORD_ATTACK_01,SN_SWORD_ATTACK_01,notanumber,0,5,500,300,1000,3000,3000,0.0,1,0,1,10,0,20,100,0,Sword Slash,257,5\n"
	_, err := LoadSkillsCSV(strings.NewReader(csv))
	if err == nil {
		t.Fatal("expected an error for a non-numeric field, got nil")
	}
}

func TestLoadMonsterDropsCSV(t *testing.T) {
	// Synthetic data, not any real game's actual values.
	csv := "1001,50,1,1,3,0.15\n" +
		"1001,51,0,1,1,0.05\n"

	drops, err := LoadMonsterDropsCSV(strings.NewReader(csv))
	if err != nil {
		t.Fatalf("LoadMonsterDropsCSV: %v", err)
	}
	if len(drops) != 2 {
		t.Fatalf("got %d drops, want 2", len(drops))
	}
	if drops[0].MonsterID != 1001 || drops[0].ItemGroupID != 50 || !drops[0].Overlap {
		t.Fatalf("drop 0 fields wrong: %+v", drops[0])
	}
	if drops[0].DropAmountMax != 3 || drops[0].DropRatio != 0.15 {
		t.Fatalf("drop 0 amount/ratio wrong: %+v", drops[0])
	}
	if drops[1].Overlap {
		t.Fatalf("drop 1 Overlap should be false: %+v", drops[1])
	}
}

func TestLoadMonsterDropsCSVEmpty(t *testing.T) {
	drops, err := LoadMonsterDropsCSV(strings.NewReader(""))
	if err != nil {
		t.Fatalf("LoadMonsterDropsCSV: %v", err)
	}
	if len(drops) != 0 {
		t.Fatalf("got %d drops, want 0", len(drops))
	}
}

func TestLoadMonsterDropsCSVMalformedRow(t *testing.T) {
	_, err := LoadMonsterDropsCSV(strings.NewReader("not,enough\n"))
	if err == nil {
		t.Fatal("expected an error for a row with the wrong column count, got nil")
	}
}

func TestLoadMonsterDropsCSVNonNumericField(t *testing.T) {
	_, err := LoadMonsterDropsCSV(strings.NewReader("1001,50,1,1,3,notanumber\n"))
	if err == nil {
		t.Fatal("expected an error for a non-numeric field, got nil")
	}
}

func TestLoadDropGroupEntriesCSV(t *testing.T) {
	// Synthetic data, not any real game's actual values.
	csv := "50,GROUP_POTION_BASIC,500,0.7\n" +
		"50,GROUP_POTION_BASIC,501,0.3\n"

	entries, err := LoadDropGroupEntriesCSV(strings.NewReader(csv))
	if err != nil {
		t.Fatalf("LoadDropGroupEntriesCSV: %v", err)
	}
	if len(entries) != 2 {
		t.Fatalf("got %d entries, want 2", len(entries))
	}
	if entries[0].GroupID != 50 || entries[0].CodeName != "GROUP_POTION_BASIC" || entries[0].ItemID != 500 {
		t.Fatalf("entry 0 fields wrong: %+v", entries[0])
	}
	if entries[1].SelectRatio != 0.3 {
		t.Fatalf("entry 1 SelectRatio = %v, want 0.3", entries[1].SelectRatio)
	}
}

func TestLoadDropGroupEntriesCSVEmpty(t *testing.T) {
	entries, err := LoadDropGroupEntriesCSV(strings.NewReader(""))
	if err != nil {
		t.Fatalf("LoadDropGroupEntriesCSV: %v", err)
	}
	if len(entries) != 0 {
		t.Fatalf("got %d entries, want 0", len(entries))
	}
}

func TestLoadDropGroupEntriesCSVMalformedRow(t *testing.T) {
	_, err := LoadDropGroupEntriesCSV(strings.NewReader("not,enough\n"))
	if err == nil {
		t.Fatal("expected an error for a row with the wrong column count, got nil")
	}
}

func TestLoadDropGroupEntriesCSVNonNumericField(t *testing.T) {
	_, err := LoadDropGroupEntriesCSV(strings.NewReader("50,GROUP_POTION_BASIC,500,notanumber\n"))
	if err == nil {
		t.Fatal("expected an error for a non-numeric field, got nil")
	}
}

// TestCapabilityFlagsDefaultToUnrestricted guards the one place where Go's zero
// value would have been actively dangerous.
//
// CanTrade/CanSell/CanDrop are PERMISSIONS: a clear bit forbids. An export made
// before those columns existed has no value for them, and a bool defaults to
// false -- so without this the loader would mark every item in an older export
// un-tradeable and un-sellable, and the server would refuse every trade and
// every sale with nothing in the logs to explain it.
//
// The SQL store defaults the same way (`DEFAULT TRUE`). These two have to agree,
// or the same export behaves differently depending on the backend.
func TestCapabilityFlagsDefaultToUnrestricted(t *testing.T) {
	// A 41-column row: everything through SetID, nothing after it.
	row := make([]string, 41)
	for i := range row {
		row[i] = "0"
	}
	row[0] = "4842"

	items, err := LoadItemsCSV(strings.NewReader(strings.Join(row, ",") + "\n"))
	if err != nil {
		t.Fatalf("LoadItemsCSV: %v", err)
	}
	if len(items) != 1 {
		t.Fatalf("got %d items, want 1", len(items))
	}
	it := items[0]
	if !it.CanTrade || !it.CanSell || !it.CanDrop {
		t.Errorf("an export predating the capability columns must load as unrestricted; "+
			"got CanTrade=%v CanSell=%v CanDrop=%v", it.CanTrade, it.CanSell, it.CanDrop)
	}

	// And a row that DOES carry them is obeyed, including the forbidding case.
	row = append(row, "0", "0", "0")
	items, err = LoadItemsCSV(strings.NewReader(strings.Join(row, ",") + "\n"))
	if err != nil {
		t.Fatalf("LoadItemsCSV with flags: %v", err)
	}
	if items[0].CanTrade || items[0].CanSell || items[0].CanDrop {
		t.Errorf("explicit zeros must forbid; got CanTrade=%v CanSell=%v CanDrop=%v",
			items[0].CanTrade, items[0].CanSell, items[0].CanDrop)
	}
}

// TestCanUseDefaultsToUsable is the same guard for CanUse (round 489, column
// 68): an export made before the column existed must load every item as
// usable, or every potion on a server that has not re-exported would be
// refused with "cannot be used". A present column is obeyed either way.
func TestCanUseDefaultsToUsable(t *testing.T) {
	// A 68-column row: everything through ParryRatioMax, nothing after it.
	row := make([]string, 68)
	for i := range row {
		row[i] = "0"
	}
	row[0] = "4"
	load := func(r []string) Item {
		t.Helper()
		items, err := LoadItemsCSV(strings.NewReader(strings.Join(r, ",") + "\n"))
		if err != nil {
			t.Fatalf("LoadItemsCSV (%d columns): %v", len(r), err)
		}
		if len(items) != 1 {
			t.Fatalf("got %d items, want 1", len(items))
		}
		return items[0]
	}
	if !load(row).CanUse {
		t.Error("a 68-column export predating CanUse must load as usable")
	}
	if load(append(append([]string(nil), row...), "0")).CanUse {
		t.Error("an explicit 0 in column 68 must forbid use")
	}
	if !load(append(append([]string(nil), row...), "1")).CanUse {
		t.Error("an explicit 1 in column 68 must permit use")
	}
}

// The three requirement slots past the first are appended columns 44..49, so
// a 28-column export made before they existed must still load and simply
// carry no requirement beyond its first pair.
func TestLoadItemsCSVRequirementSlots(t *testing.T) {
	// 50 columns: the first 44 as the loader already knew them, then the
	// three appended (type, value) pairs. Shaped like a real Chinese row
	// whose requirements are a mastery in slot 1 and masteries after it.
	full := "1,1,0,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0," + // 0..19
		"3,1,1,2,0,2,513,20," + // 20..27 classification + first pair
		"0,0,0,0,0,0,0,0,0,0,0,0,0,1,1,1," + // 28..43
		"515,30,518,40,0,0\n" // 44..49 the appended pairs

	items, err := LoadItemsCSV(strings.NewReader(full))
	if err != nil {
		t.Fatalf("LoadItemsCSV: %v", err)
	}
	if len(items) != 1 {
		t.Fatalf("got %d items, want 1", len(items))
	}
	it := items[0]
	if it.ReqLevelType1 != 513 || it.ReqLevel1 != 20 {
		t.Errorf("slot 1 = (%d,%d), want (513,20)", it.ReqLevelType1, it.ReqLevel1)
	}
	if it.ReqLevelType2 != 515 || it.ReqLevel2 != 30 {
		t.Errorf("slot 2 = (%d,%d), want (515,30)", it.ReqLevelType2, it.ReqLevel2)
	}
	if it.ReqLevelType3 != 518 || it.ReqLevel3 != 40 {
		t.Errorf("slot 3 = (%d,%d), want (518,40)", it.ReqLevelType3, it.ReqLevel3)
	}
	if it.ReqLevelType4 != 0 || it.ReqLevel4 != 0 {
		t.Errorf("slot 4 = (%d,%d), want unused", it.ReqLevelType4, it.ReqLevel4)
	}

	// An export from before the appended columns: the 28-column form the
	// original test uses. It must load, keep its first pair, and leave the
	// rest unused rather than failing.
	old := "7,1,0,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,3,1,1,2,0,2,1,20\n"
	items, err = LoadItemsCSV(strings.NewReader(old))
	if err != nil {
		t.Fatalf("LoadItemsCSV(old export): %v", err)
	}
	it = items[0]
	if it.ReqLevelType1 != 1 || it.ReqLevel1 != 20 {
		t.Errorf("old export slot 1 = (%d,%d), want (1,20)", it.ReqLevelType1, it.ReqLevel1)
	}
	if it.ReqLevelType2 != 0 || it.ReqLevelType3 != 0 || it.ReqLevelType4 != 0 {
		t.Errorf("old export should carry no later slots: %+v", it)
	}
}

// The skill CSV is a strict suffix: an export made before a column existed must
// still load, with that column's Go zero value.
//
// NoCombatParam is NEGATIVE for exactly this reason. False means "this skill
// does resolve a blow", which is what every export predating the column already
// meant -- so an old export keeps its behaviour instead of silently muting the
// 5.6% of skills that carry no combat parameter.
func TestSkillCSVNoCombatParamIsAStrictSuffix(t *testing.T) {
	// A 34-field row: everything up to and including ReqCastAll, and no more.
	old := make([]string, 34)
	for i := range old {
		old[i] = "0"
	}
	old[2] = "SKILL_TEST"
	sk, err := parseSkillRow(old)
	if err != nil {
		t.Fatalf("parseSkillRow on a pre-column export: %v", err)
	}
	if sk.NoCombatParam {
		t.Error("an export predating NoCombatParam loaded as true; it must default to false, meaning the skill still resolves a blow")
	}

	withCol := append(old, "1")
	sk, err = parseSkillRow(withCol)
	if err != nil {
		t.Fatalf("parseSkillRow with the column: %v", err)
	}
	if !sk.NoCombatParam {
		t.Error("NoCombatParam=1 did not load as true")
	}
}

// ZeroDamage is the second appended column and must behave the same way: an
// export predating it loads false, meaning "this skill's damage is computed".
func TestSkillCSVZeroDamageIsAStrictSuffix(t *testing.T) {
	old := make([]string, 35) // through NoCombatParam, no further
	for i := range old {
		old[i] = "0"
	}
	old[2] = "SKILL_TEST"
	sk, err := parseSkillRow(old)
	if err != nil {
		t.Fatalf("parseSkillRow on a pre-column export: %v", err)
	}
	if sk.ZeroDamage {
		t.Error("an export predating ZeroDamage loaded as true; it must default to false")
	}
	if sk, err = parseSkillRow(append(old, "1")); err != nil || !sk.ZeroDamage {
		t.Errorf("ZeroDamage=1 did not load as true (err=%v)", err)
	}
}

func TestSkillCSVFloorBlowIsAStrictSuffix(t *testing.T) {
	old := make([]string, 36) // through ZeroDamage, no further
	for i := range old {
		old[i] = "0"
	}
	old[2] = "SKILL_TEST"
	sk, err := parseSkillRow(old)
	if err != nil {
		t.Fatalf("parseSkillRow on a pre-column export: %v", err)
	}
	if sk.FloorBlow {
		t.Error("an export predating FloorBlow loaded as true; it must default to false")
	}
	if sk, err = parseSkillRow(append(old, "1")); err != nil || !sk.FloorBlow {
		t.Errorf("FloorBlow=1 did not load as true (err=%v)", err)
	}
}
