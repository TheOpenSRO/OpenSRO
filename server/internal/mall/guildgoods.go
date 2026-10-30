package mall

import (
	"sort"
	"strconv"
)

// Round 844 lane G (part 2): the guild stores' goods and their GP prices.
// Every good the STORE_*_GUILD tabs sell has two price rows, PaymentDevice 1
// (gold) and PaymentDevice 8 (the guild's GP), and the engine charges both:
// the gold at once, the GP from the guild (READ s:0x618930's two arms,
// CheckCurrencyRequirement s:0x617360; MEASURED in the player's archive, 20
// packages, one item each, sold by no other store). The silk shop registry
// (Build) keeps only NPC-less groups, so these are kept beside it, keyed by
// the package's item id: an NPC store's buy names the item (OpShopBuy).
const PaymentGP uint32 = 8

// NPCGPPrices is the GP price of each item an NPC store sells with a
// PaymentDevice 8 row, keyed by item id (OURS key; the engine's is the
// package's price record +0x20).
func buildNPCGPPrices(packages map[string]*Package, npcPackages map[string]bool) map[int64]int64 {
	out := map[int64]int64{}
	for code := range npcPackages {
		pk := packages[code]
		if pk == nil || pk.Mask&PaymentGP == 0 || len(pk.Scraps) != 1 {
			continue
		}
		out[pk.Scraps[0].Item.ID] = pk.Cost[PaymentGP]
	}
	return out
}

// GPPrice is the GP an NPC store's item costs (0 none).
func (c *Catalogue) GPPrice(itemID int64) int64 {
	if c == nil {
		return 0
	}
	return c.NPCGP[itemID]
}

// npcGPRows is the CSV's "npcgp" rows: item id, GP.
func npcGPRows(c *Catalogue, row func(string) []string) [][]string {
	var ids []int64
	for id := range c.NPCGP {
		ids = append(ids, id)
	}
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
	var out [][]string
	for _, id := range ids {
		r := row("npcgp")
		r[cItemID] = strconv.FormatInt(id, 10)
		r[cPrices] = strconv.FormatInt(c.NPCGP[id], 10)
		out = append(out, r)
	}
	return out
}
