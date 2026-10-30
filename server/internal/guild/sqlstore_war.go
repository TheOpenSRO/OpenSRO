package guild

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"sync"
	"time"
)

// The SQLStore's wars (round 844, lane V; war_store.go). Its tables are made
// here, the first time a war method runs (CREATE TABLE IF NOT EXISTS), so a
// database needs no migration: guild_wars is _GUILDWAR (WarType,
// VictoryPointIndex, LodgedGold, WarEndTime NULL for none, the two guilds,
// their PointGain) and guild_war_booty _GUILD.Booty.
const warSchema = `
CREATE TABLE IF NOT EXISTS guild_wars (
	id            BIGSERIAL PRIMARY KEY,
	war_type      INTEGER NOT NULL DEFAULT 0,
	victory_index INTEGER NOT NULL DEFAULT 0,
	lodged_gold   BIGINT NOT NULL DEFAULT 0,
	war_end_time  TIMESTAMPTZ,
	guild_a       BIGINT NOT NULL REFERENCES guilds(id) ON DELETE CASCADE,
	guild_b       BIGINT NOT NULL REFERENCES guilds(id) ON DELETE CASCADE,
	points_a      BIGINT NOT NULL DEFAULT 0,
	points_b      BIGINT NOT NULL DEFAULT 0,
	started_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS guild_wars_a ON guild_wars(guild_a);
CREATE INDEX IF NOT EXISTS guild_wars_b ON guild_wars(guild_b);
CREATE TABLE IF NOT EXISTS guild_war_booty (
	guild_id BIGINT PRIMARY KEY REFERENCES guilds(id) ON DELETE CASCADE,
	booty    BIGINT NOT NULL DEFAULT 0
);
`

var warSchemaDone sync.Map // *sql.DB -> *sync.Once with its error

type warSchemaState struct {
	once sync.Once
	err  error
}

func (s *SQLStore) warSchema(ctx context.Context) error {
	v, _ := warSchemaDone.LoadOrStore(s.db, &warSchemaState{})
	st := v.(*warSchemaState)
	st.once.Do(func() {
		if _, err := s.db.ExecContext(ctx, warSchema); err != nil {
			st.err = fmt.Errorf("guild: creating the war tables: %w", err)
		}
	})
	return st.err
}

const warColumns = `id, war_type, victory_index, lodged_gold, war_end_time, guild_a, guild_b, points_a, points_b, started_at`

func scanWar(row interface{ Scan(...any) error }) (War, error) {
	var w War
	var typ, idx int
	var end sql.NullTime
	err := row.Scan(&w.ID, &typ, &idx, &w.LodgedGold, &end, &w.GuildA, &w.GuildB, &w.PointsA, &w.PointsB, &w.Started)
	w.Type, w.VictoryIndex = byte(typ), byte(idx)
	if end.Valid {
		w.EndTime = end.Time
	}
	return w, err
}

func endArg(t time.Time) any {
	if t.IsZero() {
		return nil
	}
	return t
}

// BeginWar implements WarStore.
func (s *SQLStore) BeginWar(ctx context.Context, w War) (*War, error) {
	if err := s.warSchema(ctx); err != nil {
		return nil, err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("guild: beginning transaction: %w", err)
	}
	defer tx.Rollback()
	// Both guilds locked, in id order, so two declarations cannot cross.
	lo, hi := w.GuildA, w.GuildB
	if hi < lo {
		lo, hi = hi, lo
	}
	for _, id := range []int64{lo, hi} {
		var one int
		if err := tx.QueryRowContext(ctx, `SELECT 1 FROM guilds WHERE id = $1 FOR UPDATE`, id).Scan(&one); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				return nil, ErrGuildNotFound
			}
			return nil, fmt.Errorf("guild: locking a guild: %w", err)
		}
	}
	var n int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM guild_wars
		WHERE (guild_a = $1 AND guild_b = $2) OR (guild_a = $2 AND guild_b = $1)`, w.GuildA, w.GuildB).Scan(&n); err != nil {
		return nil, fmt.Errorf("guild: reading wars: %w", err)
	}
	if n > 0 {
		return nil, ErrAlreadyAtWar
	}
	if w.Started.IsZero() {
		w.Started = time.Now()
	}
	row := tx.QueryRowContext(ctx, `INSERT INTO guild_wars (war_type, victory_index, lodged_gold, war_end_time, guild_a, guild_b, points_a, points_b, started_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) RETURNING `+warColumns,
		int(w.Type), int(w.VictoryIndex), w.LodgedGold, endArg(w.EndTime), w.GuildA, w.GuildB, w.PointsA, w.PointsB, w.Started)
	out, err := scanWar(row)
	if err != nil {
		return nil, fmt.Errorf("guild: storing the war: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("guild: committing the war: %w", err)
	}
	return &out, nil
}

func (s *SQLStore) queryWars(ctx context.Context, where string, args ...any) ([]War, error) {
	if err := s.warSchema(ctx); err != nil {
		return nil, err
	}
	rows, err := s.db.QueryContext(ctx, `SELECT `+warColumns+` FROM guild_wars `+where+` ORDER BY id`, args...)
	if err != nil {
		return nil, fmt.Errorf("guild: reading wars: %w", err)
	}
	defer rows.Close()
	var out []War
	for rows.Next() {
		w, err := scanWar(rows)
		if err != nil {
			return nil, fmt.Errorf("guild: reading a war: %w", err)
		}
		out = append(out, w)
	}
	return out, rows.Err()
}

// Wars implements WarStore.
func (s *SQLStore) Wars(ctx context.Context) ([]War, error) {
	return s.queryWars(ctx, "")
}

// WarsOf implements WarStore.
func (s *SQLStore) WarsOf(ctx context.Context, guildID int64) ([]War, error) {
	return s.queryWars(ctx, "WHERE guild_a = $1 OR guild_b = $1", guildID)
}

// WarByID implements WarStore.
func (s *SQLStore) WarByID(ctx context.Context, id int64) (*War, error) {
	wars, err := s.queryWars(ctx, "WHERE id = $1", id)
	if err != nil {
		return nil, err
	}
	if len(wars) == 0 {
		return nil, ErrWarNotFound
	}
	return &wars[0], nil
}

// AddWarPoints implements WarStore.
func (s *SQLStore) AddWarPoints(ctx context.Context, id, guildID, pts int64) (*War, error) {
	if err := s.warSchema(ctx); err != nil {
		return nil, err
	}
	row := s.db.QueryRowContext(ctx, `UPDATE guild_wars SET
		points_a = points_a + CASE WHEN guild_a = $2 THEN $3 ELSE 0 END,
		points_b = points_b + CASE WHEN guild_a = $2 THEN 0 ELSE $3 END
		WHERE id = $1 AND (guild_a = $2 OR guild_b = $2) RETURNING `+warColumns, id, guildID, pts)
	w, err := scanWar(row)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrWarNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("guild: adding war points: %w", err)
	}
	return &w, nil
}

// SetWarEnd implements WarStore.
func (s *SQLStore) SetWarEnd(ctx context.Context, id int64, end time.Time) error {
	if err := s.warSchema(ctx); err != nil {
		return err
	}
	res, err := s.db.ExecContext(ctx, `UPDATE guild_wars SET war_end_time = $2 WHERE id = $1`, id, endArg(end))
	if err != nil {
		return fmt.Errorf("guild: moving the war's end: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrWarNotFound
	}
	return nil
}

// EndWar implements WarStore.
func (s *SQLStore) EndWar(ctx context.Context, id, winner int64) (*War, error) {
	if err := s.warSchema(ctx); err != nil {
		return nil, err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("guild: beginning transaction: %w", err)
	}
	defer tx.Rollback()
	w, err := scanWar(tx.QueryRowContext(ctx, `DELETE FROM guild_wars WHERE id = $1 RETURNING `+warColumns, id))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrWarNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("guild: ending the war: %w", err)
	}
	if winner != 0 && w.Has(winner) && w.LodgedGold > 0 {
		if _, err := tx.ExecContext(ctx, `INSERT INTO guild_war_booty (guild_id, booty) VALUES ($1, $2)
			ON CONFLICT (guild_id) DO UPDATE SET booty = guild_war_booty.booty + EXCLUDED.booty`, winner, w.LodgedGold); err != nil {
			return nil, fmt.Errorf("guild: crediting the war's reward: %w", err)
		}
	}
	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("guild: committing the war's end: %w", err)
	}
	return &w, nil
}

// Booty implements WarStore.
func (s *SQLStore) Booty(ctx context.Context, guildID int64) (int64, error) {
	if err := s.warSchema(ctx); err != nil {
		return 0, err
	}
	var b int64
	err := s.db.QueryRowContext(ctx, `SELECT booty FROM guild_war_booty WHERE guild_id = $1`, guildID).Scan(&b)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("guild: reading the war reward: %w", err)
	}
	return b, nil
}

// TakeBooty implements WarStore.
func (s *SQLStore) TakeBooty(ctx context.Context, guildID int64) (int64, error) {
	if err := s.warSchema(ctx); err != nil {
		return 0, err
	}
	var b int64
	err := s.db.QueryRowContext(ctx, `DELETE FROM guild_war_booty WHERE guild_id = $1 RETURNING booty`, guildID).Scan(&b)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("guild: taking the war reward: %w", err)
	}
	return b, nil
}

// AddWarStats implements WarStore.
func (s *SQLStore) AddWarStats(ctx context.Context, characterID, kills, killed, contribution int64) error {
	if _, err := s.db.ExecContext(ctx, `UPDATE guild_members SET war_kill = war_kill + $2,
		war_killed = war_killed + $3, contribution = contribution + $4 WHERE character_id = $1`,
		characterID, kills, killed, contribution); err != nil {
		return fmt.Errorf("guild: adding war counters: %w", err)
	}
	return nil
}
