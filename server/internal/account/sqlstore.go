package account

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
	_ "github.com/jackc/pgx/v5/stdlib" // driver registration ("pgx")
)

// schema creates the accounts table if it doesn't already exist. Our own
// schema — see docs/protocol/db_schema.md for the facts it's informed by,
// not a port of the original's TB_User layout.
const schema = `
CREATE TABLE IF NOT EXISTS accounts (
	id            BIGSERIAL PRIMARY KEY,
	username      TEXT NOT NULL UNIQUE,
	password_hash BYTEA NOT NULL,
	blocked       BOOLEAN NOT NULL DEFAULT FALSE,
	block_reason  TEXT NOT NULL DEFAULT ''
);
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS storage_gold BIGINT NOT NULL DEFAULT 0;
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS chest_size INTEGER NOT NULL DEFAULT 0;
`

// punishmentSchema is the punishments table (round 788, punishment.go):
// retail's `_Punishment` fields that something here reads. end_at NULL is an
// infinite punishment.
const punishmentSchema = `
CREATE TABLE IF NOT EXISTS account_punishments (
	serial      BIGSERIAL PRIMARY KEY,
	account_id  BIGINT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
	type        SMALLINT NOT NULL CHECK (type BETWEEN 1 AND 4),
	executor    TEXT NOT NULL DEFAULT '',
	guide       TEXT NOT NULL DEFAULT '',
	description TEXT NOT NULL DEFAULT '',
	raised_at   TIMESTAMPTZ NOT NULL,
	begin_at    TIMESTAMPTZ NOT NULL,
	end_at      TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS account_punishments_account ON account_punishments (account_id);
`

// blockedMigration moves the pre-round-788 accounts.blocked flag into the
// punishments table, once: each blocked account gets an infinite login block
// whose guide is its block_reason, and its flag is cleared in the same
// statement, so a second run finds nothing to move (idempotent). The two old
// columns stay (OURS): nothing reads or writes them any more, and an older
// binary rolled back onto this database still starts -- it then sees no
// account blocked, the punishments being in a table it does not know.
const blockedMigration = `
WITH moved AS (
	UPDATE accounts SET blocked = FALSE WHERE blocked RETURNING id, block_reason
)
INSERT INTO account_punishments (account_id, type, executor, guide, description, raised_at, begin_at, end_at)
SELECT id, 1, '` + migratedExecutor + `', block_reason, '` + migratedDescription + `', now(), now(), NULL FROM moved
`

// SQLStore is a Store and Registerer backed by PostgreSQL (via the pgx
// driver, registered under the "pgx" database/sql driver name).
type SQLStore struct {
	db *sql.DB
	// ownsDB is false on a shared pool (NewSQLStore), which Close leaves open.
	ownsDB bool
	// Now is the clock Authenticate and SetBlocked read; nil is time.Now.
	Now func() time.Time
}

func (s *SQLStore) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

// OpenSQLStore opens a PostgreSQL database at dsn (e.g.
// "postgres://user:pass@host:5432/dbname?sslmode=disable") and ensures its
// schema exists.
func OpenSQLStore(dsn string) (*SQLStore, error) {
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		return nil, fmt.Errorf("account: opening postgres connection: %w", err)
	}
	if err := db.Ping(); err != nil {
		db.Close()
		return nil, fmt.Errorf("account: connecting to postgres: %w", err)
	}
	s, err := NewSQLStore(db)
	if err != nil {
		db.Close()
		return nil, err
	}
	s.ownsDB = true
	return s, nil
}

// NewSQLStore is OpenSQLStore on a pool the caller owns and shares with the
// other stores (round 743). Close does not close it.
func NewSQLStore(db *sql.DB) (*SQLStore, error) {
	if err := txn.Migrate(db, schema, punishmentSchema, blockedMigration); err != nil {
		return nil, fmt.Errorf("account: creating schema: %w", err)
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

// Close closes the underlying database connection, unless it is a shared
// pool.
func (s *SQLStore) Close() error {
	if !s.ownsDB {
		return nil
	}
	return s.db.Close()
}

// Register implements Registerer.
func (s *SQLStore) Register(ctx context.Context, username, password string) (*Account, error) {
	hash, err := HashPassword(password)
	if err != nil {
		return nil, err
	}

	var id int64
	err = txn.Conn(ctx, s.db).QueryRowContext(ctx,
		`INSERT INTO accounts (username, password_hash) VALUES ($1, $2) RETURNING id`,
		username, hash).Scan(&id)
	if err != nil {
		if isUniqueConstraintErr(err) {
			return nil, ErrUsernameTaken
		}
		return nil, fmt.Errorf("account: inserting account: %w", err)
	}
	return &Account{ID: id, Username: username, PasswordHash: hash}, nil
}

// Authenticate implements Store. The password is checked first; a right
// password on an account with an active login block is a *BlockedError.
func (s *SQLStore) Authenticate(ctx context.Context, username, password string) (*Account, error) {
	var acc Account
	// chest_size is selected so Account.ChestSize means the same here as in
	// MemStore: the stored warehouse size, 0 when none was stored (round 501).
	row := txn.Conn(ctx, s.db).QueryRowContext(ctx,
		`SELECT id, username, password_hash, chest_size FROM accounts WHERE username = $1`, username)
	if err := row.Scan(&acc.ID, &acc.Username, &acc.PasswordHash, &acc.ChestSize); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrInvalidCredentials
		}
		return nil, fmt.Errorf("account: querying account: %w", err)
	}

	if !acc.verify(password) {
		return nil, ErrInvalidCredentials
	}
	active, err := s.queryPunishments(ctx, `WHERE account_id = $1 AND type IN `+loginTypesSQL+activeSQL+orderActiveSQL+` LIMIT 1`,
		acc.ID, s.now())
	if err != nil {
		return nil, err
	}
	if len(active) > 0 {
		return nil, &BlockedError{Punishment: active[0]}
	}
	return &acc, nil
}

// SetBlocked is the pre-round-788 way to block an account, kept for tests and
// tools (as MemStore.SetBlocked): blocked=true records an infinite login block
// whose guide is reason, unless one is already active; blocked=false ends the
// account's active login blocks.
func (s *SQLStore) SetBlocked(ctx context.Context, username string, blocked bool, reason string) error {
	acc, err := s.AccountByName(ctx, username)
	if errors.Is(err, ErrNoSuchAccount) {
		return fmt.Errorf("account: no such account: %s", username)
	}
	if err != nil {
		return err
	}
	now := s.now()
	if !blocked {
		_, err := s.EndPunishments(ctx, acc.ID, now, LoginBlockTypes...)
		return err
	}
	active, err := s.ActivePunishments(ctx, acc.ID, now)
	if err != nil {
		return err
	}
	if len(activeLoginBlocks(active)) > 0 {
		return nil
	}
	_, err = s.AddPunishment(ctx, Punishment{AccountID: acc.ID, Type: PunishLogin, Executor: migratedExecutor,
		Guide: reason, Description: migratedDescription, BeginAt: now})
	return err
}

// AccountByName implements AccountLookup.
func (s *SQLStore) AccountByName(ctx context.Context, username string) (*Account, error) {
	return s.accountWhere(ctx, `username = $1`, username)
}

// AccountByID implements AccountLookup.
func (s *SQLStore) AccountByID(ctx context.Context, accountID int64) (*Account, error) {
	return s.accountWhere(ctx, `id = $1`, accountID)
}

func (s *SQLStore) accountWhere(ctx context.Context, where string, arg any) (*Account, error) {
	var acc Account
	err := txn.Conn(ctx, s.db).QueryRowContext(ctx,
		`SELECT id, username, password_hash, chest_size, storage_gold FROM accounts WHERE `+where, arg).
		Scan(&acc.ID, &acc.Username, &acc.PasswordHash, &acc.ChestSize, &acc.StorageGold)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNoSuchAccount
	}
	if err != nil {
		return nil, fmt.Errorf("account: looking up an account: %w", err)
	}
	return &acc, nil
}

// The punishment queries' shared parts. The type lists are built from the
// constants (or validated types), never from text.
var loginTypesSQL = typesSQL(LoginBlockTypes)

const (
	punishmentColumns = `serial, account_id, type, executor, guide, description, raised_at, begin_at, end_at`
	// activeSQL: begun by $2 and not ended by it.
	activeSQL = ` AND begin_at <= $2 AND (end_at IS NULL OR end_at > $2)`
	// orderActiveSQL: the one ending last first, an infinite one before any.
	orderActiveSQL = ` ORDER BY end_at DESC NULLS FIRST, serial DESC`
)

func typesSQL(types []PunishmentType) string {
	parts := make([]string, len(types))
	for i, t := range types {
		parts[i] = fmt.Sprint(uint8(t))
	}
	return "(" + strings.Join(parts, ",") + ")"
}

// queryPunishments selects the punishments matching where (which begins with
// WHERE and uses args).
func (s *SQLStore) queryPunishments(ctx context.Context, where string, args ...any) ([]Punishment, error) {
	rows, err := txn.Conn(ctx, s.db).QueryContext(ctx, `SELECT `+punishmentColumns+` FROM account_punishments `+where, args...)
	if err != nil {
		return nil, fmt.Errorf("account: querying punishments: %w", err)
	}
	defer rows.Close()
	var out []Punishment
	for rows.Next() {
		var p Punishment
		var typ int16
		var end sql.NullTime
		if err := rows.Scan(&p.Serial, &p.AccountID, &typ, &p.Executor, &p.Guide, &p.Description,
			&p.RaisedAt, &p.BeginAt, &end); err != nil {
			return nil, fmt.Errorf("account: reading a punishment: %w", err)
		}
		p.Type = PunishmentType(typ)
		if end.Valid {
			p.EndAt = end.Time
		}
		out = append(out, p)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("account: reading punishments: %w", err)
	}
	return out, nil
}

// AddPunishment implements PunishmentStore.
func (s *SQLStore) AddPunishment(ctx context.Context, p Punishment) (Punishment, error) {
	if err := checkPunishment(p); err != nil {
		return Punishment{}, err
	}
	if p.RaisedAt.IsZero() {
		p.RaisedAt = s.now()
	}
	var end sql.NullTime
	if !p.Infinite() {
		end = sql.NullTime{Time: p.EndAt, Valid: true}
	}
	err := txn.Conn(ctx, s.db).QueryRowContext(ctx,
		`INSERT INTO account_punishments (account_id, type, executor, guide, description, raised_at, begin_at, end_at)
		 SELECT $1, $2, $3, $4, $5, $6, $7, $8 WHERE EXISTS (SELECT 1 FROM accounts WHERE id = $1)
		 RETURNING serial`,
		p.AccountID, int16(p.Type), p.Executor, p.Guide, p.Description, p.RaisedAt, p.BeginAt, end).Scan(&p.Serial)
	if errors.Is(err, sql.ErrNoRows) {
		return Punishment{}, ErrNoSuchAccount
	}
	if err != nil {
		return Punishment{}, fmt.Errorf("account: recording a punishment: %w", err)
	}
	return p, nil
}

// Punishments implements PunishmentStore.
func (s *SQLStore) Punishments(ctx context.Context, accountID int64) ([]Punishment, error) {
	return s.queryPunishments(ctx, `WHERE account_id = $1 ORDER BY serial DESC`, accountID)
}

// ActivePunishments implements PunishmentStore.
func (s *SQLStore) ActivePunishments(ctx context.Context, accountID int64, at time.Time) ([]Punishment, error) {
	return s.queryPunishments(ctx, `WHERE account_id = $1`+activeSQL+orderActiveSQL, accountID, at)
}

// EndPunishments implements PunishmentStore.
func (s *SQLStore) EndPunishments(ctx context.Context, accountID int64, at time.Time, types ...PunishmentType) (int, error) {
	q := `UPDATE account_punishments SET end_at = $2 WHERE account_id = $1 AND (end_at IS NULL OR end_at > $2)`
	if len(types) > 0 {
		for _, t := range types {
			if !t.Valid() {
				return 0, fmt.Errorf("account: punishment type %d is not 1-4", t)
			}
		}
		q += ` AND type IN ` + typesSQL(types)
	}
	res, err := txn.Conn(ctx, s.db).ExecContext(ctx, q, accountID, at)
	if err != nil {
		return 0, fmt.Errorf("account: ending punishments: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return 0, fmt.Errorf("account: ending punishments: %w", err)
	}
	return int(n), nil
}

func isUniqueConstraintErr(err error) bool {
	return err != nil && strings.Contains(err.Error(), "duplicate key value violates unique constraint")
}

// StorageGold implements StorageGoldStore.
func (s *SQLStore) StorageGold(ctx context.Context, accountID int64) (int64, error) {
	var gold int64
	err := txn.Conn(ctx, s.db).QueryRowContext(ctx, `SELECT storage_gold FROM accounts WHERE id = $1`, accountID).Scan(&gold)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, ErrNoSuchAccount
	}
	if err != nil {
		return 0, fmt.Errorf("account: reading storage gold: %w", err)
	}
	return gold, nil
}

// AddStorageGold implements StorageGoldStore.
func (s *SQLStore) AddStorageGold(ctx context.Context, accountID int64, amount int64) error {
	if amount <= 0 {
		return errors.New("account: storage gold amount must be positive")
	}
	res, err := txn.Conn(ctx, s.db).ExecContext(ctx, `UPDATE accounts SET storage_gold = storage_gold + $1 WHERE id = $2`, amount, accountID)
	if err != nil {
		return fmt.Errorf("account: adding storage gold: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNoSuchAccount
	}
	return nil
}

// DeductStorageGold implements StorageGoldStore. The balance check is in the
// statement itself, so two withdrawals cannot both pass it.
func (s *SQLStore) DeductStorageGold(ctx context.Context, accountID int64, amount int64) error {
	if amount <= 0 {
		return errors.New("account: storage gold amount must be positive")
	}
	res, err := txn.Conn(ctx, s.db).ExecContext(ctx,
		`UPDATE accounts SET storage_gold = storage_gold - $1 WHERE id = $2 AND storage_gold >= $1`, amount, accountID)
	if err != nil {
		return fmt.Errorf("account: deducting storage gold: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		var exists bool
		if err := txn.Conn(ctx, s.db).QueryRowContext(ctx, `SELECT EXISTS (SELECT 1 FROM accounts WHERE id = $1)`, accountID).Scan(&exists); err == nil && !exists {
			return ErrNoSuchAccount
		}
		return ErrInsufficientStorageGold
	}
	return nil
}

// ChestSize implements ChestSizeStore. The column is the game's
// `_ChestInfo.ChestSize`; 0 means no size was ever stored.
func (s *SQLStore) ChestSize(ctx context.Context, accountID int64) (int, error) {
	var size int
	err := txn.Conn(ctx, s.db).QueryRowContext(ctx, `SELECT chest_size FROM accounts WHERE id = $1`, accountID).Scan(&size)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, ErrNoSuchAccount
	}
	if err != nil {
		return 0, fmt.Errorf("account: reading chest size: %w", err)
	}
	return size, nil
}

// ExpandChest implements ChestSizeStore. The ceiling check is in the statement
// itself, so two expansions cannot both pass it.
func (s *SQLStore) ExpandChest(ctx context.Context, accountID int64, base, amount, ceiling int) (int, error) {
	if amount <= 0 {
		return 0, errors.New("account: chest expansion must be positive")
	}
	var size int
	err := txn.Conn(ctx, s.db).QueryRowContext(ctx,
		`UPDATE accounts SET chest_size = GREATEST(chest_size, $2) + $3
		 WHERE id = $1 AND GREATEST(chest_size, $2) + $3 <= $4
		 RETURNING chest_size`, accountID, base, amount, ceiling).Scan(&size)
	if errors.Is(err, sql.ErrNoRows) {
		var exists bool
		if err := txn.Conn(ctx, s.db).QueryRowContext(ctx, `SELECT EXISTS (SELECT 1 FROM accounts WHERE id = $1)`, accountID).Scan(&exists); err != nil {
			return 0, fmt.Errorf("account: checking account after a refused expansion: %w", err)
		}
		if !exists {
			return 0, ErrNoSuchAccount
		}
		return 0, ErrChestFull
	}
	if err != nil {
		return 0, fmt.Errorf("account: expanding chest: %w", err)
	}
	return size, nil
}
