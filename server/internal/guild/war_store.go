package guild

import (
	"context"
	"errors"
	"sort"
	"sync"
	"time"
)

// Round 844 (lane V): the wars kept, as the ShardManager keeps _GUILDWAR
// (WarEndTime a wall-clock time, PointGain written on every kill) and the
// winner's reward, _GUILD.Booty (+0x8c, s:0x5c4f20) -- so a war, its points
// and an unclaimed reward survive a restart, and the 1 s check picks up where
// it was (READ m:0x43be90 _GuildWar_Begin, m:0x43c320
// _GuildWar_AccountCombatResult, m:0x438430 the end check, m:0x43ccf0
// UNJOIN, m:0x439e70 the reward's job).

// Errors of the war store.
var (
	ErrAlreadyAtWar = errors.New("guild: the two guilds are already at war")
	ErrWarNotFound  = errors.New("guild: no such war")
)

// WarStore keeps the wars. MemStore and SQLStore implement it.
type WarStore interface {
	// BeginWar stores w (its ID assigned, Started now when zero); two
	// guilds already at war give ErrAlreadyAtWar (the job's -1, m:0x43be90).
	BeginWar(ctx context.Context, w War) (*War, error)
	// Wars is every war, by ID.
	Wars(ctx context.Context) ([]War, error)
	// WarsOf is guildID's wars, by ID (the CGuild +0x3c map).
	WarsOf(ctx context.Context, guildID int64) ([]War, error)
	// WarByID is one war (ErrWarNotFound).
	WarByID(ctx context.Context, id int64) (*War, error)
	// AddWarPoints adds pts to guildID's side of war id; the war after.
	AddWarPoints(ctx context.Context, id, guildID, pts int64) (*War, error)
	// SetWarEnd moves a war's end (a GM's QA aid, OURS; zero: no end).
	SetWarEnd(ctx context.Context, id int64, end time.Time) error
	// EndWar removes war id and adds its LodgedGold to winner's booty, as
	// one step (EndOfWar, then s:0x5c4f20). winner 0 credits nobody.
	EndWar(ctx context.Context, id, winner int64) (*War, error)
	// Booty is guildID's unclaimed reward.
	Booty(ctx context.Context, guildID int64) (int64, error)
	// TakeBooty empties it and returns what was there (m:0x439e70).
	TakeBooty(ctx context.Context, guildID int64) (int64, error)
	// AddWarStats adds to a member's war counters (s:0x5cb430: the killer's
	// Contribution +0x58 and GuildWarKill +0x5c, the victim's GuildWarKilled
	// +0x60). A character in no guild is no error.
	AddWarStats(ctx context.Context, characterID, kills, killed, contribution int64) error
}

// AtWar reports whether a and b are at war in ws (CGuild slot 7,
// IsHostileGuild s:0x5d1220).
func AtWar(ctx context.Context, ws WarStore, a, b int64) bool {
	if ws == nil || a == 0 || b == 0 || a == b {
		return false
	}
	wars, err := ws.WarsOf(ctx, a)
	if err != nil {
		return false
	}
	for _, w := range wars {
		if w.Other(a) == b {
			return true
		}
	}
	return false
}

// WarBetween is a's war against b, nil when none.
func WarBetween(ctx context.Context, ws WarStore, a, b int64) *War {
	if ws == nil || a == 0 || b == 0 {
		return nil
	}
	wars, err := ws.WarsOf(ctx, a)
	if err != nil {
		return nil
	}
	for i := range wars {
		if wars[i].Other(a) == b {
			return &wars[i]
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// MemStore's wars, kept beside it (a side table, so the store's own struct is
// untouched).

type memWars struct {
	mu    sync.Mutex
	wars  map[int64]*War
	next  int64
	booty map[int64]int64
}

var memWarTables sync.Map // *MemStore -> *memWars

func (m *MemStore) warTable() *memWars {
	if v, ok := memWarTables.Load(m); ok {
		return v.(*memWars)
	}
	v, _ := memWarTables.LoadOrStore(m, &memWars{wars: map[int64]*War{}, booty: map[int64]int64{}})
	return v.(*memWars)
}

// BeginWar implements WarStore.
func (m *MemStore) BeginWar(_ context.Context, w War) (*War, error) {
	t := m.warTable()
	t.mu.Lock()
	defer t.mu.Unlock()
	for _, o := range t.wars {
		if o.Has(w.GuildA) && o.Has(w.GuildB) {
			return nil, ErrAlreadyAtWar
		}
	}
	t.next++
	w.ID = t.next
	if w.Started.IsZero() {
		w.Started = time.Now()
	}
	cp := w
	t.wars[w.ID] = &cp
	out := cp
	return &out, nil
}

func (t *memWars) sorted(keep func(*War) bool) []War {
	var out []War
	for _, w := range t.wars {
		if keep == nil || keep(w) {
			out = append(out, *w)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

// Wars implements WarStore.
func (m *MemStore) Wars(_ context.Context) ([]War, error) {
	t := m.warTable()
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.sorted(nil), nil
}

// WarsOf implements WarStore.
func (m *MemStore) WarsOf(_ context.Context, guildID int64) ([]War, error) {
	t := m.warTable()
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.sorted(func(w *War) bool { return w.Has(guildID) }), nil
}

// WarByID implements WarStore.
func (m *MemStore) WarByID(_ context.Context, id int64) (*War, error) {
	t := m.warTable()
	t.mu.Lock()
	defer t.mu.Unlock()
	w, ok := t.wars[id]
	if !ok {
		return nil, ErrWarNotFound
	}
	out := *w
	return &out, nil
}

// AddWarPoints implements WarStore.
func (m *MemStore) AddWarPoints(_ context.Context, id, guildID, pts int64) (*War, error) {
	t := m.warTable()
	t.mu.Lock()
	defer t.mu.Unlock()
	w, ok := t.wars[id]
	if !ok || !w.Has(guildID) {
		return nil, ErrWarNotFound
	}
	if w.GuildA == guildID {
		w.PointsA += pts
	} else {
		w.PointsB += pts
	}
	out := *w
	return &out, nil
}

// SetWarEnd implements WarStore.
func (m *MemStore) SetWarEnd(_ context.Context, id int64, end time.Time) error {
	t := m.warTable()
	t.mu.Lock()
	defer t.mu.Unlock()
	w, ok := t.wars[id]
	if !ok {
		return ErrWarNotFound
	}
	w.EndTime = end
	return nil
}

// EndWar implements WarStore.
func (m *MemStore) EndWar(_ context.Context, id, winner int64) (*War, error) {
	t := m.warTable()
	t.mu.Lock()
	defer t.mu.Unlock()
	w, ok := t.wars[id]
	if !ok {
		return nil, ErrWarNotFound
	}
	delete(t.wars, id)
	if winner != 0 && w.Has(winner) {
		t.booty[winner] += w.LodgedGold
	}
	out := *w
	return &out, nil
}

// Booty implements WarStore.
func (m *MemStore) Booty(_ context.Context, guildID int64) (int64, error) {
	t := m.warTable()
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.booty[guildID], nil
}

// TakeBooty implements WarStore.
func (m *MemStore) TakeBooty(_ context.Context, guildID int64) (int64, error) {
	t := m.warTable()
	t.mu.Lock()
	defer t.mu.Unlock()
	b := t.booty[guildID]
	delete(t.booty, guildID)
	return b, nil
}

// AddWarStats implements WarStore.
func (m *MemStore) AddWarStats(_ context.Context, characterID, kills, killed, contribution int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	gid, ok := m.ofChar[characterID]
	if !ok {
		return nil
	}
	g := m.byID[gid]
	for i := range g.Members {
		if g.Members[i].CharacterID == characterID {
			g.Members[i].WarKill += kills
			g.Members[i].WarKilled += killed
			g.Members[i].Contribution += contribution
		}
	}
	return nil
}
