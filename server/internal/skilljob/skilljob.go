// Package skilljob keeps the item-started skill jobs (round 838): the buffs
// an item's use starts as a type-0 timed job, CTJ_SkillKeeper in
// SR_GameServer.exe -- a composite scroll's USU1 entry (GObjPC::FUN_0049f590)
// and a 3/3/13/1..3 item's bound skill (CGItemExpendable::UseByKind 0x0049c2b0
// cases 1-3 -> FUN_0059b8d0 -> GObjPC::FUN_0049a390(0, skill, dura / 1000)).
//
// READ: the engine's timed jobs outlive the character object -- the job's
// start (CTJ_SkillKeeper slot 12, 0x650e70) rebuilds the buff from the
// job's own __time32_t end stamp, so a relog finds the buff running with
// what is left of it. OpenSRO's buff book goes with the character
// (WorldDisconnectHandler), so the job is what remembers the buff: one row
// per (character, skill) with the moment it ends.
//
// OURS: the storage (retail keeps its timed jobs in its own tables, which
// were not read), and that a row stays after its end until the character's
// next entry drops it.
package skilljob

import (
	"context"
	"sort"
	"sync"
	"time"
)

// Job is one running item-started skill job.
type Job struct {
	CharacterID int64
	SkillID     int64
	// ItemID is the item whose use started it (logs; 0 when unknown).
	ItemID int64
	// Until is when the job, and its buff, ends.
	Until time.Time
}

// Store keeps the jobs.
type Store interface {
	// Put records a job, replacing the character's job of the same skill.
	Put(ctx context.Context, j Job) error
	// List returns the character's jobs, every one, oldest end first.
	List(ctx context.Context, characterID int64) ([]Job, error)
	// Delete drops the character's job of a skill (none is not an error).
	Delete(ctx context.Context, characterID, skillID int64) error
	// DeleteEnded drops the character's jobs that ended at or before now.
	DeleteEnded(ctx context.Context, characterID int64, now time.Time) error
}

// MemStore is the in-memory Store (a server with no database).
type MemStore struct {
	mu   sync.Mutex
	jobs map[int64]map[int64]Job
}

// NewMemStore returns an empty MemStore.
func NewMemStore() *MemStore { return &MemStore{jobs: map[int64]map[int64]Job{}} }

// Put implements Store.
func (s *MemStore) Put(_ context.Context, j Job) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	m := s.jobs[j.CharacterID]
	if m == nil {
		m = map[int64]Job{}
		s.jobs[j.CharacterID] = m
	}
	m[j.SkillID] = j
	return nil
}

// List implements Store.
func (s *MemStore) List(_ context.Context, characterID int64) ([]Job, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []Job
	for _, j := range s.jobs[characterID] {
		out = append(out, j)
	}
	sortJobs(out)
	return out, nil
}

// Delete implements Store.
func (s *MemStore) Delete(_ context.Context, characterID, skillID int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if m := s.jobs[characterID]; m != nil {
		delete(m, skillID)
		if len(m) == 0 {
			delete(s.jobs, characterID)
		}
	}
	return nil
}

// DeleteEnded implements Store.
func (s *MemStore) DeleteEnded(_ context.Context, characterID int64, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	m := s.jobs[characterID]
	for id, j := range m {
		if !now.Before(j.Until) {
			delete(m, id)
		}
	}
	if m != nil && len(m) == 0 {
		delete(s.jobs, characterID)
	}
	return nil
}

func sortJobs(js []Job) {
	sort.Slice(js, func(i, k int) bool {
		if !js[i].Until.Equal(js[k].Until) {
			return js[i].Until.Before(js[k].Until)
		}
		return js[i].SkillID < js[k].SkillID
	})
}
