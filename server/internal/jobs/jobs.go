// Package jobs holds the trade-route job rules recovered from
// SR_GameServer.exe -- the trader/hunter/thief system, its job guilds, the
// specialty goods they move, and the flea market.
//
// srrevamp has none of this. The package is the recovered rule set.
//
// See docs/protocol/jobs.md.
package jobs

// The refusal codes, with the client's name for each.
const (
	ErrSpecialtyNotTrade   = 0x184e // SPECIALTY_ERR_NOTTRADE
	ErrOnlyTraderCanBuy    = 0x1860 // STRGERR_ONLY_TRADER_CAN_BUY_SPECIALTY
	ErrJobGuildNotFound    = 0x480f // the job guild lookup failed
	ErrJobGuildLevel       = 0x4819 // JOBGUILD_JOIN_ERR_LEVEL
	ErrUnknownJobKind      = 0x4828 // the kind byte was not 1, 2 or 3
	ErrFleaMarketFull      = 0x3c18 // FLEAMARKET_ERR_MARKET_FULL
	ErrFleaMarketHostLeft  = 0x3c15 // FLEAMARKET_ERR_HOST_LEFT
	ErrFleaMarketHostClose = 0x3c17 // FLEAMARKET_ERR_CLOSED_BY_HOST
)

// MinJobLevel is 20, enforced in two unrelated places, both through vtable
// slot 73 (`+0x124`, the level getter) and both with the same comparison:
//
//	FUN_005120f0 (join a job guild):        if (level < 0x14) -> 0x4819
//	GObjPC::SellItemAtSpecialtyShop:        if (level < 0x14) -> 0x184e
//
// so 20 is the floor for taking a job at all and for trading the goods a job
// exists to move.
const MinJobLevel = 20

// Kind is the job a character takes. The join handler reads a byte and accepts
// exactly three values.
type Kind uint8

const (
	KindA Kind = 1
	KindB Kind = 2
	KindC Kind = 3
)

// kindIDs is what the handler maps each kind byte to:
//
//	if (b == 1) x = 0x14; else if (b == 2) x = 0x15;
//	else if (b == 3) x = 0x16; else return 0x4828;
//
// BEWARE THE COINCIDENCE: kind 1 maps to 20, and MinJobLevel is also 20. They
// are different things -- one is an identifier, the other a level -- and they
// are only equal by accident. Collapsing them would be a real bug.
//
// WHICH KIND IS TRADER, HUNTER OR THIEF IS NOT RECOVERED. The game has three
// such jobs and there are three kinds, but nothing read so far names them, so
// they are A, B and C here rather than a guess in a fixed order.
var kindIDs = map[Kind]int{KindA: 0x14, KindB: 0x15, KindC: 0x16}

// ID returns the identifier the join handler maps a kind to, and whether the
// kind is one the handler accepts.
func (k Kind) ID() (int, bool) {
	id, ok := kindIDs[k]
	return id, ok
}

// Valid reports whether the join handler would accept this kind byte.
func (k Kind) Valid() bool { _, ok := kindIDs[k]; return ok }

// CheckJoin returns 0 when a character may join a job guild, or the refusal.
// The kind is validated before the level, which is the handler's order.
func CheckJoin(kind Kind, level int) int {
	if !kind.Valid() {
		return ErrUnknownJobKind
	}
	if level < MinJobLevel {
		return ErrJobGuildLevel
	}
	return 0
}

// FleaMarketSlots is 8. FUN_004734e0 refuses with FLEAMARKET_ERR_MARKET_FULL
// when the entry vector is that long:
//
//	iVar2 = *(int *)(this + 0x198) - (int)begin;
//	if (begin != NULL && iVar2 >> 2 == 8) -> 0x3c18
//
// `>> 2` over a pointer difference is a count of 4-byte elements, so the vector
// holds eight.
const FleaMarketSlots = 8

// Procs are the stored procedures this system calls.
var Procs = map[string]int{
	"_InsertCharTrijobSafeTradeData": 3,
	"_DeleteCharTrijobSafeTradeData": 1,
	"_OpenMarket_Insert":             17,
	"_OpenMarket_Purchase":           9,
	"_OpenMarket_Cancle":             6, // the engine's spelling
	"_OpenMarket_Update":             5,
	"_OpenMarket_Receipt":            3,
}
