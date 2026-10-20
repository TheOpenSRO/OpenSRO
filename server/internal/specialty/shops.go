package specialty

import (
	"encoding/csv"
	"fmt"
	"io"
	"os"
	"sort"
	"strconv"
	"strings"
)

// The specialty stores' goods (round 801): what a 0x7034 type 0x13 buy's
// {tab, slot} names at an NPC. The engine resolves it through the NPC's
// first shop (the request's shop index is never read: GObjPC::FUN_0042fae0
// zeroes it, s:0x42fae0) -> the tab at the request's index -> the goods at
// the slot -> the package's item (FUN_005266a0 -> FUN_00618fe0, READ). The
// chain is the client's own textdata (the client's ShopReader walks the
// same files):
//
//	refshopgroup          [3] group, [4] NPC code
//	refmappingshopgroup   [2] group -> [3] shop
//	refmappingshopwithtab [2] shop  -> [3] tab group
//	refshoptab            [3] tab, [4] tab group
//	refshopgoods          [2] tab, [3] package, [4] slot
//	refscrapofpackageitem [2] package -> [3] item code
//
// Only the NPCs whose store lists a good of TypeID 3/3/8 are kept: the
// engine gives such an NPC interaction 0xc (GObjPC::FUN_004c7920 s:0x4c79a7,
// ShopApp::FUN_00867850 with the TID word 0x46c = 3/3/8) and builds its
// quotation map. The tab index counts the shop's tabs in table order across
// its tab groups (INFERRED: every specialty store has one tab group of one
// tab, MEASURED, so the order never shows).

// Good is one store slot.
type Good struct {
	NPC       string // the NPC's code name, upper case
	Tab, Slot int
	Item      int64
	Specialty bool // the item is TypeID 3/3/8
}

// ShopColumns is the CSV's header.
var ShopColumns = []string{"NPCCode", "Tab", "Slot", "ItemID", "Specialty"}

// Shops is the goods by NPC code.
type Shops map[string][]Good

// At is the good at npc's tab and slot.
func (s Shops) At(npc string, tab, slot int) (Good, bool) {
	for _, g := range s[strings.ToUpper(npc)] {
		if g.Tab == tab && g.Slot == slot {
			return g, true
		}
	}
	return Good{}, false
}

// Tabs is the number of tabs npc's store has.
func (s Shops) Tabs(npc string) int {
	n := 0
	for _, g := range s[strings.ToUpper(npc)] {
		if g.Tab+1 > n {
			n = g.Tab + 1
		}
	}
	return n
}

// SellsSpecialty reports whether npc's store lists a good of 3/3/8: the
// engine's test for interaction 0xc.
func (s Shops) SellsSpecialty(npc string) bool {
	for _, g := range s[strings.ToUpper(npc)] {
		if g.Specialty {
			return true
		}
	}
	return false
}

// ItemInfo is what the builder needs of an item code.
type ItemInfo struct {
	ID                        int64
	TypeID1, TypeID2, TypeID3 int
}

// BuildShops walks the chain over textdata rows (tab-split, as the exporter
// reads them) and keeps the NPCs selling a 3/3/8 good. items resolves an
// item code.
func BuildShops(shopGroup, mapGroup, mapTab, tabs, goods, scrap [][]string, items func(code string) (ItemInfo, bool)) Shops {
	col := func(r []string, i int) string {
		if i < len(r) {
			return strings.TrimSpace(r[i])
		}
		return ""
	}
	type kv struct{ k, v string }
	var npcGroups []kv
	for _, r := range shopGroup {
		if n := col(r, 4); strings.HasPrefix(strings.ToUpper(n), "NPC_") {
			npcGroups = append(npcGroups, kv{strings.ToUpper(n), col(r, 3)})
		}
	}
	shopsOf := map[string][]string{}
	for _, r := range mapGroup {
		if col(r, 3) != "" {
			shopsOf[col(r, 2)] = append(shopsOf[col(r, 2)], col(r, 3))
		}
	}
	groupsOf := map[string][]string{}
	for _, r := range mapTab {
		if col(r, 3) != "" {
			groupsOf[col(r, 2)] = append(groupsOf[col(r, 2)], col(r, 3))
		}
	}
	tabsOf := map[string][]string{}
	for _, r := range tabs {
		if col(r, 3) != "" {
			tabsOf[col(r, 4)] = append(tabsOf[col(r, 4)], col(r, 3))
		}
	}
	type slotPkg struct {
		slot int
		pkg  string
	}
	goodsOf := map[string][]slotPkg{}
	for _, r := range goods {
		slot, err := strconv.Atoi(col(r, 4))
		if err != nil || col(r, 3) == "" {
			continue
		}
		goodsOf[col(r, 2)] = append(goodsOf[col(r, 2)], slotPkg{slot, col(r, 3)})
	}
	itemOf := map[string]string{}
	for _, r := range scrap {
		if col(r, 3) != "" {
			itemOf[col(r, 2)] = col(r, 3)
		}
	}
	out := Shops{}
	seen := map[string]bool{}
	for _, ng := range npcGroups {
		if seen[ng.k] {
			// The NPC's first shop only (the request's shop index is 0).
			continue
		}
		shops := shopsOf[ng.v]
		if len(shops) == 0 {
			continue
		}
		seen[ng.k] = true
		var list []Good
		tab := 0
		for _, tg := range groupsOf[shops[0]] {
			for _, t := range tabsOf[tg] {
				for _, sp := range goodsOf[t] {
					code := itemOf[sp.pkg]
					if code == "" {
						continue
					}
					it, ok := items(code)
					if !ok {
						continue
					}
					list = append(list, Good{NPC: ng.k, Tab: tab, Slot: sp.slot, Item: it.ID,
						Specialty: it.TypeID1 == 3 && it.TypeID2 == 3 && it.TypeID3 == 8})
				}
				tab++
			}
		}
		keep := false
		for _, g := range list {
			keep = keep || g.Specialty
		}
		if keep {
			sort.SliceStable(list, func(i, j int) bool {
				if list[i].Tab != list[j].Tab {
					return list[i].Tab < list[j].Tab
				}
				return list[i].Slot < list[j].Slot
			})
			out[ng.k] = list
		}
	}
	return out
}

// WriteShops writes the CSV.
func WriteShops(w io.Writer, s Shops) error {
	cw := csv.NewWriter(w)
	if err := cw.Write(ShopColumns); err != nil {
		return err
	}
	npcs := make([]string, 0, len(s))
	for n := range s {
		npcs = append(npcs, n)
	}
	sort.Strings(npcs)
	for _, n := range npcs {
		for _, g := range s[n] {
			sp := "0"
			if g.Specialty {
				sp = "1"
			}
			if err := cw.Write([]string{g.NPC, strconv.Itoa(g.Tab), strconv.Itoa(g.Slot),
				strconv.FormatInt(g.Item, 10), sp}); err != nil {
				return err
			}
		}
	}
	cw.Flush()
	return cw.Error()
}

// ReadShops parses the CSV.
func ReadShops(r io.Reader) (Shops, error) {
	cr := csv.NewReader(r)
	recs, err := cr.ReadAll()
	if err != nil {
		return nil, err
	}
	if len(recs) == 0 || len(recs[0]) < len(ShopColumns) || recs[0][0] != ShopColumns[0] {
		return nil, fmt.Errorf("specialty shops CSV: want the header %v", ShopColumns)
	}
	out := Shops{}
	for i, rec := range recs[1:] {
		tab, e1 := strconv.Atoi(rec[1])
		slot, e2 := strconv.Atoi(rec[2])
		item, e3 := strconv.ParseInt(rec[3], 10, 64)
		if e1 != nil || e2 != nil || e3 != nil {
			return nil, fmt.Errorf("specialty shops CSV row %d: bad number", i+2)
		}
		n := strings.ToUpper(strings.TrimSpace(rec[0]))
		out[n] = append(out[n], Good{NPC: n, Tab: tab, Slot: slot, Item: item, Specialty: rec[4] == "1"})
	}
	return out, nil
}

// LoadShops reads the CSV file.
func LoadShops(path string) (Shops, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return ReadShops(f)
}
