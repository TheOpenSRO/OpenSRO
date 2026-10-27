package mall

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
	_ "github.com/jackc/pgx/v5/stdlib" // driver registration ("pgx")
)

// schema is OURS (store.go): the purchase log, the chest and its take log.
const schema = `
CREATE TABLE IF NOT EXISTS mall_purchases (
	id           BIGSERIAL PRIMARY KEY,
	account_id   BIGINT NOT NULL,
	character_id BIGINT NOT NULL,
	package_id   BIGINT NOT NULL,
	package_code TEXT NOT NULL,
	quantity     INTEGER NOT NULL,
	gold         BIGINT NOT NULL DEFAULT 0,
	silk_own     BIGINT NOT NULL DEFAULT 0,
	silk_gift    BIGINT NOT NULL DEFAULT 0,
	silk_point   BIGINT NOT NULL DEFAULT 0,
	to_chest     BOOLEAN NOT NULL DEFAULT FALSE,
	created_at   TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS mall_purchases_account ON mall_purchases (account_id, created_at);
CREATE TABLE IF NOT EXISTS mall_chest (
	id           BIGSERIAL PRIMARY KEY,
	character_id BIGINT NOT NULL,
	item_id      BIGINT NOT NULL,
	quantity     INTEGER NOT NULL,
	opt_level    SMALLINT NOT NULL DEFAULT 0,
	variance     BIGINT NOT NULL DEFAULT 0,
	data         INTEGER NOT NULL DEFAULT 0,
	mag_params   BYTEA NOT NULL DEFAULT ''::bytea,
	from_text    TEXT NOT NULL DEFAULT '',
	created_at   TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS mall_chest_character ON mall_chest (character_id, id);
CREATE TABLE IF NOT EXISTS mall_chest_log (
	id           BIGSERIAL PRIMARY KEY,
	character_id BIGINT NOT NULL,
	item_id      BIGINT NOT NULL,
	quantity     INTEGER NOT NULL,
	from_text    TEXT NOT NULL DEFAULT '',
	created_at   TIMESTAMPTZ NOT NULL,
	taken_at     TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS mall_chest_log_character ON mall_chest_log (character_id, taken_at);
`

// SQLStore is the PostgreSQL Store.
type SQLStore struct {
	db *sql.DB
}

// NewSQLStore opens the store on a pool shared with the other stores and
// creates its tables.
func NewSQLStore(db *sql.DB) (*SQLStore, error) {
	if err := txn.Migrate(db, schema); err != nil {
		return nil, fmt.Errorf("mall: creating schema: %w", err)
	}
	return &SQLStore{db: db}, nil
}

// TxDB implements txn.TxDBer.
func (s *SQLStore) TxDB() *sql.DB {
	if s == nil {
		return nil
	}
	return s.db
}

// TruncateForTest clears the tables. Not for production use.
func (s *SQLStore) TruncateForTest(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `TRUNCATE TABLE mall_purchases, mall_chest, mall_chest_log`)
	return err
}

// RecordPurchase implements Store.
func (s *SQLStore) RecordPurchase(ctx context.Context, p Purchase) error {
	_, err := txn.Conn(ctx, s.db).ExecContext(ctx, `INSERT INTO mall_purchases
		(account_id, character_id, package_id, package_code, quantity, gold, silk_own, silk_gift, silk_point, to_chest, created_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)`,
		p.AccountID, p.CharacterID, p.PackageID, p.PackageCode, p.Quantity, p.Pay.Gold, p.Pay.Own, p.Pay.Gift, p.Pay.Point,
		p.ToChest, p.At)
	if err != nil {
		return fmt.Errorf("mall: recording a purchase: %w", err)
	}
	return nil
}

// Purchases implements Store.
func (s *SQLStore) Purchases(ctx context.Context, accountID int64, since time.Time) ([]HistoryRow, error) {
	rows, err := txn.Conn(ctx, s.db).QueryContext(ctx, `SELECT silk_own + silk_gift + silk_point, created_at
		FROM mall_purchases WHERE account_id = $1 AND created_at >= $2 ORDER BY created_at, id`, accountID, since)
	if err != nil {
		return nil, fmt.Errorf("mall: reading purchases: %w", err)
	}
	defer rows.Close()
	var out []HistoryRow
	for rows.Next() {
		var r HistoryRow
		if err := rows.Scan(&r.Offset, &r.At); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// AddToChest implements Store.
func (s *SQLStore) AddToChest(ctx context.Context, e ChestEntry) (int64, error) {
	var id int64
	err := txn.Conn(ctx, s.db).QueryRowContext(ctx, `INSERT INTO mall_chest
		(character_id, item_id, quantity, opt_level, variance, data, mag_params, from_text, created_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) RETURNING id`,
		e.Owner, e.ItemID, e.Quantity, int(e.OptLevel), int64(e.Variance), e.Data, inventory.EncodeMagParams(e.MagParams),
		e.From, e.At).Scan(&id)
	if err != nil {
		return 0, fmt.Errorf("mall: adding to the chest: %w", err)
	}
	return id, nil
}

const chestColumns = `id, character_id, item_id, quantity, opt_level, variance, data, mag_params, from_text, created_at`

func scanChest(sc interface{ Scan(...any) error }) (ChestEntry, error) {
	var e ChestEntry
	var opt int
	var variance int64
	var params []byte
	if err := sc.Scan(&e.ID, &e.Owner, &e.ItemID, &e.Quantity, &opt, &variance, &e.Data, &params, &e.From, &e.At); err != nil {
		return e, err
	}
	e.OptLevel, e.Variance, e.MagParams = uint8(opt), uint64(variance), inventory.DecodeMagParams(params)
	return e, nil
}

// Chest implements Store.
func (s *SQLStore) Chest(ctx context.Context, owner int64) ([]ChestEntry, error) {
	rows, err := txn.Conn(ctx, s.db).QueryContext(ctx, `SELECT `+chestColumns+` FROM mall_chest WHERE character_id = $1 ORDER BY id`, owner)
	if err != nil {
		return nil, fmt.Errorf("mall: reading the chest: %w", err)
	}
	defer rows.Close()
	var out []ChestEntry
	for rows.Next() {
		e, err := scanChest(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// TakeFromChest implements Store: the DELETE ... RETURNING takes the row once
// however many takes race for it.
func (s *SQLStore) TakeFromChest(ctx context.Context, owner, id int64, at time.Time) (ChestEntry, error) {
	q := txn.Conn(ctx, s.db)
	e, err := scanChest(q.QueryRowContext(ctx, `DELETE FROM mall_chest WHERE id = $1 AND character_id = $2 RETURNING `+chestColumns, id, owner))
	if errors.Is(err, sql.ErrNoRows) {
		return ChestEntry{}, ErrNoSuchEntry
	}
	if err != nil {
		return ChestEntry{}, fmt.Errorf("mall: taking from the chest: %w", err)
	}
	if _, err := q.ExecContext(ctx, `INSERT INTO mall_chest_log (character_id, item_id, quantity, from_text, created_at, taken_at)
		VALUES ($1, $2, $3, $4, $5, $6)`, owner, e.ItemID, e.Quantity, e.From, e.At, at); err != nil {
		return ChestEntry{}, fmt.Errorf("mall: logging a take: %w", err)
	}
	return e, nil
}

// TakeLog implements Store.
func (s *SQLStore) TakeLog(ctx context.Context, owner int64, since time.Time) ([]TakeLogEntry, error) {
	rows, err := txn.Conn(ctx, s.db).QueryContext(ctx, `SELECT item_id, quantity, from_text, created_at, taken_at
		FROM mall_chest_log WHERE character_id = $1 AND taken_at >= $2 ORDER BY taken_at DESC, id DESC`, owner, since)
	if err != nil {
		return nil, fmt.Errorf("mall: reading the take log: %w", err)
	}
	defer rows.Close()
	var out []TakeLogEntry
	for rows.Next() {
		var l TakeLogEntry
		if err := rows.Scan(&l.ItemID, &l.Quantity, &l.From, &l.At, &l.TakenAt); err != nil {
			return nil, err
		}
		out = append(out, l)
	}
	return out, rows.Err()
}

// PruneTakeLog implements Store.
func (s *SQLStore) PruneTakeLog(ctx context.Context, before time.Time) (int64, error) {
	res, err := s.db.ExecContext(ctx, `DELETE FROM mall_chest_log WHERE taken_at < $1`, before)
	if err != nil {
		return 0, fmt.Errorf("mall: pruning the take log: %w", err)
	}
	return res.RowsAffected()
}
