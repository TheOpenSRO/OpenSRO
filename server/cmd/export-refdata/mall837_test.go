package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/mall"
)

// Round 837: -mode mall over synthetic files (the archive's layouts, made-up
// rows): UTF-8 tables with trailing tabs and a copyright line, one itemdata
// part, and the CSV it writes loads back into the same catalogue.
func TestExportMall(t *testing.T) {
	dir := t.TempDir()
	write := func(name string, rows ...string) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(strings.Join(rows, "\r\n")+"\r\n//Copyright line\r\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		return p
	}
	params := "\t-1\txxx\t-1\txxx\t-1\txxx\t-1\txxx\t"
	item := make([]string, 60)
	for i := range item {
		item[i] = "0"
	}
	item[0], item[1], item[2], item[9], item[10], item[11], item[12], item[fMaxStack] = "1", "501", "ITEM_T_POTION", "3", "3", "1", "1", "50"
	paths := []string{
		write("refshopgroup.txt", "1\t15\t901\tGROUP_T\txxx"+params, "1\t15\t900\tGROUP_N\tNPC_T"+params),
		write("refmappingshopgroup.txt", "1\t15\tGROUP_T\tSHOP_T\t"),
		write("refmappingshopwithtab.txt", "1\t15\tSHOP_T\tSHOP_T_G1\t"),
		write("refshoptabgroup.txt", "1\t15\t1\tSHOP_T_G1\tK\t"),
		write("refshoptab.txt", "1\t15\t1\tTAB_EMPTY\tSHOP_T_G1\tK\t", "1\t15\t2\tTAB_T\tSHOP_T_G1\tK\t"),
		write("refshopgoods.txt", "1\t15\tTAB_T\tPKG_P\t3"+params),
		write("refpackageitem.txt", "1\t15\t7001\tPKG_P\t2\tEXPAND_TERM_ALL\tSN\tSN_D\ticon"+params+"\t"),
		write("refscrapofpackageitem.txt", "1\t15\tPKG_P\tITEM_T_POTION\t0\t0\t11\t0"+strings.Repeat("\t0", 12)+params+"1\t"),
		write("refpricepolicyofitem.txt", "1\t15\tPKG_P\t2\t0\t45"+params, "1\t15\tPKG_P\t4\t0\t45"+params+"\t"),
		write("itemdata_5000.txt", strings.Join(item, "\t")),
	}
	out := filepath.Join(dir, "mall.csv")
	if err := exportMall(out, paths); err != nil {
		t.Fatal(err)
	}
	cat, err := mall.LoadCSV(out)
	if err != nil {
		t.Fatal(err)
	}
	if n := cat.Count(); n != (mall.Counts{Groups: 1, Shops: 1, Tabs: 2, Goods: 1, Packages: 1}) {
		t.Fatalf("counts %+v", n)
	}
	sh, ok := cat.Shop(901, 0)
	if !ok {
		t.Fatal("GROUP_T's shop 0 is not registered")
	}
	p := sh.Tabs[1].Goods[3].Package
	if p.ID != 7001 || p.SaleTag != 2 || p.Cost[mall.DeviceSilk] != 45 || p.Cost[mall.DeviceGiftSilk] != 45 ||
		len(p.Scraps) != 1 || p.Scraps[0].Data != 11 || p.Scraps[0].Item.ID != 501 || p.Scraps[0].Item.MaxStack != 50 {
		t.Fatalf("the good %+v", p)
	}
	if err := exportMall(out, paths[:3]); err == nil {
		t.Fatal("an export without every table succeeded")
	}
}
