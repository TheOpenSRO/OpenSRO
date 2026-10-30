package guild

import (
	"context"
	"fmt"
)

// The MemStore's round 844 union additions (union844.go): breaking a union
// and its crest.

// BreakUnion implements UnionBreaker.
func (m *MemStore) BreakUnion(_ context.Context, unionID int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	u := m.unions[unionID]
	if u == nil {
		return nil
	}
	for _, g := range u.GuildIDs() {
		delete(m.unionOf, g)
	}
	delete(m.unions, unionID)
	return nil
}

// SetUnionCrest implements UnionCrestStore.
func (m *MemStore) SetUnionCrest(_ context.Context, unionID int64, pixels []byte) (uint32, error) {
	if len(pixels) != CrestBytes {
		return 0, fmt.Errorf("guild: a crest is %d bytes, not %d", CrestBytes, len(pixels))
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	u := m.unions[unionID]
	if u == nil {
		return 0, ErrNoSuchUnion
	}
	u.crestLast++
	u.CrestRev = u.crestLast
	u.crest = append([]byte(nil), pixels...)
	return u.CrestRev, nil
}

// ClearUnionCrest implements UnionCrestStore.
func (m *MemStore) ClearUnionCrest(_ context.Context, unionID int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	u := m.unions[unionID]
	if u == nil {
		return ErrNoSuchUnion
	}
	u.CrestRev = 0
	u.crest = nil
	return nil
}

// UnionCrest implements UnionCrestStore.
func (m *MemStore) UnionCrest(_ context.Context, unionID int64) (uint32, []byte, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	u := m.unions[unionID]
	if u == nil {
		return 0, nil, ErrNoSuchUnion
	}
	if u.CrestRev == 0 {
		return 0, nil, nil
	}
	return u.CrestRev, append([]byte(nil), u.crest...), nil
}
