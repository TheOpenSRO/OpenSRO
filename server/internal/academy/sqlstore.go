package academy

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/persistence"
	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
)

// SQLStore is a Store on PostgreSQL, its tables persistence.AcademySchema.
// Every change runs in one transaction with the camp's row locked, so two
// requests on one camp take turns as the shard manager's job queue makes
// them.
type SQLStore struct{ db *sql.DB }

// NewSQLStore opens the store on a pool the caller owns, creating its tables.
func NewSQLStore(db *sql.DB) (*SQLStore, error) {
	if err := txn.Migrate(db, persistence.AcademySchema); err != nil {
		return nil, fmt.Errorf("academy: creating schema: %w", err)
	}
	return &SQLStore{db: db}, nil
}

// TruncateForTest empties every academy table.
func (s *SQLStore) TruncateForTest(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `TRUNCATE TABLE academy_buff_status, academy_members, academy_camps,
		academy_honor_rank, academy_honor_bank, academy_rank_update RESTART IDENTITY CASCADE`)
	return err
}

type querier interface {
	QueryContext(ctx context.Context, q string, args ...any) (*sql.Rows, error)
	QueryRowContext(ctx context.Context, q string, args ...any) *sql.Row
	ExecContext(ctx context.Context, q string, args ...any) (sql.Result, error)
}

func (s *SQLStore) inTx(ctx context.Context, f func(tx *sql.Tx) error) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("academy: beginning transaction: %w", err)
	}
	defer tx.Rollback()
	if err := f(tx); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("academy: committing: %w", err)
	}
	return nil
}

const campCols = `id, creation_date, rank, graduate_count, evaluation_point, latest_evaluation_date, comment_title, comment`
const memberCols = `camp_id, char_id, ref_obj_id, char_name, join_date, member_class, char_joined_level, char_cur_level, char_max_level, honor_point`

func loadCamp(ctx context.Context, q querier, campID int64, lock bool) (*Camp, error) {
	query := `SELECT ` + campCols + ` FROM academy_camps WHERE id = $1`
	if lock {
		query += ` FOR UPDATE`
	}
	c := &Camp{}
	err := q.QueryRowContext(ctx, query, campID).Scan(&c.ID, &c.CreationDate, &c.Rank, &c.GraduateCount,
		&c.EvaluationPoint, &c.LatestEvaluationDate, &c.NoticeTitle, &c.Notice)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNoSuchCamp
	}
	if err != nil {
		return nil, fmt.Errorf("academy: reading camp: %w", err)
	}
	c.CreationDate, c.LatestEvaluationDate = c.CreationDate.In(time.Local), c.LatestEvaluationDate.In(time.Local)
	rows, err := q.QueryContext(ctx, `SELECT `+memberCols+` FROM academy_members WHERE camp_id = $1
		ORDER BY (member_class <> 0), join_seq`, campID)
	if err != nil {
		return nil, fmt.Errorf("academy: reading members: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var m Member
		if err := rows.Scan(&m.CampID, &m.CharID, &m.RefObjID, &m.Name, &m.JoinDate, &m.Class, &m.JoinedLevel,
			&m.CurLevel, &m.MaxLevel, &m.Honor); err != nil {
			return nil, fmt.Errorf("academy: reading member: %w", err)
		}
		m.JoinDate = m.JoinDate.In(time.Local)
		c.Members = append(c.Members, m)
	}
	return c, rows.Err()
}

// campIDOf is charID's camp id; with lock, the camp row is locked.
func campIDOf(ctx context.Context, q querier, charID int64, lock bool) (int64, error) {
	var id int64
	err := q.QueryRowContext(ctx, `SELECT camp_id FROM academy_members WHERE char_id = $1`, charID).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, ErrNotInCamp
	}
	if err != nil {
		return 0, fmt.Errorf("academy: looking up membership: %w", err)
	}
	if lock {
		if _, err := q.ExecContext(ctx, `SELECT 1 FROM academy_camps WHERE id = $1 FOR UPDATE`, id); err != nil {
			return 0, fmt.Errorf("academy: locking camp: %w", err)
		}
		// The member may have moved while the lock was awaited.
		var again int64
		err := q.QueryRowContext(ctx, `SELECT camp_id FROM academy_members WHERE char_id = $1`, charID).Scan(&again)
		if errors.Is(err, sql.ErrNoRows) {
			return 0, ErrNotInCamp
		}
		if err != nil {
			return 0, fmt.Errorf("academy: looking up membership: %w", err)
		}
		if again != id {
			return campIDOf(ctx, q, charID, lock)
		}
	}
	return id, nil
}

func addBank(ctx context.Context, q querier, charID int64, points int) error {
	if points <= 0 {
		return nil
	}
	_, err := q.ExecContext(ctx, `INSERT INTO academy_honor_bank (char_id, honor_point) VALUES ($1, $2)
		ON CONFLICT (char_id) DO UPDATE SET honor_point = academy_honor_bank.honor_point + $2`, charID, points)
	if err != nil {
		return fmt.Errorf("academy: banking honor: %w", err)
	}
	return nil
}

func (s *SQLStore) addMember(ctx context.Context, tx *sql.Tx, c *Camp, j Joiner, now time.Time) error {
	var in int
	if err := tx.QueryRowContext(ctx, `SELECT count(*) FROM academy_members WHERE char_id = $1`, j.CharID).Scan(&in); err != nil {
		return fmt.Errorf("academy: checking membership: %w", err)
	}
	if in > 0 {
		return ErrInCamp
	}
	class := ClassForMaxLevel(j.MaxLevel)
	if err := checkAdd(c, class); err != nil {
		return err
	}
	var honor int
	err := tx.QueryRowContext(ctx, `DELETE FROM academy_honor_bank WHERE char_id = $1 RETURNING honor_point`, j.CharID).Scan(&honor)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("academy: reading the honor bank: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO academy_members (`+memberCols+`) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`,
		c.ID, j.CharID, j.RefObjID, j.Name, now.UTC(), class, j.MaxLevel, j.CurLevel, j.MaxLevel, honor); err != nil {
		return fmt.Errorf("academy: adding member: %w", err)
	}
	for _, b := range BuffRowsFor(c.ID, j.CharID, class) {
		if _, err := tx.ExecContext(ctx, `INSERT INTO academy_buff_status (camp_id, recipient_char_id, buff_slot_idx,
			donor_char_id, starting_time, remain_buff_point, buff_type) VALUES ($1,$2,$3,$4,$5,$6,$7)`,
			b.CampID, b.RecipientID, b.Slot, b.DonorID, b.Start.UTC(), b.Points, b.Type); err != nil {
			return fmt.Errorf("academy: adding buff row: %w", err)
		}
	}
	return nil
}

func (s *SQLStore) Found(ctx context.Context, j Joiner, now time.Time) (*Camp, error) {
	now = Minute(now)
	var out *Camp
	err := s.inTx(ctx, func(tx *sql.Tx) error {
		var id int64
		if err := tx.QueryRowContext(ctx, `INSERT INTO academy_camps (creation_date, latest_evaluation_date)
			VALUES ($1, $1) RETURNING id`, now.UTC()).Scan(&id); err != nil {
			return fmt.Errorf("academy: founding: %w", err)
		}
		c, err := loadCamp(ctx, tx, id, true)
		if err != nil {
			return err
		}
		if err := s.addMember(ctx, tx, c, j, now); err != nil {
			return err
		}
		out, err = loadCamp(ctx, tx, id, false)
		return err
	})
	return out, err
}

func (s *SQLStore) AddMember(ctx context.Context, campID int64, j Joiner, now time.Time) (*Camp, error) {
	var out *Camp
	err := s.inTx(ctx, func(tx *sql.Tx) error {
		c, err := loadCamp(ctx, tx, campID, true)
		if err != nil {
			return err
		}
		if err := s.addMember(ctx, tx, c, j, Minute(now)); err != nil {
			return err
		}
		out, err = loadCamp(ctx, tx, campID, false)
		return err
	})
	return out, err
}

// lockMember locks charID's camp and returns it with charID's row.
func lockMember(ctx context.Context, tx *sql.Tx, charID int64) (*Camp, Member, error) {
	id, err := campIDOf(ctx, tx, charID, true)
	if err != nil {
		return nil, Member{}, err
	}
	c, err := loadCamp(ctx, tx, id, false)
	if err != nil {
		return nil, Member{}, err
	}
	m, ok := c.Member(charID)
	if !ok {
		return nil, Member{}, ErrNotInCamp
	}
	return c, m, nil
}

func deleteMember(ctx context.Context, tx *sql.Tx, charID int64) error {
	if _, err := tx.ExecContext(ctx, `DELETE FROM academy_buff_status WHERE recipient_char_id = $1`, charID); err != nil {
		return fmt.Errorf("academy: deleting buff rows: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM academy_members WHERE char_id = $1`, charID); err != nil {
		return fmt.Errorf("academy: deleting member: %w", err)
	}
	return nil
}

func (s *SQLStore) RemoveMember(ctx context.Context, charID int64, reason int) (*Camp, Member, error) {
	var out *Camp
	var gone Member
	err := s.inTx(ctx, func(tx *sql.Tx) error {
		c, m, err := lockMember(ctx, tx, charID)
		if err != nil {
			return err
		}
		if m.Class == MemberClassGuardian {
			return ErrGuardian
		}
		if err := addBank(ctx, tx, charID, bankAfterRemoval(m, reason)); err != nil {
			return err
		}
		if err := deleteMember(ctx, tx, charID); err != nil {
			return err
		}
		gone = m
		out, err = loadCamp(ctx, tx, c.ID, false)
		return err
	})
	if err != nil {
		return nil, Member{}, err
	}
	return out, gone, nil
}

func (s *SQLStore) Graduate(ctx context.Context, charID int64, points int, now time.Time) (*Camp, Graduation, error) {
	var out *Camp
	var g Graduation
	err := s.inTx(ctx, func(tx *sql.Tx) error {
		c, m, err := lockMember(ctx, tx, charID)
		if err != nil {
			return err
		}
		if m.Class == MemberClassGuardian {
			return ErrGuardian
		}
		g = Graduation{Member: m}
		if m.Class == MemberClassSecondGuardian {
			if err := addBank(ctx, tx, charID, m.Honor); err != nil {
				return err
			}
		} else if m.JoinedLevel <= HonorJoinLevelCeiling {
			gs, as := GraduationHonor(m.JoinedLevel)
			if _, err := tx.ExecContext(ctx, `UPDATE academy_camps SET graduate_count = graduate_count + 1,
				evaluation_point = evaluation_point + $2, latest_evaluation_date = $3 WHERE id = $1`,
				c.ID, points, Minute(now).UTC()); err != nil {
				return fmt.Errorf("academy: counting the graduate: %w", err)
			}
			if _, err := tx.ExecContext(ctx, `UPDATE academy_members SET honor_point = honor_point +
				CASE member_class WHEN 0 THEN $2::integer ELSE $3::integer END WHERE camp_id = $1 AND member_class IN (0, 1)`,
				c.ID, gs, as); err != nil {
				return fmt.Errorf("academy: paying the honor shares: %w", err)
			}
		} else {
			if _, err := tx.ExecContext(ctx, `UPDATE academy_camps SET graduate_count = graduate_count + 1 WHERE id = $1`, c.ID); err != nil {
				return fmt.Errorf("academy: counting the graduate: %w", err)
			}
		}
		if err := deleteMember(ctx, tx, charID); err != nil {
			return err
		}
		out, err = loadCamp(ctx, tx, c.ID, false)
		if err != nil {
			return err
		}
		if m.Class == MemberClassStudent && m.JoinedLevel <= HonorJoinLevelCeiling {
			for _, o := range out.Members {
				if o.Class != MemberClassStudent {
					g.Shares = append(g.Shares, HonorShare{CharID: o.CharID, Honor: o.Honor})
				}
			}
		}
		return nil
	})
	if err != nil {
		return nil, Graduation{}, err
	}
	return out, g, nil
}

func (s *SQLStore) Disband(ctx context.Context, campID int64) ([]Member, error) {
	var members []Member
	err := s.inTx(ctx, func(tx *sql.Tx) error {
		c, err := loadCamp(ctx, tx, campID, true)
		if err != nil {
			return err
		}
		for _, m := range c.Members {
			if m.Class == MemberClassSecondGuardian {
				if err := addBank(ctx, tx, m.CharID, m.Honor); err != nil {
					return err
				}
			}
		}
		if _, err := tx.ExecContext(ctx, `DELETE FROM academy_camps WHERE id = $1`, campID); err != nil {
			return fmt.Errorf("academy: disbanding: %w", err)
		}
		members = c.Members
		return nil
	})
	return members, err
}

func (s *SQLStore) SetNotice(ctx context.Context, campID int64, title, content string) error {
	res, err := s.db.ExecContext(ctx, `UPDATE academy_camps SET comment_title = $2, comment = $3 WHERE id = $1`, campID, title, content)
	if err != nil {
		return fmt.Errorf("academy: setting notice: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNoSuchCamp
	}
	return nil
}

func (s *SQLStore) setMember(ctx context.Context, charID int64, set string, args ...any) error {
	res, err := s.db.ExecContext(ctx, `UPDATE academy_members SET `+set+` WHERE char_id = $1`, append([]any{charID}, args...)...)
	if err != nil {
		return fmt.Errorf("academy: updating member: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotInCamp
	}
	return nil
}

func (s *SQLStore) SetLevels(ctx context.Context, charID int64, cur, max int) error {
	return s.setMember(ctx, charID, `char_cur_level = $2, char_max_level = $3`, cur, max)
}

func (s *SQLStore) SetRefObj(ctx context.Context, charID, refObjID int64) error {
	return s.setMember(ctx, charID, `ref_obj_id = $2`, refObjID)
}

func (s *SQLStore) SetName(ctx context.Context, charID int64, name string) error {
	return s.setMember(ctx, charID, `char_name = $2`, name)
}

func (s *SQLStore) SpendHonor(ctx context.Context, charID int64, amount int, pay func() error) (int, error) {
	var left int
	err := s.inTx(ctx, func(tx *sql.Tx) error {
		err := tx.QueryRowContext(ctx, `SELECT honor_point FROM academy_members WHERE char_id = $1 FOR UPDATE`, charID).Scan(&left)
		if errors.Is(err, sql.ErrNoRows) {
			return ErrNotInCamp
		}
		if err != nil {
			return fmt.Errorf("academy: reading honor: %w", err)
		}
		if left < amount {
			return ErrHonorShort
		}
		if pay != nil {
			if err := pay(); err != nil {
				return err
			}
		}
		left -= amount
		_, err = tx.ExecContext(ctx, `UPDATE academy_members SET honor_point = $2 WHERE char_id = $1`, charID, left)
		if err != nil {
			return fmt.Errorf("academy: spending honor: %w", err)
		}
		return nil
	})
	return left, err
}

func (s *SQLStore) CampOf(ctx context.Context, charID int64) (*Camp, error) {
	id, err := campIDOf(ctx, s.db, charID, false)
	if err != nil {
		return nil, err
	}
	c, err := loadCamp(ctx, s.db, id, false)
	if errors.Is(err, ErrNoSuchCamp) {
		return nil, ErrNotInCamp
	}
	return c, err
}

func (s *SQLStore) Get(ctx context.Context, campID int64) (*Camp, error) {
	return loadCamp(ctx, s.db, campID, false)
}

func (s *SQLStore) BuffRows(ctx context.Context, charID int64) ([]BuffRow, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT camp_id, recipient_char_id, buff_slot_idx, donor_char_id, starting_time,
		remain_buff_point, buff_type FROM academy_buff_status WHERE recipient_char_id = $1 ORDER BY buff_type, buff_slot_idx`, charID)
	if err != nil {
		return nil, fmt.Errorf("academy: reading buff rows: %w", err)
	}
	defer rows.Close()
	var out []BuffRow
	for rows.Next() {
		var b BuffRow
		if err := rows.Scan(&b.CampID, &b.RecipientID, &b.Slot, &b.DonorID, &b.Start, &b.Points, &b.Type); err != nil {
			return nil, fmt.Errorf("academy: reading buff row: %w", err)
		}
		b.Start = b.Start.In(time.Local)
		out = append(out, b)
	}
	return out, rows.Err()
}

func (s *SQLStore) Bank(ctx context.Context, charID int64) (int, error) {
	var n int
	err := s.db.QueryRowContext(ctx, `SELECT honor_point FROM academy_honor_bank WHERE char_id = $1`, charID).Scan(&n)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("academy: reading the honor bank: %w", err)
	}
	return n, nil
}

func (s *SQLStore) UpdateRanks(ctx context.Context, now time.Time) ([]RankChange, error) {
	var changes []RankChange
	err := s.inTx(ctx, func(tx *sql.Tx) error {
		rows, err := tx.QueryContext(ctx, `SELECT id, rank, evaluation_point, latest_evaluation_date FROM academy_camps ORDER BY id FOR UPDATE`)
		if err != nil {
			return fmt.Errorf("academy: reading camps: %w", err)
		}
		var all []*Camp
		for rows.Next() {
			c := &Camp{}
			if err := rows.Scan(&c.ID, &c.Rank, &c.EvaluationPoint, &c.LatestEvaluationDate); err != nil {
				rows.Close()
				return fmt.Errorf("academy: reading camp: %w", err)
			}
			all = append(all, c)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return err
		}
		ranking, ranks := RankCamps(all)
		for _, c := range all {
			if r := ranks[c.ID]; r != c.Rank {
				if _, err := tx.ExecContext(ctx, `UPDATE academy_camps SET rank = $2 WHERE id = $1`, c.ID, r); err != nil {
					return fmt.Errorf("academy: setting rank: %w", err)
				}
				changes = append(changes, RankChange{CampID: c.ID, Rank: r})
			}
		}
		if _, err := tx.ExecContext(ctx, `DELETE FROM academy_honor_rank`); err != nil {
			return fmt.Errorf("academy: clearing the ranking: %w", err)
		}
		for _, r := range ranking {
			if _, err := tx.ExecContext(ctx, `INSERT INTO academy_honor_rank (ranking, camp_id, rank) VALUES ($1,$2,$3)`,
				r.Ranking, r.CampID, r.Rank); err != nil {
				return fmt.Errorf("academy: storing the ranking: %w", err)
			}
		}
		_, err = tx.ExecContext(ctx, `INSERT INTO academy_rank_update (id, updated_at) VALUES (1, $1)
			ON CONFLICT (id) DO UPDATE SET updated_at = $1`, now.UTC())
		if err != nil {
			return fmt.Errorf("academy: stamping the update: %w", err)
		}
		return nil
	})
	return changes, err
}

func (s *SQLStore) Ranking(ctx context.Context) ([]RankRow, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT ranking, camp_id, rank FROM academy_honor_rank ORDER BY ranking`)
	if err != nil {
		return nil, fmt.Errorf("academy: reading the ranking: %w", err)
	}
	defer rows.Close()
	var out []RankRow
	for rows.Next() {
		var r RankRow
		if err := rows.Scan(&r.Ranking, &r.CampID, &r.Rank); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func (s *SQLStore) LastRankUpdate(ctx context.Context) (time.Time, error) {
	var t time.Time
	err := s.db.QueryRowContext(ctx, `SELECT updated_at FROM academy_rank_update WHERE id = 1`).Scan(&t)
	if errors.Is(err, sql.ErrNoRows) {
		return time.Time{}, nil
	}
	if err != nil {
		return time.Time{}, fmt.Errorf("academy: reading the last rank update: %w", err)
	}
	return t.In(time.Local), nil
}
