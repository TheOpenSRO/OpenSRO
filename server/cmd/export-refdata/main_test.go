package main

import (
	"strings"
	"testing"

	"github.com/OpenSRO/srrevamp/server/internal/refdata"
	"strconv"

	"github.com/OpenSRO/srrevamp/server/internal/skillparam"
)

// A synthetic itemdata row with the Copper Sword's real, verified values at
// the columns itemRecord maps, run through export's itemRecord and then the
// importer's own LoadItemsCSV -- so the two tools are pinned to the same
// column mapping. The values are the ones a real Copper Sword (+5) tooltip
// confirmed (see the package doc and ITEM_FORMAT.md).
func TestItemRecordRoundTripsThroughTheImporter(t *testing.T) {
	cols := make([]string, 120)
	for i := range cols {
		cols[i] = "0"
	}
	set := func(i int, v string) { cols[i] = v }
	set(fID, "3632")
	set(fTypeID1, "3")
	set(fTypeID1+1, "1")
	set(fTypeID1+2, "6") // weapon family
	set(fTypeID1+3, "2") // sword
	set(fCountry, "0")
	set(fReqGender, "2")
	set(fReqLevelType1, "1")
	set(fReqLevel1, "1")
	set(fReqStr, "20")
	set(fReqInt, "0")
	set(fDurabilityMin, "62")
	set(fDurabilityMin+1, "76")
	set(fPhysAttackMin, "15")
	set(fPhysAttackMax, "16")
	set(fMagAttackMin, "25")
	set(fMagAttackMax, "28")
	set(fHitRate, "24")
	set(fHitRate+1, "30")
	set(fCritical, "3")
	set(fCritical+1, "15")
	// col 114/117 are the variance ceilings of attack rate and critical, and
	// they ARE exported -- restored 2026-09-15 after the argument that
	// withdrew them turned out to rest on a false premise. The assertions
	// below pin the real values rather than the zeros that used to ship.
	// The Copper Sword's real reinforce quad, which is also the floor of each
	// of these four columns across every weapon row in the table. The
	// neighbouring odd columns carry the per-instance variance high end and
	// must NOT be what gets exported, so they are set to sentinels.
	set(fReinforcePhysMin, "306")
	set(fReinforcePhysMin+1, "999")
	set(fReinforcePhysMax, "342")
	set(fReinforcePhysMax+1, "999")
	set(fReinforceMagMin, "490")
	set(fReinforceMagMin+1, "999")
	set(fReinforceMagMax, "548")
	set(fReinforceMagMax+1, "999")
	set(fPrice, "890")     // the Copper Sword's real buy price
	set(fSellPrice, "427") // and its real buy-back price
	// A sentinel (a real sword is 1) so this fails if MaxStack is hardcoded
	// again instead of read from its column.
	set(fMaxStack, "99")

	rec, ok := itemRecord(cols)
	if !ok {
		t.Fatal("itemRecord rejected a valid row")
	}
	// The width grows as verified columns are appended -- 30 before the
	// Param-block restore amounts, 34 before the shield block ratio, 36
	// before the weapon reinforce quad, 44 before the three requirement
	// slots past the first. The importer takes each addition as an optional
	// suffix, so every older export still loads; this only pins that the
	// exporter and importer agree on the CURRENT width, which is the half
	// that would otherwise drift. Read from the importer rather than
	// repeated here, so appending a column cannot break this test.
	if len(rec) != refdata.ItemCSVColumnCount {
		t.Fatalf("record has %d fields, want the importer's %d", len(rec), refdata.ItemCSVColumnCount)
	}

	items, err := refdata.LoadItemsCSV(strings.NewReader(strings.Join(rec, ",") + "\n"))
	if err != nil {
		t.Fatalf("the importer rejected export's own output: %v", err)
	}
	if len(items) != 1 {
		t.Fatalf("parsed %d items, want 1", len(items))
	}
	it := items[0]
	if it.ID != 3632 {
		t.Errorf("ID = %d, want 3632", it.ID)
	}
	if it.PhysAttackMax != 16 {
		t.Errorf("PhysAttackMax = %v, want 16 (the value combat reads)", it.PhysAttackMax)
	}
	if it.PhysAttackMin != 15 || it.MagAttackMin != 25 || it.MagAttackMax != 28 {
		t.Errorf("attack = %v..%v phys / %v..%v mag, want 15..16 / 25..28",
			it.PhysAttackMin, it.PhysAttackMax, it.MagAttackMin, it.MagAttackMax)
	}
	if it.Price != 890 || it.SellPrice != 427 {
		t.Errorf("price = %d buy / %d sell, want 890 / 427", it.Price, it.SellPrice)
	}
	if it.MaxStack != 99 {
		t.Errorf("MaxStack = %d, want 99 (read from its column, not hardcoded)", it.MaxStack)
	}
	if it.DurabilityMin != 62 || it.DurabilityMax != 76 {
		t.Errorf("durability = %v/%v, want 62/76", it.DurabilityMin, it.DurabilityMax)
	}
	if it.TypeID3 != 6 || it.TypeID4 != 2 {
		t.Errorf("typeids = %d/%d, want family 6, sword 2", it.TypeID3, it.TypeID4)
	}
	if it.Country != 0 || it.ReqGender != 2 || it.ReqLevel1 != 1 {
		t.Errorf("country/gender/reqlevel = %d/%d/%d, want 0/2/1", it.Country, it.ReqGender, it.ReqLevel1)
	}
	// The reinforce quad has to arrive with the right VALUES, not merely
	// occupy the right number of columns: a 999 here would mean the exporter
	// reached for the variance column beside each one. This assertion exists
	// because an earlier append shipped a column that was never actually
	// written, and only the width was being checked.
	if it.ReinforcePhysMin != 306 || it.ReinforcePhysMax != 342 {
		t.Errorf("physical reinforce = %v/%v, want 306/342 (the low end, not the variance ceiling)",
			it.ReinforcePhysMin, it.ReinforcePhysMax)
	}
	if it.ReinforceMagMin != 490 || it.ReinforceMagMax != 548 {
		t.Errorf("magical reinforce = %v/%v, want 490/548 (the low end, not the variance ceiling)",
			it.ReinforceMagMin, it.ReinforceMagMax)
	}
}

// A row too short to hold the mapped columns, or with a non-numeric id, is
// not an item and is skipped rather than mis-parsed.
func TestItemRecordSkipsNonItemRows(t *testing.T) {
	if _, ok := itemRecord([]string{"1", "not-a-number", "x"}); ok {
		t.Error("a short row was accepted as an item")
	}
	long := make([]string, 120)
	for i := range long {
		long[i] = "0"
	}
	long[fID] = "xxx"
	if _, ok := itemRecord(long); ok {
		t.Error("a row with a non-numeric id was accepted")
	}
}

// The armour defence and shield block columns are exported, not zeroed.
//
// Until 2026-09-15 this exporter emitted a literal "0" for both defences,
// carrying a note that they were "armour, not verified" -- which stopped being
// true when docs/protocol/ITEM_FORMAT.md grounded them three ways (the real DB
// column order, heavy-vs-cloth behaviour, and a real +5 tooltip). Every
// deployment importing through this tool gave armour no defence at all. This
// test is the thing that would have caught it.
func TestItemRecordCarriesArmourDefenceAndBlock(t *testing.T) {
	cols := make([]string, fMax+2)
	for i := range cols {
		cols[i] = "0"
	}
	set := func(i int, v string) { cols[i] = v }
	set(fID, "11")
	set(fMaxStack, "1")
	// A Cotton garment's real readings, and a shield's real block ratio.
	set(fPhysDefenseMin, "2")
	set(fPhysDefenseMin+1, "2.5")
	set(fMagDefenseMin, "4.3")
	set(fMagDefenseMin+1, "5.2")
	set(fBlockRatio, "10")
	set(fBlockRatio+1, "20")
	set(fTwoHanded, "1")
	set(fItemClass, "7")

	rec, ok := itemRecord(cols)
	if !ok {
		t.Fatal("itemRecord rejected a valid row")
	}
	items, err := refdata.LoadItemsCSV(strings.NewReader(strings.Join(rec, ",") + "\n"))
	if err != nil {
		t.Fatalf("the importer rejected export's own output: %v", err)
	}
	if len(items) != 1 {
		t.Fatalf("got %d items, want 1", len(items))
	}
	it := items[0]
	for _, tc := range []struct {
		name string
		got  float64
		want float64
	}{
		{"PhysDefenseMin", it.PhysDefenseMin, 2},
		{"PhysDefenseMax", it.PhysDefenseMax, 2.5},
		{"MagDefenseMin", it.MagDefenseMin, 4.3},
		{"MagDefenseMax", it.MagDefenseMax, 5.2},
		{"BlockRatioMin", it.BlockRatioMin, 10},
		{"BlockRatioMax", it.BlockRatioMax, 20},
	} {
		if tc.got != tc.want {
			t.Errorf("%s = %v, want %v", tc.name, tc.got, tc.want)
		}
	}
	// TwoHanded travels the same route, and nearly did not: the edit that
	// was supposed to map it in v0.1.169 silently matched nothing, so the
	// column constant was defined and never used and the equipment rule that
	// depends on it was inert in production. Nothing caught it, because the
	// round-trip test only checked the record's WIDTH and this test only
	// checked defence and block. It checks TwoHanded now.
	if !it.TwoHanded {
		t.Error("TwoHanded = false, want true -- column 93 is not reaching the importer")
	}
	// ItemClass reaches the client through the shop listing, so a zero here
	// is visible, not just internal. The server's own deserialiser asserts
	// "m_btItemClass > 0", which is what identifies column 61.
	if it.ItemClass != 7 {
		t.Errorf("ItemClass = %d, want 7 -- column 61 is not reaching the importer", it.ItemClass)
	}
}

// The two Max columns that the verified tooltip contradicts are exported as
// zero, not as the neighbouring column.
//
// A Copper Sword reads 24 at col 113 and 30 at 114, 3 at col 116 and 15 at 117,
// and its +5 tooltip showed "Attack rate 24" and "Critical 3" -- single values.
// This pins that the exporter does not hand 30 and 15 out under a max's name,
// where the next reader would take them for the stat.
func TestUnverifiedMaxColumnsAreNotExported(t *testing.T) {
	cols := make([]string, fMax+2)
	for i := range cols {
		cols[i] = "0"
	}
	cols[fID] = "71"
	cols[fMaxStack] = "1"
	// The Copper Sword's real readings.
	cols[fHitRate] = "24"
	cols[fHitRate+1] = "30"
	cols[fCritical] = "3"
	cols[fCritical+1] = "15"

	rec, ok := itemRecord(cols)
	if !ok {
		t.Fatal("itemRecord rejected a valid row")
	}
	items, err := refdata.LoadItemsCSV(strings.NewReader(strings.Join(rec, ",") + "\n"))
	if err != nil {
		t.Fatalf("the importer rejected export's own output: %v", err)
	}
	it := items[0]
	if it.HitRateMin != 24 {
		t.Errorf("HitRateMin = %v, want the verified 24", it.HitRateMin)
	}
	if it.CriticalMin != 3 {
		t.Errorf("CriticalMin = %v, want the verified 3", it.CriticalMin)
	}
	// The variance ceilings, restored. These were literal zeros until
	// 2026-09-15; the fixture sets 30 and 15, and both must now arrive.
	if it.HitRateMax != 30 {
		t.Errorf("HitRateMax = %v, want 30 -- col 114, attack rate's variance ceiling", it.HitRateMax)
	}
	if it.CriticalMax != 15 {
		t.Errorf("CriticalMax = %v, want 15 -- col 117, critical's variance ceiling", it.CriticalMax)
	}
	// And the engine's own precondition holds on the fixture, as it does on
	// every real row: the floor never exceeds the ceiling.
	if it.HitRateMin > it.HitRateMax || it.CriticalMin > it.CriticalMax {
		t.Errorf("a variance pair is inverted: hit rate %v..%v, critical %v..%v",
			it.HitRateMin, it.HitRateMax, it.CriticalMin, it.CriticalMax)
	}
}

// TestSameRecordComparesNumbersAsNumbers covers the distinction that makes the
// duplicate report useful. A real client's itemdata shards overlap on 6,224 of
// 15,338 ids, but 5,616 of those differ only in how a number is written -- "0"
// in one table against "0.0" in another. Reporting those as conflicts would
// bury the 608 that genuinely disagree.
func TestSameRecordComparesNumbersAsNumbers(t *testing.T) {
	for _, tc := range []struct {
		name string
		a, b []string
		want bool
	}{
		{"identical", []string{"4", "60", "0"}, []string{"4", "60", "0"}, true},
		{"0 against 0.0 is the same value", []string{"4", "0"}, []string{"4", "0.0"}, true},
		{"1.3 against 1.30 is the same value", []string{"7", "1.3"}, []string{"7", "1.30"}, true},
		{"1.3 against 1.25 is a real conflict", []string{"7", "1.3"}, []string{"7", "1.25"}, false},
		{"text fields still compare exactly", []string{"ITEM_A"}, []string{"ITEM_B"}, false},
		{"a number against text is a conflict", []string{"1"}, []string{"one"}, false},
		{"different lengths are never equal", []string{"1", "2"}, []string{"1"}, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := sameRecord(tc.a, tc.b); got != tc.want {
				t.Errorf("sameRecord(%v, %v) = %v, want %v", tc.a, tc.b, got, tc.want)
			}
		})
	}
}

// skillRow builds a synthetic 119-column skilldata row whose Param block (from
// skillparam.ParamBlockColumn) holds the given words. No real row is used.
func skillRow(words ...int32) []string {
	cols := make([]string, 119)
	for i := range cols {
		cols[i] = "0"
	}
	for i, w := range words {
		cols[skillparam.ParamBlockColumn+i] = strconv.Itoa(int(w))
	}
	return cols
}

func TestSkillDamageClassColumns(t *testing.T) {
	att := skillparam.WordOf("att")
	ck := skillparam.WordOf("ck")
	bl := skillparam.WordOf("bl")
	dura := skillparam.WordOf("dura")
	// 'ssou' is the block terminator: the parser returns at it, so a walk
	// COMPLETES there and anything after it is never parsed -- by the engine or
	// by us.
	ssou := skillparam.WordOf("ssou")
	if skillparam.Kind["ssou"] != skillparam.KindTerminator {
		t.Fatal("test premise: ssou must be the terminator")
	}

	for _, c := range []struct {
		name                    string
		cols                    []string
		noCombat, zero, floorBl string
	}{
		{"ordinary att skill", skillRow(att, 5, 143, 15, 18, 0), "0", "0", "0"},
		{"att with a percent of 0", skillRow(att, 8, 0, 0, 0, 0), "0", "0", "1"},
		{"att with neither damage bit", skillRow(att, 1, 121, 0, 0, 0), "0", "0", "1"},
		{"ck alone", skillRow(ck, 100), "0", "0", "1"},
		{"a combat parameter but no att/ck", skillRow(bl, 1, 2, 3, 4, 5), "0", "1", "0"},
		{"no combat parameter at all", skillRow(dura, 30000), "1", "1", "0"},
		// The terminator completes the walk with no att/ck seen -> zero-damage.
		{"terminator, no combat param", skillRow(ssou), "1", "1", "0"},
		// An 'att' placed AFTER the terminator is never parsed -- the engine
		// returns at ssou -- so the skill genuinely has no working att and is
		// zero-damage. The old whole-row scan wrongly reached past it.
		{"att after the terminator is dead", skillRow(ssou, att, 5, 143, 15, 18, 0), "1", "1", "0"},
		// An unknown word leaves the walk undecided; literal absence then proves
		// no att/ck is anywhere in the row.
		{"undecided walk, literals absent", skillRow(0x7fffffff, 7, 7), "1", "1", "0"},
	} {
		if got := noCombatParam(c.cols); got != c.noCombat {
			t.Errorf("%s: noCombatParam = %s, want %s", c.name, got, c.noCombat)
		}
		if got := zeroDamage(c.cols); got != c.zero {
			t.Errorf("%s: zeroDamage = %s, want %s", c.name, got, c.zero)
		}
		if got := floorBlow(c.cols); got != c.floorBl {
			t.Errorf("%s: floorBlow = %s, want %s", c.name, got, c.floorBl)
		}
		// The three damage classes must never overlap.
		if zeroDamage(c.cols) == "1" && floorBlow(c.cols) == "1" {
			t.Errorf("%s: both zero-damage and floor-blow", c.name)
		}
		// And no-combat must sit inside zero-damage.
		if noCombatParam(c.cols) == "1" && zeroDamage(c.cols) != "1" {
			t.Errorf("%s: no-combat but not zero-damage; the first must be inside the second", c.name)
		}
	}
}

// Absence of a code word from the whole row is proof; PRESENCE is not, because
// the same integer can be another column's value. When a walk is UNDECIDED (an
// unknown word), a row that has the att literal only OUTSIDE the block -- as a
// skill id, say -- must not be declared zero-damage on the strength of the walk
// having found nothing: absence was not proved.
func TestLiteralAbsenceIsOnlyUsedInTheSoundDirection(t *testing.T) {
	cols := skillRow(0x7fffffff, 7, 7)                    // an unknown word -> the walk cannot finish
	cols[1] = strconv.Itoa(int(skillparam.WordOf("att"))) // the literal, but as the ID column
	if got := zeroDamage(cols); got != "0" {
		t.Errorf("zeroDamage = %s with the att literal present in the row; absence was not proved, so it must answer 0", got)
	}
}

// The cooltime pair comes from whichever (Param, Desc128) element reads
// "COOLTIME:<group>" -- the parser's own rule, case-insensitive with a decimal
// or 0x-hex group -- and a row without one exports 0/0. The retail cure pill
// ITEM_ETC_CURE_RANDOM_01 (10374) carries its pair in element 4: 20000 ms,
// group 0xC8 (round 263).
func TestItemRecordFindsTheCooltimeDescriptor(t *testing.T) {
	cols := make([]string, 160)
	for i := range cols {
		cols[i] = "0"
	}
	for k := 0; k < 20; k++ {
		cols[fParam1+2*k+1] = "xxx"
	}
	cols[fID] = "10374"
	cols[fParam1+2*3] = "20000"
	cols[fParam1+2*3+1] = "COOLTIME:0x000000C8"
	if g, ms := cooltimeOf(cols); g != "200" || ms != "20000" {
		t.Fatalf("cooltimeOf = %s,%s; want 200 (0xC8), 20000", g, ms)
	}
	rec, ok := itemRecord(cols)
	if !ok {
		t.Fatal("itemRecord rejected the row")
	}
	if rec[64] != "200" || rec[65] != "20000" {
		t.Fatalf("columns 64/65 = %s/%s; want 200/20000", rec[64], rec[65])
	}
	// Decimal groups and mixed case are the same rule.
	cols[fParam1+2*3+1] = "cooltime:7"
	if g, _ := cooltimeOf(cols); g != "7" {
		t.Fatalf("decimal group: %s; want 7", g)
	}
	// No descriptor, no delay -- an HP potion's row.
	cols[fParam1+2*3+1] = "HP"
	if g, ms := cooltimeOf(cols); g != "0" || ms != "0" {
		t.Fatalf("a row without the descriptor exports 0/0, got %s/%s", g, ms)
	}
}
