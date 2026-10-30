// Package mall is the item mall's server side (round 837): the catalogue
// built from the player's own textdata, the purchase's checks and payment,
// the silk history and OpenSRO's item chest.
//
// The specs are docs/protocol/item_mall_wire.md (the wire and SR_GameServer's
// purchase path), item_mall_data.md (the tables) and item_mall.md (the
// client's window), each with its review (*_verify.md). Addresses: s:
// SR_GameServer.exe, c: sro_client.exe. Labels as everywhere: READ (seen in
// code), MEASURED (counted in data), INFERRED (the reason is given), OPEN,
// OURS.
//
// No row of any table is in this repository (docs/LEGAL.md): the catalogue
// comes from `export-refdata -mode mall` run on the operator's own archive,
// loaded with cmd/server's -mall-csv.
package mall

import (
	"strconv"
	"strings"
)

// The PaymentDevice bits (item_mall_data.md §4, READ: _UPDATE_COST's
// #defines and _STRG_ADD_PACKAGEITEM_CORE's token block). A price row carries
// one bit; a package's mask is the OR of its rows' lowest bits
// (ReferenceData::FUN_006a99c0).
const (
	DeviceGold       uint32 = 1
	DeviceSilk       uint32 = 2 // own silk
	DeviceGiftSilk   uint32 = 4
	DeviceGuildPoint uint32 = 8
	DevicePoint      uint32 = 16 // mileage: the silk points
	DeviceHonor      uint32 = 32
	// DeviceTokens are bits 64..1024, the brass/steel/silver/gold tokens and
	// the arena medal: payable only by operation 0x2b (43).
	DeviceTokens uint32 = 64 | 128 | 256 | 512 | 1024
)

// ExpandTerm values (s:0x6a94a0 compares the package's string with these two;
// s:0x617950 tests them at purchase, item_mall_wire_verify.md M6).
const (
	ExpandTermAll = "EXPAND_TERM_ALL"
	ExpandTermOne = "EXPAND_TERM_ONE"
)

// Item is what the purchase needs of an itemdata row: its id, code and type
// words, and MaxStack (column 57).
type Item struct {
	ID       int64
	Code     string
	TypeID   [4]int // TypeID1..4
	Bionic   bool   // the TID word's bit 1 (itemdata column 8)
	MaxStack int
	CashItem bool
}

// Expendable reports the non-bionic 3/3 the slot-count and quantity rules
// single out (s:0x4de170, _GetNeededSlotCountByBuyPackageItem).
func (it Item) Expendable() bool {
	return it.TypeID[0] == 3 && it.TypeID[1] == 3 && !it.Bionic
}

// Stackable reports an item one slot can hold several of. INFERRED: the
// engine asks the item (vslot 0x4c, item_mall_wire_verify.md W5), OpenSRO's
// bag stacks by MaxStack.
func (it Item) Stackable() bool { return it.MaxStack > 1 }

// Scrap is one _RefScrapOfPackageItem row: an item the package gives, with
// the instance it is made with (item_mall_data.md §1.8).
type Scrap struct {
	Item      Item
	OptLevel  uint8
	Variance  uint64
	Data      int // an expendable's stack count; else the instance's Data word
	MagParams []uint64
}

// Package is one _RefPackageItem row: the GOOD, with its scrap rows and its
// prices (item_mall_data.md §1.7, §1.9).
type Package struct {
	ID         int64
	Code       string
	SaleTag    int
	ExpandTerm string
	// Mask is the OR of the price rows' devices; Cost the Cost of each
	// device bit present (keyed by the bit's value, 1..1024).
	Mask   uint32
	Cost   map[uint32]int64
	Scraps []Scrap
}

// Good is one _RefShopGoods row, resolved: the slot in a tab and its package.
type Good struct {
	Slot    int
	Package *Package
}

// Tab is one tab of a shop's first tab group, in refshoptab's order; empty
// tabs are kept, since the client counts them (c:0x7e4b0c / 0x7e50ea, W11).
type Tab struct {
	Code  string
	Goods map[int]*Good // by SlotIndex
}

// Shop is one shop of a silk shop group, at its index in the group.
type Shop struct {
	Code string
	Tabs []*Tab
}

// Group is one NPC-less shop group: what CMainProcess::FUN_00411b30 registers
// as a silk shop, its shops in refmappingshopgroup's order.
type Group struct {
	ID    int
	Code  string
	Shops []*Shop
}

// Catalogue is the silk shop registry (DAT_00d6a9e4 in retail), keyed by the
// group id the purchase names.
type Catalogue struct {
	Groups map[int]*Group
	// NPCGP is the GP price of each NPC store item with one (round 844,
	// guildgoods.go): the guild stores' goods.
	NPCGP map[int64]int64
}

// Shop is the registered shop at (group, index), the lookup s:0x526610 makes
// through s:0x523740 -> s:0x5236f0 (READ). ok false is retail's "SilkShop
// was not registered" (refused 2).
func (c *Catalogue) Shop(group, index int) (*Shop, bool) {
	if c == nil {
		return nil, false
	}
	g := c.Groups[group]
	if g == nil || index < 0 || index >= len(g.Shops) {
		return nil, false
	}
	return g.Shops[index], true
}

// Counts are a catalogue's sizes, for the export's and the server's logs.
type Counts struct {
	Groups, Shops, Tabs, Goods, Packages int
}

// Count totals the catalogue.
func (c *Catalogue) Count() Counts {
	var n Counts
	if c == nil {
		return n
	}
	pk := map[*Package]bool{}
	for _, g := range c.Groups {
		n.Groups++
		for _, s := range g.Shops {
			n.Shops++
			for _, t := range s.Tabs {
				n.Tabs++
				for _, gd := range t.Goods {
					n.Goods++
					pk[gd.Package] = true
				}
			}
		}
	}
	n.Packages = len(pk)
	return n
}

// Tables are the textdata rows Build reads, each split on tabs as the
// exporter reads them (column 0 is Service).
type Tables struct {
	ShopGroup, MapGroup, MapTab, TabGroup, Tab, Goods, Package, Scrap, Price [][]string
}

// col is a row's trimmed column, "" past its end.
func col(r []string, i int) string {
	if i < len(r) {
		return strings.TrimSpace(r[i])
	}
	return ""
}

// live drops Service-0 rows. INFERRED: the client's loader reads column 0
// itself and skips a 0 (READ for mallitemmenulistdata, c:0x95739d,
// item_mall_data_verify.md U4); a client file carries only Service-1 rows
// (MEASURED), so this only matters for a hand-made table.
func live(rows [][]string) [][]string {
	out := make([][]string, 0, len(rows))
	for _, r := range rows {
		if col(r, 0) == "0" {
			continue
		}
		out = append(out, r)
	}
	return out
}

// noNPC is the placeholder RefShopGroup_ExtractData tests (s:0x6a9fb0, U6:
// the 3-character placeholder; `xxx` in every source, MEASURED).
func noNPC(s string) bool { return s == "" || strings.EqualFold(s, "xxx") }

// trimTrailing drops a row's trailing empty fields (A's rows end in one or two
// tabs, B's in none: item_mall_data_verify.md, §1 encoding).
func trimTrailing(r []string) []string {
	for len(r) > 0 && strings.TrimSpace(r[len(r)-1]) == "" {
		r = r[:len(r)-1]
	}
	return r
}

// lowestBit is the lowest set bit of v, 0 when none.
func lowestBit(v uint32) uint32 { return v & -v }

// Build walks the chain (item_mall_data.md §2) for every NPC-less shop group.
// items resolves an itemdata code name; a scrap row whose item it does not
// know is dropped, as the client's parser drops it (c:0x9824e0,
// item_mall_data_verify.md §1.8).
//
// The orders, and why:
//   - a group's shops: refmappingshopgroup's row order. READ on the client
//     (c:0x9379c0, the shop's position in its group's list); the server builds
//     its list from the rows in load order (FUN_004119e0, U12), whose SQL
//     order is OPEN. The file order is alphabetical in every source
//     (MEASURED), so the two agree on the shipped data.
//   - a shop's tabs: the FIRST tab group's tabs only, in refshoptab's row
//     order, empty tabs counted. READ: the client builds sub-tabs from the
//     first group alone (0x7e4a90, W10) and the request's tab byte is
//     CMallItemData +0x8 (c:0x7e8651 reads it), the counter zeroed at
//     c:0x7e4b0c and stepped per tab at c:0x7e50ea (W11). Which tabs the
//     SERVER's shop counts for 0x1806 is OPEN; every mall shop has one tab
//     group (MEASURED), so the two agree.
func Build(t Tables, items func(code string) (Item, bool)) *Catalogue {
	shopsOf := map[string][]string{}
	for _, r := range live(t.MapGroup) {
		if col(r, 3) != "" {
			shopsOf[col(r, 2)] = append(shopsOf[col(r, 2)], col(r, 3))
		}
	}
	groupsOf := map[string][]string{}
	for _, r := range live(t.MapTab) {
		if col(r, 3) != "" {
			groupsOf[col(r, 2)] = append(groupsOf[col(r, 2)], col(r, 3))
		}
	}
	tabsOf := map[string][]string{}
	tabName := map[string]string{}
	for _, r := range live(t.Tab) {
		if col(r, 3) != "" {
			tabsOf[col(r, 4)] = append(tabsOf[col(r, 4)], col(r, 3))
			tabName[col(r, 3)] = col(r, 5)
		}
	}
	packages := buildPackages(t, items)
	goodsOf := map[string]map[int]*Good{}
	for _, r := range live(t.Goods) {
		slot, err := strconv.Atoi(col(r, 4))
		pk := packages[col(r, 3)]
		if err != nil || pk == nil {
			continue
		}
		if goodsOf[col(r, 2)] == nil {
			goodsOf[col(r, 2)] = map[int]*Good{}
		}
		goodsOf[col(r, 2)][slot] = &Good{Slot: slot, Package: pk}
	}
	borrowed := borrowedGoods(shopsOf[AvatarStoreGroup], groupsOf, tabsOf, tabName, goodsOf)
	cat := &Catalogue{Groups: map[int]*Group{}}
	// Round 844: the packages NPC groups' tabs sell (their goods' package
	// codes), for their GP prices.
	npcPackages := map[string]bool{}
	for _, r := range live(t.ShopGroup) {
		if noNPC(col(r, 4)) {
			continue
		}
		for _, sc := range shopsOf[col(r, 3)] {
			for _, tg := range groupsOf[sc] {
				for _, tc := range tabsOf[tg] {
					for _, gd := range goodsOf[tc] {
						npcPackages[gd.Package.Code] = true
					}
				}
			}
		}
	}
	cat.NPCGP = buildNPCGPPrices(packages, npcPackages)
	for _, r := range live(t.ShopGroup) {
		id, err := strconv.Atoi(col(r, 2))
		if err != nil || !noNPC(col(r, 4)) {
			continue
		}
		g := &Group{ID: id, Code: col(r, 3)}
		for _, sc := range shopsOf[g.Code] {
			sh := &Shop{Code: sc}
			if tgs := groupsOf[sc]; len(tgs) > 0 {
				for _, tc := range tabsOf[tgs[0]] {
					goods := goodsOf[tc]
					if len(goods) == 0 {
						goods = borrowed[tabName[tc]]
					}
					if goods == nil {
						goods = map[int]*Good{}
					}
					sh.Tabs = append(sh.Tabs, &Tab{Code: tc, Goods: goods})
				}
			}
			g.Shops = append(g.Shops, sh)
		}
		cat.Groups[id] = g
	}
	return cat
}

// AvatarStoreGroup is the shop group whose tabs fill a silk shop's empty
// ones (OURS, round 838). The player's archive leaves the mall's Avatar
// shop's Hat, Dress and Attach tabs empty and sells its avatars, for silk, at
// an NPC store (GROUP_STORE_AVATARS) whose tabs carry the same names. An
// empty tab of an NPC-less group takes the goods of the avatar store's tab
// of its name, so the mall sells them at the store's SlotIndex. The client
// does the same (client MallData.borrowed_goods), so a purchase's (shop,
// tab, slot) names the same good on both sides.
const AvatarStoreGroup = "GROUP_STORE_AVATARS"

// borrowedGoods is the avatar store's goods by tab name: each tab of each of
// its shops' first tab group, its goods with a silk or gift-silk price only.
func borrowedGoods(storeShops []string, groupsOf, tabsOf map[string][]string, tabName map[string]string, goodsOf map[string]map[int]*Good) map[string]map[int]*Good {
	out := map[string]map[int]*Good{}
	for _, sc := range storeShops {
		tgs := groupsOf[sc]
		if len(tgs) == 0 {
			continue
		}
		for _, tc := range tabsOf[tgs[0]] {
			name := tabName[tc]
			if name == "" || out[name] != nil {
				continue
			}
			goods := map[int]*Good{}
			for slot, g := range goodsOf[tc] {
				if g.Package.Mask&(DeviceSilk|DeviceGiftSilk) != 0 {
					goods[slot] = g
				}
			}
			if len(goods) > 0 {
				out[name] = goods
			}
		}
	}
	return out
}

// buildPackages reads the packages with their scrap rows and prices.
func buildPackages(t Tables, items func(code string) (Item, bool)) map[string]*Package {
	out := map[string]*Package{}
	for _, r := range live(t.Package) {
		id, err := strconv.ParseInt(col(r, 2), 10, 64)
		if err != nil || col(r, 3) == "" {
			continue
		}
		tag, _ := strconv.Atoi(col(r, 4))
		out[col(r, 3)] = &Package{ID: id, Code: col(r, 3), SaleTag: tag, ExpandTerm: col(r, 5), Cost: map[uint32]int64{}}
	}
	for _, r := range live(t.Scrap) {
		pk := out[col(r, 2)]
		if pk == nil {
			continue
		}
		it, ok := items(col(r, 3))
		if !ok {
			continue
		}
		opt, _ := strconv.Atoi(col(r, 4))
		variance, _ := strconv.ParseUint(col(r, 5), 10, 64)
		data, _ := strconv.Atoi(col(r, 6))
		nParams, _ := strconv.Atoi(col(r, 7))
		var params []uint64
		for i := 0; i < nParams && i < 12; i++ {
			v, _ := strconv.ParseUint(col(r, 8+i), 10, 64)
			params = append(params, v)
		}
		pk.Scraps = append(pk.Scraps, Scrap{Item: it, OptLevel: uint8(opt), Variance: variance, Data: data, MagParams: params})
	}
	for _, r := range live(t.Price) {
		pk := out[col(r, 2)]
		if pk == nil {
			continue
		}
		dev64, err := strconv.ParseUint(col(r, 3), 10, 32)
		bit := lowestBit(uint32(dev64))
		if err != nil || bit == 0 {
			continue
		}
		// Cost is column 5 of the 14-column layout the server reads (Service,
		// Country, package, PaymentDevice, PreviousCost, Cost, 8 params: READ
		// RefPricePolicyOfItem_ExtractData s:0x6a8b80). A 13-column file
		// (the y0gi package's, no PreviousCost; MEASURED) has it at 4.
		ci := 5
		if len(trimTrailing(r)) == 13 {
			ci = 4
		}
		cost, err := strconv.ParseInt(col(r, ci), 10, 64)
		if err != nil {
			continue
		}
		pk.Mask |= bit
		pk.Cost[bit] = cost
	}
	return out
}
