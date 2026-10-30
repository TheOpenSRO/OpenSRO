package guildstorage

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"sync"

	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
)

// MemGold is the in-memory GoldStore (tests and -in-memory): every change
// registers its undo with the action's journal (txn.OnRollback).
type MemGold struct {
	mu   sync.Mutex
	gold map[int64]int64
}

// NewMemGold returns an empty MemGold.
func NewMemGold() *MemGold { return &MemGold{gold: map[int64]int64{}} }

// Gold implements GoldStore.
func (m *MemGold) Gold(_ context.Context, guildID int64) (int64, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.gold[guildID], nil
}

// AddGold implements GoldStore.
func (m *MemGold) AddGold(ctx context.Context, guildID, amount int64) error {
	if amount <= 0 {
		return errors.New("guildstorage: gold amount must be positive")
	}
	m.mu.Lock()
	m.gold[guildID] += amount
	m.mu.Unlock()
	txn.OnRollback(ctx, func() {
		m.mu.Lock()
		m.gold[guildID] -= amount
		m.mu.Unlock()
	})
	return nil
}

// TakeGold implements GoldStore.
func (m *MemGold) TakeGold(ctx context.Context, guildID, amount int64) error {
	if amount <= 0 {
		return errors.New("guildstorage: gold amount must be positive")
	}
	m.mu.Lock()
	if m.gold[guildID] < amount {
		m.mu.Unlock()
		return ErrNotEnoughGold
	}
	m.gold[guildID] -= amount
	m.mu.Unlock()
	txn.OnRollback(ctx, func() {
		m.mu.Lock()
		m.gold[guildID] += amount
		m.mu.Unlock()
	})
	return nil
}

// DropGuild implements GoldStore.
func (m *MemGold) DropGuild(ctx context.Context, guildID int64) error {
	m.mu.Lock()
	was, ok := m.gold[guildID]
	delete(m.gold, guildID)
	m.mu.Unlock()
	if ok {
		txn.OnRollback(ctx, func() {
			m.mu.Lock()
			m.gold[guildID] = was
			m.mu.Unlock()
		})
	}
	return nil
}

// goldSchema is the gold's own table, created at boot (CREATE ... IF NOT
// EXISTS: a database without it needs no migration).
const goldSchema = `
CREATE TABLE IF NOT EXISTS guild_storage_gold (
	guild_id BIGINT PRIMARY KEY,
	gold     BIGINT NOT NULL DEFAULT 0 CHECK (gold >= 0)
);
`

// SQLGold is the PostgreSQL GoldStore, on the stores' shared pool.
type SQLGold struct{ db *sql.DB }

// NewSQLGold opens the gold store on db, creating its table.
func NewSQLGold(db *sql.DB) (*SQLGold, error) {
	if err := txn.Migrate(db, goldSchema); err != nil {
		return nil, fmt.Errorf("guildstorage: creating schema: %w", err)
	}
	return &SQLGold{db: db}, nil
}

// TxDB implements txn.TxDBer.
func (s *SQLGold) TxDB() *sql.DB {
	if s == nil {
		return nil
	}
	return s.db
}

// Gold implements GoldStore.
func (s *SQLGold) Gold(ctx context.Context, guildID int64) (int64, error) {
	var g int64
	err := txn.Conn(ctx, s.db).QueryRowContext(ctx, `SELECT gold FROM guild_storage_gold WHERE guild_id = $1`, guildID).Scan(&g)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("guildstorage: reading the gold: %w", err)
	}
	return g, nil
}

// AddGold implements GoldStore.
func (s *SQLGold) AddGold(ctx context.Context, guildID, amount int64) error {
	if amount <= 0 {
		return errors.New("guildstorage: gold amount must be positive")
	}
	_, err := txn.Conn(ctx, s.db).ExecContext(ctx, `
INSERT INTO guild_storage_gold (guild_id, gold) VALUES ($1, $2)
ON CONFLICT (guild_id) DO UPDATE SET gold = guild_storage_gold.gold + EXCLUDED.gold`, guildID, amount)
	if err != nil {
		return fmt.Errorf("guildstorage: adding gold: %w", err)
	}
	return nil
}

// TakeGold implements GoldStore: the balance test is in the statement, so
// two withdrawals cannot both pass it.
func (s *SQLGold) TakeGold(ctx context.Context, guildID, amount int64) error {
	if amount <= 0 {
		return errors.New("guildstorage: gold amount must be positive")
	}
	res, err := txn.Conn(ctx, s.db).ExecContext(ctx,
		`UPDATE guild_storage_gold SET gold = gold - $1 WHERE guild_id = $2 AND gold >= $1`, amount, guildID)
	if err != nil {
		return fmt.Errorf("guildstorage: taking gold: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotEnoughGold
	}
	return nil
}

// DropGuild implements GoldStore.
func (s *SQLGold) DropGuild(ctx context.Context, guildID int64) error {
	if _, err := txn.Conn(ctx, s.db).ExecContext(ctx, `DELETE FROM guild_storage_gold WHERE guild_id = $1`, guildID); err != nil {
		return fmt.Errorf("guildstorage: dropping the gold: %w", err)
	}
	return nil
}

// TruncateForTest empties the table.
func (s *SQLGold) TruncateForTest(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `TRUNCATE guild_storage_gold`)
	return err
}
