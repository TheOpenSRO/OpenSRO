package jobs

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
)

// schema is _CharTrijob, _OldTrijob, _TrijobRewards and the Tab_RefRanking_*
// tables this server keeps (OURS: the names and types; the fields are
// retail's, docs/protocol/jobs.md). The alias index makes
// _CanAssignThisNickName's "taken" answer a constraint.
const schema = `
CREATE TABLE IF NOT EXISTS char_trijob (
	char_id       BIGINT PRIMARY KEY,
	job_type      SMALLINT NOT NULL DEFAULT 0,
	lvl           SMALLINT NOT NULL DEFAULT 1,
	exp           BIGINT NOT NULL DEFAULT 0,
	contribution  BIGINT NOT NULL DEFAULT 0,
	reward        BIGINT NOT NULL DEFAULT 0,
	alias         TEXT NOT NULL DEFAULT '',
	penalty_until TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS char_trijob_alias_key ON char_trijob (lower(alias)) WHERE alias <> '';
CREATE INDEX IF NOT EXISTS char_trijob_type ON char_trijob (job_type);
ALTER TABLE char_trijob ADD COLUMN IF NOT EXISTS safe_count SMALLINT NOT NULL DEFAULT 0;
ALTER TABLE char_trijob ADD COLUMN IF NOT EXISTS safe_status BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE char_trijob ADD COLUMN IF NOT EXISTS safe_last TIMESTAMPTZ;
CREATE TABLE IF NOT EXISTS char_old_trijob (
	char_id    BIGINT PRIMARY KEY,
	lvl_trader SMALLINT NOT NULL DEFAULT 1,
	exp_trader BIGINT NOT NULL DEFAULT 0,
	lvl_robber SMALLINT NOT NULL DEFAULT 1,
	exp_robber BIGINT NOT NULL DEFAULT 0,
	lvl_hunter SMALLINT NOT NULL DEFAULT 1,
	exp_hunter BIGINT NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS trijob_rewards (
	job_type SMALLINT PRIMARY KEY,
	reward   BIGINT NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS trijob_ranking (
	job_type     SMALLINT NOT NULL,
	rank_type    SMALLINT NOT NULL,
	rank         SMALLINT NOT NULL,
	alias        TEXT NOT NULL,
	lvl          SMALLINT NOT NULL,
	exp          BIGINT NOT NULL DEFAULT 0,
	contribution BIGINT NOT NULL DEFAULT 0,
	country      SMALLINT NOT NULL DEFAULT 0,
	PRIMARY KEY (job_type, rank_type, rank)
);
`

// SQLStore is a Store on PostgreSQL.
type SQLStore struct{ db *sql.DB }

// NewSQLStore opens the store on a pool the caller owns, creating its tables.
func NewSQLStore(db *sql.DB) (*SQLStore, error) {
	if err := txn.Migrate(db, schema); err != nil {
		return nil, fmt.Errorf("jobs: creating schema: %w", err)
	}
	return &SQLStore{db: db}, nil
}

// TxDB implements txn.TxDBer.
func (s *SQLStore) TxDB() *sql.DB { return s.db }

const recordCols = `char_id, job_type, lvl, exp, contribution, reward, alias, penalty_until, safe_count, safe_status, safe_last`

func scanJob(sc interface{ Scan(...any) error }) (Record, error) {
	var r Record
	var kind, lvl int
	var pen, last sql.NullTime
	if err := sc.Scan(&r.CharID, &kind, &lvl, &r.Exp, &r.Contribution, &r.Reward, &r.Alias, &pen,
		&r.Safe.Count, &r.Safe.Status, &last); err != nil {
		return Record{}, err
	}
	r.Kind, r.Level = Kind(kind), lvl
	if pen.Valid {
		r.PenaltyUntil = pen.Time
	}
	if last.Valid {
		r.Safe.Last = last.Time
	}
	return r, nil
}

func timeArg(t time.Time) any {
	if t.IsZero() {
		return nil
	}
	return t.UTC()
}

// Get implements Store.
func (s *SQLStore) Get(ctx context.Context, charID int64) (Record, error) {
	r, err := scanJob(txn.Conn(ctx, s.db).QueryRowContext(ctx,
		`SELECT `+recordCols+` FROM char_trijob WHERE char_id = $1`, charID))
	if errors.Is(err, sql.ErrNoRows) {
		return NewRecord(charID), nil
	}
	if err != nil {
		return Record{}, fmt.Errorf("jobs: reading %d: %w", charID, err)
	}
	return r, nil
}

// Save implements Store.
func (s *SQLStore) Save(ctx context.Context, r Record) error {
	_, err := txn.Conn(ctx, s.db).ExecContext(ctx, `INSERT INTO char_trijob
		(char_id, job_type, lvl, exp, contribution, reward, penalty_until, safe_count, safe_status, safe_last)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)
		ON CONFLICT (char_id) DO UPDATE SET job_type=$2, lvl=$3, exp=$4, contribution=$5, reward=$6, penalty_until=$7,
		safe_count=$8, safe_status=$9, safe_last=$10`,
		r.CharID, int(r.Kind), r.Level, r.Exp, r.Contribution, r.Reward, timeArg(r.PenaltyUntil),
		r.Safe.Count, r.Safe.Status, timeArg(r.Safe.Last))
	if err != nil {
		return fmt.Errorf("jobs: saving %d: %w", r.CharID, err)
	}
	return nil
}

// SetAlias implements Store.
func (s *SQLStore) SetAlias(ctx context.Context, charID int64, alias string) error {
	_, err := txn.Conn(ctx, s.db).ExecContext(ctx, `INSERT INTO char_trijob (char_id, alias) VALUES ($1, $2)
		ON CONFLICT (char_id) DO UPDATE SET alias = $2`, charID, alias)
	if err != nil {
		if strings.Contains(err.Error(), "char_trijob_alias_key") {
			return ErrAliasTaken
		}
		return fmt.Errorf("jobs: naming %d: %w", charID, err)
	}
	return nil
}

// AliasFree implements Store.
func (s *SQLStore) AliasFree(ctx context.Context, charID int64, alias string) (bool, error) {
	var n int
	err := txn.Conn(ctx, s.db).QueryRowContext(ctx,
		`SELECT count(*) FROM char_trijob WHERE lower(alias) = lower($1) AND alias <> '' AND char_id <> $2`,
		alias, charID).Scan(&n)
	if err != nil {
		return false, fmt.Errorf("jobs: checking an alias: %w", err)
	}
	return n == 0, nil
}

// OldJob implements Store.
func (s *SQLStore) OldJob(ctx context.Context, charID int64) (OldJob, error) {
	var o OldJob
	err := txn.Conn(ctx, s.db).QueryRowContext(ctx, `SELECT lvl_trader, exp_trader, lvl_robber, exp_robber,
		lvl_hunter, exp_hunter FROM char_old_trijob WHERE char_id = $1`, charID).Scan(
		&o.Level[0], &o.Exp[0], &o.Level[1], &o.Exp[1], &o.Level[2], &o.Exp[2])
	if errors.Is(err, sql.ErrNoRows) {
		return OldJob{}, ErrNoOldJob
	}
	if err != nil {
		return OldJob{}, fmt.Errorf("jobs: reading %d's previous job: %w", charID, err)
	}
	return o, nil
}

// DeleteOldJob implements Store.
func (s *SQLStore) DeleteOldJob(ctx context.Context, charID int64) error {
	if _, err := txn.Conn(ctx, s.db).ExecContext(ctx, `DELETE FROM char_old_trijob WHERE char_id = $1`, charID); err != nil {
		return fmt.Errorf("jobs: deleting %d's previous job: %w", charID, err)
	}
	return nil
}

// List implements Store.
func (s *SQLStore) List(ctx context.Context, kind Kind) ([]Record, error) {
	rows, err := txn.Conn(ctx, s.db).QueryContext(ctx,
		`SELECT `+recordCols+` FROM char_trijob WHERE job_type = $1 ORDER BY char_id`, int(kind))
	if err != nil {
		return nil, fmt.Errorf("jobs: listing kind %d: %w", kind, err)
	}
	defer rows.Close()
	var out []Record
	for rows.Next() {
		r, err := scanJob(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// AddPool implements Store.
func (s *SQLStore) AddPool(ctx context.Context, pool Kind, amount int64) error {
	_, err := txn.Conn(ctx, s.db).ExecContext(ctx, `INSERT INTO trijob_rewards (job_type, reward) VALUES ($1, $2)
		ON CONFLICT (job_type) DO UPDATE SET reward = trijob_rewards.reward + $2`, int(pool), amount)
	if err != nil {
		return fmt.Errorf("jobs: adding to pool %d: %w", pool, err)
	}
	return nil
}

// TakePool implements Store.
func (s *SQLStore) TakePool(ctx context.Context, pool Kind) (int64, error) {
	var v int64
	err := txn.For(s).Run(ctx, func(ctx context.Context) error {
		q := txn.Conn(ctx, s.db)
		err := q.QueryRowContext(ctx, `SELECT reward FROM trijob_rewards WHERE job_type = $1 FOR UPDATE`, int(pool)).Scan(&v)
		if errors.Is(err, sql.ErrNoRows) {
			v = 0
			return nil
		}
		if err != nil {
			return err
		}
		_, err = q.ExecContext(ctx, `UPDATE trijob_rewards SET reward = 0 WHERE job_type = $1`, int(pool))
		return err
	})
	if err != nil {
		return 0, fmt.Errorf("jobs: taking pool %d: %w", pool, err)
	}
	return v, nil
}

// Rankings implements Store.
func (s *SQLStore) Rankings(ctx context.Context, kind Kind, t RankType) ([]RankRow, error) {
	rows, err := txn.Conn(ctx, s.db).QueryContext(ctx, `SELECT rank, alias, lvl, exp, contribution, country
		FROM trijob_ranking WHERE job_type = $1 AND rank_type = $2 ORDER BY rank`, int(kind), int(t))
	if err != nil {
		return nil, fmt.Errorf("jobs: reading rankings: %w", err)
	}
	defer rows.Close()
	var out []RankRow
	for rows.Next() {
		var r RankRow
		var country int
		if err := rows.Scan(&r.Rank, &r.Alias, &r.Level, &r.Exp, &r.Contribution, &country); err != nil {
			return nil, err
		}
		r.Country = uint8(country)
		out = append(out, r)
	}
	return out, rows.Err()
}

// SetRankings implements Store.
func (s *SQLStore) SetRankings(ctx context.Context, kind Kind, t RankType, rows []RankRow) error {
	return txn.For(s).Run(ctx, func(ctx context.Context) error {
		q := txn.Conn(ctx, s.db)
		if _, err := q.ExecContext(ctx, `DELETE FROM trijob_ranking WHERE job_type = $1 AND rank_type = $2`,
			int(kind), int(t)); err != nil {
			return err
		}
		for _, r := range rows {
			if _, err := q.ExecContext(ctx, `INSERT INTO trijob_ranking (job_type, rank_type, rank, alias, lvl,
				exp, contribution, country) VALUES ($1,$2,$3,$4,$5,$6,$7,$8)`, int(kind), int(t), r.Rank, r.Alias,
				r.Level, r.Exp, r.Contribution, int(r.Country)); err != nil {
				return err
			}
		}
		return nil
	})
}
