package account

// Punishments (round 788): an account's blocks, modelled on retail's
// `_Punishment` rows (docs/protocol/opcodes/login.md, "Punishments"). Retail
// keeps them in the account database, written by the operator's console (the
// SMC's SR_UserPunishment.dll: "block login", "block login for inspection",
// "block p2p trade", "block chat") and by GlobalManager's automatic
// punishment for too many wrong passwords (`_RegisterAutomatedPunishment`,
// GlobalManager 0x4277a5). This is OpenSRO's own schema informed by those
// fields, not a port of the original table.

import (
	"context"
	"errors"
	"fmt"
	"time"
)

// PunishmentType is what a punishment blocks. The numbers are the SMC's
// order of its four kinds (INFERRED from the plugin's list, agreeing with the
// gateway and the game server, RESEARCH section 2).
type PunishmentType uint8

const (
	// PunishLogin blocks logging in: the gateway answers 0xA102 [2,2,1,
	// reason, end] (READ: `_CertifyTB_User` result 3 -> `_QueryBlockGuide`,
	// GatewayServer 0x415f2d / 0x415f46).
	PunishLogin PunishmentType = 1
	// PunishLoginInspection is the SMC's "block login for inspection". How
	// the gateway treats it is decided inside the account database's
	// `_CertifyTB_User`, which this package does not have (OPEN): the gateway
	// itself knows only certify result 0 (in), 3 (blocked) and anything else
	// (wrong password), 0x415f25-0x415f41. OURS: it blocks a login exactly
	// as PunishLogin does, with its own guide and end time.
	PunishLoginInspection PunishmentType = 2
	// PunishTrade blocks player-to-player trade (the game server's own
	// check, 0x3405 kind 1). Stored, not yet enforced (round 788).
	PunishTrade PunishmentType = 3
	// PunishChat blocks chat (0x3405 kind 0). Stored, not yet enforced.
	PunishChat PunishmentType = 4
)

// Valid reports whether t is one of the four kinds.
func (t PunishmentType) Valid() bool { return t >= PunishLogin && t <= PunishChat }

// BlocksLogin reports whether a punishment of this kind keeps the account
// out (types 1 and 2; see PunishLoginInspection).
func (t PunishmentType) BlocksLogin() bool { return t == PunishLogin || t == PunishLoginInspection }

// String is the kind's name as the SMC lists it.
func (t PunishmentType) String() string {
	switch t {
	case PunishLogin:
		return "block login"
	case PunishLoginInspection:
		return "block login for inspection"
	case PunishTrade:
		return "block p2p trade"
	case PunishChat:
		return "block chat"
	}
	return fmt.Sprintf("punishment type %d", uint8(t))
}

// LoginBlockTypes are the kinds Authenticate and the unblock end.
var LoginBlockTypes = []PunishmentType{PunishLogin, PunishLoginInspection}

// Punishment is one record. The SMC's other fields (shard, character name
// and info, position, sentenced time, e-mail template) are not kept (OURS:
// nothing reads them).
type Punishment struct {
	// Serial is the record's id (retail's SerialNo), assigned by the store.
	Serial    int64
	AccountID int64
	Type      PunishmentType
	// Executor is who raised it: a GM's account name, or AutomatedPunisher.
	Executor string
	// Guide is the reason the player is shown (retail's "Guide For Web";
	// for a login block, the reason in 0xA102 [2,2,1]).
	Guide string
	// Description is the staff-only note (retail's "Accident Description").
	Description string
	// RaisedAt is when it was recorded; BeginAt..EndAt is when it holds.
	RaisedAt time.Time
	BeginAt  time.Time
	// EndAt is the end; the zero time is "infinite" (NULL in the database).
	EndAt time.Time
}

// Infinite reports whether the punishment has no end.
func (p Punishment) Infinite() bool { return p.EndAt.IsZero() }

// ActiveAt reports whether the punishment holds at t: begun, not ended.
func (p Punishment) ActiveAt(t time.Time) bool {
	return !t.Before(p.BeginAt) && (p.Infinite() || t.Before(p.EndAt))
}

// endsAfter orders two punishments by end, an infinite one last.
func (p Punishment) endsAfter(q Punishment) bool {
	switch {
	case p.Infinite() != q.Infinite():
		return p.Infinite()
	case !p.EndAt.Equal(q.EndAt):
		return p.EndAt.After(q.EndAt)
	}
	return p.Serial > q.Serial
}

// AutomatedPunisher is the executor of the automatic block for wrong
// passwords: the name GlobalManager's `AutomatedPunisher` config key holds
// (READ string 0x12a850; MEASURED value "AutomatedPunisher" in the package's
// server.cfg).
const AutomatedPunisher = "AutomatedPunisher"

// BlockedError is Authenticate's answer for an account with the right
// password and an active login block. errors.Is(err, ErrBlocked) holds.
// Punishment is the active login block that ends last (OURS when several
// hold: retail's `_QueryBlockGuide` returns one row, which one is the
// procedure's, OPEN).
type BlockedError struct {
	Punishment Punishment
}

func (e *BlockedError) Error() string {
	if e.Punishment.Infinite() {
		return fmt.Sprintf("%v: %q, no end", ErrBlocked, e.Punishment.Guide)
	}
	return fmt.Sprintf("%v: %q until %s", ErrBlocked, e.Punishment.Guide, e.Punishment.EndAt.Format(time.RFC3339))
}

// Is makes errors.Is(err, ErrBlocked) true.
func (e *BlockedError) Is(target error) bool { return target == ErrBlocked }

// PunishmentStore keeps the punishments. MemStore and SQLStore implement it.
type PunishmentStore interface {
	// AddPunishment records p for p.AccountID and returns it with its
	// Serial (and RaisedAt, when p left it zero). ErrNoSuchAccount for an
	// account that does not exist; an error for an invalid type or an end
	// not after the begin.
	AddPunishment(ctx context.Context, p Punishment) (Punishment, error)
	// Punishments returns every punishment of accountID, newest first.
	Punishments(ctx context.Context, accountID int64) ([]Punishment, error)
	// ActivePunishments returns accountID's punishments active at at, the
	// one ending last first.
	ActivePunishments(ctx context.Context, accountID int64, at time.Time) ([]Punishment, error)
	// EndPunishments ends, at at, each punishment of accountID of one of
	// types that has not ended by then (a future one included), and returns
	// how many it ended.
	EndPunishments(ctx context.Context, accountID int64, at time.Time, types ...PunishmentType) (int, error)
}

// AccountLookup finds accounts without a password: the GM console's and the
// automatic punishment's (retail's `_RegisterAutomatedPunishment` takes the
// account NAME, GlobalManager 0x4277a5). ErrNoSuchAccount when none.
type AccountLookup interface {
	AccountByName(ctx context.Context, username string) (*Account, error)
	AccountByID(ctx context.Context, accountID int64) (*Account, error)
}

// checkPunishment validates p before it is stored.
func checkPunishment(p Punishment) error {
	if !p.Type.Valid() {
		return fmt.Errorf("account: punishment type %d is not 1-4", p.Type)
	}
	if p.BeginAt.IsZero() {
		return errors.New("account: punishment has no begin time")
	}
	if !p.Infinite() && !p.EndAt.After(p.BeginAt) {
		return errors.New("account: punishment ends before it begins")
	}
	return nil
}

// typeSet reports the types given, all four when none is.
func typeSet(types []PunishmentType) map[PunishmentType]bool {
	set := map[PunishmentType]bool{}
	for _, t := range types {
		set[t] = true
	}
	return set
}

// migratedExecutor and migratedDescription mark the punishments made from the
// old accounts.blocked column (round 788's migration, sqlstore.go) and by
// SetBlocked, which now writes a punishment.
const (
	migratedExecutor    = "accounts.blocked"
	migratedDescription = "made from the accounts.blocked flag (round 788)"
)
