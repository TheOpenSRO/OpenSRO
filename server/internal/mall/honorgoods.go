package mall

import (
	"sort"
	"strconv"
)

// Round 865: the honor stores' goods and their honor-point prices. MEASURED in
// the player's archive: 32 store packages carry a PaymentDevice 32 (honor
// point) row, from 10 to 8,000 points, in STORE_<race>_HONOR_TAB1/2, beside
// their gold row ("Price: 46000000Gold", "Honor Point : 2500P" on one item's
// tooltip). The engine charges both, gold first (CheckCurrencyRequirement
// s:0x617360: gold 0x180f, then honor 0x18d4 against the academy member's
// HonorPoint, s:0x617629 / s:0x4ea600), and the database deducts the points
// (_UPDATE_COST, PaymentDevice & 32). Kept beside the GP prices, keyed by the
// package's item id as they are.

// buildNPCHonorPrices is the honor price of each item an NPC store sells with
// a PaymentDevice 32 row, keyed by item id.
func buildNPCHonorPrices(packages map[string]*Package, npcPackages map[string]bool) map[int64]int64 {
	out := map[int64]int64{}
	for code := range npcPackages {
		pk := packages[code]
		if pk == nil || pk.Mask&DeviceHonor == 0 || len(pk.Scraps) != 1 {
			continue
		}
		out[pk.Scraps[0].Item.ID] = pk.Cost[DeviceHonor]
	}
	return out
}

// HonorPrice is the honor points an NPC store's item costs (0 none).
func (c *Catalogue) HonorPrice(itemID int64) int64 {
	if c == nil {
		return 0
	}
	return c.NPCHonor[itemID]
}

// npcHonorRows is the CSV's "npchonor" rows: item id, honor points.
func npcHonorRows(c *Catalogue, row func(string) []string) [][]string {
	var ids []int64
	for id := range c.NPCHonor {
		ids = append(ids, id)
	}
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
	var out [][]string
	for _, id := range ids {
		r := row("npchonor")
		r[cItemID] = strconv.FormatInt(id, 10)
		r[cPrices] = strconv.FormatInt(c.NPCHonor[id], 10)
		out = append(out, r)
	}
	return out
}
