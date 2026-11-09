package gameworld

import (
	"context"
	"database/sql"
	"fmt"
	"sort"
	"sync"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/persistence"
	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
)

// CharInstance is one _CharInstanceWorldData row (game_worlds.md 6): where a
// character is in an instance and which incarnation (the key) it is.
type CharInstance struct {
	CharID        int64
	Key           uint32
	World, Layer  uint16
	Opened        time.Time
	Region        uint16
	X, Y, Z       int32
	Activated     bool
	EnterCount    int
	LastEnterTime time.Time
}

// CharStore keeps the rows. Safe for concurrent use.
type CharStore interface {
	Put(ctx context.Context, r CharInstance) error
	// Get is the row of a character in a world.
	Get(ctx context.Context, char int64, world uint16) (CharInstance, bool, error)
	// List is a character's rows, by world.
	List(ctx context.Context, char int64) ([]CharInstance, error)
	// Delete removes a character's row of a world (READ s:0x602d50: delete
	// where CharID and WorldID).
	Delete(ctx context.Context, char int64, world uint16) error
}

// MemCharStore is a CharStore in memory (-in-memory and tests).
type MemCharStore struct {
	mu   sync.Mutex
	rows map[[2]int64]CharInstance
}

// NewMemCharStore makes an empty store.
func NewMemCharStore() *MemCharStore { return &MemCharStore{rows: map[[2]int64]CharInstance{}} }

func (m *MemCharStore) Put(_ context.Context, r CharInstance) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.rows[[2]int64{r.CharID, int64(r.World)}] = r
	return nil
}

func (m *MemCharStore) Get(_ context.Context, char int64, world uint16) (CharInstance, bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	r, ok := m.rows[[2]int64{char, int64(world)}]
	return r, ok, nil
}

func (m *MemCharStore) List(_ context.Context, char int64) ([]CharInstance, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var out []CharInstance
	for k, r := range m.rows {
		if k[0] == char {
			out = append(out, r)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].World < out[j].World })
	return out, nil
}

func (m *MemCharStore) Delete(_ context.Context, char int64, world uint16) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.rows, [2]int64{char, int64(world)})
	return nil
}

// SQLCharStore is a CharStore on PostgreSQL
// (persistence.CharInstanceWorldSchema).
type SQLCharStore struct{ db *sql.DB }

// NewSQLCharStore opens the store on a pool the caller owns, creating its
// table.
func NewSQLCharStore(db *sql.DB) (*SQLCharStore, error) {
	if err := txn.Migrate(db, persistence.CharInstanceWorldSchema); err != nil {
		return nil, fmt.Errorf("gameworld: creating schema: %w", err)
	}
	return &SQLCharStore{db: db}, nil
}

func (s *SQLCharStore) Put(ctx context.Context, r CharInstance) error {
	act := 0
	if r.Activated {
		act = 1
	}
	_, err := txn.Conn(ctx, s.db).ExecContext(ctx, `INSERT INTO char_instance_world
		(char_id, dungeon_key_id, world_id, layer_id, opened_time, region_id, pos_x, pos_y, pos_z, is_activated, enter_count, last_enter_time)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)
		ON CONFLICT (char_id, world_id) DO UPDATE SET dungeon_key_id=$2, layer_id=$4, opened_time=$5, region_id=$6,
		pos_x=$7, pos_y=$8, pos_z=$9, is_activated=$10, enter_count=$11, last_enter_time=$12`,
		r.CharID, int64(r.Key), int(r.World), int(r.Layer), r.Opened.UTC(), int(r.Region), r.X, r.Y, r.Z, act,
		r.EnterCount, r.LastEnterTime.UTC())
	if err != nil {
		return fmt.Errorf("gameworld: saving the instance row: %w", err)
	}
	return nil
}

func (s *SQLCharStore) scan(rows *sql.Rows) (CharInstance, error) {
	var r CharInstance
	var key int64
	var w, l, region, act int
	err := rows.Scan(&r.CharID, &key, &w, &l, &r.Opened, &region, &r.X, &r.Y, &r.Z, &act, &r.EnterCount, &r.LastEnterTime)
	r.Key, r.World, r.Layer, r.Region, r.Activated = uint32(key), uint16(w), uint16(l), uint16(region), act != 0
	return r, err
}

const charInstanceCols = `char_id, dungeon_key_id, world_id, layer_id, opened_time, region_id, pos_x, pos_y, pos_z, is_activated, enter_count, last_enter_time`

func (s *SQLCharStore) Get(ctx context.Context, char int64, world uint16) (CharInstance, bool, error) {
	rows, err := txn.Conn(ctx, s.db).QueryContext(ctx, `SELECT `+charInstanceCols+` FROM char_instance_world WHERE char_id=$1 AND world_id=$2`, char, int(world))
	if err != nil {
		return CharInstance{}, false, err
	}
	defer rows.Close()
	if !rows.Next() {
		return CharInstance{}, false, rows.Err()
	}
	r, err := s.scan(rows)
	return r, err == nil, err
}

func (s *SQLCharStore) List(ctx context.Context, char int64) ([]CharInstance, error) {
	rows, err := txn.Conn(ctx, s.db).QueryContext(ctx, `SELECT `+charInstanceCols+` FROM char_instance_world WHERE char_id=$1 ORDER BY world_id`, char)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []CharInstance
	for rows.Next() {
		r, err := s.scan(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func (s *SQLCharStore) Delete(ctx context.Context, char int64, world uint16) error {
	_, err := txn.Conn(ctx, s.db).ExecContext(ctx, `DELETE FROM char_instance_world WHERE char_id=$1 AND world_id=$2`, char, int(world))
	return err
}
