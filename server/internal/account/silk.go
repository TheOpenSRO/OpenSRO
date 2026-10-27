package account

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
)

// Silk is an account's three silk balances (round 837): own silk, gift silk
// and the silk points (mileage), the order of the client's 0x3153
// (docs/protocol/item_mall_wire.md §2.1).
//
// OURS, the storage: retail's GameServer reads them over HTTP from a billing
// web server (billing_silkdatacall.asp, s:0x6a1750) which reads the account
// database (SRO_VT_ACCOUNT, not in any backup here). OpenSRO keeps them on its
// own accounts row: silk_own, silk_gift and silk_point. They belong to the
// ACCOUNT, as retail's JID-keyed balances do: every character on it shares
// them.
type Silk struct {
	Own, Gift, Point int64
}

// SilkKind names one of the three balances.
type SilkKind int

const (
	SilkOwn SilkKind = iota
	SilkGift
	SilkPoint
)

// ErrInsufficientSilk is SpendSilk's answer when a balance holds less than
// asked; nothing is taken.
var ErrInsufficientSilk = errors.New("account: not enough silk")

// SilkStore keeps the balances. Every method joins the context's transaction
// (txn), so a purchase's spend stands or falls with its items.
type SilkStore interface {
	// Silk reads accountID's balances. With a starting grant set
	// (SetStartingSilk), an account read for the first time is given it, once.
	Silk(ctx context.Context, accountID int64) (Silk, error)
	// AddSilk moves one balance by delta (negative subtracts), floored at 0,
	// and answers the balances after.
	AddSilk(ctx context.Context, accountID int64, kind SilkKind, delta int64) (Silk, error)
	// SpendSilk takes own, gift and point (each >= 0) at once, or nothing
	// with ErrInsufficientSilk.
	SpendSilk(ctx context.Context, accountID int64, own, gift, point int64) (Silk, error)
}

// silkSchema adds the balances to the accounts table. silk_seeded marks an
// account the starting grant (OPENSRO_STARTING_SILK) was given to.
const silkSchema = `
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS silk_own BIGINT NOT NULL DEFAULT 0;
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS silk_gift BIGINT NOT NULL DEFAULT 0;
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS silk_point BIGINT NOT NULL DEFAULT 0;
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS silk_seeded BOOLEAN NOT NULL DEFAULT FALSE;
`

var silkColumns = [...]string{SilkOwn: "silk_own", SilkGift: "silk_gift", SilkPoint: "silk_point"}

func (k SilkKind) valid() bool { return k >= SilkOwn && k <= SilkPoint }

// SetStartingSilk sets the own silk an account is given the first time its
// balances are read (OURS, OPENSRO_STARTING_SILK; 0, the default, gives none
// and marks nothing, so turning it on later still gives every account it once).
func (s *SQLStore) SetStartingSilk(n int64) { s.startingSilk = max(n, 0) }

// Silk implements SilkStore.
func (s *SQLStore) Silk(ctx context.Context, accountID int64) (Silk, error) {
	q := txn.Conn(ctx, s.db)
	if s.startingSilk > 0 {
		if _, err := q.ExecContext(ctx, `UPDATE accounts SET silk_own = silk_own + $1, silk_seeded = TRUE
			WHERE id = $2 AND NOT silk_seeded`, s.startingSilk, accountID); err != nil {
			return Silk{}, fmt.Errorf("account: granting the starting silk: %w", err)
		}
	}
	var b Silk
	err := q.QueryRowContext(ctx, `SELECT silk_own, silk_gift, silk_point FROM accounts WHERE id = $1`, accountID).
		Scan(&b.Own, &b.Gift, &b.Point)
	if errors.Is(err, sql.ErrNoRows) {
		return Silk{}, ErrNoSuchAccount
	}
	if err != nil {
		return Silk{}, fmt.Errorf("account: reading silk: %w", err)
	}
	return b, nil
}

// AddSilk implements SilkStore.
func (s *SQLStore) AddSilk(ctx context.Context, accountID int64, kind SilkKind, delta int64) (Silk, error) {
	if !kind.valid() {
		return Silk{}, fmt.Errorf("account: no silk kind %d", kind)
	}
	c := silkColumns[kind]
	var b Silk
	err := txn.Conn(ctx, s.db).QueryRowContext(ctx, `UPDATE accounts SET `+c+` = GREATEST(`+c+` + $1, 0) WHERE id = $2
		RETURNING silk_own, silk_gift, silk_point`, delta, accountID).Scan(&b.Own, &b.Gift, &b.Point)
	if errors.Is(err, sql.ErrNoRows) {
		return Silk{}, ErrNoSuchAccount
	}
	if err != nil {
		return Silk{}, fmt.Errorf("account: changing silk: %w", err)
	}
	return b, nil
}

// SpendSilk implements SilkStore: the balance tests are in the statement, so
// two purchases cannot both pass them.
func (s *SQLStore) SpendSilk(ctx context.Context, accountID int64, own, gift, point int64) (Silk, error) {
	if own < 0 || gift < 0 || point < 0 {
		return Silk{}, errors.New("account: a silk spend must not be negative")
	}
	q := txn.Conn(ctx, s.db)
	var b Silk
	err := q.QueryRowContext(ctx, `UPDATE accounts SET silk_own = silk_own - $1, silk_gift = silk_gift - $2,
		silk_point = silk_point - $3 WHERE id = $4 AND silk_own >= $1 AND silk_gift >= $2 AND silk_point >= $3
		RETURNING silk_own, silk_gift, silk_point`, own, gift, point, accountID).Scan(&b.Own, &b.Gift, &b.Point)
	if errors.Is(err, sql.ErrNoRows) {
		var exists bool
		if err := q.QueryRowContext(ctx, `SELECT EXISTS (SELECT 1 FROM accounts WHERE id = $1)`, accountID).Scan(&exists); err == nil && !exists {
			return Silk{}, ErrNoSuchAccount
		}
		return Silk{}, ErrInsufficientSilk
	}
	if err != nil {
		return Silk{}, fmt.Errorf("account: spending silk: %w", err)
	}
	return b, nil
}

// SetStartingSilk is the MemStore's starting grant (see SQLStore's).
func (m *MemStore) SetStartingSilk(n int64) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.startingSilk = max(n, 0)
}

func (a *Account) silkPtr(k SilkKind) *int64 {
	switch k {
	case SilkGift:
		return &a.silk.Gift
	case SilkPoint:
		return &a.silk.Point
	}
	return &a.silk.Own
}

// Silk implements SilkStore.
func (m *MemStore) Silk(ctx context.Context, accountID int64) (Silk, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	acc := m.byID(accountID)
	if acc == nil {
		return Silk{}, ErrNoSuchAccount
	}
	if m.startingSilk > 0 && !acc.silkSeeded {
		grant := m.startingSilk
		acc.silk.Own += grant
		acc.silkSeeded = true
		m.undoLocked(ctx, accountID, func(a *Account) { a.silk.Own -= grant; a.silkSeeded = false })
	}
	return acc.silk, nil
}

// AddSilk implements SilkStore.
func (m *MemStore) AddSilk(ctx context.Context, accountID int64, kind SilkKind, delta int64) (Silk, error) {
	if !kind.valid() {
		return Silk{}, fmt.Errorf("account: no silk kind %d", kind)
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	acc := m.byID(accountID)
	if acc == nil {
		return Silk{}, ErrNoSuchAccount
	}
	p := acc.silkPtr(kind)
	before := *p
	*p = max(*p+delta, 0)
	m.undoLocked(ctx, accountID, func(a *Account) { *a.silkPtr(kind) = before })
	return acc.silk, nil
}

// SpendSilk implements SilkStore.
func (m *MemStore) SpendSilk(ctx context.Context, accountID int64, own, gift, point int64) (Silk, error) {
	if own < 0 || gift < 0 || point < 0 {
		return Silk{}, errors.New("account: a silk spend must not be negative")
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	acc := m.byID(accountID)
	if acc == nil {
		return Silk{}, ErrNoSuchAccount
	}
	if acc.silk.Own < own || acc.silk.Gift < gift || acc.silk.Point < point {
		return Silk{}, ErrInsufficientSilk
	}
	acc.silk.Own -= own
	acc.silk.Gift -= gift
	acc.silk.Point -= point
	m.undoLocked(ctx, accountID, func(a *Account) { a.silk.Own += own; a.silk.Gift += gift; a.silk.Point += point })
	return acc.silk, nil
}
