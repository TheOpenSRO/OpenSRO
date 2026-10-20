// Package jobs holds the trade-route job rules recovered from
// SR_GameServer.exe -- the trader/hunter/thief system, its job guilds, the
// specialty goods they move, and the flea market.
//
// Round 799 builds the job guild on it: the record and its store
// (record.go, sqlstore.go), the exp rules (exp.go) and the wire (wire.go).
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

	// The job guild's other refusals (round 799, READ the handlers
	// s:0x5120f0..0x513190 and their completions; the names are the
	// client's UIIT where it has one).
	ErrNPC             = 3      // not at (or not interacting with) the NPC: FUN_004e72a0 != 1, a literal
	ErrDB              = 2      // an async query failed to post (UIIT_MSG_PARTYERR_UNKNOWN_ERROR)
	ErrNotEnoughGold   = 0x4807 // the join or alias-change fee (no client text)
	ErrJobOverlap      = 0x4820 // JOBGUILD_JOIN_ERR_OVERLAP: already in a job
	ErrSuitWorn        = 0x4822 // UIIT_CTL_JOBGUILD_WITHD_ERR_WEARITEM (withdraw and alias)
	ErrAliasRule       = 0x4823 // ALIAS_CREATE_ERR_NOTRULE
	ErrJoinPenalty     = 0x4824 // JOBGUILD_JOIN_ERR_EXPIRE: 7 days after a withdrawal
	ErrAliasTaken1     = 0x4825 // ALIAS_CREATE_ERR_NAMEDULPLICATE (the procedure's -1)
	ErrAliasTaken2     = 0x4826 // the same text (the procedure's -2)
	ErrNoOldJobInfo    = 0x4829 // JOBINFO_OLD_NOTEXIST
	ErrNoReward        = 0x482a // a collect with nothing to collect (no client text)
	ErrWithdrawInQuest = 0x482e // JOBGUILD_WITHD_ERR_QUEST
)

// JoinFee is the join's gold (READ s:0x5121d3 `sub eax,0x14; imul 0x1388`,
// charged at the join's completion, s:0x4e7a2a): (level - 20) x 5000.
func JoinFee(level int) int64 { return int64(level-MinJobLevel) * 5000 }

// AliasChangeFee is a changed alias's gold (READ GObjPC_HandleAliasMsg_0e3:
// level x 50000, charged only when the old alias was not empty; the client's
// cost line is the same, c:0x74b82d).
func AliasChangeFee(level int) int64 { return int64(level) * 50000 }

// PenaltySeconds is the withdrawal's timed job: 0x93a80 s = 604800 s = 7 days
// (JobGuild_HandleWithdraw s:0x5124b8).
const PenaltySeconds = 604800

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
	KindTrader Kind = 1
	KindThief  Kind = 2 // "Robber" in the engine's own word
	KindHunter Kind = 3

	// The former placeholders, kept as aliases so nothing that used A/B/C
	// breaks; the names above are the engine's.
	KindA = KindTrader
	KindB = KindThief
	KindC = KindHunter
)

// Name is the engine's own word for a kind: two independent labellers,
// 0x466e70 (on GetJobType, vtable slot 71) and GObjPC::FUN_0060da10 (on the
// job record's byte at +0x1c), both spell 1 "Trader", 2 "Robber", 3 "Hunter",
// and 0 "no job" (round 273). Nothing else in the package depends on the
// order; the ids 0x14..0x16 stay what the join handler maps.
func (k Kind) Name() string {
	switch k {
	case KindTrader:
		return "Trader"
	case KindThief:
		return "Robber"
	case KindHunter:
		return "Hunter"
	}
	return "no job"
}

// kindIDs is what the handler maps each kind byte to:
//
//	if (b == 1) x = 0x14; else if (b == 2) x = 0x15;
//	else if (b == 3) x = 0x16; else return 0x4828;
//
// BEWARE THE COINCIDENCE: kind 1 maps to 20, and MinJobLevel is also 20. They
// are different things -- one is an identifier, the other a level -- and they
// are only equal by accident. Collapsing them would be a real bug.
//
// Which kind is which WAS unrecovered until round 273; the engine's own
// labellers name them (see Kind.Name), and the ids below are unchanged.
var kindIDs = map[Kind]int{KindTrader: 0x14, KindThief: 0x15, KindHunter: 0x16}

// ID returns the identifier the join handler maps a kind to, and whether the
// kind is one the handler accepts.
func (k Kind) ID() (int, bool) {
	id, ok := kindIDs[k]
	return id, ok
}

// Valid reports whether the join handler would accept this kind byte.
func (k Kind) Valid() bool { _, ok := kindIDs[k]; return ok }

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
