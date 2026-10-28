package mall

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
)

// The Silk Lottery (round 838, OURS). The archive's mall sells three tickets,
// ITEM_LOTTERY_BRONZE / _SILVER / _GOLD (3/3/5/1, 50 / 100 / 150 silk,
// CanUse 0), each "A ticket that automatically registers you for the Silk
// Lottery Event upon purchase." The event itself was the private server's,
// and nothing in the archive says how it is drawn or what it pays. OpenSRO's
// smallest honest version:
//
//   - The purchase registers: one entry per ticket bought, carrying the silk
//     it cost, written in the purchase's own transaction. The ticket still
//     goes to the bag (or the chest) as the purchase's item -- the receipt.
//   - A GM draws (/lottery draw): one winner among the open entries, each
//     entry weighted by the silk it cost (a gold ticket is three bronze
//     chances), and the winner's account is paid the pot -- the silk every
//     open entry cost -- as own silk, unless the GM names another prize.
//     Every open entry is then closed, the winner's marked won.
//   - /lottery alone shows the open entries and the pot.

// LotteryTicketPrefix names the tickets: every ITEM_LOTTERY_ row.
const LotteryTicketPrefix = "ITEM_LOTTERY_"

// IsLotteryTicket reports whether code is a Silk Lottery ticket.
func IsLotteryTicket(code string) bool {
	return strings.HasPrefix(strings.ToUpper(code), LotteryTicketPrefix)
}

// LotteryEntry is one ticket's registration.
type LotteryEntry struct {
	ID          int64
	AccountID   int64
	CharacterID int64
	Ticket      string // the ticket's code
	Silk        int64  // what the ticket cost: its weight and its share of the pot
	At          time.Time
}

// ErrNoLotteryEntries is a draw with no open entry.
var ErrNoLotteryEntries = errors.New("mall: no open lottery entries")

// LotteryStore keeps the registrations. Every write joins the context's
// transaction, so a ticket's entry stands or falls with its purchase.
type LotteryStore interface {
	RegisterLottery(ctx context.Context, e LotteryEntry) error
	// OpenLottery is the entries not yet drawn, oldest first.
	OpenLottery(ctx context.Context) ([]LotteryEntry, error)
	// CloseLottery closes every open entry at at, marking winnerID's won
	// with prize; it answers how many it closed.
	CloseLottery(ctx context.Context, winnerID, prize int64, at time.Time) (int, error)
}

// LotteryPick is the weighted draw: roll in [0, the entries' total silk)
// picks the entry whose span holds it. An entry of no silk has no chance; ok
// is false when no entry has any.
func LotteryPick(es []LotteryEntry, roll func(n int64) int64) (LotteryEntry, int64, bool) {
	var total int64
	for _, e := range es {
		total += max(e.Silk, 0)
	}
	if total <= 0 {
		return LotteryEntry{}, 0, false
	}
	r := roll(total)
	for _, e := range es {
		if w := max(e.Silk, 0); r < w {
			return e, total, true
		} else {
			r -= w
		}
	}
	return es[len(es)-1], total, true
}

// lotterySchema is the registrations' table.
const lotterySchema = `
CREATE TABLE IF NOT EXISTS mall_lottery (
	id           BIGSERIAL PRIMARY KEY,
	account_id   BIGINT NOT NULL,
	character_id BIGINT NOT NULL,
	ticket       TEXT NOT NULL,
	silk         BIGINT NOT NULL DEFAULT 0,
	created_at   TIMESTAMPTZ NOT NULL,
	drawn_at     TIMESTAMPTZ,
	won          BOOLEAN NOT NULL DEFAULT FALSE,
	prize        BIGINT NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS mall_lottery_open ON mall_lottery (id) WHERE drawn_at IS NULL;
`

// memLottery is one MemStore registration.
type memLottery struct {
	LotteryEntry
	drawn bool
	won   bool
	prize int64
}

// RegisterLottery implements LotteryStore.
func (m *MemStore) RegisterLottery(ctx context.Context, e LotteryEntry) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.nextID++
	e.ID = m.nextID
	m.lottery = append(m.lottery, memLottery{LotteryEntry: e})
	id := e.ID
	txn.OnRollback(ctx, func() {
		m.mu.Lock()
		defer m.mu.Unlock()
		for i, l := range m.lottery {
			if l.ID == id {
				m.lottery = append(m.lottery[:i], m.lottery[i+1:]...)
				return
			}
		}
	})
	return nil
}

// OpenLottery implements LotteryStore.
func (m *MemStore) OpenLottery(_ context.Context) ([]LotteryEntry, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var out []LotteryEntry
	for _, l := range m.lottery {
		if !l.drawn {
			out = append(out, l.LotteryEntry)
		}
	}
	return out, nil
}

// CloseLottery implements LotteryStore.
func (m *MemStore) CloseLottery(ctx context.Context, winnerID, prize int64, _ time.Time) (int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var closed []int64
	for i := range m.lottery {
		l := &m.lottery[i]
		if l.drawn {
			continue
		}
		l.drawn = true
		if l.ID == winnerID {
			l.won, l.prize = true, prize
		}
		closed = append(closed, l.ID)
	}
	txn.OnRollback(ctx, func() {
		m.mu.Lock()
		defer m.mu.Unlock()
		for i := range m.lottery {
			for _, id := range closed {
				if m.lottery[i].ID == id {
					m.lottery[i].drawn, m.lottery[i].won, m.lottery[i].prize = false, false, 0
				}
			}
		}
	})
	return len(closed), nil
}

// RegisterLottery implements LotteryStore.
func (s *SQLStore) RegisterLottery(ctx context.Context, e LotteryEntry) error {
	if _, err := txn.Conn(ctx, s.db).ExecContext(ctx, `INSERT INTO mall_lottery
		(account_id, character_id, ticket, silk, created_at) VALUES ($1, $2, $3, $4, $5)`,
		e.AccountID, e.CharacterID, e.Ticket, e.Silk, e.At); err != nil {
		return fmt.Errorf("mall: registering a lottery ticket: %w", err)
	}
	return nil
}

// OpenLottery implements LotteryStore. Inside a transaction the rows are
// locked, so two draws cannot both close them.
func (s *SQLStore) OpenLottery(ctx context.Context) ([]LotteryEntry, error) {
	q := `SELECT id, account_id, character_id, ticket, silk, created_at FROM mall_lottery
		WHERE drawn_at IS NULL ORDER BY id`
	if txn.InSQL(ctx) {
		q += ` FOR UPDATE`
	}
	rows, err := txn.Conn(ctx, s.db).QueryContext(ctx, q)
	if err != nil {
		return nil, fmt.Errorf("mall: reading the lottery: %w", err)
	}
	defer rows.Close()
	var out []LotteryEntry
	for rows.Next() {
		var e LotteryEntry
		if err := rows.Scan(&e.ID, &e.AccountID, &e.CharacterID, &e.Ticket, &e.Silk, &e.At); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// CloseLottery implements LotteryStore.
func (s *SQLStore) CloseLottery(ctx context.Context, winnerID, prize int64, at time.Time) (int, error) {
	res, err := txn.Conn(ctx, s.db).ExecContext(ctx, `UPDATE mall_lottery SET drawn_at = $1, won = (id = $2),
		prize = CASE WHEN id = $2 THEN $3 ELSE 0 END WHERE drawn_at IS NULL`, at, winnerID, prize)
	if err != nil {
		return 0, fmt.Errorf("mall: closing the lottery: %w", err)
	}
	n, err := res.RowsAffected()
	return int(n), err
}
