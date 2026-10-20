package jobs

import (
	"context"
	"errors"
	"sort"
	"strings"
	"sync"
	"time"
)

// Record is one character's job: retail's _CharTrijob row (READ the
// in-memory record CInstanceCharTrijob, player+0x1fb8: +0x18 CharID, +0x1c
// kind, +0x1d level, +0x20 exp, +0x24 contribution, +0x28 reward; the row
// _AddNewChar inserts is (CharID, 0, 1, 0, 0, 0)). Two fields retail keeps
// elsewhere ride along (OURS, the place; the rules are retail's):
//   - Alias is _Char.NickName16, the job alias (CGObjPC::GetNickName, vtable
//     +0xf0, chardata+0x4c);
//   - PenaltyUntil is the timed job (category 2, id 2) a withdrawal sets for
//     604800 s (JobGuild_HandleWithdraw s:0x5124b8, 0x93a80), which
//     HasTimedJob(2,2) tests at a join (0x4824). Retail keeps it in _TimedJob;
//     OpenSRO's timed jobs live in memory, so the penalty is kept here and
//     survives a restart as retail's does.
type Record struct {
	CharID       int64
	Kind         Kind
	Level        int
	Exp          int64
	Contribution int64
	Reward       int64
	Alias        string
	PenaltyUntil time.Time
}

// NewRecord is the row a new character starts with (_AddNewChar.sql:
// `INSERT INTO _CharTrijob VALUES (@NewCharID, 0, 1, 0, 0, 0)`).
func NewRecord(charID int64) Record { return Record{CharID: charID, Level: 1} }

// HasJob reports a record in a job guild (kind 1..3).
func (r Record) HasJob() bool { return r.Kind.Valid() }

// Penalized reports the withdrawal's 7 days still running at now.
func (r Record) Penalized(now time.Time) bool { return now.Before(r.PenaltyUntil) }

// RankType is 0x70E4's second byte: 0 the activity ranking, 1 the
// contribution (a trader's "donation") ranking.
type RankType uint8

const (
	RankActivity     RankType = 0
	RankContribution RankType = 1
)

// RankRow is one row of the weekly ranking tables (Tab_RefRanking_*):
// activity rows carry Exp and Country, contribution rows Contribution.
type RankRow struct {
	Rank         int
	Alias        string
	Level        int
	Exp          int64
	Contribution int64
	Country      uint8
}

// OldJob is _OldTrijob's row: a level and exp per kind (_GetOldTrijobData's
// outputs, trader, robber, hunter).
type OldJob struct {
	Level [3]int
	Exp   [3]int64
}

// The store's errors.
var (
	ErrAliasTaken = errors.New("jobs: the alias is taken")
	ErrNoOldJob   = errors.New("jobs: no previous job information")
)

// Store keeps the job records, the reward pools and the weekly tables.
type Store interface {
	// Get is a character's record, NewRecord when it has none.
	Get(ctx context.Context, charID int64) (Record, error)
	// Save writes every field but the alias.
	Save(ctx context.Context, r Record) error
	// SetAlias sets (or, with "", clears) a character's alias:
	// ErrAliasTaken when another character holds it (compared without case,
	// INFERRED: SQL Server's default collation; _CanAssignThisNickName's body
	// is not in the procedure dump).
	SetAlias(ctx context.Context, charID int64, alias string) error
	// AliasFree reports whether alias is held by no character but charID
	// (_CanAssignThisNickName).
	AliasFree(ctx context.Context, charID int64, alias string) (bool, error)
	// OldJob is _GetOldTrijobData: ErrNoOldJob when the character has none.
	OldJob(ctx context.Context, charID int64) (OldJob, error)
	// DeleteOldJob is _DeleteOldTrijobData.
	DeleteOldJob(ctx context.Context, charID int64) error
	// List is every record of a kind (the weekly procedure's cursors).
	List(ctx context.Context, kind Kind) ([]Record, error)
	// AddPool is _AddTrijobReward: a reward pool (2 robbers, 3 hunters) grows.
	AddPool(ctx context.Context, pool Kind, amount int64) error
	// TakePool returns a pool and sets it to 0.
	TakePool(ctx context.Context, pool Kind) (int64, error)
	// Rankings is a kind's table of a type; SetRankings replaces it.
	Rankings(ctx context.Context, kind Kind, t RankType) ([]RankRow, error)
	SetRankings(ctx context.Context, kind Kind, t RankType, rows []RankRow) error
}

// MemStore is an in-memory Store (tests, -in-memory).
type MemStore struct {
	mu    sync.Mutex
	recs  map[int64]Record
	old   map[int64]OldJob
	pools map[Kind]int64
	ranks map[[2]int][]RankRow
}

// NewMemStore returns an empty MemStore.
func NewMemStore() *MemStore {
	return &MemStore{recs: map[int64]Record{}, old: map[int64]OldJob{}, pools: map[Kind]int64{},
		ranks: map[[2]int][]RankRow{}}
}

// Get implements Store.
func (m *MemStore) Get(_ context.Context, charID int64) (Record, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if r, ok := m.recs[charID]; ok {
		return r, nil
	}
	return NewRecord(charID), nil
}

// Save implements Store.
func (m *MemStore) Save(_ context.Context, r Record) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	r.Alias = m.recs[r.CharID].Alias
	m.recs[r.CharID] = r
	return nil
}

// SetAlias implements Store.
func (m *MemStore) SetAlias(_ context.Context, charID int64, alias string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if alias != "" {
		for id, r := range m.recs {
			if id != charID && strings.EqualFold(r.Alias, alias) {
				return ErrAliasTaken
			}
		}
	}
	r, ok := m.recs[charID]
	if !ok {
		r = NewRecord(charID)
	}
	r.Alias = alias
	m.recs[charID] = r
	return nil
}

// AliasFree implements Store.
func (m *MemStore) AliasFree(_ context.Context, charID int64, alias string) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for id, r := range m.recs {
		if id != charID && strings.EqualFold(r.Alias, alias) {
			return false, nil
		}
	}
	return true, nil
}

// OldJob implements Store.
func (m *MemStore) OldJob(_ context.Context, charID int64) (OldJob, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	o, ok := m.old[charID]
	if !ok {
		return OldJob{}, ErrNoOldJob
	}
	return o, nil
}

// PutOldJob stores a previous-job row (tests; retail's writer is not known,
// docs/protocol/jobs.md).
func (m *MemStore) PutOldJob(charID int64, o OldJob) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.old[charID] = o
}

// DeleteOldJob implements Store.
func (m *MemStore) DeleteOldJob(_ context.Context, charID int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.old, charID)
	return nil
}

// List implements Store.
func (m *MemStore) List(_ context.Context, kind Kind) ([]Record, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var out []Record
	for _, r := range m.recs {
		if r.Kind == kind {
			out = append(out, r)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CharID < out[j].CharID })
	return out, nil
}

// AddPool implements Store.
func (m *MemStore) AddPool(_ context.Context, pool Kind, amount int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.pools[pool] += amount
	return nil
}

// TakePool implements Store.
func (m *MemStore) TakePool(_ context.Context, pool Kind) (int64, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	v := m.pools[pool]
	m.pools[pool] = 0
	return v, nil
}

// Rankings implements Store.
func (m *MemStore) Rankings(_ context.Context, kind Kind, t RankType) ([]RankRow, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return append([]RankRow(nil), m.ranks[[2]int{int(kind), int(t)}]...), nil
}

// SetRankings implements Store.
func (m *MemStore) SetRankings(_ context.Context, kind Kind, t RankType, rows []RankRow) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.ranks[[2]int{int(kind), int(t)}] = append([]RankRow(nil), rows...)
	return nil
}
