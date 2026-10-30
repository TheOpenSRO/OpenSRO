package mall

import (
	"encoding/csv"
	"fmt"
	"io"
	"os"
	"sort"
	"strconv"
	"strings"
)

// The mall CSV (round 837, OURS: the file format; its content is the player's
// archive): what `export-refdata -mode mall` writes and cmd/server's
// -mall-csv loads. One file, one row per thing, the Kind column saying which:
//
//	group  Group, GroupCode                     an NPC-less shop group (registered even with no shop)
//	shop   Group, Shop, ShopCode                the shop at its index in the group
//	tab    Group, Shop, Tab, TabCode            the tab at its index in the shop (empty tabs too)
//	good   Group, Shop, Tab, Slot, the package  a good: PackageID..Prices
//	scrap  Group, Shop, Tab, Slot, the item     the good's next scrap row: ItemID..MagParams
//
// Prices is "device:cost" pairs joined by "|" (e.g. "2:30|4:30"); MagParams
// the scrap row's MagParam1..n joined by "|".

// CSVColumns is the header.
var CSVColumns = []string{"Kind", "Group", "GroupCode", "Shop", "ShopCode", "Tab", "TabCode", "Slot",
	"PackageID", "PackageCode", "SaleTag", "ExpandTerm", "Prices",
	"ItemID", "ItemCode", "TypeID1", "TypeID2", "TypeID3", "TypeID4", "Bionic", "MaxStack", "CashItem",
	"OptLevel", "Variance", "Data", "MagParams"}

const (
	cKind = iota
	cGroup
	cGroupCode
	cShop
	cShopCode
	cTab
	cTabCode
	cSlot
	cPackageID
	cPackageCode
	cSaleTag
	cExpandTerm
	cPrices
	cItemID
	cItemCode
	cType1
	cType2
	cType3
	cType4
	cBionic
	cMaxStack
	cCashItem
	cOptLevel
	cVariance
	cData
	cMagParams
	nColumns
)

func b01(b bool) string {
	if b {
		return "1"
	}
	return "0"
}

func itoa(v int) string { return strconv.Itoa(v) }

// pricesField is a package's Cost as "device:cost|...", devices ascending.
func pricesField(p *Package) string {
	var bits []int
	for b := range p.Cost {
		bits = append(bits, int(b))
	}
	sort.Ints(bits)
	parts := make([]string, 0, len(bits))
	for _, b := range bits {
		parts = append(parts, fmt.Sprintf("%d:%d", b, p.Cost[uint32(b)]))
	}
	return strings.Join(parts, "|")
}

func paramsField(ps []uint64) string {
	parts := make([]string, len(ps))
	for i, p := range ps {
		parts[i] = strconv.FormatUint(p, 10)
	}
	return strings.Join(parts, "|")
}

// WriteCSV writes the catalogue, groups by id.
func WriteCSV(w io.Writer, c *Catalogue) error {
	cw := csv.NewWriter(w)
	if err := cw.Write(CSVColumns); err != nil {
		return err
	}
	var ids []int
	for id := range c.Groups {
		ids = append(ids, id)
	}
	sort.Ints(ids)
	for _, id := range ids {
		if err := writeGroup(cw, c.Groups[id]); err != nil {
			return err
		}
	}
	// Round 844: the NPC stores' GP prices (guildgoods.go).
	for _, r := range npcGPRows(c, func(kind string) []string {
		r := make([]string, nColumns)
		r[cKind] = kind
		return r
	}) {
		if err := cw.Write(r); err != nil {
			return err
		}
	}
	cw.Flush()
	return cw.Error()
}

func writeGroup(cw *csv.Writer, g *Group) error {
	row := func(kind string) []string {
		r := make([]string, nColumns)
		r[cKind], r[cGroup] = kind, itoa(g.ID)
		return r
	}
	r := row("group")
	r[cGroupCode] = g.Code
	if err := cw.Write(r); err != nil {
		return err
	}
	for si, sh := range g.Shops {
		r := row("shop")
		r[cShop], r[cShopCode] = itoa(si), sh.Code
		if err := cw.Write(r); err != nil {
			return err
		}
		for ti, t := range sh.Tabs {
			r := row("tab")
			r[cShop], r[cTab], r[cTabCode] = itoa(si), itoa(ti), t.Code
			if err := cw.Write(r); err != nil {
				return err
			}
			var slots []int
			for s := range t.Goods {
				slots = append(slots, s)
			}
			sort.Ints(slots)
			for _, s := range slots {
				if err := writeGood(cw, row, si, ti, t.Goods[s]); err != nil {
					return err
				}
			}
		}
	}
	return nil
}

func writeGood(cw *csv.Writer, row func(string) []string, si, ti int, gd *Good) error {
	key := func(kind string) []string {
		r := row(kind)
		r[cShop], r[cTab], r[cSlot] = itoa(si), itoa(ti), itoa(gd.Slot)
		return r
	}
	p := gd.Package
	r := key("good")
	r[cPackageID], r[cPackageCode], r[cSaleTag] = strconv.FormatInt(p.ID, 10), p.Code, itoa(p.SaleTag)
	r[cExpandTerm], r[cPrices] = p.ExpandTerm, pricesField(p)
	if err := cw.Write(r); err != nil {
		return err
	}
	for _, sc := range p.Scraps {
		r := key("scrap")
		it := sc.Item
		r[cItemID], r[cItemCode] = strconv.FormatInt(it.ID, 10), it.Code
		r[cType1], r[cType2], r[cType3], r[cType4] = itoa(it.TypeID[0]), itoa(it.TypeID[1]), itoa(it.TypeID[2]), itoa(it.TypeID[3])
		r[cBionic], r[cMaxStack], r[cCashItem] = b01(it.Bionic), itoa(it.MaxStack), b01(it.CashItem)
		r[cOptLevel], r[cVariance], r[cData] = itoa(int(sc.OptLevel)), strconv.FormatUint(sc.Variance, 10), itoa(sc.Data)
		r[cMagParams] = paramsField(sc.MagParams)
		if err := cw.Write(r); err != nil {
			return err
		}
	}
	return nil
}

// csvReader keeps what ReadCSV has built so far.
type csvReader struct {
	cat  *Catalogue
	line int
}

func (cr *csvReader) errf(format string, args ...any) error {
	return fmt.Errorf("mall CSV row %d: %s", cr.line, fmt.Sprintf(format, args...))
}

func (cr *csvReader) num(r []string, i int) (int, error) {
	v, err := strconv.Atoi(strings.TrimSpace(r[i]))
	if err != nil {
		return 0, cr.errf("bad %s %q", CSVColumns[i], r[i])
	}
	return v, nil
}

// at finds the group, shop and tab a row names.
func (cr *csvReader) at(r []string, depth int) (*Group, *Shop, *Tab, error) {
	gid, err := cr.num(r, cGroup)
	if err != nil {
		return nil, nil, nil, err
	}
	g := cr.cat.Groups[gid]
	if g == nil {
		return nil, nil, nil, cr.errf("group %d before its group row", gid)
	}
	if depth == 0 {
		return g, nil, nil, nil
	}
	si, err := cr.num(r, cShop)
	if err != nil || si < 0 || si >= len(g.Shops) {
		return nil, nil, nil, cr.errf("shop %q not listed", r[cShop])
	}
	sh := g.Shops[si]
	if depth == 1 {
		return g, sh, nil, nil
	}
	ti, err := cr.num(r, cTab)
	if err != nil || ti < 0 || ti >= len(sh.Tabs) {
		return nil, nil, nil, cr.errf("tab %q not listed", r[cTab])
	}
	return g, sh, sh.Tabs[ti], nil
}

func (cr *csvReader) row(r []string) error {
	switch r[cKind] {
	case "group":
		gid, err := cr.num(r, cGroup)
		if err != nil {
			return err
		}
		cr.cat.Groups[gid] = &Group{ID: gid, Code: r[cGroupCode]}
	case "shop":
		g, _, _, err := cr.at(r, 0)
		if err != nil {
			return err
		}
		if si, err := cr.num(r, cShop); err != nil || si != len(g.Shops) {
			return cr.errf("shop %q out of order", r[cShop])
		}
		g.Shops = append(g.Shops, &Shop{Code: r[cShopCode]})
	case "tab":
		_, sh, _, err := cr.at(r, 1)
		if err != nil {
			return err
		}
		if ti, err := cr.num(r, cTab); err != nil || ti != len(sh.Tabs) {
			return cr.errf("tab %q out of order", r[cTab])
		}
		sh.Tabs = append(sh.Tabs, &Tab{Code: r[cTabCode], Goods: map[int]*Good{}})
	case "good":
		return cr.good(r)
	case "scrap":
		return cr.scrap(r)
	case "npcgp":
		// Round 844: an NPC store item's GP price (guildgoods.go).
		id, err1 := strconv.ParseInt(r[cItemID], 10, 64)
		gp, err2 := strconv.ParseInt(r[cPrices], 10, 64)
		if err1 != nil || err2 != nil {
			return cr.errf("bad npcgp row")
		}
		if cr.cat.NPCGP == nil {
			cr.cat.NPCGP = map[int64]int64{}
		}
		cr.cat.NPCGP[id] = gp
	default:
		return cr.errf("unknown kind %q", r[cKind])
	}
	return nil
}

func (cr *csvReader) good(r []string) error {
	_, _, t, err := cr.at(r, 2)
	if err != nil {
		return err
	}
	slot, err := cr.num(r, cSlot)
	if err != nil {
		return err
	}
	id, err := strconv.ParseInt(r[cPackageID], 10, 64)
	if err != nil {
		return cr.errf("bad PackageID %q", r[cPackageID])
	}
	tag, _ := strconv.Atoi(r[cSaleTag])
	p := &Package{ID: id, Code: r[cPackageCode], SaleTag: tag, ExpandTerm: r[cExpandTerm], Cost: map[uint32]int64{}}
	for _, pair := range strings.Split(r[cPrices], "|") {
		if pair == "" {
			continue
		}
		dev, cost, ok := strings.Cut(pair, ":")
		d, e1 := strconv.ParseUint(dev, 10, 32)
		c, e2 := strconv.ParseInt(cost, 10, 64)
		if !ok || e1 != nil || e2 != nil || lowestBit(uint32(d)) != uint32(d) || d == 0 {
			return cr.errf("bad price %q", pair)
		}
		p.Mask |= uint32(d)
		p.Cost[uint32(d)] = c
	}
	t.Goods[slot] = &Good{Slot: slot, Package: p}
	return nil
}

func (cr *csvReader) scrap(r []string) error {
	_, _, t, err := cr.at(r, 2)
	if err != nil {
		return err
	}
	slot, err := cr.num(r, cSlot)
	if err != nil {
		return err
	}
	gd := t.Goods[slot]
	if gd == nil {
		return cr.errf("scrap row before its good")
	}
	var it Item
	if it.ID, err = strconv.ParseInt(r[cItemID], 10, 64); err != nil {
		return cr.errf("bad ItemID %q", r[cItemID])
	}
	it.Code = r[cItemCode]
	for k, c := range []int{cType1, cType2, cType3, cType4} {
		if it.TypeID[k], err = cr.num(r, c); err != nil {
			return err
		}
	}
	it.Bionic, it.CashItem = r[cBionic] == "1", r[cCashItem] == "1"
	if it.MaxStack, err = cr.num(r, cMaxStack); err != nil {
		return err
	}
	sc := Scrap{Item: it}
	opt, err := cr.num(r, cOptLevel)
	if err != nil {
		return err
	}
	sc.OptLevel = uint8(opt)
	if sc.Variance, err = strconv.ParseUint(r[cVariance], 10, 64); err != nil {
		return cr.errf("bad Variance %q", r[cVariance])
	}
	if sc.Data, err = cr.num(r, cData); err != nil {
		return err
	}
	for _, p := range strings.Split(r[cMagParams], "|") {
		if p == "" {
			continue
		}
		v, err := strconv.ParseUint(p, 10, 64)
		if err != nil {
			return cr.errf("bad MagParam %q", p)
		}
		sc.MagParams = append(sc.MagParams, v)
	}
	gd.Package.Scraps = append(gd.Package.Scraps, sc)
	return nil
}

// ReadCSV parses the CSV.
func ReadCSV(r io.Reader) (*Catalogue, error) {
	rd := csv.NewReader(r)
	rd.FieldsPerRecord = -1
	recs, err := rd.ReadAll()
	if err != nil {
		return nil, err
	}
	if len(recs) == 0 || len(recs[0]) < nColumns || recs[0][0] != CSVColumns[0] {
		return nil, fmt.Errorf("mall CSV: want the header %v", CSVColumns)
	}
	cr := &csvReader{cat: &Catalogue{Groups: map[int]*Group{}}}
	for i, rec := range recs[1:] {
		cr.line = i + 2
		if len(rec) < nColumns {
			return nil, cr.errf("%d columns, want %d", len(rec), nColumns)
		}
		if err := cr.row(rec); err != nil {
			return nil, err
		}
	}
	return cr.cat, nil
}

// LoadCSV reads the CSV file.
func LoadCSV(path string) (*Catalogue, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return ReadCSV(f)
}
