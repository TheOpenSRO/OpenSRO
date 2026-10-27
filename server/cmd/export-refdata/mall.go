package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/TheOpenSRO/OpenSRO/server/internal/mall"
)

// mallTables are the textdata files -mode mall reads, by their file names
// (item_mall_data.md §2's join chain).
var mallTables = []string{"refshopgroup.txt", "refmappingshopgroup.txt", "refmappingshopwithtab.txt",
	"refshoptabgroup.txt", "refshoptab.txt", "refshopgoods.txt", "refpackageitem.txt",
	"refscrapofpackageitem.txt", "refpricepolicyofitem.txt"}

// mallItem reads an itemdata row's parts the purchase needs: ID (col 1), code
// (2), CashItem (7), Bionic (8), TypeID1..4 (9..12), MaxStack (57).
func mallItem(cols []string) (mall.Item, bool) {
	if len(cols) <= fMaxStack {
		return mall.Item{}, false
	}
	at := func(i int) int {
		v, _ := strconv.Atoi(strings.TrimSpace(cols[i]))
		return v
	}
	id, err := strconv.ParseInt(strings.TrimSpace(cols[1]), 10, 64)
	if err != nil {
		return mall.Item{}, false
	}
	return mall.Item{ID: id, Code: strings.TrimSpace(cols[2]), CashItem: at(fCashItem) != 0, Bionic: at(8) != 0,
		TypeID: [4]int{at(9), at(10), at(11), at(12)}, MaxStack: at(fMaxStack)}, true
}

// exportMall writes the item mall's catalogue (round 837, mall.Build) from the
// shop chain's nine tables and the item parts.
func exportMall(out string, paths []string) error {
	tables := map[string][][]string{}
	items := map[string]mall.Item{}
	for _, path := range paths {
		tab, err := readTable(path)
		if err != nil {
			return fmt.Errorf("reading %s: %w", path, err)
		}
		base := strings.ToLower(filepath.Base(path))
		if isMallTable(base) {
			tables[base] = append(tables[base], tab...)
			continue
		}
		for _, cols := range tab {
			if it, ok := mallItem(cols); ok {
				items[it.Code] = it
			}
		}
	}
	for _, need := range mallTables {
		if _, ok := tables[need]; !ok {
			return fmt.Errorf("-mode mall needs %s among the inputs", need)
		}
	}
	if len(items) == 0 {
		return fmt.Errorf("-mode mall needs the itemdata parts among the inputs")
	}
	cat := mall.Build(mall.Tables{ShopGroup: tables["refshopgroup.txt"], MapGroup: tables["refmappingshopgroup.txt"],
		MapTab: tables["refmappingshopwithtab.txt"], TabGroup: tables["refshoptabgroup.txt"], Tab: tables["refshoptab.txt"],
		Goods: tables["refshopgoods.txt"], Package: tables["refpackageitem.txt"], Scrap: tables["refscrapofpackageitem.txt"],
		Price: tables["refpricepolicyofitem.txt"]}, func(code string) (mall.Item, bool) {
		it, ok := items[code]
		return it, ok
	})
	var buf strings.Builder
	if err := mall.WriteCSV(&buf, cat); err != nil {
		return err
	}
	if _, err := mall.ReadCSV(strings.NewReader(buf.String())); err != nil {
		return fmt.Errorf("the export does not load back: %w", err)
	}
	if out == "-" {
		if _, err := os.Stdout.WriteString(buf.String()); err != nil {
			return err
		}
	} else if err := os.WriteFile(out, []byte(buf.String()), 0o644); err != nil {
		return err
	}
	n := cat.Count()
	var groups []string
	for id, g := range cat.Groups {
		groups = append(groups, fmt.Sprintf("%s(%d):%d", g.Code, id, len(g.Shops)))
	}
	sort.Strings(groups)
	fmt.Fprintf(os.Stderr, "export-refdata: mall: %d silk shop groups, %d shops, %d tabs, %d goods, %d packages: %s\n",
		n.Groups, n.Shops, n.Tabs, n.Goods, n.Packages, strings.Join(groups, " "))
	return nil
}

func isMallTable(base string) bool {
	for _, t := range mallTables {
		if base == t {
			return true
		}
	}
	return false
}
