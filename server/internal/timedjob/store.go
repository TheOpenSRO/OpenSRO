package timedjob

import (
	"context"
	"database/sql"
	"fmt"
	"sort"
	"sync"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
)

// Round 838: the character's timed jobs OpenSRO keeps across a restart --
// retail's _TIMEDJOB rows (_ADDTIMEDJOB above). OURS: the table's names and
// columns; what a row holds is each kind's own (session/goldtime.go,
// session/composite.go).
//
// The job types are the engine's (CTimedJobManagerForPC's switch 0x6565f0):
// 3 the premium (CTJ_PremiumKeeper), 5 a composite item's grant
// (CTJ_CompositeItemKeeper; its entry's FourCC in Sub).
const (
	TypePremium   = 3
	TypeComposite = 5
)

// Job is one row. A row is keyed by (CharID, Type, Sub, Ref).
type Job struct {
	CharID int64
	Type   int
	// Sub is a type-5 entry's FourCC ("UIL1", "BFI1", "UQL1"); empty for a
	// premium.
	Sub string
	// Ref is what the job is about: the premium item's id, a grant's item or
	// quest id.
	Ref int64
	// Key is the item that made it (a composite scroll's id; the premium's
	// own id again).
	Key   int64
	Start time.Time
	// End is a grant's fixed expiry; zero for a premium, whose end its tick
	// decides.
	End time.Time
	// V1..V4 are the kind's own words (a grant's remaining and maximum, a
	// premium's days, gold time halves, paused flag).
	V1, V2, V3, V4 int64
}

// Store keeps the rows.
type Store interface {
	// Put inserts or replaces the row with j's key.
	Put(ctx context.Context, j Job) error
	// Delete removes the row with that key (none is not an error).
	Delete(ctx context.Context, charID int64, typ int, sub string, ref int64) error
	// List returns a character's rows.
	List(ctx context.Context, charID int64) ([]Job, error)
}

type jobKey struct {
	char int64
	typ  int
	sub  string
	ref  int64
}

// MemStore is a Store in memory (the -in-memory server).
type MemStore struct {
	mu   sync.Mutex
	rows map[jobKey]Job
}

func NewMemStore() *MemStore { return &MemStore{rows: map[jobKey]Job{}} }

func (m *MemStore) Put(_ context.Context, j Job) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.rows[jobKey{j.CharID, j.Type, j.Sub, j.Ref}] = j
	return nil
}

func (m *MemStore) Delete(_ context.Context, charID int64, typ int, sub string, ref int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.rows, jobKey{charID, typ, sub, ref})
	return nil
}

func (m *MemStore) List(_ context.Context, charID int64) ([]Job, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var out []Job
	for k, j := range m.rows {
		if k.char == charID {
			out = append(out, j)
		}
	}
	sort.Slice(out, func(a, b int) bool {
		if out[a].Type != out[b].Type {
			return out[a].Type < out[b].Type
		}
		if out[a].Sub != out[b].Sub {
			return out[a].Sub < out[b].Sub
		}
		return out[a].Ref < out[b].Ref
	})
	return out, nil
}

const schema = `
CREATE TABLE IF NOT EXISTS char_timed_job (
	char_id  BIGINT NOT NULL,
	job_type INTEGER NOT NULL,
	sub      TEXT NOT NULL DEFAULT '',
	ref_id   BIGINT NOT NULL,
	key_id   BIGINT NOT NULL DEFAULT 0,
	started  TIMESTAMPTZ NOT NULL,
	ends     TIMESTAMPTZ,
	v1       BIGINT NOT NULL DEFAULT 0,
	v2       BIGINT NOT NULL DEFAULT 0,
	v3       BIGINT NOT NULL DEFAULT 0,
	v4       BIGINT NOT NULL DEFAULT 0,
	PRIMARY KEY (char_id, job_type, sub, ref_id)
);
`

// SQLStore is a Store on PostgreSQL.
type SQLStore struct{ db *sql.DB }

// NewSQLStore opens the store on a pool the caller owns, creating its table.
func NewSQLStore(db *sql.DB) (*SQLStore, error) {
	if err := txn.Migrate(db, schema); err != nil {
		return nil, fmt.Errorf("timedjob: creating schema: %w", err)
	}
	return &SQLStore{db: db}, nil
}

func endArg(t time.Time) any {
	if t.IsZero() {
		return nil
	}
	return t.UTC()
}

func (s *SQLStore) Put(ctx context.Context, j Job) error {
	_, err := txn.Conn(ctx, s.db).ExecContext(ctx, `INSERT INTO char_timed_job
		(char_id, job_type, sub, ref_id, key_id, started, ends, v1, v2, v3, v4)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
		ON CONFLICT (char_id, job_type, sub, ref_id) DO UPDATE SET key_id=$5, started=$6, ends=$7,
		v1=$8, v2=$9, v3=$10, v4=$11`,
		j.CharID, j.Type, j.Sub, j.Ref, j.Key, j.Start.UTC(), endArg(j.End), j.V1, j.V2, j.V3, j.V4)
	if err != nil {
		return fmt.Errorf("timedjob: saving: %w", err)
	}
	return nil
}

func (s *SQLStore) Delete(ctx context.Context, charID int64, typ int, sub string, ref int64) error {
	if _, err := txn.Conn(ctx, s.db).ExecContext(ctx,
		`DELETE FROM char_timed_job WHERE char_id=$1 AND job_type=$2 AND sub=$3 AND ref_id=$4`,
		charID, typ, sub, ref); err != nil {
		return fmt.Errorf("timedjob: deleting: %w", err)
	}
	return nil
}

func (s *SQLStore) List(ctx context.Context, charID int64) ([]Job, error) {
	rows, err := txn.Conn(ctx, s.db).QueryContext(ctx, `SELECT char_id, job_type, sub, ref_id, key_id, started, ends,
		v1, v2, v3, v4 FROM char_timed_job WHERE char_id=$1 ORDER BY job_type, sub, ref_id`, charID)
	if err != nil {
		return nil, fmt.Errorf("timedjob: listing: %w", err)
	}
	defer rows.Close()
	var out []Job
	for rows.Next() {
		var j Job
		var end sql.NullTime
		if err := rows.Scan(&j.CharID, &j.Type, &j.Sub, &j.Ref, &j.Key, &j.Start, &end, &j.V1, &j.V2, &j.V3, &j.V4); err != nil {
			return nil, fmt.Errorf("timedjob: reading: %w", err)
		}
		if end.Valid {
			j.End = end.Time
		}
		out = append(out, j)
	}
	return out, rows.Err()
}
