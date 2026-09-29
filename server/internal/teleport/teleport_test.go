package teleport

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// A SYNTHETIC network in the tables' shape: own ids, codes, regions and
// positions, never an archive's rows. Point 1 has three links whose file order
// (3, 2, 4) is not sorted, so an implementation that sorts fails the order
// check.
const (
	fixturePoints = `ID,Code,ObjectID,ZoneName,Region,X,Y,Z,Radius,Interaction7,Interaction9
1,GATE_TEST_A,9001,SN_ZONE_TEST_A,12345,100,5,200,70,1,0
2,GATE_TEST_B,9002,SN_ZONE_TEST_B,12600,300,0,400,70,1,1
3,GATE_NPC_TEST_FERRY,4242,SN_ZONE_TEST_C,12346,10,0,20,30,0,0
4,GATE_TEST_CAVE,0,SN_ZONE_TEST_D,-32000,-50,1,60,50,0,0
`
	fixtureLinks = `From,To,Fee,Rule1Type,Rule1Data1,Rule1Data2,Rule2Type,Rule2Data1,Rule2Data2,Rule3Type,Rule3Data1,Rule3Data2,Rule4Type,Rule4Data1,Rule4Data2,Rule5Type,Rule5Data1,Rule5Data2
1,3,500,2,0,0,0,,,0,,,0,,,0,,
1,2,5000,1,1,110,2,0,0,0,,,0,,,0,,
1,4,0,0,,,0,,,0,,,0,,,0,,
2,1,5000,2,0,0,0,0,0,0,0,0,0,0,0,0,0,0
`
	fixtureBuildings = `ID,Code,NameStrID,Region,X,Y,Z,Fortress
9001,STORE_TEST_A_GATE,SN_NPC_TEST_A_GATE,12345,110,4,210,FORTRESS_TEST
9002,STORE_TEST_B_GATE,SN_NPC_TEST_B_GATE,12600,310,0,410,xxx
`
)

func readFixture(t *testing.T) *Table {
	t.Helper()
	tb, err := Read(strings.NewReader(fixturePoints), strings.NewReader(fixtureLinks), strings.NewReader(fixtureBuildings))
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	return tb
}

func TestReadParsesAllThreeTables(t *testing.T) {
	tb := readFixture(t)
	if len(tb.Points) != 4 || len(tb.Links) != 4 || len(tb.Buildings) != 2 {
		t.Fatalf("got %d points, %d links, %d buildings; want 4, 4, 2", len(tb.Points), len(tb.Links), len(tb.Buildings))
	}
	p, ok := tb.PointByID(2)
	want := Point{ID: 2, Code: "GATE_TEST_B", ObjectID: 9002, ZoneName: "SN_ZONE_TEST_B", Region: 12600,
		X: 300, Y: 0, Z: 400, Radius: 70, Interaction7: true, Interaction9: true}
	if !ok || p != want {
		t.Errorf("PointByID(2) = %+v, %v; want %+v", p, ok, want)
	}
	if p, ok := tb.PointByID(4); !ok || p.Region != -32000 || p.X != -50 {
		t.Errorf("PointByID(4) = %+v, %v; a negative (dungeon) region and position must parse", p, ok)
	}
	if _, ok := tb.PointByID(99); ok {
		t.Error("PointByID(99) found a point the fixture does not have")
	}
	b := tb.Buildings[0]
	if b.ID != 9001 || b.Code != "STORE_TEST_A_GATE" || b.NameStrID != "SN_NPC_TEST_A_GATE" ||
		b.Region != 12345 || b.X != 110 || b.Y != 4 || b.Z != 210 || b.Fortress != "FORTRESS_TEST" {
		t.Errorf("building 0 = %+v", b)
	}
	if tb.Buildings[1].Fortress != "" {
		t.Errorf("the table's xxx placeholder must read as no fortress, got %q", tb.Buildings[1].Fortress)
	}
	// A type-0 slot is empty: only non-zero types become rules, in order.
	l, ok := tb.LinkBetween(1, 2)
	if !ok || l.Fee != 5000 || !reflect.DeepEqual(l.Rules, []Rule{{1, 1, 110}, {2, 0, 0}}) {
		t.Errorf("LinkBetween(1, 2) = %+v, %v", l, ok)
	}
	if l, ok := tb.LinkBetween(1, 4); !ok || l.Fee != 0 || len(l.Rules) != 0 {
		t.Errorf("LinkBetween(1, 4) = %+v, %v; want a free link with no rules", l, ok)
	}
	if _, ok := tb.LinkBetween(2, 3); ok {
		t.Error("LinkBetween(2, 3) found a link the fixture does not have")
	}
}

func TestPointByBuildingCodeJoinsThroughTheBuilding(t *testing.T) {
	tb := readFixture(t)
	p, ok := tb.PointByBuildingCode("STORE_TEST_A_GATE")
	if !ok || p.ID != 1 {
		t.Errorf("PointByBuildingCode(STORE_TEST_A_GATE) = %+v, %v; want point 1", p, ok)
	}
	// Point 3's object (4242) is not a building (a ferry NPC in the real
	// table), and an unknown code finds nothing.
	if p, ok := tb.PointByBuildingCode("STORE_NO_SUCH_GATE"); ok {
		t.Errorf("an unknown building code found %+v", p)
	}
}

func TestLinksFromKeepsFileOrder(t *testing.T) {
	tb := readFixture(t)
	var got []int
	for _, l := range tb.LinksFrom(1) {
		got = append(got, l.To)
	}
	if !reflect.DeepEqual(got, []int{3, 2, 4}) {
		t.Errorf("LinksFrom(1) destinations = %v, want [3 2 4] (file order)", got)
	}
	if n := len(tb.LinksFrom(3)); n != 0 {
		t.Errorf("LinksFrom(3) = %d links, want 0", n)
	}
}

func TestQuoteFee(t *testing.T) {
	paid := Link{From: 1, To: 2, Fee: 5000}
	free := Link{From: 1, To: 4, Fee: 0}
	cases := []struct {
		name     string
		link     Link
		level    int
		gm, flag bool
		fee      int64
		waiver   Waiver
	}{
		{"level 21 pays the link's fee", paid, 21, false, false, 5000, WaiverNone},
		// NEGATIVE against a naive implementation that always charges.
		{"level 20 is waived by the engine's rule", paid, 20, false, false, 0, WaiverLevel},
		{"level 1 is waived", paid, 1, false, false, 0, WaiverLevel},
		{"a GM at level 50 travels free", paid, 50, true, false, 0, WaiverGM},
		{"the testing flag makes it free", paid, 50, false, true, 0, WaiverFlag},
		{"the engine's waiver is reported before the GM one", paid, 20, true, true, 0, WaiverLevel},
		{"the GM waiver is reported before the flag", paid, 50, true, true, 0, WaiverGM},
		{"a free link waives nothing", free, 5, true, true, 0, WaiverNone},
	}
	for _, c := range cases {
		fee, w := QuoteFee(c.link, c.level, c.gm, c.flag)
		if fee != c.fee || w != c.waiver {
			t.Errorf("%s: QuoteFee = %d, %d; want %d, %d", c.name, fee, w, c.fee, c.waiver)
		}
	}
}

func TestCheckRestrictions(t *testing.T) {
	link := func(rules ...Rule) Link { return Link{From: 1, To: 2, Fee: 5000, Rules: rules} }
	cases := []struct {
		name  string
		link  Link
		level int
		want  uint16
	}{
		{"(1,1,110) at 110 passes", link(Rule{1, 1, 110}), 110, 0},
		{"(1,1,110) at 1 passes", link(Rule{1, 1, 110}), 1, 0},
		// NEGATIVE: above the range and below it refuse 0x1c15.
		{"(1,1,110) at 111 refuses", link(Rule{1, 1, 110}), 111, ErrLevelRange},
		{"(1,80,102) at 79 refuses", link(Rule{1, 80, 102}), 79, ErrLevelRange},
		{"(2,0,0): no trade cart, passes", link(Rule{2, 0, 0}), 50, 0},
		{"(7,0,0): no trade cart, passes", link(Rule{7, 0, 0}), 50, 0},
		{"(4,23973,0): the item is not checked, refuses", link(Rule{4, 23973, 0}), 50, ErrRocItem},
		{"(5,23973,0) refuses", link(Rule{5, 23973, 0}), 50, ErrRocItem},
		{"(4,0,0): no item named, passes", link(Rule{4, 0, 0}), 50, 0},
		{"(6,0,0): no job state, refuses", link(Rule{6, 0, 0}), 50, ErrRocJob},
		{"(6,1,0): the assert arm passes", link(Rule{6, 1, 0}), 50, 0},
		{"an unknown type passes", link(Rule{9, 1, 1}), 50, 0},
		{"no rules pass", link(), 50, 0},
		{"the first failing rule's code wins", link(Rule{2, 0, 0}, Rule{1, 1, 110}, Rule{6, 0, 0}), 111, ErrLevelRange},
	}
	for _, c := range cases {
		if got := CheckRestrictions(c.link, c.level, PvPNeutral); got != c.want {
			t.Errorf("%s: CheckRestrictions = %#x, want %#x", c.name, got, c.want)
		}
	}
}

// Rule type 3 refuses iff D1 has the bit for the character's PvP state
// (`shl edx,cl; test [esi+0x4],edx` at 0x513b51, cl the chardata's PvPSTATE
// byte): D1 is a mask of barred states, not a switch.
func TestCheckRestrictionsPvPStateMask(t *testing.T) {
	link := func(d1 int) Link { return Link{From: 1, To: 2, Rules: []Rule{{3, d1, 0}}} }
	cases := []struct {
		name string
		d1   int
		pvp  PvPState
		want uint16
	}{
		{"an empty mask passes a neutral character", 0, PvPNeutral, 0},
		{"an empty mask passes a murderer", 0, PvPMurderer, 0},
		{"bit 0 bars a neutral character", 1, PvPNeutral, ErrPvPState},
		// NEGATIVE against the "D1 non-zero refuses" rule: a mask barring
		// only assaulters lets a neutral character through.
		{"D1 = 2 (assaulters only) passes a neutral character", 2, PvPNeutral, 0},
		{"D1 = 2 bars an assaulter", 2, PvPAssaulter, ErrPvPState},
		{"D1 = 1 (neutral only) passes an assaulter", 1, PvPAssaulter, 0},
		{"D1 = 4 bars a murderer", 4, PvPMurderer, ErrPvPState},
		{"D1 = 3 passes a murderer", 3, PvPMurderer, 0},
		{"D1 = 7 bars every state", 7, PvPAssaulter, ErrPvPState},
	}
	for _, c := range cases {
		if got := CheckRestrictions(link(c.d1), 50, c.pvp); got != c.want {
			t.Errorf("%s: CheckRestrictions((3,%d,0), pvp %d) = %#x, want %#x", c.name, c.d1, c.pvp, got, c.want)
		}
	}
}

func TestReadRefusesBrokenTables(t *testing.T) {
	headerless := func(s string) string { return s[strings.Index(s, "\n")+1:] }
	cases := []struct {
		name                     string
		points, links, buildings string
	}{
		{"points without a header", headerless(fixturePoints), fixtureLinks, fixtureBuildings},
		{"links without a header", fixturePoints, headerless(fixtureLinks), fixtureBuildings},
		{"buildings without a header", fixturePoints, fixtureLinks, headerless(fixtureBuildings)},
		{"an empty points file", "", fixtureLinks, fixtureBuildings},
		{"a link to a point the table lacks", fixturePoints, fixtureLinks + "2,77,0,0,,,0,,,0,,,0,,,0,,\n", fixtureBuildings},
		{"a duplicate point id", fixturePoints + "2,GATE_TEST_DUP,0,SN_X,1,1,1,1,1,0,0\n", fixtureLinks, fixtureBuildings},
		{"a duplicate link", fixturePoints, fixtureLinks + "1,2,5000,0,,,0,,,0,,,0,,,0,,\n", fixtureBuildings},
		{"a negative fee", fixturePoints, fixtureLinks + "2,3,-5,0,,,0,,,0,,,0,,,0,,\n", fixtureBuildings},
		{"a non-zero rule with blank data", fixturePoints, fixtureLinks + "2,3,5,1,,,0,,,0,,,0,,,0,,\n", fixtureBuildings},
		{"a short row", fixturePoints + "5,GATE_SHORT,0\n", fixtureLinks, fixtureBuildings},
	}
	for _, c := range cases {
		if _, err := Read(strings.NewReader(c.points), strings.NewReader(c.links), strings.NewReader(c.buildings)); err == nil {
			t.Errorf("%s: Read accepted it", c.name)
		}
	}
}

func TestLoadReadsADirectory(t *testing.T) {
	dir := t.TempDir()
	for name, body := range map[string]string{PointsFile: fixturePoints, LinksFile: fixtureLinks, BuildingsFile: fixtureBuildings} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	tb, err := Load(dir)
	if err != nil || len(tb.Points) != 4 {
		t.Fatalf("Load = %v, %v", tb, err)
	}
	if err := os.Remove(filepath.Join(dir, LinksFile)); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(dir); err == nil {
		t.Error("Load accepted a directory without teleportlink.csv")
	}
}

// Round 642: teleportdata.csv's twelfth column, WorldID (teleportdata.txt
// column 12, Point.WorldID), is read; a CSV exported before round 642 ends at
// Interaction9 and still loads, every point's WorldID 0 (unknown). A header
// with any other twelfth name is still refused. And PointByObject finds a
// point by its NPC as well as by its building.
func TestReadTakesTheWorldColumnAndTheOlderHeader(t *testing.T) {
	withWorld := strings.Replace(fixturePoints, "Interaction9\n", "Interaction9,WorldID\n", 1)
	withWorld = strings.Replace(withWorld, "70,1,0\n", "70,1,0,1\n", 1)
	withWorld = strings.Replace(withWorld, "70,1,1\n", "70,1,1,2\n", 1)
	withWorld = strings.Replace(withWorld, "30,0,0\n", "30,0,0,1\n", 1)
	withWorld = strings.Replace(withWorld, "50,0,0\n", "50,0,0,1\n", 1)
	tb, err := Read(strings.NewReader(withWorld), strings.NewReader(fixtureLinks), strings.NewReader(fixtureBuildings))
	if err != nil {
		t.Fatalf("Read with WorldID: %v", err)
	}
	if p, _ := tb.PointByID(2); p.WorldID != 2 {
		t.Errorf("point 2's WorldID = %d; want 2", p.WorldID)
	}
	if p, _ := tb.PointByID(1); p.WorldID != MainWorld {
		t.Errorf("point 1's WorldID = %d; want %d", p.WorldID, MainWorld)
	}
	old := readFixture(t)
	for _, p := range old.Points {
		if p.WorldID != 0 {
			t.Errorf("an 11-column CSV gave point %d WorldID %d; want 0 (unknown)", p.ID, p.WorldID)
		}
	}
	bad := strings.Replace(withWorld, "Interaction9,WorldID\n", "Interaction9,World\n", 1)
	if _, err := Read(strings.NewReader(bad), strings.NewReader(fixtureLinks), strings.NewReader(fixtureBuildings)); err == nil {
		t.Error("Read accepted a twelfth column that is not WorldID")
	}
	if p, ok := tb.PointByObject(4242); !ok || p.Code != "GATE_NPC_TEST_FERRY" {
		t.Errorf("PointByObject(4242) = %+v, %v; want the NPC's point", p, ok)
	}
	if p, ok := tb.PointByObject(9001); !ok || p.ID != 1 {
		t.Errorf("PointByObject(9001) = %+v, %v; want the building's point", p, ok)
	}
	if _, ok := tb.PointByObject(0); ok {
		t.Error("PointByObject(0) found a point: 0 is 'no object'")
	}
}
