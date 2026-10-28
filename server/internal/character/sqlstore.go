package character

import (
	"context"
	"database/sql"
	"fmt"
	"strings"

	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
	_ "github.com/jackc/pgx/v5/stdlib" // driver registration ("pgx")
)

// schema creates the characters table if it doesn't already exist. Own
// schema (see docs/protocol/db_schema.md), not a port of the original. The
// unique index on lower(name) gives case-insensitive uniqueness, matching
// MemStore's normalizeName behavior (Postgres has no COLLATE NOCASE).
// The 'china_man' literal below must match DefaultGender in character.go --
// SQL can't reference the Go constant directly.
const schema = `
CREATE TABLE IF NOT EXISTS characters (
	id         BIGSERIAL PRIMARY KEY,
	account_id BIGINT NOT NULL,
	name       TEXT NOT NULL,
	gold       BIGINT NOT NULL DEFAULT 0,
	hp         INTEGER NOT NULL DEFAULT 100,
	gender     TEXT NOT NULL DEFAULT 'china_man'
);
ALTER TABLE characters ADD COLUMN IF NOT EXISTS gold BIGINT NOT NULL DEFAULT 0;
ALTER TABLE characters ADD COLUMN IF NOT EXISTS hp INTEGER NOT NULL DEFAULT 100;
ALTER TABLE characters ADD COLUMN IF NOT EXISTS gender TEXT NOT NULL DEFAULT 'china_man';
ALTER TABLE characters ADD COLUMN IF NOT EXISTS level INTEGER NOT NULL DEFAULT 1;
ALTER TABLE characters ADD COLUMN IF NOT EXISTS exp BIGINT NOT NULL DEFAULT 0;
ALTER TABLE characters ADD COLUMN IF NOT EXISTS stat_points INTEGER NOT NULL DEFAULT 0;
ALTER TABLE characters ADD COLUMN IF NOT EXISTS storage_gold BIGINT NOT NULL DEFAULT 0;
-- The berserk orbs, the engine's _CHAR.RemainHwanCount (charData+0x86). A
-- persisted column there, so it must survive a logout here too.
ALTER TABLE characters ADD COLUMN IF NOT EXISTS hwan_count INTEGER NOT NULL DEFAULT 0;
-- Str and Int are what health and mana are derived from (character.MaxHPFor).
-- Existing rows default to the starting values rather than 0, which would
-- otherwise leave every migrated character on zero health.
ALTER TABLE characters ADD COLUMN IF NOT EXISTS str INTEGER NOT NULL DEFAULT 20;
ALTER TABLE characters ADD COLUMN IF NOT EXISTS intel INTEGER NOT NULL DEFAULT 20;
-- Where the character last stood (round 573, cmd/server's -persist-position):
-- the engine's _CHAR.LatestRegion / PosX / PosY / PosZ (charData +0x94..+0xa0,
-- docs/protocol/db_bind_offsets.tsv), in OpenSRO's shape -- the zone label,
-- the frame region "x/y" and a world point in that frame (Character.Zone).
-- latest_zone '' is "nothing saved": every existing row enters at the spawn.
ALTER TABLE characters ADD COLUMN IF NOT EXISTS latest_zone TEXT NOT NULL DEFAULT '';
ALTER TABLE characters ADD COLUMN IF NOT EXISTS latest_frame TEXT NOT NULL DEFAULT '';
ALTER TABLE characters ADD COLUMN IF NOT EXISTS pos_x DOUBLE PRECISION NOT NULL DEFAULT 0;
ALTER TABLE characters ADD COLUMN IF NOT EXISTS pos_y DOUBLE PRECISION NOT NULL DEFAULT 0;
ALTER TABLE characters ADD COLUMN IF NOT EXISTS pos_z DOUBLE PRECISION NOT NULL DEFAULT 0;
-- The bag's size in slots (round 633), the engine's _CHAR.InventorySize
-- (charData+0xac) less its 13 equipment slots. 0 is "none stored": the
-- server's -inventory-size default applies (InventorySizeStore).
ALTER TABLE characters ADD COLUMN IF NOT EXISTS inventory_size INTEGER NOT NULL DEFAULT 0;
-- The way the character last faced (round 637's review follow-up,
-- HeadingStore): the client's heading in radians, saved with the position.
-- OURS: _CHAR declares no such column.
ALTER TABLE characters ADD COLUMN IF NOT EXISTS heading DOUBLE PRECISION NOT NULL DEFAULT 0;
-- The lobby (round 682, docs/protocol/charselect.md): the body a character was
-- made from (_CHAR.RefObjID), its scale byte (_CHAR.Scale: Height low nibble,
-- Volume high), when its 7-day deletion started (NULL: not deleting), and its
-- race's start spawn (start_zone '' : none, the zone spawn as before).
ALTER TABLE characters ADD COLUMN IF NOT EXISTS ref_obj_id BIGINT NOT NULL DEFAULT 0;
ALTER TABLE characters ADD COLUMN IF NOT EXISTS scale INTEGER NOT NULL DEFAULT 34;
ALTER TABLE characters ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;
ALTER TABLE characters ADD COLUMN IF NOT EXISTS start_zone TEXT NOT NULL DEFAULT '';
ALTER TABLE characters ADD COLUMN IF NOT EXISTS start_x DOUBLE PRECISION NOT NULL DEFAULT 0;
ALTER TABLE characters ADD COLUMN IF NOT EXISTS start_y DOUBLE PRECISION NOT NULL DEFAULT 0;
ALTER TABLE characters ADD COLUMN IF NOT EXISTS start_z DOUBLE PRECISION NOT NULL DEFAULT 0;
-- Existing characters get the body the world draws for their gender today,
-- CHAR_CH_WOMAN_FIGHTER 1923 or CHAR_CH_MAN_FIGHTER 1909 (character.
-- LegacyModelFor; OURS, the user accepted it), at the default scale 0x22 (the
-- column default above). Only rows still at 0, so a second run changes nothing.
UPDATE characters SET ref_obj_id = CASE WHEN gender = 'china_woman' THEN 1923 ELSE 1909 END WHERE ref_obj_id = 0;
CREATE INDEX IF NOT EXISTS characters_deleted_at ON characters (deleted_at) WHERE deleted_at IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS characters_name_lower ON characters (LOWER(name));
CREATE INDEX IF NOT EXISTS characters_account_id ON characters(account_id);
-- The designated return point (round 686, RecallStore): the engine's
-- _CHAR.AppointedTeleport (charData +0xa4), the ref object id of the town gate
-- whose "Designate as return/recall point" line the character last used. 0 is
-- "none designated": the character's race's gate, STORE_CH_GATE or
-- STORE_EU_GATE, resolved when needed (OURS: retail writes that id at
-- creation). Every existing row takes the 0, so it returns where its race's
-- default sends it; ADD COLUMN IF NOT EXISTS makes a second run a no-op.
ALTER TABLE characters ADD COLUMN IF NOT EXISTS appointed_teleport BIGINT NOT NULL DEFAULT 0;
-- The reverse return scroll's two points (round 778, ReturnPointStore): the
-- engine's _CHAR TelRegion/TelPosX/Y/Z/TelWorldID (charData +0xcc..+0xd8,
-- +0xee), where a return scroll was last used, and DiedRegion/DiedPosX/Y/Z/
-- DiedWorldID (+0xdc..+0xe8, +0xf0), where the character last died. A region
-- of 0 is "none recorded" (the scroll refuses it, 0x1885 / 0x1886); the
-- position is region-local, or dungeon space in a dungeon (a negative region).
ALTER TABLE characters ADD COLUMN IF NOT EXISTS tel_region INTEGER NOT NULL DEFAULT 0;
ALTER TABLE characters ADD COLUMN IF NOT EXISTS tel_x DOUBLE PRECISION NOT NULL DEFAULT 0;
ALTER TABLE characters ADD COLUMN IF NOT EXISTS tel_y DOUBLE PRECISION NOT NULL DEFAULT 0;
ALTER TABLE characters ADD COLUMN IF NOT EXISTS tel_z DOUBLE PRECISION NOT NULL DEFAULT 0;
ALTER TABLE characters ADD COLUMN IF NOT EXISTS tel_world INTEGER NOT NULL DEFAULT 0;
ALTER TABLE characters ADD COLUMN IF NOT EXISTS died_region INTEGER NOT NULL DEFAULT 0;
ALTER TABLE characters ADD COLUMN IF NOT EXISTS died_x DOUBLE PRECISION NOT NULL DEFAULT 0;
ALTER TABLE characters ADD COLUMN IF NOT EXISTS died_y DOUBLE PRECISION NOT NULL DEFAULT 0;
ALTER TABLE characters ADD COLUMN IF NOT EXISTS died_z DOUBLE PRECISION NOT NULL DEFAULT 0;
ALTER TABLE characters ADD COLUMN IF NOT EXISTS died_world INTEGER NOT NULL DEFAULT 0;
-- The auto potion settings (round 786, AutoPotionStore): the seven bytes the
-- client's 0x7158 type 2 carries -- u16 HP, u16 MP, u16 abnormal, u8 delay --
-- which retail keeps in its _ClientConfig record. Empty is "never set".
ALTER TABLE characters ADD COLUMN IF NOT EXISTS auto_potion BYTEA NOT NULL DEFAULT '';
-- Round 838: the stall decoration (StallDecorationStore), the engine's
-- _STATICAVATAR.Param1 -- the RefObjID of the last stall decoration item
-- used, 0 for the default stall.
ALTER TABLE characters ADD COLUMN IF NOT EXISTS stall_decoration INTEGER NOT NULL DEFAULT 0;
-- Round 838: the special reverse return scroll's saved locations
-- (SavedLocationStore, OURS), one row per filled slot.
CREATE TABLE IF NOT EXISTS character_saved_locations (
	character_id BIGINT NOT NULL REFERENCES characters(id) ON DELETE CASCADE,
	slot SMALLINT NOT NULL,
	region INTEGER NOT NULL,
	x DOUBLE PRECISION NOT NULL,
	y DOUBLE PRECISION NOT NULL,
	z DOUBLE PRECISION NOT NULL,
	world INTEGER NOT NULL,
	PRIMARY KEY (character_id, slot)
);
`

// SQLStore is a Store backed by PostgreSQL (via the pgx driver) — same
// approach as account.SQLStore.
type SQLStore struct {
	db *sql.DB
	// ownsDB is false on a shared pool (NewSQLStore), which Close leaves open.
	ownsDB bool
}

// OpenSQLStore opens a PostgreSQL database at dsn and ensures its schema
// exists.
func OpenSQLStore(dsn string) (*SQLStore, error) {
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		return nil, fmt.Errorf("character: opening postgres connection: %w", err)
	}
	if err := db.Ping(); err != nil {
		db.Close()
		return nil, fmt.Errorf("character: connecting to postgres: %w", err)
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
// other stores (round 743: one capped pool, so one transaction can move gold
// and items together). Close does not close it.
func NewSQLStore(db *sql.DB) (*SQLStore, error) {
	if err := txn.Migrate(db, schema, txn.Schema); err != nil {
		return nil, fmt.Errorf("character: creating schema: %w", err)
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

// ListByAccount implements Store.
func (s *SQLStore) ListByAccount(ctx context.Context, accountID int64) ([]*Character, error) {
	rows, err := txn.Conn(ctx, s.db).QueryContext(ctx,
		`SELECT `+characterColumns+` FROM characters WHERE account_id = $1 ORDER BY id`, accountID)
	if err != nil {
		return nil, fmt.Errorf("character: listing characters: %w", err)
	}
	defer rows.Close()

	var out []*Character
	for rows.Next() {
		c, err := scanCharacter(rows)
		if err != nil {
			return nil, fmt.Errorf("character: scanning row: %w", err)
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// Create implements Store.
func (s *SQLStore) Create(ctx context.Context, accountID int64, name string) (*Character, error) {
	var count int
	if err := txn.Conn(ctx, s.db).QueryRowContext(ctx,
		`SELECT COUNT(*) FROM characters WHERE account_id = $1`, accountID).Scan(&count); err != nil {
		return nil, fmt.Errorf("character: counting existing characters: %w", err)
	}
	if count >= MaxPerAccount {
		return nil, ErrAccountFull
	}

	var id int64
	err := txn.Conn(ctx, s.db).QueryRowContext(ctx,
		`INSERT INTO characters (account_id, name, gold, hp, gender, level, str, intel, ref_obj_id, scale) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) RETURNING id`,
		accountID, name, StartingGold, StartingMaxHP, DefaultGender, StartingLevel,
		StartingStr, StartingInt, LegacyModelFor(DefaultGender), DefaultScale).Scan(&id)
	if err != nil {
		if isUniqueConstraintErr(err) {
			return nil, ErrNameTaken
		}
		return nil, fmt.Errorf("character: inserting character: %w", err)
	}
	return &Character{ID: id, AccountID: accountID, Name: name, Gold: StartingGold, HP: StartingMaxHP,
		Gender: DefaultGender, Level: StartingLevel, Str: StartingStr, Int: StartingInt,
		RefObjID: LegacyModelFor(DefaultGender), Scale: DefaultScale}, nil
}

// Delete implements Store.
func (s *SQLStore) Delete(ctx context.Context, accountID, characterID int64) error {
	res, err := txn.Conn(ctx, s.db).ExecContext(ctx,
		`DELETE FROM characters WHERE id = $1 AND account_id = $2`, characterID, accountID)
	if err != nil {
		return fmt.Errorf("character: deleting character: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("character: checking delete result: %w", err)
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// AddGold implements Store.
func (s *SQLStore) AddGold(ctx context.Context, characterID int64, amount int64) error {
	res, err := txn.Conn(ctx, s.db).ExecContext(ctx,
		`UPDATE characters SET gold = gold + $1 WHERE id = $2`, amount, characterID)
	if err != nil {
		return fmt.Errorf("character: adding gold: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("character: checking update result: %w", err)
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// DeductGold implements Store.
func (s *SQLStore) DeductGold(ctx context.Context, characterID int64, amount int64) error {
	res, err := txn.Conn(ctx, s.db).ExecContext(ctx,
		`UPDATE characters SET gold = gold - $1 WHERE id = $2 AND gold >= $1`, amount, characterID)
	if err != nil {
		return fmt.Errorf("character: deducting gold: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("character: checking update result: %w", err)
	}
	if n == 0 {
		// Either the character doesn't exist, or gold was insufficient --
		// distinguish so callers get an accurate error.
		var exists bool
		if err := txn.Conn(ctx, s.db).QueryRowContext(ctx,
			`SELECT EXISTS(SELECT 1 FROM characters WHERE id = $1)`, characterID).Scan(&exists); err != nil {
			return fmt.Errorf("character: checking existence: %w", err)
		}
		if !exists {
			return ErrNotFound
		}
		return ErrInsufficientGold
	}
	return nil
}

// AddStorageGold implements Store.
func (s *SQLStore) AddStorageGold(ctx context.Context, characterID int64, amount int64) error {
	res, err := txn.Conn(ctx, s.db).ExecContext(ctx,
		`UPDATE characters SET storage_gold = storage_gold + $1 WHERE id = $2`, amount, characterID)
	if err != nil {
		return fmt.Errorf("character: adding storage gold: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("character: checking update result: %w", err)
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// SetHwanCount implements Store.
func (s *SQLStore) SetHwanCount(ctx context.Context, characterID int64, count int) error {
	res, err := txn.Conn(ctx, s.db).ExecContext(ctx,
		`UPDATE characters SET hwan_count = $1 WHERE id = $2`, count, characterID)
	if err != nil {
		return fmt.Errorf("character: setting hwan count: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("character: checking update result: %w", err)
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// DeductStorageGold implements Store.
func (s *SQLStore) DeductStorageGold(ctx context.Context, characterID int64, amount int64) error {
	res, err := txn.Conn(ctx, s.db).ExecContext(ctx,
		`UPDATE characters SET storage_gold = storage_gold - $1 WHERE id = $2 AND storage_gold >= $1`, amount, characterID)
	if err != nil {
		return fmt.Errorf("character: deducting storage gold: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("character: checking update result: %w", err)
	}
	if n == 0 {
		var exists bool
		if err := txn.Conn(ctx, s.db).QueryRowContext(ctx,
			`SELECT EXISTS(SELECT 1 FROM characters WHERE id = $1)`, characterID).Scan(&exists); err != nil {
			return fmt.Errorf("character: checking existence: %w", err)
		}
		if !exists {
			return ErrNotFound
		}
		return ErrInsufficientGold
	}
	return nil
}

// ApplyDamage implements Store. The UPDATE touches only a row above 0, so a
// row it finds at 0 is left as it is and the row lock decides which of two
// racing blows made the transition (Store's contract, round 550); a row the
// UPDATE skipped is then told apart from a missing one.
func (s *SQLStore) ApplyDamage(ctx context.Context, characterID int64, amount int) (int, bool, error) {
	var hp int
	err := txn.Conn(ctx, s.db).QueryRowContext(ctx,
		`UPDATE characters SET hp = GREATEST(hp - $1, 0) WHERE id = $2 AND hp > 0 RETURNING hp`,
		amount, characterID).Scan(&hp)
	if err == nil {
		return hp, hp == 0, nil
	}
	if err != sql.ErrNoRows {
		return 0, false, fmt.Errorf("character: applying damage: %w", err)
	}
	// No row above 0: the character is missing, or the blow found it at 0.
	// The 0 reported is the HP the blow found; nothing was written.
	var exists bool
	err = txn.Conn(ctx, s.db).QueryRowContext(ctx, `SELECT true FROM characters WHERE id = $1`, characterID).Scan(&exists)
	if err == sql.ErrNoRows {
		return 0, false, ErrNotFound
	}
	if err != nil {
		return 0, false, fmt.Errorf("character: applying damage: %w", err)
	}
	return 0, false, nil
}

// Heal implements Store.
func (s *SQLStore) Heal(ctx context.Context, characterID int64, amount, maxHP int) (int, error) {
	if amount <= 0 {
		c, err := s.GetByID(ctx, characterID)
		if err != nil {
			return 0, err
		}
		return c.HP, nil
	}
	var hp int
	err := txn.Conn(ctx, s.db).QueryRowContext(ctx,
		`UPDATE characters SET hp = LEAST(hp + $1, $2) WHERE id = $3 RETURNING hp`,
		amount, maxHP, characterID).Scan(&hp)
	if err == sql.ErrNoRows {
		return 0, ErrNotFound
	}
	if err != nil {
		return 0, fmt.Errorf("character: healing: %w", err)
	}
	return hp, nil
}

// hpPctFactor is scalePct's multiplier, 1 + pct/100, worked out in Go so the
// SQL multiplies by the same float64 the memory store does.
func hpPctFactor(pct float64) float64 { return 1 + pct/100 }

// ResetHP implements Store.
// RespawnHP implements Store: back from death at RespawnFraction of maximum,
// floored at 1 so a character never respawns dead.
func (s *SQLStore) RespawnHP(ctx context.Context, characterID int64) error {
	// Round 769's review F1: the maximum with the worn items' bonus
	// (MaxHPWith), as the memory store's MaxHP has it.
	// Round 785's review: and its buffs' percent ('hpi', b.HPPct), as
	// MaxHPWith scales it -- the whole times (1 + pct/100), truncated
	// (hpPctFactor; scalePct's floor of 1 is GREATEST's).
	b := BonusOf(characterID)
	res, err := txn.Conn(ctx, s.db).ExecContext(ctx,
		`UPDATE characters SET hp = GREATEST(1, FLOOR(GREATEST(1, FLOOR((ROUND((str + $5) * $1 * POWER($2, level - 1)) + $6) * $7)) * $3)) WHERE id = $4`,
		HPPerStr, StatGrowth, RespawnFraction, characterID, b.Str, b.HP, hpPctFactor(b.HPPct))
	if err != nil {
		return fmt.Errorf("character: respawning hp: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("character: checking update result: %w", err)
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

func (s *SQLStore) ResetHP(ctx context.Context, characterID int64) error {
	// Max HP scales with the row's own level (base + per-level), so a reset
	// heals to the level-appropriate maximum.
	// With the worn items' bonus (round 769's review F1; MaxHPWith).
	// And its buffs' percent (round 785's review; MaxHPWith's scalePct).
	b := BonusOf(characterID)
	res, err := txn.Conn(ctx, s.db).ExecContext(ctx,
		`UPDATE characters SET hp = GREATEST(1, FLOOR((ROUND((str + $4) * $1 * POWER($2, level - 1)) + $5) * $6)) WHERE id = $3`,
		HPPerStr, StatGrowth, characterID, b.Str, b.HP, hpPctFactor(b.HPPct))
	if err != nil {
		return fmt.Errorf("character: resetting hp: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("character: checking update result: %w", err)
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// GetByID implements Store.
func (s *SQLStore) GetByID(ctx context.Context, characterID int64) (*Character, error) {
	c, err := scanCharacter(txn.Conn(ctx, s.db).QueryRowContext(ctx,
		`SELECT `+characterColumns+` FROM characters WHERE id = $1`, characterID))
	if err == sql.ErrNoRows {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("character: getting character: %w", err)
	}
	return c, nil
}

// SetLeveling implements Store.
func (s *SQLStore) SetLeveling(ctx context.Context, characterID int64, level int, exp int64, statPoints, str, intel int) error {
	res, err := txn.Conn(ctx, s.db).ExecContext(ctx,
		`UPDATE characters SET level = $1, exp = $2, stat_points = $3, str = $4, intel = $5 WHERE id = $6`,
		level, exp, statPoints, str, intel, characterID)
	if err != nil {
		return fmt.Errorf("character: setting leveling: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("character: checking update result: %w", err)
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// SetGender implements Store.
func (s *SQLStore) SetGender(ctx context.Context, characterID int64, gender string) error {
	// A China gender carries its legacy body with it (LegacyModelFor), so the
	// old create path and the tests that set a gender keep RefObjID agreeing.
	res, err := txn.Conn(ctx, s.db).ExecContext(ctx,
		`UPDATE characters SET gender = $1, ref_obj_id = CASE WHEN $1 IN ('china_man', 'china_woman') THEN $3 ELSE ref_obj_id END WHERE id = $2`,
		gender, characterID, LegacyModelFor(gender))
	if err != nil {
		return fmt.Errorf("character: setting gender: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("character: checking update result: %w", err)
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// SavePosition implements Store.
func (s *SQLStore) SavePosition(ctx context.Context, characterID int64, zone, frame string, x, y, z float64) error {
	res, err := txn.Conn(ctx, s.db).ExecContext(ctx,
		`UPDATE characters SET latest_zone = $1, latest_frame = $2, pos_x = $3, pos_y = $4, pos_z = $5 WHERE id = $6`,
		zone, frame, x, y, z, characterID)
	if err != nil {
		return fmt.Errorf("character: saving position: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("character: checking update result: %w", err)
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

func isUniqueConstraintErr(err error) bool {
	return err != nil && strings.Contains(err.Error(), "duplicate key value violates unique constraint")
}
