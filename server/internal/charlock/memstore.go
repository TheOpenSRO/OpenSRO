package charlock

import (
	"context"
	"sync"
	"time"
)

// MemStore is an in-memory Store, for tests and a server without a database
// (nothing survives a restart there, the lock included).
type MemStore struct {
	mu   sync.Mutex
	recs map[int64]*memRecord
}

type memRecord struct {
	Record
	added []time.Time // per device, when it was remembered
}

// NewMemStore returns an empty MemStore.
func NewMemStore() *MemStore {
	return &MemStore{recs: map[int64]*memRecord{}}
}

func (m *MemStore) rec(accountID int64) *memRecord {
	r := m.recs[accountID]
	if r == nil {
		r = &memRecord{}
		m.recs[accountID] = r
	}
	return r
}

// Get implements Store.
func (m *MemStore) Get(_ context.Context, accountID int64) (Record, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	r := m.recs[accountID]
	if r == nil {
		return Record{}, nil
	}
	out := r.Record
	out.PinHash = append([]byte(nil), r.PinHash...)
	out.Devices = make([][]byte, len(r.Devices))
	for i, d := range r.Devices {
		out.Devices[i] = append([]byte(nil), d...)
	}
	if len(out.PinHash) == 0 {
		out.PinHash = nil
	}
	return out, nil
}

// SetPin implements Store.
func (m *MemStore) SetPin(_ context.Context, accountID int64, hash []byte) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	r := m.rec(accountID)
	if r.HasPin() {
		return ErrPinExists
	}
	*r = memRecord{Record: Record{PinHash: append([]byte(nil), hash...)}}
	return nil
}

// ClearPin implements Store.
func (m *MemStore) ClearPin(_ context.Context, accountID int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	r := m.recs[accountID]
	if r == nil || !r.HasPin() {
		return ErrNoPin
	}
	delete(m.recs, accountID)
	return nil
}

// RecordFailure implements Store.
func (m *MemStore) RecordFailure(_ context.Context, accountID int64, max int, until time.Time) (int, time.Time, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	r := m.recs[accountID]
	if r == nil || !r.HasPin() {
		return 0, time.Time{}, ErrNoPin
	}
	r.Failures++
	if r.Failures >= max {
		r.Failures = 0
		r.LockedUntil = until
	}
	return r.Failures, r.LockedUntil, nil
}

// ResetFailures implements Store.
func (m *MemStore) ResetFailures(_ context.Context, accountID int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if r := m.recs[accountID]; r != nil {
		r.Failures = 0
	}
	return nil
}

// RememberDevice implements Store.
func (m *MemStore) RememberDevice(_ context.Context, accountID int64, tokenHash []byte, now time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	r := m.rec(accountID)
	if r.Remembers(tokenHash) {
		return nil
	}
	r.Devices = append(r.Devices, append([]byte(nil), tokenHash...))
	r.added = append(r.added, now)
	for len(r.Devices) > MaxDevices {
		r.Devices = r.Devices[1:]
		r.added = r.added[1:]
	}
	return nil
}
