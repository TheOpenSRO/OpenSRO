package stall

// The sale record (round 839, OURS). Retail persists a stall sale as one DB
// job (AQ_ItemXChanger::DoWork s:0x43fb20, kind 1): `_STRG_MOVEITEM_NEW`
// (0x26, 0, giver, receiver, from slot, to slot, 0, count, 0) and an UPDATE
// of each side's RemainGold, with item log events 0x4b / 0x4d -- the item
// table and the character rows are the sale. OpenSRO's sale moves the item
// and both golds in one transaction over the inventory and character stores
// (session/stall.go) and adds this row in the same transaction: the item
// log's place, so a sale can be audited and a lost answer told from a sale
// that never happened. The row is written by the sale alone; nothing reads
// it back into the game.

import (
	"context"
	"database/sql"
	"fmt"
	"sync"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
)

// Sale is one item bought out of a stall.
type Sale struct {
	ID       int64
	SellerID int64
	BuyerID  int64
	ItemID   int64
	Quantity int
	// Serial is the stack's serial the buyer received (0 when the store keeps
	// none).
	Serial int64
	Price  int64
	// Slot is the stall slot, BagSlot the seller's bag slot, ToSlot the
	// buyer's.
	Slot    int
	BagSlot int
	ToSlot  int
	SoldAt  time.Time
}

// SaleStore keeps the sales.
type SaleStore interface {
	// RecordSale adds s, inside the context's transaction when there is one.
	RecordSale(ctx context.Context, s Sale) error
	// Sales lists characterID's sales as seller or buyer, newest first, at
	// most limit.
	Sales(ctx context.Context, characterID int64, limit int) ([]Sale, error)
}

// MemStore keeps the sales in memory.
type MemStore struct {
	mu    sync.Mutex
	sales []Sale
	next  int64
}

// NewMemStore returns an empty store.
func NewMemStore() *MemStore { return &MemStore{} }

// RecordSale implements SaleStore. Inside an action (txn.Runner.Run) a
// rollback takes the row back out.
func (m *MemStore) RecordSale(ctx context.Context, s Sale) error {
	m.mu.Lock()
	m.next++
	s.ID = m.next
	if s.SoldAt.IsZero() {
		s.SoldAt = time.Now()
	}
	m.sales = append(m.sales, s)
	m.mu.Unlock()
	txn.OnRollback(ctx, func() {
		m.mu.Lock()
		defer m.mu.Unlock()
		for i := len(m.sales) - 1; i >= 0; i-- {
			if m.sales[i].ID == s.ID {
				m.sales = append(m.sales[:i], m.sales[i+1:]...)
				return
			}
		}
	})
	return nil
}

// Sales implements SaleStore.
func (m *MemStore) Sales(_ context.Context, characterID int64, limit int) ([]Sale, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var out []Sale
	for i := len(m.sales) - 1; i >= 0 && (limit <= 0 || len(out) < limit); i-- {
		if s := m.sales[i]; s.SellerID == characterID || s.BuyerID == characterID {
			out = append(out, s)
		}
	}
	return out, nil
}

const schema = `
CREATE TABLE IF NOT EXISTS stall_sales (
	id         BIGSERIAL PRIMARY KEY,
	seller_id  BIGINT NOT NULL,
	buyer_id   BIGINT NOT NULL,
	item_id    BIGINT NOT NULL,
	quantity   INT NOT NULL,
	serial     BIGINT NOT NULL DEFAULT 0,
	price      BIGINT NOT NULL,
	slot       SMALLINT NOT NULL DEFAULT 0,
	bag_slot   SMALLINT NOT NULL DEFAULT 0,
	to_slot    SMALLINT NOT NULL DEFAULT 0,
	sold_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS stall_sales_seller ON stall_sales (seller_id, sold_at);
CREATE INDEX IF NOT EXISTS stall_sales_buyer ON stall_sales (buyer_id, sold_at);
`

// SQLStore keeps the sales in Postgres.
type SQLStore struct {
	db *sql.DB
}

// NewSQLStore opens the store on db and creates its table (idempotent).
func NewSQLStore(db *sql.DB) (*SQLStore, error) {
	if err := txn.Migrate(db, schema); err != nil {
		return nil, fmt.Errorf("stall: creating schema: %w", err)
	}
	return &SQLStore{db: db}, nil
}

// TxDB names the store's database, so an action over it runs as one
// transaction with the other stores (txn.For).
func (s *SQLStore) TxDB() *sql.DB { return s.db }

// TruncateForTest clears the table. Not for production use.
func (s *SQLStore) TruncateForTest(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `TRUNCATE TABLE stall_sales RESTART IDENTITY`)
	return err
}

// RecordSale implements SaleStore.
func (s *SQLStore) RecordSale(ctx context.Context, sale Sale) error {
	at := sale.SoldAt
	if at.IsZero() {
		at = time.Now()
	}
	_, err := txn.Conn(ctx, s.db).ExecContext(ctx, `INSERT INTO stall_sales
		(seller_id, buyer_id, item_id, quantity, serial, price, slot, bag_slot, to_slot, sold_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)`,
		sale.SellerID, sale.BuyerID, sale.ItemID, sale.Quantity, sale.Serial, sale.Price,
		sale.Slot, sale.BagSlot, sale.ToSlot, at)
	if err != nil {
		return fmt.Errorf("stall: recording a sale: %w", err)
	}
	return nil
}

// Sales implements SaleStore.
func (s *SQLStore) Sales(ctx context.Context, characterID int64, limit int) ([]Sale, error) {
	if limit <= 0 {
		limit = 1000
	}
	rows, err := txn.Conn(ctx, s.db).QueryContext(ctx, `SELECT id, seller_id, buyer_id, item_id, quantity, serial,
		price, slot, bag_slot, to_slot, sold_at FROM stall_sales
		WHERE seller_id = $1 OR buyer_id = $1 ORDER BY id DESC LIMIT $2`, characterID, limit)
	if err != nil {
		return nil, fmt.Errorf("stall: reading sales: %w", err)
	}
	defer rows.Close()
	var out []Sale
	for rows.Next() {
		var v Sale
		if err := rows.Scan(&v.ID, &v.SellerID, &v.BuyerID, &v.ItemID, &v.Quantity, &v.Serial,
			&v.Price, &v.Slot, &v.BagSlot, &v.ToSlot, &v.SoldAt); err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, rows.Err()
}
