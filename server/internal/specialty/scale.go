package specialty

import "github.com/TheOpenSRO/OpenSRO/server/internal/jobs"

// The trade scale and the transport's bag (READ, SR_GameServer.exe).

// Thresholds are the trade scale's bounds T[0..4] (the table at
// s:0xc826c0): T[0] is 0, T[1..4] the config keys TRADESCALE1..4_AMOUNT_MAX
// (loader CMainProcess::FUN_0060c6c0). TRADESCALE5_AMOUNT_MAX is loaded into
// T[5] but never compared (FUN_0060c330 walks indexes 0..4).
type Thresholds [5]uint32

// EngineDefaultThresholds are the loader's own values when a key is absent
// (s:0x60c6fd.. 0x198, 0x396, 0x594, 0x85e; READ).
var EngineDefaultThresholds = Thresholds{0, 408, 918, 1428, 2142}

// ShardThresholds are the shard's _RefShardContentConfig rows
// TRADESCALE1..4_AMOUNT_MAX (MEASURED: 510, 918, 1428, 2142; TRADESCALE5 is
// 2856), the same numbers as the client's maxtradescaledata.txt after its
// leading 0. The server's default.
var ShardThresholds = Thresholds{0, 510, 918, 1428, 2142}

// EngineDefaultMonFactor and ShardMonFactor are TRADE_MON_FACTOR's loader
// default (0x132) and the shard's row (MEASURED 2300): the ambush count's
// divisor (round 802).
const (
	EngineDefaultMonFactor = 306
	ShardMonFactor         = 2300
)

// RarityFactor is FUN_004d2da0 (s:0x4d2da0): 40 for a COS of rarity 1, 30 for
// rarity 2, 0 (with an assert) for anything else; the callers then take the
// ref's word at +0xe6, which no column OpenSRO exports is known to be
// (OPEN). Every serviced transport row has rarity 1 or 2 (MEASURED), so
// fallback (OURS: 40) is never reached with retail data.
func RarityFactor(rarity int) int {
	switch rarity {
	case 1:
		return 40
	case 2:
		return 30
	}
	return 40
}

// ClampTradeLevel is the trade amount's level: GetMaxLevel (vslot +0x128)
// held to 20..140 (s:0x60c245..0x60c25c).
func ClampTradeLevel(level int) int {
	if level < 20 {
		return 20
	}
	if level > 140 {
		return 140
	}
	return level
}

// Amount is CMainProcess::FUN_0060c1f0 (s:0x60c1f0): the trade amount of a
// transport holding units of goods, for an owner whose clamped level's
// levelgold minimum is goldMin:
//
//	d = units x 348.0 / jobs.Unit(goldMin) / (40.0 / S)
//	amount = 1 when 0 < d < 1, else trunc(d)
//
// 0 when units is 0 (the engine returns 0 with no goods, s:0x60c22c).
func Amount(units int, goldMin int64, rarity int) uint32 {
	if units <= 0 {
		return 0
	}
	u := jobs.Unit(goldMin)
	if u == 0 {
		return 0
	}
	s := float64(RarityFactor(rarity))
	d := float64(units) * 348.0 / float64(u) / (40.0 / s)
	if d > 0 && d < 1 {
		return 1
	}
	if d <= 0 {
		return 0
	}
	return uint32(int64(d))
}

// Scale is FUN_0060c330 (s:0x60c330): the first i in 0..4 with amount <=
// T[i], else 5 -- 0 for an empty transport, 1..5 the stars.
func (t Thresholds) Scale(amount uint32) byte {
	for i := 0; i < 5; i++ {
		if amount <= t[i] {
			return byte(i)
		}
	}
	return 5
}

// BagSize is FUN_004d1a50 (s:0x4d1a50): a transport's usable bag.
// invSize is the ref's InventorySize (+0x224, col 61), goldMin levelgold's
// minimum at the owner's level, rarity col 15, cash the TID word's bit 0
// (with the Bionic bit and TypeID 1/2/3, which every COS row has: Bionic 1
// on all of them, CashItem 1 on 64 of the 94 transport rows, MEASURED):
//
//	cap = trunc(jobs.Unit(goldMin) x 2448 / 11796.0 x 40.0 / S')
//	S'  = S, or S / 1.4 for a cash COS (the float32 1.4 at s:0xb45c08)
//	size = 0 when invSize is 0, else 1 when cap < 1, else min(cap, invSize)
//
// Round 839 traced the rest of the chain (READ): CGObjCOS vslot_349
// (s:0x4d1bd0) makes the cart's storage with InventorySize as its maximum
// (+0x1c, passed in ecx) and this size as its usable count (+0x20,
// s:0x4b7680); the owner's 0x30C8 writes +0x20 (CGCOSInventoryOP slot 29,
// s:0x4ba720); the client draws 28-cell pages and paints every cell past
// the size with interface\pet\pt_block.ddj (c:0x7a7e90). The only other
// caller is GObjPC_SetLevel (s:0x4e4f0a -> s:0x4fc960): on a level change it
// sends 0x30C9 type 2 with the new size when it is above the storage's.
// MEASURED: InventorySize is 1 on all 47 COS_T rows of the archive's
// characterdata and on the same rows of the private server's own
// _RefObjChar (only its COS_T_SCORPION* 50..177 and COS_T_TEMP* 99, absent
// from the client archive, are larger), so min(cap, 1) is 1 at every level:
// retail gives these transports one slot, and so does OpenSRO.
func BagSize(invSize int, goldMin int64, rarity int, cash bool) int {
	if invSize <= 0 {
		return 0
	}
	u := float64(int32(jobs.Unit(goldMin) * 0x990))
	s := float64(RarityFactor(rarity))
	if cash {
		s = s / float64(float32(1.4))
	}
	cp := int64(u / 11796.0 * (40.0 / s))
	if cp < 1 {
		return 1
	}
	if cp < int64(invSize) {
		return int(cp)
	}
	return invSize
}

// LeashRange is the owner-to-transport distance the engine tests (the
// double 1000.0 at s:0xb45c68): the specialty buy and sell (0x1865) and the
// owner's move (0x30E7).
const LeashRange = 1000.0
