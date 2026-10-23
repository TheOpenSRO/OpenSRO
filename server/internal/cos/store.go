package cos

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
)

// Record is one COS's saved state: retail's _CHARCOS row (round 795, READ
// the in-memory record +0x20..+0x7a and _AddNewCOS's arguments,
// docs/protocol/pets.md). A pet belongs to its summon item -- the item
// instance's Data word holds the record's ID, 0 before the first summon
// (READ item +0x38) -- and its OwnerCharID is 0; a ride or transport belongs
// to the character that summoned it.
type Record struct {
	ID          int64
	OwnerCharID int64
	RefCharID   int64
	HP, MP      int
	// State is StateAlive | StateSummoned bits.
	State uint8
	Name  string
	Level int
	Exp   int64
	HGP   int
	// PetOption is the growth pet's AI mode or the ability pet's pickup
	// flags (PetOption at creation).
	PetOption uint32
	// RentEnd is an ability pet's rent end (zero for the others).
	RentEnd time.Time
	// InvSize is its bag's capacity (AbilityPetSlots for an ability pet).
	InvSize int
}

// Alive and Summoned read State.
func (r Record) Alive() bool    { return r.State&StateAlive != 0 }
func (r Record) Summoned() bool { return r.State&StateSummoned != 0 }

// ErrNotFound is a lookup of an id the store does not hold.
var ErrNotFound = errors.New("cos: no such COS")

// ErrNameTaken is _COS_Naming's -2: another pet has the name.
var ErrNameTaken = errors.New("cos: the name is taken")

// Store keeps the records.
type Store interface {
	// Create saves a new record and returns its id (_AddNewCOS).
	Create(ctx context.Context, r Record) (int64, error)
	Get(ctx context.Context, id int64) (Record, error)
	// Save writes every field but the name (_ChangeCOSState and the
	// async saves of HP, HGP, EXP and the rent).
	Save(ctx context.Context, r Record) error
	// Delete removes a record (_DeleteCharCOS).
	Delete(ctx context.Context, id int64) error
	// SetName names a pet once (_COS_Naming): ErrNameTaken when another
	// record has it (compared without case, OURS).
	SetName(ctx context.Context, id int64, name string) error
	// SummonedRides lists a character's records that are still out -- the
	// rides and transports re-spawned at world entry (FUN_004fa430's first
	// list).
	SummonedRides(ctx context.Context, ownerCharID int64) ([]Record, error)
}

// MemStore is an in-memory Store (tests, -in-memory).
type MemStore struct {
	mu   sync.Mutex
	next int64
	recs map[int64]Record
}

// NewMemStore returns an empty MemStore.
func NewMemStore() *MemStore { return &MemStore{recs: map[int64]Record{}} }

// Create implements Store.
func (m *MemStore) Create(_ context.Context, r Record) (int64, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.next++
	r.ID = m.next
	m.recs[r.ID] = r
	return r.ID, nil
}

// Get implements Store.
func (m *MemStore) Get(_ context.Context, id int64) (Record, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	r, ok := m.recs[id]
	if !ok {
		return Record{}, ErrNotFound
	}
	return r, nil
}

// Save implements Store.
func (m *MemStore) Save(_ context.Context, r Record) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	old, ok := m.recs[r.ID]
	if !ok {
		return ErrNotFound
	}
	r.Name = old.Name
	m.recs[r.ID] = r
	return nil
}

// Delete implements Store.
func (m *MemStore) Delete(_ context.Context, id int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.recs, id)
	return nil
}

// SetName implements Store.
func (m *MemStore) SetName(_ context.Context, id int64, name string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	r, ok := m.recs[id]
	if !ok {
		return ErrNotFound
	}
	for oid, o := range m.recs {
		if oid != id && o.Name != "" && strings.EqualFold(o.Name, name) {
			return ErrNameTaken
		}
	}
	r.Name = name
	m.recs[id] = r
	return nil
}

// SummonedRides implements Store.
func (m *MemStore) SummonedRides(_ context.Context, owner int64) ([]Record, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var out []Record
	for _, r := range m.recs {
		if owner != 0 && r.OwnerCharID == owner && r.Summoned() {
			out = append(out, r)
		}
	}
	return out, nil
}

// schema is _CHARCOS's columns this server keeps (OURS: the names and
// types; the fields are retail's). The name index makes _COS_Naming's
// "taken" answer a constraint.
const schema = `
CREATE TABLE IF NOT EXISTS char_cos (
	id            BIGSERIAL PRIMARY KEY,
	owner_char_id BIGINT NOT NULL DEFAULT 0,
	ref_char_id   BIGINT NOT NULL,
	hp            INTEGER NOT NULL DEFAULT 0,
	mp            INTEGER NOT NULL DEFAULT 0,
	state         SMALLINT NOT NULL DEFAULT 0,
	name          TEXT NOT NULL DEFAULT '',
	lvl           INTEGER NOT NULL DEFAULT 1,
	exp           BIGINT NOT NULL DEFAULT 0,
	hgp           INTEGER NOT NULL DEFAULT 10000,
	pet_option    BIGINT NOT NULL DEFAULT 0,
	rent_end      TIMESTAMPTZ,
	inv_size      INTEGER NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX IF NOT EXISTS char_cos_name_key ON char_cos (lower(name)) WHERE name <> '';
CREATE INDEX IF NOT EXISTS char_cos_owner ON char_cos (owner_char_id) WHERE owner_char_id <> 0;
`

// SQLStore is a Store on PostgreSQL.
type SQLStore struct{ db *sql.DB }

// NewSQLStore opens the store on a pool the caller owns, creating its table.
func NewSQLStore(db *sql.DB) (*SQLStore, error) {
	if err := txn.Migrate(db, schema); err != nil {
		return nil, fmt.Errorf("cos: creating schema: %w", err)
	}
	return &SQLStore{db: db}, nil
}

// TxDB implements txn.TxDBer.
func (s *SQLStore) TxDB() *sql.DB { return s.db }

func rentArg(t time.Time) any {
	if t.IsZero() {
		return nil
	}
	return t.UTC()
}

// Create implements Store.
func (s *SQLStore) Create(ctx context.Context, r Record) (int64, error) {
	var id int64
	err := txn.Conn(ctx, s.db).QueryRowContext(ctx, `INSERT INTO char_cos
		(owner_char_id, ref_char_id, hp, mp, state, name, lvl, exp, hgp, pet_option, rent_end, inv_size)
		VALUES ($1,$2,$3,$4,$5,'',$6,$7,$8,$9,$10,$11) RETURNING id`,
		r.OwnerCharID, r.RefCharID, r.HP, r.MP, int(r.State), r.Level, r.Exp, r.HGP, int64(r.PetOption),
		rentArg(r.RentEnd), r.InvSize).Scan(&id)
	if err != nil {
		return 0, fmt.Errorf("cos: creating: %w", err)
	}
	return id, nil
}

const selectCols = `id, owner_char_id, ref_char_id, hp, mp, state, name, lvl, exp, hgp, pet_option, rent_end, inv_size`

func scanRecord(sc interface{ Scan(...any) error }) (Record, error) {
	var r Record
	var state int
	var opt int64
	var rent sql.NullTime
	if err := sc.Scan(&r.ID, &r.OwnerCharID, &r.RefCharID, &r.HP, &r.MP, &state, &r.Name, &r.Level, &r.Exp,
		&r.HGP, &opt, &rent, &r.InvSize); err != nil {
		return Record{}, err
	}
	r.State, r.PetOption = uint8(state), uint32(opt)
	if rent.Valid {
		r.RentEnd = rent.Time
	}
	return r, nil
}

// Get implements Store.
func (s *SQLStore) Get(ctx context.Context, id int64) (Record, error) {
	r, err := scanRecord(txn.Conn(ctx, s.db).QueryRowContext(ctx,
		`SELECT `+selectCols+` FROM char_cos WHERE id = $1`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return Record{}, ErrNotFound
	}
	if err != nil {
		return Record{}, fmt.Errorf("cos: reading %d: %w", id, err)
	}
	return r, nil
}

// Save implements Store.
func (s *SQLStore) Save(ctx context.Context, r Record) error {
	res, err := txn.Conn(ctx, s.db).ExecContext(ctx, `UPDATE char_cos SET owner_char_id=$2, ref_char_id=$3,
		hp=$4, mp=$5, state=$6, lvl=$7, exp=$8, hgp=$9, pet_option=$10, rent_end=$11, inv_size=$12 WHERE id=$1`,
		r.ID, r.OwnerCharID, r.RefCharID, r.HP, r.MP, int(r.State), r.Level, r.Exp, r.HGP, int64(r.PetOption),
		rentArg(r.RentEnd), r.InvSize)
	if err != nil {
		return fmt.Errorf("cos: saving %d: %w", r.ID, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

// Delete implements Store.
func (s *SQLStore) Delete(ctx context.Context, id int64) error {
	if _, err := txn.Conn(ctx, s.db).ExecContext(ctx, `DELETE FROM char_cos WHERE id = $1`, id); err != nil {
		return fmt.Errorf("cos: deleting %d: %w", id, err)
	}
	return nil
}

// SetName implements Store.
func (s *SQLStore) SetName(ctx context.Context, id int64, name string) error {
	res, err := txn.Conn(ctx, s.db).ExecContext(ctx, `UPDATE char_cos SET name = $2 WHERE id = $1`, id, name)
	if err != nil {
		if strings.Contains(err.Error(), "char_cos_name_key") {
			return ErrNameTaken
		}
		return fmt.Errorf("cos: naming %d: %w", id, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

// SummonedRides implements Store.
func (s *SQLStore) SummonedRides(ctx context.Context, owner int64) ([]Record, error) {
	rows, err := txn.Conn(ctx, s.db).QueryContext(ctx,
		`SELECT `+selectCols+` FROM char_cos WHERE owner_char_id = $1 AND state & 2 <> 0 ORDER BY id`, owner)
	if err != nil {
		return nil, fmt.Errorf("cos: listing %d's: %w", owner, err)
	}
	defer rows.Close()
	var out []Record
	for rows.Next() {
		r, err := scanRecord(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}
