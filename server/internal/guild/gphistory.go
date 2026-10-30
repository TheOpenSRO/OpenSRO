package guild

import (
	"context"
	"fmt"
	"sort"
	"sync"
	"time"
)

// Round 844 lane G (part 2): the guild's GP usage history -- the guild
// manager's line 0x43 "GP Usage History" (READ: the ShardManager's
// _AddGPHistory sm:0x43c5d0 and its load `SELECT TOP 100 * FROM _GPHistory
// WHERE GuildID = %d AND UsedTime >= (GETDATE() - 30) ORDER BY ID DESC`; past
// 100 entries _DeleteGPHistory drops the oldest). Donations and other gains
// are never logged; only GP spent is.

// The history's kinds, the window's texts (c:0x5b9d70, READ).
const (
	GPUseFortressBuff      uint8 = 0 // UIIT_STT_FORTRESS_BUFF
	GPUseFortressStructure uint8 = 1
	GPUseFortressNPC       uint8 = 2
	GPUseFortressGuard     uint8 = 3
	GPUseFortressItem      uint8 = 4
	GPUseGuildGrowth       uint8 = 5 // the level-up (sm:0x438bb0)
	GPUseGuildItem         uint8 = 6 // a guild store purchase (s:0x4e9bce)
	GPUseFortressDungeon   uint8 = 7
	GPUseMisc              uint8 = 8
)

const (
	// GPHistoryMax is the most entries a guild keeps (READ `TOP 100`, and
	// _DeleteGPHistory past it).
	GPHistoryMax = 100
	// GPHistoryDays is the window the history is read over (READ
	// `GETDATE() - 30`).
	GPHistoryDays = 30
)

// GPHistoryEntry is one use: when, who (the character's name, INFERRED),
// how much and on what.
type GPHistoryEntry struct {
	At   time.Time
	Name string
	GP   int64
	Kind uint8
}

// GPHistoryStore keeps the history.
type GPHistoryStore interface {
	AddGPHistory(ctx context.Context, guildID int64, e GPHistoryEntry) error
	// GPHistory is the last GPHistoryDays days' entries, newest first, at
	// most GPHistoryMax.
	GPHistory(ctx context.Context, guildID int64, now time.Time) ([]GPHistoryEntry, error)
}

// --- MemStore ---------------------------------------------------------------

var memGPHistory sync.Map // *MemStore -> *gpHist

type gpHist struct {
	mu sync.Mutex
	by map[int64][]GPHistoryEntry
}

func (m *MemStore) gpHist() *gpHist {
	v, _ := memGPHistory.LoadOrStore(m, &gpHist{by: map[int64][]GPHistoryEntry{}})
	return v.(*gpHist)
}

// AddGPHistory implements GPHistoryStore.
func (m *MemStore) AddGPHistory(_ context.Context, guildID int64, e GPHistoryEntry) error {
	h := m.gpHist()
	h.mu.Lock()
	defer h.mu.Unlock()
	list := append(h.by[guildID], e)
	if len(list) > GPHistoryMax {
		list = list[len(list)-GPHistoryMax:]
	}
	h.by[guildID] = list
	return nil
}

// GPHistory implements GPHistoryStore.
func (m *MemStore) GPHistory(_ context.Context, guildID int64, now time.Time) ([]GPHistoryEntry, error) {
	h := m.gpHist()
	h.mu.Lock()
	defer h.mu.Unlock()
	since := now.Add(-GPHistoryDays * 24 * time.Hour)
	var out []GPHistoryEntry
	for i := len(h.by[guildID]) - 1; i >= 0; i-- {
		if e := h.by[guildID][i]; !e.At.Before(since) {
			out = append(out, e)
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].At.After(out[j].At) })
	return out, nil
}

// --- SQLStore ---------------------------------------------------------------

// AddGPHistory implements GPHistoryStore: the row, then the oldest beyond
// GPHistoryMax dropped (_DeleteGPHistory).
func (s *SQLStore) AddGPHistory(ctx context.Context, guildID int64, e GPHistoryEntry) error {
	if err := ensureManageSchema(ctx, s.db); err != nil {
		return err
	}
	if _, err := s.db.ExecContext(ctx,
		`INSERT INTO guild_gp_history (guild_id, at, kind, amount, actor) VALUES ($1, $2, $3, $4, $5)`,
		guildID, e.At, int(e.Kind), e.GP, e.Name); err != nil {
		return fmt.Errorf("guild: adding GP history: %w", err)
	}
	if _, err := s.db.ExecContext(ctx,
		`DELETE FROM guild_gp_history WHERE guild_id = $1 AND id NOT IN
		 (SELECT id FROM guild_gp_history WHERE guild_id = $1 ORDER BY id DESC LIMIT $2)`, guildID, GPHistoryMax); err != nil {
		return fmt.Errorf("guild: trimming GP history: %w", err)
	}
	return nil
}

// GPHistory implements GPHistoryStore.
func (s *SQLStore) GPHistory(ctx context.Context, guildID int64, now time.Time) ([]GPHistoryEntry, error) {
	if err := ensureManageSchema(ctx, s.db); err != nil {
		return nil, err
	}
	rows, err := s.db.QueryContext(ctx,
		`SELECT at, actor, amount, kind FROM guild_gp_history WHERE guild_id = $1 AND at >= $2
		 ORDER BY id DESC LIMIT $3`, guildID, now.Add(-GPHistoryDays*24*time.Hour), GPHistoryMax)
	if err != nil {
		return nil, fmt.Errorf("guild: reading GP history: %w", err)
	}
	defer rows.Close()
	var out []GPHistoryEntry
	for rows.Next() {
		var e GPHistoryEntry
		var kind int
		if err := rows.Scan(&e.At, &e.Name, &e.GP, &kind); err != nil {
			return nil, err
		}
		e.Kind = uint8(kind)
		out = append(out, e)
	}
	return out, rows.Err()
}
