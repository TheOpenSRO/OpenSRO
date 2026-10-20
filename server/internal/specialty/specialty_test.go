package specialty

import (
	"bytes"
	"strings"
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/jobs"
)

// The shard's own row shape (MEASURED: BaseQuot = LB = UB = 1.1, stocks
// 50000, Fluct 250) on a good costing 4000: 4400 a unit, and selling never
// moves it.
func TestFlatQuote(t *testing.T) {
	rows, err := ReadQuotes(strings.NewReader("1,1,2010,2151,1.1,1.1,1.1,50000,250,50000\n"))
	if err != nil || len(rows) != 1 {
		t.Fatalf("ReadQuotes: %v %v", rows, err)
	}
	q := NewQuote(rows[0], 4000)
	if q.Price != 4400 || q.MaxStock != 50000 || q.MinStock != 50000 {
		t.Fatalf("price %d stocks %d..%d, want 4400 50000..50000", q.Price, q.MinStock, q.MaxStock)
	}
	gold, profit, changed := q.Sell(10)
	if gold != 44000 || profit != 4000 || changed || q.Row.CurStock != 50000 {
		t.Fatalf("sell 10: gold %d profit %d changed %v stock %d", gold, profit, changed, q.Row.CurStock)
	}
}

// A moving quotation, in the engine's float widths: a sale raises the stock
// and the price falls to 4599 (float32(1.15) x 4000 is 4599.9999), the tick
// brings the stock down by Fluct and the price back up.
func TestMovingQuote(t *testing.T) {
	q := NewQuote(QuoteRow{Service: true, NPC: 1, Item: 2, BaseQuot: 1.2, LB: 1.0, UB: 1.5, BaseStock: 1000,
		Fluct: 100, CurStock: 1000}, 4000)
	if q.Price != 4800 || q.MaxStock != 3000 || q.MinStock != -2000 {
		t.Fatalf("price %d stocks %d..%d", q.Price, q.MinStock, q.MaxStock)
	}
	gold, profit, changed := q.Sell(500)
	if gold != 2400000 || profit != 400000 || !changed || q.Price != 4599 || q.Row.CurStock != 1500 {
		t.Fatalf("sell: gold %d profit %d changed %v price %d stock %d", gold, profit, changed, q.Price, q.Row.CurStock)
	}
	if !q.Recover() || q.Row.CurStock != 1400 || q.Price != 4639 {
		t.Fatalf("recover: stock %d price %d", q.Row.CurStock, q.Price)
	}
	// The stock never passes MaxStock.
	q.Sell(100000)
	if q.Row.CurStock != 3000 {
		t.Fatalf("stock %d, want MaxStock 3000", q.Row.CurStock)
	}
	if got := q.Quotient(); got != 1.0 {
		t.Fatalf("quotient at MaxStock %v, want LB 1.0", got)
	}
}

func TestBoardDropsUnservicedRows(t *testing.T) {
	rows, err := ReadQuotes(strings.NewReader(strings.Join(QuoteColumns, ",") + "\n" +
		"1,1,7,30,1.1,1.1,1.1,50000,250,50000\n2,0,7,31,1.1,1.1,1.1,50000,250,50000\n" +
		"3,1,7,29,1.2,1.2,1.2,50000,250,50000\n4,1,8,30,1.1,1.1,1.1,0,250,0\n"))
	if err != nil {
		t.Fatal(err)
	}
	b := NewBoard(rows, func(int64) int64 { return 4000 })
	if !b.Has(7) || b.Has(8) {
		t.Fatalf("Has: 7 %v 8 %v", b.Has(7), b.Has(8))
	}
	p := b.Prices(7)
	if len(p) != 2 || p[0] != (UnitPrice{29, 4800}) || p[1] != (UnitPrice{30, 4400}) {
		t.Fatalf("prices %v", p)
	}
	if _, _, _, ok := b.Sell(7, 31, 1); ok {
		t.Fatal("an unserviced row sold")
	}
}

func TestAmountAndScale(t *testing.T) {
	// goldMin 1000: Unit 1250. 100 units: 100 x 348 / 1250 = 27.84.
	if a := Amount(100, 1000, 1); a != 27 {
		t.Fatalf("rarity 1: %d", a)
	}
	if a := Amount(100, 1000, 2); a != 20 {
		t.Fatalf("rarity 2: %d (27.84 / (40/30))", a)
	}
	if a := Amount(2, 100000, 1); a != 1 {
		t.Fatalf("a fraction counts 1: %d", a)
	}
	if a := Amount(0, 1000, 1); a != 0 {
		t.Fatalf("no goods: %d", a)
	}
	for _, c := range []struct {
		amount uint32
		want   byte
	}{{0, 0}, {1, 1}, {510, 1}, {511, 2}, {918, 2}, {1428, 3}, {2142, 4}, {2143, 5}} {
		if got := ShardThresholds.Scale(c.amount); got != c.want {
			t.Fatalf("Scale(%d) = %d, want %d", c.amount, got, c.want)
		}
	}
	if EngineDefaultThresholds.Scale(409) != 2 {
		t.Fatal("the engine's own T[1] is 408")
	}
}

func TestBagSize(t *testing.T) {
	// Unit(1000) = 1250: 1250 x 2448 / 11796 = 259.4.
	if n := BagSize(1, 1000, 1, false); n != 1 {
		t.Fatalf("InventorySize 1: %d", n)
	}
	if n := BagSize(33, 1000, 1, false); n != 33 {
		t.Fatalf("InventorySize 33: %d", n)
	}
	// Unit(10) = 12: 12 x 2448 / 11796 = 2.49.
	if n := BagSize(33, 10, 1, false); n != 2 {
		t.Fatalf("a low level's cap: %d", n)
	}
	if n := BagSize(33, 10, 2, false); n != 3 {
		t.Fatalf("rarity 2: %d (2.49 x 40/30)", n)
	}
	if n := BagSize(33, 10, 2, true); n != 4 {
		t.Fatalf("a cash transport: %d (2.49 x 40/(30/1.4))", n)
	}
	if n := BagSize(0, 1000, 1, false); n != 0 {
		t.Fatalf("no bag: %d", n)
	}
	if n := BagSize(33, 0, 1, false); n != 1 {
		t.Fatalf("cap 0 still gives 1: %d", n)
	}
}

func TestSaleExp(t *testing.T) {
	for _, c := range []struct {
		profit int64
		state  byte
		scale  byte
		want   int64
	}{
		{4000, byte(jobs.KindTrader), 1, 3200},
		{4000, byte(jobs.KindTrader), 2, 2000},
		{40000, byte(jobs.KindThief), 0, 16000},
		{0, byte(jobs.KindTrader), 2, 1},
		{4000, 4, 1, 0},
	} {
		if got := jobs.SaleExp(c.profit, c.state, c.scale); got != c.want {
			t.Fatalf("SaleExp(%d, %d, %d) = %d, want %d", c.profit, c.state, c.scale, got, c.want)
		}
	}
}

func TestBuildShops(t *testing.T) {
	split := func(s string) [][]string {
		var out [][]string
		for _, l := range strings.Split(strings.TrimSpace(s), "\n") {
			out = append(out, strings.Split(l, "\t"))
		}
		return out
	}
	shops := BuildShops(
		split("1\t15\t985\tGROUP_STORE_CH_SPECIAL\tNPC_CH_SPECIAL\n1\t15\t1\tGROUP_STORE_CH_SMITH\tNPC_CH_SMITH"),
		split("1\t15\tGROUP_STORE_CH_SPECIAL\tSTORE_CH_SPECIAL\n1\t15\tGROUP_STORE_CH_SMITH\tSTORE_CH_SMITH"),
		split("1\t15\tSTORE_CH_SPECIAL\tSTORE_CH_SPECIAL_GROUP1\n1\t15\tSTORE_CH_SMITH\tSTORE_CH_SMITH_GROUP1"),
		split("1\t15\t25\tSTORE_CH_SPECIAL_TAB1\tSTORE_CH_SPECIAL_GROUP1\tSN_TAB_SPECIAL\n1\t15\t2\tSTORE_CH_SMITH_TAB1\tSTORE_CH_SMITH_GROUP1\tSN_TAB_WEAPON"),
		split("1\t15\tSTORE_CH_SPECIAL_TAB1\tPACKAGE_CH_02\t1\n1\t15\tSTORE_CH_SPECIAL_TAB1\tPACKAGE_CH_01\t0\n1\t15\tSTORE_CH_SMITH_TAB1\tPACKAGE_BLADE\t0"),
		split("1\t15\tPACKAGE_CH_01\tITEM_ETC_TRADE_CH_01\n1\t15\tPACKAGE_CH_02\tITEM_ETC_TRADE_CH_02\n1\t15\tPACKAGE_BLADE\tITEM_CH_BLADE_01"),
		func(code string) (ItemInfo, bool) {
			switch code {
			case "ITEM_ETC_TRADE_CH_01":
				return ItemInfo{ID: 2147, TypeID1: 3, TypeID2: 3, TypeID3: 8}, true
			case "ITEM_ETC_TRADE_CH_02":
				return ItemInfo{ID: 2148, TypeID1: 3, TypeID2: 3, TypeID3: 8}, true
			case "ITEM_CH_BLADE_01":
				return ItemInfo{ID: 3, TypeID1: 3, TypeID2: 1, TypeID3: 6}, true
			}
			return ItemInfo{}, false
		})
	if len(shops) != 1 || !shops.SellsSpecialty("npc_ch_special") || shops.SellsSpecialty("NPC_CH_SMITH") {
		t.Fatalf("shops %v", shops)
	}
	if g, ok := shops.At("NPC_CH_SPECIAL", 0, 1); !ok || g.Item != 2148 {
		t.Fatalf("At(0, 1) = %v %v", g, ok)
	}
	var buf bytes.Buffer
	if err := WriteShops(&buf, shops); err != nil {
		t.Fatal(err)
	}
	back, err := ReadShops(&buf)
	if err != nil || len(back["NPC_CH_SPECIAL"]) != 2 || back.Tabs("NPC_CH_SPECIAL") != 1 {
		t.Fatalf("round trip %v %v", back, err)
	}
}

func TestPercents(t *testing.T) {
	rows, _ := ReadQuotes(strings.NewReader("2,1,7,30,1.1,1.1,1.1,50000,250,50000\n1,1,7,29,1.2,1.2,1.2,0,250,0\n3,0,7,31,1.1,1.1,1.1,50000,250,50000\n"))
	b := NewBoard(rows, func(int64) int64 { return 4000 })
	p := b.Percents(7)
	if len(p) != 2 || p[0] != (ItemPercent{29, 120}) || p[1] != (ItemPercent{30, 110}) {
		t.Fatalf("percents %v", p)
	}
}
