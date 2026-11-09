package gameworld

import (
	"math/rand"
	"time"
)

// The entry refusals (READ CanEnter s:0x609c30, base s:0x5ec5b0, the warp
// handler s:0x4f3347, the layer pick s:0x60a5b0; game_worlds.md 5). These are
// the reply codes the client gets in 0xB05A {2, code} (error category 0xd).
const (
	CodeRefused       uint16 = 3      // the warp's plain refusal (no text)
	CodeNoDestination uint16 = 2      // the portal's destination missed
	CodeTradeCOS      uint16 = 0x1c10 // CANT_USE_TELEPORT_WITH_TRADECART
	CodeFlag40000     uint16 = 0x1c17 // player flag 0x40000
	CodeMaxUsers      uint16 = 0x1c25 // OUT_OF_REQUIRED_NUMBER_FOR_TELEPORT
	CodeMasterLayer   uint16 = 0x1c28 // not the master's layer (no text read)
	CodeParty         uint16 = 0x1c2a // no party / fewer than 2 members
	CodeJobSuit       uint16 = 0x1c2b // a job suit or a free-PvP voucher worn
	CodeLevel         uint16 = 0x1c2c // level outside the band
	CodeAccess        uint16 = 0x1c2f // the portal's access rule
	CodeRiding        uint16 = 0x1c30 // CANT_USE_TELEPORT_WITH_RIDE
	CodeAssigned      uint16 = 0x1c31 // INSTANCEDUNGEON_ERROR_MSG_02
	CodeCoolTime      uint16 = 0x1c32 // UIIT_MGS_ERR_GOD_LIMIT_TIME
	CodeDead          uint16 = 0x1c36 // UIIT_MGS_ERR_GOD_DEADSTATE (the exit NPC)
)

// worldBusy and worldNoLayer are CanEnter's own codes 2 and 6, which the
// warp handler answers as 3 (READ s:0x5f9950).
const (
	worldBusy    uint16 = 2
	worldNoLayer uint16 = 6
)

// ReplyCode is CanEnter's code as the client gets it (s:0x5f9950: 2 and 6
// become 3).
func ReplyCode(c uint16) uint16 {
	if c == worldBusy || c == worldNoLayer {
		return CodeRefused
	}
	return c
}

// CoolTime is a running group re-entry limit (the category-0xC timed job,
// CTJ_EnterWorldGroupKeeper: game_worlds.md 5): the group, the instance key
// it was started for and its end.
type CoolTime struct {
	Group int
	Key   uint32
	End   time.Time
}

// Entrant is what CanEnter reads of a character.
type Entrant struct {
	CharID int64
	Level  int
	GM     bool
	// Party is the character's party state: in one, its member count.
	InParty      bool
	PartyMembers int
	JobSuit      bool
	Riding       bool
	TradeCOS     bool
	Voucher      bool
	// Busy is a stall or an exchange open (code 2).
	Busy bool
	// CoolTimes are the character's running group limits.
	CoolTimes []CoolTime
}

// CanEnter is the world's entry check for e into w at now, in the order READ
// (s:0x609c30; 0 is allowed). The codes are CanEnter's own: ReplyCode turns
// them into the reply.
//
//  1. the layer full (WorldMaxUserCount; GMs exempt)         0x1c25
//  2. the party condition (INFERRED: only with EntryType 6,  0x1c2a
//     the type READ to switch the party rule on -- every FGW
//     world's is 0, and a solo entry MEASURED was refused 3,
//     not 0x1c2a)
//  3. a job suit worn (JOB_CLOTHES_TAKE_OFF)                 0x1c2b
//  4. the level outside the band                             0x1c2c
//  5. riding (RIDE_COS_NOT_RIDING)                           0x1c30
//  6. a trade transport out (TRADE_COS_NOT_RIDING)           0x1c10
//  7. a free-PvP voucher worn (FRPVP_VOUCHER_TAKE_OFF)       0x1c2b
//  8. the group cool time running for another instance       0x1c32
//  9. a stall or an exchange                                 2
func CanEnter(w *World, e Entrant, now time.Time) uint16 {
	if w == nil || w.Closed() {
		return worldNoLayer
	}
	ref := w.Ref
	if ref.MaxUsers > 0 && !e.GM {
		n := len(w.Members())
		in := false
		for _, c := range w.Members() {
			if c == e.CharID {
				in = true
			}
		}
		if !in && n >= ref.MaxUsers {
			return CodeMaxUsers
		}
	}
	if ref.EntryType == 6 && (!e.InParty || e.PartyMembers < 2) {
		return CodeParty
	}
	c := ref.Config
	if c.JobSuitOff && e.JobSuit {
		return CodeJobSuit
	}
	if (c.LevelMin > 0 && e.Level < c.LevelMin) || (c.LevelMax > 0 && e.Level > c.LevelMax) {
		return CodeLevel
	}
	if c.NotRiding && e.Riding {
		return CodeRiding
	}
	if c.NoTradeCOS && e.TradeCOS {
		return CodeTradeCOS
	}
	if c.VoucherOff && e.Voucher {
		return CodeJobSuit
	}
	if ref.Group != nil {
		for _, ct := range e.CoolTimes {
			if ct.Group == ref.Group.ID && now.Before(ct.End) && ct.Key != w.Key {
				return CodeCoolTime
			}
		}
	}
	if e.Busy {
		return worldBusy
	}
	return 0
}

// StartPos picks the arrival: a random row of the world's start positions
// (READ s:0x6029e0). ok is false for a world with none.
func StartPosOf(ref *WorldRef, rng *rand.Rand) (StartPos, bool) {
	if ref == nil || len(ref.Starts) == 0 {
		return StartPos{}, false
	}
	if rng == nil || len(ref.Starts) == 1 {
		return ref.Starts[0], true
	}
	return ref.Starts[rng.Intn(len(ref.Starts))], true
}
