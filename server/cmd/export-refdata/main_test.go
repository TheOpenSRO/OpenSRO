package main

import (
	"encoding/csv"
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
	// Body armour's parry pair, the exact complement of the block pair: across
	// all 21,560 retail rows no item carries both, every non-zero block row is
	// a shield and no non-zero parry row is (round 377). A row setting both is
	// therefore not realistic -- this one does it so a single record exercises
	// each column, which is what the surrounding assertions need.
	set(fParryRatio, "4")
	set(fParryRatio+1, "5")
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
		{"ParryRatioMin", it.ParryRatioMin, 4},
		{"ParryRatioMax", it.ParryRatioMax, 5},
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

// TestRepairCostReadsTheBasisColumn pins the COLUMN, which is the thing no
// existing test could see.
//
// repair.TestFullRepairCostsExactlyTheBasis asserts that a full repair costs
// the basis. That is an identity of the formula -- true of whatever number is
// handed in -- so it described the arithmetic correctly while the exporter read
// the wrong column for three days. The two candidate columns are adjacent and
// carry an authored 1.5 ratio (the Copper Sword: 198 at column 27, 297 at
// column 28), so any test that feeds one number cannot tell them apart.
//
// This one gives the neighbours different values and names which must win.
// `refRecord+0xa4` is _RefObjCommon field 28 = text column 27; `+0xa8`, the
// flat restore cost, is field 29 = column 28.
func TestRepairCostReadsTheBasisColumn(t *testing.T) {
	cols := make([]string, 200)
	for i := range cols {
		cols[i] = "0"
	}
	set := func(i int, v string) { cols[i] = v }
	set(0, "1")
	set(1, "1")
	set(2, "ITEM_CH_SWORD_01_A")
	set(fPrice, "890")
	// The Copper Sword's real pair, kept distinct so a shift by one is visible.
	set(27, "198") // +0xa4, the price basis -- what a full repair costs
	set(28, "297") // +0xa8, the adjacent flat restore cost

	rec, ok := itemRecord(cols)
	if !ok {
		t.Fatal("itemRecord rejected a valid row")
	}
	items, err := refdata.LoadItemsCSV(strings.NewReader(strings.Join(rec, ",") + "\n"))
	if err != nil {
		t.Fatalf("the importer rejected export's own output: %v", err)
	}
	if got := items[0].RepairCost; got != 198 {
		t.Errorf("RepairCost = %d, want 198 (itemdata column 27, refRecord+0xa4). "+
			"297 means the exporter is reading column 28, which is +0xa8, the "+
			"flat restore cost -- an authored 1.5x that overcharges every repair",
			got)
	}
}

// CanUse is itemdata column 24 (round 489, docs/protocol/item_capability_flags.md
// round-460 table), and its neighbours are flag columns of the same 0/1 shape,
// so a test feeding one value cannot tell a shift from a hit. This gives 23 and
// 25 the opposite value and names which one must win, then runs each record
// through the importer so the two tools stay pinned to the same column.
//
// Column 24 also holds 129 on 213 retail rows; the parser keeps only
// `c != 0` (RefObjCommon_ExtractData, `-(cVar1 != 0) & 0x100`), so 129 must
// arrive as usable, not as a stray number.
func TestItemRecordReadsCanUseFromColumn24(t *testing.T) {
	for _, tc := range []struct {
		name              string
		c23, c24, c25, rc string
		want              bool
	}{
		{"clear between set neighbours", "1", "0", "1", "0", false},
		{"set between clear neighbours", "0", "1", "0", "1", true},
		{"129 is non-zero", "0", "129", "0", "1", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cols := make([]string, 200)
			for i := range cols {
				cols[i] = "0"
			}
			cols[0], cols[1], cols[2] = "1", "7001", "ITEM_CANUSE_PROBE"
			cols[23], cols[24], cols[25] = tc.c23, tc.c24, tc.c25

			rec, ok := itemRecord(cols)
			if !ok {
				t.Fatal("itemRecord rejected a valid row")
			}
			if got := rec[68]; got != tc.rc {
				t.Errorf("record[68] = %q, want %q (column 24 normalised to 0/1; columns 23 and 25 hold %q)",
					got, tc.rc, tc.c23)
			}
			items, err := refdata.LoadItemsCSV(strings.NewReader(strings.Join(rec, ",") + "\n"))
			if err != nil {
				t.Fatalf("the importer rejected export's own output: %v", err)
			}
			if items[0].CanUse != tc.want {
				t.Errorf("CanUse = %v, want %v", items[0].CanUse, tc.want)
			}
		})
	}
}

// CanPick is itemdata column 21 (round 493): RefObjCommon_ExtractData stores
// that column's byte at 0x6a3464 `mov [esp+0x23],dl` and turns it into flags
// bit 5 at 0x6a3590, the bit CGObj::CanPick (0x00483e50) reads. Its
// neighbours differ in shape -- 19 is the 0/128/223/255 packed column, 20
// the 0/1/3 one, 22 a 0/1 flag -- so each case below gives 19, 20 and 22
// values that would answer the OTHER way if the exporter read one of them,
// then runs the record through the importer so the two tools stay pinned to
// the same column.
func TestCanPickReadsColumn21(t *testing.T) {
	for _, tc := range []struct {
		name                   string
		c19, c20, c21, c22, rc string
		want                   bool
	}{
		{"set between clear neighbours", "128", "0", "1", "0", "1", true},
		{"clear between set neighbours", "255", "3", "0", "1", "0", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cols := make([]string, 200)
			for i := range cols {
				cols[i] = "0"
			}
			cols[0], cols[1], cols[2] = "1", "7002", "ITEM_CANPICK_PROBE"
			cols[19], cols[20], cols[21], cols[22] = tc.c19, tc.c20, tc.c21, tc.c22

			rec, ok := itemRecord(cols)
			if !ok {
				t.Fatal("itemRecord rejected a valid row")
			}
			if len(rec) <= 69 {
				t.Fatalf("record has %d fields, want CanPick at index 69", len(rec))
			}
			if got := rec[69]; got != tc.rc {
				t.Errorf("record[69] = %q, want %q (column 21; columns 19/20/22 hold %s/%s/%s)",
					got, tc.rc, tc.c19, tc.c20, tc.c22)
			}
			items, err := refdata.LoadItemsCSV(strings.NewReader(strings.Join(rec, ",") + "\n"))
			if err != nil {
				t.Fatalf("the importer rejected export's own output: %v", err)
			}
			if items[0].CanPick != tc.want {
				t.Errorf("CanPick = %v, want %v", items[0].CanPick, tc.want)
			}
		})
	}
}

// CodeName is itemdata column 2 (round 497): RefObjCommon_ExtractData's first
// string read (0x6a3130/0x6a3139, into ref+0x10), the string
// CGObj::GetCodeName returns and CheckCanPickUp compares with
// "ITEM_QNO_RM_ARCHEMY". Columns 3 and 4 (ObjName, OrgObjCodeName) are also
// strings, so each holds a different value and a read one column off shows.
// The value goes out verbatim -- an empty cell stays empty, not get's "0" --
// and comes back through the importer.
func TestCodeNameReadsColumn2(t *testing.T) {
	for _, tc := range []struct {
		name, c2, want string
	}{
		{"a quest item", "ITEM_QNO_RM_ARCHEMY_1", "ITEM_QNO_RM_ARCHEMY_1"},
		{"an empty cell", "", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cols := make([]string, 200)
			for i := range cols {
				cols[i] = "0"
			}
			cols[0], cols[1], cols[2], cols[3], cols[4] = "1", "23980", tc.c2, "OBJNAME_PROBE", "xxx"

			rec, ok := itemRecord(cols)
			if !ok {
				t.Fatal("itemRecord rejected a valid row")
			}
			if len(rec) <= 70 {
				t.Fatalf("record has %d fields, want CodeName at index 70", len(rec))
			}
			if got := rec[70]; got != tc.want {
				t.Errorf("record[70] = %q, want %q (column 2; column 3 holds OBJNAME_PROBE)", got, tc.want)
			}
			items, err := refdata.LoadItemsCSV(strings.NewReader(strings.Join(rec, ",") + "\n"))
			if err != nil {
				t.Fatalf("the importer rejected export's own output: %v", err)
			}
			if items[0].CodeName != tc.want {
				t.Errorf("CodeName = %q, want %q", items[0].CodeName, tc.want)
			}
		})
	}
}

// CanDrop is itemdata column 20 (round 494), not 19. RefObjCommon_ExtractData
// (0x006a3090) consumes column 18 without a load (0x6a33f0/0x6a33f6), stores
// column 19 at esp+0x12 and tests it only `& 0x80`/`& 0x40` (flags bits 12
// and 13), and stores column 20 at esp+0x13 (0x6a3441), whose `& 1` becomes
// flags bit 4, CanDrop (0x6a3540..0x6a3552). Before building the word it
// clears a CanDrop byte of exactly 1 when CanTrade is 0 (0x6a34e6..0x6a34f7).
//
// Each case gives column 19 a value whose bit 0 answers the OTHER way from
// the expected CanDrop wherever it can, so reading 19 fails. Cases d and e pin
// the coupling: it fires only on equality with 1, so 3 keeps bit 0. Case f
// pins that bit 1 (the unnamed bit 14) is not CanDrop.
func TestCanDropReadsColumn20WithTheTradeCoupling(t *testing.T) {
	for _, tc := range []struct {
		name          string
		c16, c19, c20 string
		rc            string
		want          bool
	}{
		{"a: column 19 set, column 20 clear", "1", "255", "0", "0", false},
		{"b: column 20 is 3, column 19 clear", "1", "0", "3", "1", true},
		{"c: column 20 is 1, column 19 is 128", "1", "128", "1", "1", true},
		{"d: untradeable and exactly 1 is cleared", "0", "255", "1", "0", false},
		{"e: untradeable and 3 keeps bit 0", "0", "0", "3", "1", true},
		// Column 19 at 255 so this case also fails the old column-19 reading
		// (round 495; it held 0, which passed either way).
		{"f: bit 1 alone is not CanDrop", "1", "255", "2", "0", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cols := make([]string, 200)
			for i := range cols {
				cols[i] = "0"
			}
			cols[0], cols[1], cols[2] = "1", "7003", "ITEM_CANDROP_PROBE"
			cols[16], cols[19], cols[20] = tc.c16, tc.c19, tc.c20

			rec, ok := itemRecord(cols)
			if !ok {
				t.Fatal("itemRecord rejected a valid row")
			}
			if got := rec[43]; got != tc.rc {
				t.Errorf("record[43] = %q, want %q (columns 16/19/20 hold %s/%s/%s)",
					got, tc.rc, tc.c16, tc.c19, tc.c20)
			}
			items, err := refdata.LoadItemsCSV(strings.NewReader(strings.Join(rec, ",") + "\n"))
			if err != nil {
				t.Fatalf("the importer rejected export's own output: %v", err)
			}
			if items[0].CanDrop != tc.want {
				t.Errorf("CanDrop = %v, want %v", items[0].CanDrop, tc.want)
			}
			if wantTrade := tc.c16 != "0"; items[0].CanTrade != wantTrade {
				t.Errorf("CanTrade = %v, want %v (column 16 is %s)", items[0].CanTrade, wantTrade, tc.c16)
			}
		})
	}
}

// Basic_ChainCode is skilldata column 9 (CRefSkill+0x68) and AutoAttackType is
// column 19 (CRefSkill+0x90), both by CRefSkill::CopyFixedColumns (0x6ab5a0);
// see docs/protocol/skill_fields.md. Until round 502 the exporter wrote a
// literal "0" into both record slots, so the keep-up hand-off (keepup.go's
// skillHandsOff, AutoAttackType == 1) never fired on a real export. The
// columns are written as literals here on purpose: the test pins the raw
// column, not whatever the constant says. The neighbours carry sentinels so a
// read one column off shows up as a wrong value rather than a lucky zero.
func TestSkillRecordCarriesAutoAttackTypeAndChainCode(t *testing.T) {
	for _, tc := range []struct {
		name          string
		col19, col9   string
		wantAAT       int
		wantChainCode int64
	}{
		// (a) Smash-shaped: a plain melee skill that hands off.
		{"type 1, no chain", "1", "0", 1, 0},
		// (b) a bolt or buff: no hand-off.
		{"type 0", "0", "0", 0, 0},
		// (c) the 322 real type-2 rows: carried through as 2, not folded to 1.
		{"type 2", "2", "0", 2, 0},
		// (d) a chain head: SKILL_CH_SWORD_SMASH_D_01's next link is 7140.
		{"chain head", "1", "7140", 1, 7140},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cols := skillRow()
			cols[1], cols[2], cols[3] = "3", "174", "SKILL_CH_SWORD_SMASH_A_01"
			cols[8], cols[10] = "2", "11"  // Basic_Activity, Basic_RecycleCost
			cols[18], cols[20] = "13", "1" // Overlap, InTown
			cols[19], cols[9] = tc.col19, tc.col9

			rec, ok := skillRecord(cols)
			if !ok {
				t.Fatal("skillRecord rejected a valid row")
			}
			if rec[15] != tc.col19 {
				t.Errorf("record[15] AutoAttackType = %q, want %q (raw column 19)", rec[15], tc.col19)
			}
			if rec[5] != tc.col9 {
				t.Errorf("record[5] Basic_ChainCode = %q, want %q (raw column 9)", rec[5], tc.col9)
			}
			skills, err := refdata.LoadSkillsCSV(strings.NewReader(strings.Join(rec, ",") + "\n"))
			if err != nil {
				t.Fatalf("the importer rejected export's own output: %v", err)
			}
			if len(skills) != 1 {
				t.Fatalf("parsed %d skills, want 1", len(skills))
			}
			if got := skills[0].AutoAttackType; got != tc.wantAAT {
				t.Errorf("AutoAttackType = %d, want %d", got, tc.wantAAT)
			}
			if got := skills[0].BasicChainCode; got != tc.wantChainCode {
				t.Errorf("BasicChainCode = %d, want %d", got, tc.wantChainCode)
			}
		})
	}
}

// Round 503: the self-heal columns. A flat 'heal' on an instant, untargeted row
// lands in record slots 43/44; Target_Required (raw column 22) or a non-zero
// action kind (raw column 68, the word before the Param block) zeroes them, as
// Skill_ApplyEffectsAndNotify's gates at 0x5942b1 and 0x5941f1 do.
func TestSelfHealColumns(t *testing.T) {
	heal := skillparam.WordOf("heal")
	if skActionKind != 68 || skTargetRequired != 22 {
		t.Fatalf("test premise: action kind at raw column %d, Target_Required at %d; want 68 and 22", skActionKind, skTargetRequired)
	}
	base := func() []string {
		cols := skillRow(heal, 300, 0, 0, 0)
		cols[1], cols[2], cols[3] = "143", "90", "SKILL_CH_WATER_SELFHEAL_A_01"
		return cols
	}
	for _, tc := range []struct {
		name   string
		edit   func([]string)
		hp, mp string
	}{
		{"instant untargeted flat heal", func([]string) {}, "300", "0"},
		{"Target_Required", func(c []string) { c[22] = "1" }, "0", "0"},
		{"timed buff action kind", func(c []string) { c[68] = "3" }, "0", "0"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cols := base()
			tc.edit(cols)
			hp, mp := selfHeal(cols)
			if hp != tc.hp || mp != tc.mp {
				t.Errorf("selfHeal = (%s, %s), want (%s, %s)", hp, mp, tc.hp, tc.mp)
			}
			rec, ok := skillRecord(cols)
			if !ok {
				t.Fatal("skillRecord rejected a valid row")
			}
			if len(rec) != 61 {
				t.Fatalf("record has %d fields, want 61 (SelfHealHP at 43, SelfHealMP at 44, CooldownGroup at 45, SitGate at 46, the buff columns 47-60)", len(rec))
			}
			if rec[43] != tc.hp || rec[44] != tc.mp {
				t.Errorf("record[43:45] = %v, want [%s %s]", rec[43:45], tc.hp, tc.mp)
			}
			skills, err := refdata.LoadSkillsCSV(strings.NewReader(strings.Join(rec, ",") + "\n"))
			if err != nil || len(skills) != 1 {
				t.Fatalf("the importer rejected export's own output: %v", err)
			}
			if got := strconv.Itoa(skills[0].SelfHealHP); got != tc.hp {
				t.Errorf("imported SelfHealHP = %s, want %s", got, tc.hp)
			}
		})
	}
}

// Round 504: the cooldown group is the HIGH byte of Action_Overlap, raw column
// 18 (the u32 at CRefSkill+0x8c; SkillCooldowns::IsReady 0x64c1a0 reads the
// byte at +0x8f), and lands in record slot 45. SKILL_CH_SWORD_SMASH_A_01's
// real column 18 is 33554432 = 2 << 24. The low bits carry other flags and
// must not leak into the group, so 335544402 (20 << 24 | 82) is group 20. The
// neighbours carry sentinels so a read one column off shows up.
func TestSkillRecordCarriesCooldownGroup(t *testing.T) {
	if skOverlap != 18 {
		t.Fatalf("test premise: Overlap at raw column %d, want 18", skOverlap)
	}
	for _, tc := range []struct {
		name, col18, want string
	}{
		{"Smash A, group 2", "33554432", "2"},
		{"group 20 with low bits set", "335544402", "20"},
		{"ungrouped", "0", "0"},
		{"empty column", "", "0"},
		{"low bits only", "13", "0"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cols := skillRow()
			cols[1], cols[2], cols[3] = "3", "174", "SKILL_CH_SWORD_SMASH_A_01"
			cols[17], cols[19] = "1", "1" // Interruptable, AutoAttackType
			cols[18] = tc.col18

			rec, ok := skillRecord(cols)
			if !ok {
				t.Fatal("skillRecord rejected a valid row")
			}
			if len(rec) <= 45 {
				t.Fatalf("record has %d fields, want CooldownGroup at index 45", len(rec))
			}
			if rec[45] != tc.want {
				t.Errorf("record[45] CooldownGroup = %q, want %q (raw column 18 >> 24)", rec[45], tc.want)
			}
			if rec[14] != "0" {
				t.Errorf("record[14] Overlap = %q, want the \"0\" placeholder", rec[14])
			}
			skills, err := refdata.LoadSkillsCSV(strings.NewReader(strings.Join(rec, ",") + "\n"))
			if err != nil || len(skills) != 1 {
				t.Fatalf("the importer rejected export's own output: %v", err)
			}
			if got := strconv.Itoa(skills[0].CooldownGroup); got != tc.want {
				t.Errorf("imported CooldownGroup = %s, want %s", got, tc.want)
			}
		})
	}
}

// Round 607: the SitGate column, the skill-use gate's two motion-state
// branches -- bit 1 for a skill carrying 'ao' or 'pw' (0x58e0ad/0x58e0b6), bit
// 2 for 'msch' with value[0] == 1 (0x58de46). Synthetic rows; the values are
// the Param block's own run lengths.
func TestSitGateColumn(t *testing.T) {
	ao, pw, msch := skillparam.WordOf("ao"), skillparam.WordOf("pw"), skillparam.WordOf("msch")
	ssou := skillparam.WordOf("ssou")
	for _, c := range []struct {
		name string
		row  []string
		want string
	}{
		{"no gate parameter", skillRow(), "0"},
		{"pw (a wall)", skillRow(pw, 7, 0, 0, 0), "1"},
		{"ao", skillRow(ao), "1"},
		{"msch kind 1 (the transform)", skillRow(msch, 1, 0), "2"},
		{"msch kind 2 is the other branch", skillRow(msch, 2, 0), "0"},
		{"pw and msch kind 1", skillRow(pw, 7, 0, 0, 0, msch, 1, 0), "3"},
		{"pw past the terminator is never parsed", skillRow(ssou, 0, 0, 0, 0, pw, 7, 0, 0, 0), "0"},
	} {
		if got := sitGate(c.row); got != c.want {
			t.Errorf("%s: sitGate = %s, want %s", c.name, got, c.want)
		}
		rec, ok := skillRecord(c.row)
		if !ok || len(rec) != 61 || rec[46] != c.want {
			t.Errorf("%s: record column 46 = %v (ok %v, %d fields), want %s", c.name, rec, ok, len(rec), c.want)
			continue
		}
		skills, err := refdata.LoadSkillsCSV(strings.NewReader(strings.Join(rec, ",") + "\n"))
		if err != nil || len(skills) != 1 || strconv.Itoa(skills[0].SitGate) != c.want {
			t.Errorf("%s: the importer read SitGate %v (err %v), want %s", c.name, skills, err, c.want)
		}
	}
}

// Round 616: the buff and self-cast columns 47..60, from synthetic rows with
// Grass Walk A lv1's and Ghost Walk B lv1's shapes (the retail values the
// spec MEASURED: kind 3, 'dura' 355462, 'hste' 20; kind 0, Target_Required
// and TargetType_Land 1, 'tele' 500, 100), through the exporter and back
// through the importer's own parser with a real CSV writer (BuffParams
// carries commas).
func TestBuffColumns(t *testing.T) {
	dura, hste, tele := skillparam.WordOf("dura"), skillparam.WordOf("hste"), skillparam.WordOf("tele")
	nbuf, lnks, defr := skillparam.WordOf("nbuf"), skillparam.WordOf("lnks"), skillparam.WordOf("defr")
	grass := skillRow(dura, 355462, hste, 20)
	grass[skActionKind] = "3"
	ghost := skillRow(tele, 500, 100)
	ghost[skTargetRequired], ghost[skTargetLand] = "1", "1"
	heal := skillRow()
	heal[skTargetRequired], heal[skTargetSelf], heal[skTargetAlly], heal[skTargetParty] = "1", "1", "1", "1"
	marked := skillRow(nbuf, lnks, 1, 2, 3, 4, defr, 10, 12)
	marked[skActionKind] = "3"
	for _, c := range []struct {
		name string
		row  []string
		want []string
	}{
		{"Grass Walk", grass, []string{"3", "0", "0", "0", "0", "0", "355462", "0", "0", "0", "0", "0", "0", "hste:20"}},
		{"Ghost Walk", ghost, []string{"0", "1", "1", "0", "0", "0", "0", "0", "0", "0", "0", "500", "100", ""}},
		{"a friendly heal", heal, []string{"0", "1", "0", "1", "1", "1", "0", "0", "0", "0", "0", "0", "0", ""}},
		{"nbuf, lnks and defr", marked, []string{"3", "0", "0", "0", "0", "0", "0", "0", "1", "0", "1", "0", "0", "defr:10,12"}},
	} {
		rec, ok := skillRecord(c.row)
		if !ok || len(rec) != 61 {
			t.Fatalf("%s: %d fields (ok %v)", c.name, len(rec), ok)
		}
		if got := strings.Join(rec[47:], "|"); got != strings.Join(c.want, "|") {
			t.Errorf("%s: columns 47..60 = %s, want %s", c.name, got, strings.Join(c.want, "|"))
		}
		var buf strings.Builder
		w := csv.NewWriter(&buf)
		w.Write(rec)
		w.Flush()
		skills, err := refdata.LoadSkillsCSV(strings.NewReader(buf.String()))
		if err != nil || len(skills) != 1 {
			t.Fatalf("%s: the importer rejected the export: %v", c.name, err)
		}
		sk := skills[0]
		if strconv.Itoa(sk.ActionKind) != c.want[0] || strconv.Itoa(sk.DuraMs) != c.want[6] ||
			strconv.Itoa(sk.Tele1) != c.want[12] || sk.BuffParams != c.want[13] || sk.Nbuf != (c.want[8] == "1") {
			t.Errorf("%s: imported %+v", c.name, sk)
		}
	}
}
