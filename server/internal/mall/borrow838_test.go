package mall

import "testing"

// Round 838 (OURS): an empty tab of an NPC-less group takes the silk-priced
// goods of the avatar store's tab of its name. Synthetic tables, as the
// rest of the package's tests (docs/LEGAL.md).
func TestEmptyTabBorrowsTheAvatarStore(t *testing.T) {
	tb := testTables()
	tb.ShopGroup = append(tb.ShopGroup, pad(row("1", "15", "950", AvatarStoreGroup, "NPC_T_AVATARS"), 8))
	tb.MapGroup = append(tb.MapGroup, row("1", "15", AvatarStoreGroup, "SHOP_AV"))
	tb.MapTab = append(tb.MapTab, row("1", "15", "SHOP_AV", "SHOP_AV_G1"))
	tb.TabGroup = append(tb.TabGroup, row("1", "15", "9", "SHOP_AV_G1", "K"))
	// TAB_A_EMPTY is named K_HAT from here; the store's hat tab carries it.
	for i, r := range tb.Tab {
		if r[3] == "TAB_A_EMPTY" {
			tb.Tab[i] = row("1", "15", "11", "TAB_A_EMPTY", "SHOP_A_G1", "K_HAT")
		}
	}
	tb.Tab = append(tb.Tab,
		row("1", "15", "91", "TAB_AV_HAT", "SHOP_AV_G1", "K_HAT"),
		row("1", "15", "92", "TAB_AV_DRESS", "SHOP_AV_G1", "K_DRESS"))
	tb.Goods = append(tb.Goods,
		pad(row("1", "15", "TAB_AV_HAT", "PKG_SWORD", "17"), 8),
		pad(row("1", "15", "TAB_AV_HAT", "PKG_GOLD", "18"), 8),
		pad(row("1", "15", "TAB_AV_DRESS", "PKG_POTION", "3"), 8))
	c := Build(tb, lookup)
	if _, ok := c.Groups[950]; ok {
		t.Fatal("the avatar store (an NPC group) was registered as a silk shop")
	}
	a := c.Groups[901].Shops[1]
	empty := a.Tabs[0]
	if empty.Code != "TAB_A_EMPTY" || len(empty.Goods) != 1 || empty.Goods[17] == nil || empty.Goods[17].Package.Code != "PKG_SWORD" {
		t.Fatalf("the empty K_HAT tab: want the store hat tab's silk good at slot 17 only, got %+v", empty.Goods)
	}
	if _, ok := empty.Goods[18]; ok {
		t.Fatal("a gold-only store good was borrowed")
	}
	if main := a.Tabs[1]; len(main.Goods) != 14 {
		t.Fatalf("a tab with goods of its own must not borrow: %d goods", len(main.Goods))
	}
}
