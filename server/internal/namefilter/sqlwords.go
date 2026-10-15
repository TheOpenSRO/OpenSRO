package namefilter

// SQLWords is the SQL-injection list SR_ShardManager builds once at
// 0x5261c0 and 0x527390 searches every name for (READ: 54 std::string pushes,
// every one into the vector at 0x89bcf0 -- object 0x89bcb0 + 0x40, its
// begin/end at +0x44/+0x48, 0x1c bytes an element -- in this order; the
// strings at 0x78d30c..0x78d58c). They are not game data: they are the
// server's own table and column-free table names, compiled in.
//
// The search is std::string::find on the name lower-cased by 0x6df010, so
// the 11 entries with a capital letter (from "_BindingOptionWithItem" on) can
// never match: a lower-cased name has a capital only as the trail byte of a
// DBCS pair, and each of those words has a capital right after a byte below
// 0x80. They are kept, as retail keeps them.
//
// Round 788's research note said "45 entries; 34 lower-case, 11 mixed-case";
// the binary has 54 (43 without a capital, 11 with): 54 calls to the insert
// 0x44c340 in 0x5261c0, every one on 0x89bcf0.
var SQLWords = []string{
	"--", "'", "\"", "/*", "*/", "%%", ";",
	"_accountjid", "_alliedclans", "_char", "_charcos", "_charnamelist",
	"_charnicknamelist", "_charquest", "_charskill", "_charskillmastery",
	"_chartrijob", "_chest", "_clientconfig", "_deletedchar", "_friend",
	"_guild", "_guildmember", "_guildwar", "_invcos", "_inventory",
	"_itempool", "_itemquotation", "_items", "_latestitemserial", "_memo",
	"_staticavatar", "_exploitlog", "_timedjob", "_trijobrewards", "_user",
	"_ref", "tab_ref", "sysobjects", "xp_cmdshell", "xp_", "_gacha", "_siege",
	"_BindingOptionWithItem", "_OpenMarket", "_ShopItemStockQuantity",
	"_TempChest", "_ChestInfo", "_InventoryForMagicCube", "_RentItemInfo",
	"_KeepDelCharName", "_TradeBagInventory", "_EquipInvCos",
	"_SupportGoldConfig",
}
