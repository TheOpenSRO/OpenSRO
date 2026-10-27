package mall

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
)

// Round 837's tests. Every table here is synthetic (docs/LEGAL.md): made-up
// codes in the files' column layouts, never a row of a real archive.

func row(cols ...string) []string { return cols }

// pad appends n "xxx"/-1 parameter columns, as the files carry.
func pad(r []string, n int) []string {
	for i := 0; i < n; i++ {
		r = append(r, "-1")
	}
	return r
}

// items is the synthetic itemdata: a stackable expendable (3/3, MaxStack 50),
// a non-stackable equipment piece (3/1), a stackable 3/2, a bionic 3/3.
var testItems = map[string]Item{
	"ITEM_T_POTION": {ID: 501, Code: "ITEM_T_POTION", TypeID: [4]int{3, 3, 1, 1}, MaxStack: 50, CashItem: true},
	"ITEM_T_SWORD":  {ID: 502, Code: "ITEM_T_SWORD", TypeID: [4]int{3, 1, 6, 2}, MaxStack: 1},
	"ITEM_T_SCROLL": {ID: 503, Code: "ITEM_T_SCROLL", TypeID: [4]int{3, 2, 1, 1}, MaxStack: 10},
	"ITEM_T_BIONIC": {ID: 504, Code: "ITEM_T_BIONIC", TypeID: [4]int{3, 3, 1, 1}, Bionic: true, MaxStack: 20},
}

func lookup(code string) (Item, bool) {
	it, ok := testItems[code]
	return it, ok
}

func pkgRow(id, code, term string) []string {
	return pad(row("1", "15", id, code, "0", term, "SN_"+code, "SN_"+code+"_TT_DESC", "item\\etc\\x.ddj"), 8)
}

func scrapRow(pkg, item, opt, variance, data string, params ...string) []string {
	r := row("1", "15", pkg, item, opt, variance, data, itoa(len(params)))
	for i := 0; i < 12; i++ {
		if i < len(params) {
			r = append(r, params[i])
		} else {
			r = append(r, "0")
		}
	}
	return append(pad(r, 8), "1")
}

func priceRow(pkg string, device, cost int) []string {
	return pad(row("1", "15", pkg, itoa(device), "0", itoa(cost)), 8)
}

// testTables: an NPC group (not registered) and two NPC-less groups. GROUP_T
// maps SHOP_B then SHOP_A (file order, not alphabetical); SHOP_A has two tab
// groups, of which only the first counts, and an empty first tab.
func testTables() Tables {
	return Tables{
		ShopGroup: [][]string{
			pad(row("1", "15", "900", "GROUP_NPC", "NPC_T_SMITH"), 8),
			pad(row("1", "15", "901", "GROUP_T", "xxx"), 8),
			pad(row("1", "15", "902", "GROUP_EMPTY", "xxx"), 8),
			pad(row("0", "15", "903", "GROUP_OFF", "xxx"), 8),
		},
		MapGroup: [][]string{
			row("1", "15", "GROUP_NPC", "SHOP_NPC"),
			row("1", "15", "GROUP_T", "SHOP_B"),
			row("1", "15", "GROUP_T", "SHOP_A"),
			row("0", "15", "GROUP_T", "SHOP_OFF"),
		},
		MapTab: [][]string{
			row("1", "15", "SHOP_A", "SHOP_A_G1"),
			row("1", "15", "SHOP_A", "SHOP_A_G2"),
			row("1", "15", "SHOP_B", "SHOP_B_G1"),
		},
		TabGroup: [][]string{
			row("1", "15", "1", "SHOP_A_G1", "K"), row("1", "15", "2", "SHOP_A_G2", "K"), row("1", "15", "3", "SHOP_B_G1", "K"),
		},
		Tab: [][]string{
			row("1", "15", "11", "TAB_A_EMPTY", "SHOP_A_G1", "K"),
			row("1", "15", "12", "TAB_A_MAIN", "SHOP_A_G1", "K"),
			row("1", "15", "13", "TAB_A_LATER", "SHOP_A_G2", "K"),
			row("1", "15", "14", "TAB_B_MAIN", "SHOP_B_G1", "K"),
		},
		Goods: [][]string{
			pad(row("1", "15", "TAB_A_MAIN", "PKG_POTION", "0"), 8),
			pad(row("1", "15", "TAB_A_MAIN", "PKG_POTION10", "3"), 8),
			pad(row("1", "15", "TAB_A_MAIN", "PKG_SWORD", "4"), 8),
			pad(row("1", "15", "TAB_A_MAIN", "PKG_BUNDLE", "5"), 8),
			pad(row("1", "15", "TAB_A_MAIN", "PKG_GOLD", "6"), 8),
			pad(row("1", "15", "TAB_A_MAIN", "PKG_GIFTONLY", "7"), 8),
			pad(row("1", "15", "TAB_A_MAIN", "PKG_OWNONLY", "8"), 8),
			pad(row("1", "15", "TAB_A_MAIN", "PKG_TOKEN", "9"), 8),
			pad(row("1", "15", "TAB_A_MAIN", "PKG_HONOR", "10"), 8),
			pad(row("1", "15", "TAB_A_MAIN", "PKG_GUILD", "11"), 8),
			pad(row("1", "15", "TAB_A_MAIN", "PKG_ODDTERM", "12"), 8),
			pad(row("1", "15", "TAB_A_MAIN", "PKG_SCROLL", "13"), 8),
			pad(row("1", "15", "TAB_A_MAIN", "PKG_BIONIC", "14"), 8),
			pad(row("1", "15", "TAB_A_MAIN", "PKG_GHOST", "15"), 8),
			pad(row("1", "15", "TAB_A_LATER", "PKG_POTION", "0"), 8),
			pad(row("1", "15", "TAB_B_MAIN", "PKG_POINTS", "2"), 8),
		},
		Package: [][]string{
			pkgRow("7001", "PKG_POTION", ExpandTermAll), pkgRow("7002", "PKG_POTION10", ExpandTermAll),
			pkgRow("7003", "PKG_SWORD", ExpandTermAll), pkgRow("7004", "PKG_BUNDLE", ExpandTermAll),
			pkgRow("7005", "PKG_GOLD", ExpandTermAll), pkgRow("7006", "PKG_GIFTONLY", ExpandTermAll),
			pkgRow("7007", "PKG_OWNONLY", ExpandTermOne), pkgRow("7008", "PKG_TOKEN", ExpandTermAll),
			pkgRow("7009", "PKG_HONOR", ExpandTermAll), pkgRow("7010", "PKG_GUILD", ExpandTermAll),
			pkgRow("7011", "PKG_ODDTERM", "EXPAND_TERM_X"), pkgRow("7012", "PKG_SCROLL", ExpandTermAll),
			pkgRow("7013", "PKG_BIONIC", ExpandTermAll), pkgRow("7014", "PKG_GHOST", ExpandTermAll),
			pkgRow("7015", "PKG_POINTS", ExpandTermAll),
		},
		Scrap: [][]string{
			scrapRow("PKG_POTION", "ITEM_T_POTION", "0", "0", "0"),
			scrapRow("PKG_POTION10", "ITEM_T_POTION", "0", "0", "10"),
			scrapRow("PKG_SWORD", "ITEM_T_SWORD", "7", "12345", "0", "9876", "5432"),
			scrapRow("PKG_BUNDLE", "ITEM_T_SWORD", "0", "0", "0"),
			scrapRow("PKG_BUNDLE", "ITEM_T_POTION", "0", "0", "20"),
			scrapRow("PKG_GOLD", "ITEM_T_POTION", "0", "0", "0"),
			scrapRow("PKG_GIFTONLY", "ITEM_T_POTION", "0", "0", "0"),
			scrapRow("PKG_OWNONLY", "ITEM_T_POTION", "0", "0", "0"),
			scrapRow("PKG_TOKEN", "ITEM_T_POTION", "0", "0", "0"),
			scrapRow("PKG_HONOR", "ITEM_T_POTION", "0", "0", "0"),
			scrapRow("PKG_GUILD", "ITEM_T_POTION", "0", "0", "0"),
			scrapRow("PKG_ODDTERM", "ITEM_T_POTION", "0", "0", "0"),
			scrapRow("PKG_SCROLL", "ITEM_T_SCROLL", "0", "0", "0"),
			scrapRow("PKG_BIONIC", "ITEM_T_BIONIC", "0", "0", "0"),
			scrapRow("PKG_GHOST", "ITEM_T_NOT_IN_ITEMDATA", "0", "0", "0"),
			scrapRow("PKG_POINTS", "ITEM_T_POTION", "0", "0", "0"),
		},
		Price: [][]string{
			priceRow("PKG_POTION", 2, 30), priceRow("PKG_POTION", 4, 30),
			priceRow("PKG_POTION10", 2, 5), priceRow("PKG_POTION10", 4, 5),
			priceRow("PKG_SWORD", 2, 100), priceRow("PKG_SWORD", 4, 100),
			priceRow("PKG_BUNDLE", 2, 40),
			priceRow("PKG_GOLD", 1, 1000),
			priceRow("PKG_GIFTONLY", 4, 25),
			priceRow("PKG_OWNONLY", 2, 25),
			priceRow("PKG_TOKEN", 2, 10), priceRow("PKG_TOKEN", 64, 3),
			priceRow("PKG_HONOR", 32, 10),
			priceRow("PKG_GUILD", 2, 10), priceRow("PKG_GUILD", 8, 10),
			priceRow("PKG_ODDTERM", 2, 10),
			priceRow("PKG_SCROLL", 2, 10),
			priceRow("PKG_BIONIC", 2, 10),
			priceRow("PKG_GHOST", 2, 10),
			// The 13-column layout (no PreviousCost): Cost at 4.
			row("1", "15", "PKG_POINTS", "2", "60", "-1", "xxx", "-1", "xxx", "-1", "xxx", "-1", "xxx"),
			row("1", "15", "PKG_POINTS", "4", "0", "-1", "xxx", "-1", "xxx", "-1", "xxx", "-1", "xxx"),
			row("1", "15", "PKG_POINTS", "16", "0", "-1", "xxx", "-1", "xxx", "-1", "xxx", "-1", "xxx"),
		},
	}
}

func testCatalogue() *Catalogue { return Build(testTables(), lookup) }

func TestBuildRegistersNPCLessGroups(t *testing.T) {
	c := testCatalogue()
	if _, ok := c.Groups[900]; ok {
		t.Fatal("a group with an NPC was registered as a silk shop")
	}
	if _, ok := c.Groups[903]; ok {
		t.Fatal("a Service-0 group was registered")
	}
	if g := c.Groups[902]; g == nil || len(g.Shops) != 0 {
		t.Fatalf("the NPC-less group without shops: %+v", g)
	}
	g := c.Groups[901]
	if g == nil || len(g.Shops) != 2 || g.Shops[0].Code != "SHOP_B" || g.Shops[1].Code != "SHOP_A" {
		t.Fatalf("GROUP_T's shops are not in the mapping's file order: %+v", g)
	}
	a := g.Shops[1]
	if len(a.Tabs) != 2 || a.Tabs[0].Code != "TAB_A_EMPTY" || len(a.Tabs[0].Goods) != 0 || a.Tabs[1].Code != "TAB_A_MAIN" {
		t.Fatalf("SHOP_A's tabs: want the first tab group's two, the empty one counted; got %d", len(a.Tabs))
	}
	if n := c.Count(); n.Groups != 2 || n.Shops != 2 || n.Tabs != 3 {
		t.Fatalf("counts %+v", n)
	}
	sw := a.Tabs[1].Goods[4].Package
	if sw.ID != 7003 || sw.Mask != DeviceSilk|DeviceGiftSilk || sw.Cost[DeviceSilk] != 100 || len(sw.Scraps) != 1 {
		t.Fatalf("PKG_SWORD %+v", sw)
	}
	if s := sw.Scraps[0]; s.OptLevel != 7 || s.Variance != 12345 || len(s.MagParams) != 2 || s.MagParams[1] != 5432 {
		t.Fatalf("PKG_SWORD's scrap %+v", s)
	}
	if ghost := a.Tabs[1].Goods[15].Package; len(ghost.Scraps) != 0 {
		t.Fatal("a scrap row naming no itemdata row was kept (the client drops it)")
	}
	pts := g.Shops[0].Tabs[0].Goods[2].Package
	if pts.Mask != DeviceSilk|DeviceGiftSilk|DevicePoint || pts.Cost[DeviceSilk] != 60 || pts.Cost[DevicePoint] != 0 {
		t.Fatalf("the 13-column price rows: %+v", pts)
	}
}

func TestCSVRoundTrip(t *testing.T) {
	c := testCatalogue()
	var buf bytes.Buffer
	if err := WriteCSV(&buf, c); err != nil {
		t.Fatal(err)
	}
	back, err := ReadCSV(strings.NewReader(buf.String()))
	if err != nil {
		t.Fatal(err)
	}
	if back.Count() != c.Count() {
		t.Fatalf("counts %+v, want %+v", back.Count(), c.Count())
	}
	var again bytes.Buffer
	if err := WriteCSV(&again, back); err != nil {
		t.Fatal(err)
	}
	if again.String() != buf.String() {
		t.Fatal("the CSV does not survive a read and a write unchanged")
	}
	sh, _ := back.Shop(901, 1)
	sw := sh.Tabs[1].Goods[4].Package
	if sw.Code != "PKG_SWORD" || sw.Scraps[0].Item.TypeID != [4]int{3, 1, 6, 2} || sw.Scraps[0].MagParams[0] != 9876 {
		t.Fatalf("PKG_SWORD after the round trip: %+v", sw)
	}
	if _, err := ReadCSV(strings.NewReader("nope\n")); err == nil {
		t.Fatal("a file without the header loaded")
	}
}

// The wire spec's §3.5 example, byte for byte (item_mall_wire.md: package
// 85592, group 1051, shop 0, tab 0, slot 0, own 939 / gift 3731).
const example7034 = "181b0400000032005041434b414745" + "5f4d414c4c5f4954454d5f4554435f41524348454d" +
	"595f4d4147494353544f4e455f41535452414c5f3131" + "01000000000000000000584e0100"

func TestWireExample(t *testing.T) {
	raw, _ := hex.DecodeString(example7034)
	r, err := DecodeBuy(raw)
	if err != nil {
		t.Fatal(err)
	}
	want := BuyRequest{Group: 1051, Code: "PACKAGE_MALL_ITEM_ETC_ARCHEMY_MAGICSTONE_ASTRAL_11", Quantity: 1, PackageID: 85592}
	if r != want {
		t.Fatalf("decoded %+v", r)
	}
	if !bytes.Equal(EncodeBuy(r), raw) {
		t.Fatal("EncodeBuy is not the request's bytes")
	}
	if got, w := hex.EncodeToString(EncodeBuyOK(r, []int{0})), "01181b0400000001"+"0d"+"0100"+"00000000"; got != w {
		t.Fatalf("0xB034 %s, want %s", got, w)
	}
	if got := hex.EncodeToString(EncodeBalances(Balances{Own: 939, Gift: 3701})); got != "ab030000750e000000000000" {
		t.Fatalf("0x3153 %s", got)
	}
	if got := hex.EncodeToString(EncodeBuyFail(CodeNoSilk)); got != "028018" {
		t.Fatalf("failure %s", got)
	}
	if got := EncodeBalances(Balances{Own: -5, Gift: 1 << 40}); binary.LittleEndian.Uint32(got) != 0 || binary.LittleEndian.Uint32(got[4:]) != 0xffffffff {
		t.Fatalf("clamps % x", got)
	}
	if _, err := DecodeBuy(raw[:20]); err == nil {
		t.Fatal("a truncated request decoded")
	}
	// The example's own check: one good priced (2:30, 4:30), gift pays first.
	cat := Build(Tables{
		ShopGroup: [][]string{pad(row("1", "15", "1051", "GROUP_X", "xxx"), 8)},
		MapGroup:  [][]string{row("1", "15", "GROUP_X", "SHOP_X")},
		MapTab:    [][]string{row("1", "15", "SHOP_X", "SHOP_X_G1")},
		Tab:       [][]string{row("1", "15", "1", "TAB_X", "SHOP_X_G1", "K")},
		Goods:     [][]string{pad(row("1", "15", "TAB_X", want.Code, "0"), 8)},
		Package:   [][]string{pkgRow("85592", want.Code, ExpandTermAll)},
		Scrap:     [][]string{scrapRow(want.Code, "ITEM_T_POTION", "0", "0", "0")},
		Price:     [][]string{priceRow(want.Code, 2, 30), priceRow(want.Code, 4, 30)},
	}, lookup)
	plan, code := Check(cat, r, Wallet{Silk: Balances{Own: 939, Gift: 3731}})
	if code != 0 || plan.Pay != (Payment{Gift: 30}) || plan.Slots != 1 || len(plan.Units) != 1 || plan.Units[0].Stack != 1 {
		t.Fatalf("the example's plan %+v code %#x", plan, code)
	}
}

func buy(shop, tab, slot uint8, code string, qty uint16) BuyRequest {
	return BuyRequest{Group: 901, Shop: shop, Tab: tab, Slot: slot, Code: code, Quantity: qty}
}

var rich = Wallet{Gold: 1 << 40, Silk: Balances{Own: 100000, Gift: 100000, Point: 100000}}

// TestCheckRefusals runs every refusal, each in the place the order puts it.
func TestCheckRefusals(t *testing.T) {
	c := testCatalogue()
	for _, tc := range []struct {
		name string
		r    BuyRequest
		w    Wallet
		want uint16
	}{
		{"unregistered group", BuyRequest{Group: 900, Code: "PKG_POTION", Quantity: 1}, rich, CodeFail},
		{"shop index past the group", buy(2, 0, 0, "PKG_POTION", 1), rich, CodeFail},
		{"tab past the shop", buy(1, 2, 0, "PKG_POTION", 1), rich, CodeNoTab},
		{"the second tab group's tab is not the shop's", buy(1, 2, 0, "PKG_POTION", 1), rich, CodeNoTab},
		{"tab before quantity", buy(1, 9, 0, "PKG_POTION", 0), rich, CodeNoTab},
		{"quantity 0", buy(1, 1, 0, "PKG_POTION", 0), rich, CodeFail},
		{"quantity 0x8000 is negative", buy(1, 1, 0, "PKG_POTION", 0x8000), rich, CodeFail},
		{"quantity before the good", buy(1, 1, 99, "PKG_POTION", 0), rich, CodeFail},
		{"the empty tab has no good", buy(1, 0, 0, "PKG_POTION", 1), rich, CodeNoGood},
		{"no good at the slot", buy(1, 1, 1, "PKG_POTION", 1), rich, CodeNoGood},
		{"the code name", buy(1, 1, 0, "PKG_POTION10", 1), rich, CodeCodeName},
		{"an empty code name (the old window)", buy(1, 1, 0, "", 1), rich, CodeCodeName},
		{"one stack: above MaxStack", buy(1, 1, 0, "PKG_POTION", 51), rich, CodeFail},
		{"one stack: a stackable that is not 3/3", buy(1, 1, 13, "PKG_SCROLL", 1), rich, CodeFail},
		{"one stack: a bionic 3/3 is not an expendable", buy(1, 1, 14, "PKG_BIONIC", 1), rich, CodeFail},
		{"per-unit quantity above 5 (OURS)", buy(1, 1, 4, "PKG_SWORD", 6), rich, CodeFail},
		{"no scrap row (OURS)", buy(1, 1, 15, "PKG_GHOST", 1), rich, CodeFail},
		{"gold short", buy(1, 1, 6, "PKG_GOLD", 2), Wallet{Gold: 1999}, CodeNoGold},
		{"tokens on op 0x18", buy(1, 1, 9, "PKG_TOKEN", 1), rich, CodeFail},
		{"honour", buy(1, 1, 10, "PKG_HONOR", 1), rich, CodeHonor},
		{"silk short", buy(1, 1, 0, "PKG_POTION", 2), Wallet{Silk: Balances{Own: 30, Gift: 29}}, CodeNoSilk},
		{"points without bit 16 count nothing", buy(1, 1, 0, "PKG_POTION", 1), Wallet{Silk: Balances{Point: 1000}}, CodeNoSilk},
		{"gift alone short", buy(1, 1, 7, "PKG_GIFTONLY", 2), Wallet{Silk: Balances{Own: 1000, Gift: 49}}, CodeNoSilk},
		{"own alone short", buy(1, 1, 8, "PKG_OWNONLY", 1), Wallet{Silk: Balances{Own: 24, Gift: 1000}}, CodeNoSilk},
		{"silk before guild points", buy(1, 1, 11, "PKG_GUILD", 1), Wallet{}, CodeNoSilk},
		{"guild points last", buy(1, 1, 11, "PKG_GUILD", 1), rich, CodeNoGuild},
		{"an ExpandTerm neither ALL nor ONE", buy(1, 1, 12, "PKG_ODDTERM", 1), rich, CodeFail},
	} {
		if _, code := Check(c, tc.r, tc.w); code != tc.want {
			t.Errorf("%s: code %#x, want %#x", tc.name, code, tc.want)
		}
	}
}

func TestCheckPoints(t *testing.T) {
	c := testCatalogue()
	r := BuyRequest{Group: 901, Shop: 0, Tab: 0, Slot: 2, Code: "PKG_POINTS", Quantity: 1}
	w := Wallet{Silk: Balances{Own: 10, Gift: 20, Point: 40}}
	// 60 from own + gift + points: available 70.
	for _, tc := range []struct {
		points uint64
		pay    Payment
		code   uint16
	}{
		{40, Payment{Own: 0, Gift: 20, Point: 40}, 0},
		{30, Payment{Own: 10, Gift: 20, Point: 30}, 0},
		{29, Payment{}, CodeFail},      // own short after gift: 2
		{41, Payment{}, CodeFail},      // above the point balance
		{1 << 63, Payment{}, CodeFail}, // negative as the engine's signed field
		{0, Payment{}, CodeFail},       // 60 > 10 + 20 after no points: 2 (both bits)
	} {
		r.Points = tc.points
		plan, code := Check(c, r, w)
		if code != tc.code || (code == 0 && plan.Pay != tc.pay) {
			t.Errorf("points %d: pay %+v code %#x, want %+v %#x", tc.points, plan.Pay, code, tc.pay, tc.code)
		}
	}
	// Points above the price: 2.
	r.Points = 61
	if _, code := Check(c, r, Wallet{Silk: Balances{Own: 100, Point: 100}}); code != CodeFail {
		t.Fatalf("points above the price: %#x", code)
	}
}

func TestCheckSplitsGiftFirst(t *testing.T) {
	c := testCatalogue()
	for _, tc := range []struct {
		name string
		r    BuyRequest
		w    Balances
		pay  Payment
	}{
		{"both, gift covers", buy(1, 1, 0, "PKG_POTION", 2), Balances{Own: 100, Gift: 100}, Payment{Gift: 60}},
		{"both, gift then own", buy(1, 1, 0, "PKG_POTION", 2), Balances{Own: 100, Gift: 25}, Payment{Gift: 25, Own: 35}},
		{"both, no gift", buy(1, 1, 0, "PKG_POTION", 1), Balances{Own: 30}, Payment{Own: 30}},
		{"gift alone", buy(1, 1, 7, "PKG_GIFTONLY", 2), Balances{Own: 1000, Gift: 50}, Payment{Gift: 50}},
		{"own alone", buy(1, 1, 8, "PKG_OWNONLY", 1), Balances{Own: 25, Gift: 1000}, Payment{Own: 25}},
		{"price x quantity", buy(1, 1, 3, "PKG_POTION10", 3), Balances{Gift: 15}, Payment{Gift: 15}},
	} {
		plan, code := Check(c, tc.r, Wallet{Silk: tc.w})
		if code != 0 || plan.Pay != tc.pay {
			t.Errorf("%s: %+v %#x, want %+v", tc.name, plan.Pay, code, tc.pay)
		}
	}
	plan, code := Check(c, buy(1, 1, 6, "PKG_GOLD", 2), Wallet{Gold: 2000})
	if code != 0 || plan.Pay != (Payment{Gold: 2000}) || plan.SilkPriced() {
		t.Fatalf("gold: %+v %#x", plan.Pay, code)
	}
}

func TestStackRules(t *testing.T) {
	c := testCatalogue()
	units := func(r BuyRequest) (int, []Unit) {
		t.Helper()
		plan, code := Check(c, r, rich)
		if code != 0 {
			t.Fatalf("%+v refused %#x", r, code)
		}
		return plan.Slots, plan.Units
	}
	// A one-row expendable with Data 0: one slot, one stack of the quantity.
	if n, u := units(buy(1, 1, 0, "PKG_POTION", 50)); n != 1 || len(u) != 1 || u[0].Stack != 50 {
		t.Fatalf("PKG_POTION x50: n %d units %+v", n, u)
	}
	// Data 10: a stack of 10 per unit, quantity units.
	if n, u := units(buy(1, 1, 3, "PKG_POTION10", 3)); n != 3 || len(u) != 3 || u[2].Stack != 10 {
		t.Fatalf("PKG_POTION10 x3: n %d units %+v", n, u)
	}
	// Equipment: one each.
	if n, u := units(buy(1, 1, 4, "PKG_SWORD", 2)); n != 2 || len(u) != 2 || u[0].Stack != 1 || u[0].Scrap.OptLevel != 7 {
		t.Fatalf("PKG_SWORD x2: n %d units %+v", n, u)
	}
	// Two rows: n per row, the rows in order (scrap outer, count inner).
	n, u := units(buy(1, 1, 5, "PKG_BUNDLE", 2))
	if n != 2 || len(u) != 4 || u[0].Scrap.Item.ID != 502 || u[1].Scrap.Item.ID != 502 || u[2].Scrap.Item.ID != 501 || u[3].Stack != 20 {
		t.Fatalf("PKG_BUNDLE x2: n %d units %+v", n, u)
	}
	if SlotsNeeded(&Package{Scraps: []Scrap{{Item: testItems["ITEM_T_SWORD"]}}}, 9) != 5 {
		t.Fatal("the slot count is not clamped to 5")
	}
}

func TestHistoryWire(t *testing.T) {
	at := time.Date(2026, 10, 27, 13, 45, 59, 0, time.Local)
	d := PackDate(at)
	if y, mo, da, h, mi := UnpackDate(d); y != 2026 || mo != 10 || da != 27 || h != 13 || mi != 45 {
		t.Fatalf("packed %#x unpacks to %d/%d/%d %d:%d", d, y, mo, da, h, mi)
	}
	if d>>26 != 0 {
		t.Fatalf("bits 26..31 written: %#x", d)
	}
	got := EncodeHistory(1, 2, []HistoryRow{{Offset: 30, At: at}})
	want := []byte{1, 2, 0, 1, 0, 30, 0, 0, 0}
	want = binary.LittleEndian.AppendUint32(want, d)
	if !bytes.Equal(got, want) {
		t.Fatalf("0xB11A % x, want % x", got, want)
	}
	if !bytes.Equal(EncodeHistory(2, 1, nil), []byte{2, 1, 0, 0, 0}) {
		t.Fatal("an empty list")
	}
	if !bytes.Equal(EncodeHistoryFailed(1, 9), []byte{1, 9, 1}) {
		t.Fatal("a failure")
	}
	now := time.Date(2026, 10, 27, 0, 0, 0, 0, time.UTC)
	for p, want := range map[byte]time.Time{1: now.Add(-24 * time.Hour), 2: now.Add(-7 * 24 * time.Hour),
		3: now.AddDate(0, -1, 0), 4: now.AddDate(0, -3, 0)} {
		if got, ok := PeriodStart(p, now); !ok || !got.Equal(want) {
			t.Errorf("period %d: %v", p, got)
		}
	}
	if _, ok := PeriodStart(5, now); ok {
		t.Fatal("period 5 accepted")
	}
}

func TestChestWire(t *testing.T) {
	at := time.Unix(1_800_000_000, 0)
	got := EncodeChestList([]ChestEntry{{ID: 7, ItemID: 501, Quantity: 50, From: "Item Mall", At: at}})
	want := []byte{1, 0, 7, 0, 0, 0, 0xf5, 1, 0, 0, 50, 0, 0, 0, 9, 0}
	want = append(want, "Item Mall"...)
	want = binary.LittleEndian.AppendUint32(want, 1_800_000_000)
	if !bytes.Equal(got, want) {
		t.Fatalf("0x00D1 % x\nwant % x", got, want)
	}
	if !bytes.Equal(EncodeChestTaken(3), []byte{1, 3, 0}) || !bytes.Equal(EncodeChestTakeFail(CodeBagFull), []byte{2, 7, 0x18}) {
		t.Fatal("0x00D3")
	}
	if id, ok := DecodeChestTake([]byte{9, 0, 0, 0}); !ok || id != 9 {
		t.Fatal("0x00D2")
	}
	lg := EncodeTakeLog([]TakeLogEntry{{ItemID: 501, Quantity: 2, From: "x", At: at, TakenAt: at.Add(time.Second)}})
	if len(lg) != 2+4+4+2+1+4+4 || binary.LittleEndian.Uint32(lg[len(lg)-4:]) != 1_800_000_001 {
		t.Fatalf("0x00D5 % x", lg)
	}
	if !bytes.Equal(EncodeChestReceived(501, 50), []byte{0xf5, 1, 0, 0, 50, 0, 0, 0}) {
		t.Fatal("0x00D6")
	}
	if !bytes.Equal(EncodeOpen(1051), []byte{1, 0x1b, 4, 0}) {
		t.Fatal("0xB121")
	}
	if !bytes.Equal(EncodeSilkChange(ReasonReceived, CashGift, 500), []byte{2, 1, 0xf4, 1, 0, 0}) {
		t.Fatal("0x3154")
	}
}

func TestMemStoreChest(t *testing.T) {
	ctx := context.Background()
	m := NewMemStore()
	now := time.Now()
	a, _ := m.AddToChest(ctx, ChestEntry{Owner: 1, ItemID: 501, Quantity: 5, From: FromItemMall, At: now})
	b, _ := m.AddToChest(ctx, ChestEntry{Owner: 1, ItemID: 502, Quantity: 1, From: FromItemMall, At: now})
	m.AddToChest(ctx, ChestEntry{Owner: 2, ItemID: 503, Quantity: 1, At: now})
	if es, _ := m.Chest(ctx, 1); len(es) != 2 || es[0].ID != a || es[1].ID != b {
		t.Fatalf("chest %+v", es)
	}
	// A take inside a failed action comes back, and its log row goes.
	errBoom := errors.New("boom")
	err := txn.Runner{}.Run(ctx, func(ctx context.Context) error {
		if _, err := m.TakeFromChest(ctx, 1, a, now); err != nil {
			return err
		}
		return errBoom
	})
	if !errors.Is(err, errBoom) {
		t.Fatal(err)
	}
	if es, _ := m.Chest(ctx, 1); len(es) != 2 || es[0].ID != a {
		t.Fatalf("rolled back chest %+v", es)
	}
	if l, _ := m.TakeLog(ctx, 1, now.Add(-time.Hour)); len(l) != 0 {
		t.Fatalf("rolled back log %+v", l)
	}
	if _, err := m.TakeFromChest(ctx, 2, a, now); !errors.Is(err, ErrNoSuchEntry) {
		t.Fatal("another character took the entry")
	}
	got, err := m.TakeFromChest(ctx, 1, a, now)
	if err != nil || got.ItemID != 501 {
		t.Fatal(got, err)
	}
	if _, err := m.TakeFromChest(ctx, 1, a, now); !errors.Is(err, ErrNoSuchEntry) {
		t.Fatal("taken twice")
	}
	m.TakeFromChest(ctx, 1, b, now.Add(time.Minute))
	l, _ := m.TakeLog(ctx, 1, now.Add(-time.Hour))
	if len(l) != 2 || l[0].ItemID != 502 {
		t.Fatalf("log (newest first) %+v", l)
	}
	if n, _ := m.PruneTakeLog(ctx, now.Add(30*time.Second)); n != 1 {
		t.Fatalf("pruned %d", n)
	}
	// The purchase log reads by account and period.
	m.RecordPurchase(ctx, Purchase{AccountID: 3, Pay: Payment{Own: 5, Gift: 7}, At: now.Add(-48 * time.Hour)})
	m.RecordPurchase(ctx, Purchase{AccountID: 3, Pay: Payment{Point: 2}, At: now})
	m.RecordPurchase(ctx, Purchase{AccountID: 4, Pay: Payment{Own: 1}, At: now})
	if rows, _ := m.Purchases(ctx, 3, now.Add(-24*time.Hour)); len(rows) != 1 || rows[0].Offset != 2 {
		t.Fatalf("a day's purchases %+v", rows)
	}
	if rows, _ := m.Purchases(ctx, 3, now.Add(-72*time.Hour)); len(rows) != 2 || rows[0].Offset != 12 {
		t.Fatalf("three days' purchases %+v", rows)
	}
}
